#!/usr/bin/env bash
set -euo pipefail

# Enable the Region ap-southeast-4
# aws account enable-region --region-name ap-southeast-4

########################################
# User-configurable values
########################################
ACCOUNT_ROLES_PREFIX="${ACCOUNT_ROLES_PREFIX:-ManagedOpenShift}"
OPENSHIFT_VERSION="${OPENSHIFT_VERSION:-4.20.15}"
COMPUTE_MACHINE_TYPE="${COMPUTE_MACHINE_TYPE:-m5.xlarge}"
REPLICAS="${REPLICAS:-3}"
EC2_METADATA_HTTP_TOKENS="${EC2_METADATA_HTTP_TOKENS:-optional}"

SYD_CLUSTER_NAME="${SYD_CLUSTER_NAME:-rosa-syd}"
SYD_REGION="${SYD_REGION:-ap-southeast-2}"
SYD_VPC_CIDR="${SYD_VPC_CIDR:-10.0.0.0/16}"
SYD_MACHINE_CIDR="${SYD_MACHINE_CIDR:-10.0.0.0/16}"
SYD_SERVICE_CIDR="${SYD_SERVICE_CIDR:-172.30.0.0/16}"
SYD_POD_CIDR="${SYD_POD_CIDR:-10.128.0.0/14}"
SYD_HOST_PREFIX="${SYD_HOST_PREFIX:-23}"

MEL_CLUSTER_NAME="${MEL_CLUSTER_NAME:-rosa-melb}"
MEL_REGION="${MEL_REGION:-ap-southeast-4}"
MEL_VPC_CIDR="${MEL_VPC_CIDR:-10.1.0.0/16}"
MEL_MACHINE_CIDR="${MEL_MACHINE_CIDR:-10.1.0.0/16}"
MEL_SERVICE_CIDR="${MEL_SERVICE_CIDR:-172.30.0.0/16}"
MEL_POD_CIDR="${MEL_POD_CIDR:-10.132.0.0/14}"
MEL_HOST_PREFIX="${MEL_HOST_PREFIX:-23}"

AWS_PRIMARY_REGION="${AWS_PRIMARY_REGION:-${SYD_REGION}}"

# Optional explicit override
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"

# Preferred for direct OCM API calls
OCM_API_TOKEN="${OCM_API_TOKEN:-}"

# Fallback if you only have offline token
OCM_OFFLINE_TOKEN="${OCM_OFFLINE_TOKEN:-}"

########################################
# Summary variables
########################################
SYD_ADMIN_USER=""
SYD_ADMIN_PASSWORD=""
MEL_ADMIN_USER=""
MEL_ADMIN_PASSWORD=""
SYD_VPC_ID=""
MEL_VPC_ID=""
SYD_OIDC_ID=""
MEL_OIDC_ID=""
SYD_STATUS="not-run"
MEL_STATUS="not-run"

########################################
# Helpers
########################################
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Required command not found: $1" >&2
    exit 1
  }
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local current_xtrace=0

  case "$-" in
    *x*) current_xtrace=1; set +x ;;
  esac

  read -r -s -p "${prompt_text}" "$var_name"
  echo

  if [[ "${current_xtrace}" -eq 1 ]]; then
    set -x
  fi
}

########################################
# Prerequisites
########################################
require_cmd aws
require_cmd rosa
require_cmd curl
require_cmd jq
require_cmd sed
require_cmd tail

########################################
# AWS credentials
########################################
ensure_aws_creds() {
  if aws sts get-caller-identity >/dev/null 2>&1; then
    log "Using existing AWS CLI credentials."
    return 0
  fi

  echo "Enter AWS credentials for deployment."
  read -r -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID_INPUT
  prompt_secret AWS_SECRET_ACCESS_KEY_INPUT "AWS Secret Access Key: "
  read -r -p "AWS Session Token (press Enter if not using one): " AWS_SESSION_TOKEN_INPUT

  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_INPUT}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_INPUT}"
  if [[ -n "${AWS_SESSION_TOKEN_INPUT}" ]]; then
    export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN_INPUT}"
  fi

  log "Verifying AWS credentials..."
  aws sts get-caller-identity >/dev/null
}

get_aws_account_id() {
  aws sts get-caller-identity --query 'Account' --output text
}

########################################
# OCM / ROSA auth
########################################
ensure_ocm_auth() {
  if [[ -n "${OCM_API_TOKEN}" || -n "${OCM_OFFLINE_TOKEN}" ]]; then
    return 0
  fi

  echo "Enter your OpenShift Cluster Manager token."
  echo "Preferred: OCM API token"
  echo "Fallback: ROSA offline token from https://console.redhat.com/openshift/token/rosa"
  read -r -p "Use API token or offline token? [api/offline]: " TOKEN_MODE

  case "${TOKEN_MODE}" in
    api|API)
      prompt_secret OCM_API_TOKEN "OCM API Token: "
      export OCM_API_TOKEN
      ;;
    offline|OFFLINE)
      prompt_secret OCM_OFFLINE_TOKEN "OCM Offline Token: "
      export OCM_OFFLINE_TOKEN
      ;;
    *)
      echo "ERROR: Please enter 'api' or 'offline'." >&2
      exit 1
      ;;
  esac
}

get_ocm_access_token() {
  ensure_ocm_auth

  if [[ -n "${OCM_API_TOKEN}" ]]; then
    printf '%s\n' "${OCM_API_TOKEN}"
    return 0
  fi

  curl -fsSL \
    -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token" \
    -d "client_id=cloud-services" \
    --data-urlencode "refresh_token=${OCM_OFFLINE_TOKEN}" \
    "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
    | jq -r '.access_token'
}

rosa_login_if_needed() {
  ensure_ocm_auth

  if [[ -n "${OCM_API_TOKEN}" ]]; then
    log "Logging into ROSA with OCM API token..."
    rosa login --token="${OCM_API_TOKEN}" >/dev/null
  else
    log "Logging into ROSA with offline token..."
    rosa login --token="${OCM_OFFLINE_TOKEN}" >/dev/null
  fi
}

########################################
# OCM billing lookup
########################################
get_ocm_org_id() {
  local access_token
  access_token="$(get_ocm_access_token)"

  curl -fsSL \
    -H "Authorization: Bearer ${access_token}" \
    -H "Accept: application/json" \
    "https://api.openshift.com/api/accounts_mgmt/v1/current_account" \
    | jq -r '.organization.id'
}

get_ocm_billing_accounts() {
  local org_id="$1"
  local access_token
  access_token="$(get_ocm_access_token)"

  curl -fsSL \
    -H "Authorization: Bearer ${access_token}" \
    -H "Accept: application/json" \
    "https://api.openshift.com/api/accounts_mgmt/v1/organizations/${org_id}/quota_cost?fetchCloudAccounts=true&page=1&search=quota_id%3D%27cluster%7Cbyoc%7Cmoa%7Cmarketplace%27&size=-1" \
    | jq -r '.items[].cloud_accounts[].cloud_account_id'
}

get_billing_account() {
  if [[ -n "${BILLING_ACCOUNT}" ]]; then
    printf '%s\n' "${BILLING_ACCOUNT}"
    return 0
  fi

  local org_id
  local accounts=()

  org_id="$(get_ocm_org_id)"
  mapfile -t accounts < <(get_ocm_billing_accounts "${org_id}")

  if [[ "${#accounts[@]}" -eq 0 ]]; then
    echo "ERROR: No ROSA marketplace billing accounts returned by OCM for org ${org_id}." >&2
    exit 1
  fi

  log "OCM org id: ${org_id}"
  log "Discovered ROSA billing accounts from OCM: ${accounts[*]}"

  printf '%s\n' "${accounts[0]}"
}

########################################
# Region helpers
########################################
is_opt_in_region() {
  local region="$1"
  case "${region}" in
    ap-southeast-4) return 0 ;;
    *) return 1 ;;
  esac
}

ec2_region_probe() {
  local region="$1"
  aws ec2 describe-availability-zones \
    --region "${region}" \
    --filters Name=state,Values=available \
    --query 'AvailabilityZones[0].ZoneName' \
    --output text >/dev/null 2>&1
}

get_region_opt_status() {
  local region="$1"
  aws account get-region-opt-status \
    --region-name "${region}" \
    --output json 2>/dev/null \
    | jq -r '.RegionOptStatus'
}

wait_for_region_enabled() {
  local region="$1"
  local attempts="${2:-60}"
  local sleep_seconds="${3:-10}"
  local status=""
  local i

  for ((i=1; i<=attempts; i++)); do
    status="$(get_region_opt_status "${region}" || true)"
    case "${status}" in
      ENABLED|ENABLED_BY_DEFAULT)
        log "Region ${region} is ready with status ${status}."
        return 0
        ;;
      ENABLING)
        log "Region ${region} is still enabling (${i}/${attempts})..."
        sleep "${sleep_seconds}"
        ;;
      *)
        log "Region ${region} is in status '${status:-unknown}' while waiting..."
        sleep "${sleep_seconds}"
        ;;
    esac
  done

  return 1
}

ensure_region_enabled() {
  local region="$1"
  local status=""

  # Already usable? Great.
  if ec2_region_probe "${region}"; then
    log "Region ${region} is already usable via EC2."
    return 0
  fi

  # If account API is available, use it.
  status="$(get_region_opt_status "${region}" || true)"
  case "${status}" in
    ENABLED|ENABLED_BY_DEFAULT)
      log "Region ${region} is enabled according to Account Management (${status})."
      return 0
      ;;
    ENABLING)
      log "Region ${region} is already enabling."
      if wait_for_region_enabled "${region}"; then
        return 0
      fi
      ;;
    DISABLED)
      log "Region ${region} is disabled. Attempting to enable it..."
      if aws account enable-region --region-name "${region}" >/dev/null 2>&1; then
        if wait_for_region_enabled "${region}"; then
          return 0
        fi
      fi
      ;;
  esac

  # No permissions / no luck.
  if is_opt_in_region "${region}"; then
    log "Region ${region} is not usable and cannot be queried/enabled with current credentials."
    return 1
  fi

  log "Could not query opt-in status for ${region}, but it is treated as a default region. Continuing."
  return 0
}

########################################
# IAM / OIDC helpers
########################################
role_exists() {
  local role_name="$1"
  aws iam get-role --role-name "${role_name}" >/dev/null 2>&1
}

get_existing_oidc_id_from_prefix() {
  local cluster_name="$1"
  local role_name="${cluster_name}-openshift-image-registry-installer-cloud-credentials"

  if ! role_exists "${role_name}"; then
    return 1
  fi

  aws iam get-role \
    --role-name "${role_name}" \
    --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Federated' \
    --output text \
    | sed -nE 's#.*oidc-provider/oidc\.op1\.openshiftapps\.com/([a-z0-9]+).*#\1#p'
}

operator_roles_exist() {
  local cluster_name="$1"
  local role_name="${cluster_name}-openshift-image-registry-installer-cloud-credentials"
  role_exists "${role_name}"
}

########################################
# ROSA cluster helpers
########################################
cluster_exists() {
  local cluster_name="$1"
  rosa describe cluster -c "${cluster_name}" >/dev/null 2>&1
}

ensure_cluster_oidc_id() {
  local cluster_name="$1"
  local existing_oidc

  existing_oidc="$(get_existing_oidc_id_from_prefix "${cluster_name}" || true)"
  if [[ -n "${existing_oidc}" ]]; then
    log "Reusing existing OIDC ID ${existing_oidc} for operator-role prefix ${cluster_name}"
    printf '%s\n' "${existing_oidc}"
    return 0
  fi

  create_oidc_config
}

########################################
# AWS / Network helpers
########################################
get_three_azs() {
  local region="$1"
  aws ec2 describe-availability-zones \
    --region "${region}" \
    --filters Name=state,Values=available \
    --query 'AvailabilityZones[0:3].ZoneName' \
    --output text
}

########################################
# ROSA setup
########################################
ensure_account_roles() {
  log "Ensuring ROSA account roles exist for prefix ${ACCOUNT_ROLES_PREFIX} in region ${AWS_PRIMARY_REGION}..."
  rosa create account-roles \
    --hosted-cp \
    --mode auto \
    --prefix "${ACCOUNT_ROLES_PREFIX}" \
    --region "${AWS_PRIMARY_REGION}" \
    --yes
}

create_oidc_config() {
  log "Creating OIDC config dynamically in region ${AWS_PRIMARY_REGION}..."

  local oidc_out
  local oidc_id

  oidc_out="$(
    rosa create oidc-config \
      --mode auto \
      --region "${AWS_PRIMARY_REGION}" \
      --yes 2>&1
  )"

  printf '%s\n' "${oidc_out}" >&2

  oidc_id="$(
    printf '%s\n' "${oidc_out}" \
      | sed -nE 's/.*--oidc-config-id[ =]([a-z0-9]+).*/\1/p' \
      | tail -n1
  )"

  if [[ -z "${oidc_id}" ]]; then
    oidc_id="$(
      printf '%s\n' "${oidc_out}" \
        | sed -nE 's#.*oidc-provider/oidc\.op1\.openshiftapps\.com/([a-z0-9]+).*#\1#p' \
        | tail -n1
    )"
  fi

  if [[ -z "${oidc_id}" ]]; then
    echo "ERROR: Failed to extract OIDC config ID from rosa create oidc-config output." >&2
    exit 1
  fi

  printf '%s\n' "${oidc_id}"
}

create_operator_roles_if_needed() {
  local cluster_name="$1"
  local oidc_id="$2"
  local installer_role_arn="$3"

  if operator_roles_exist "${cluster_name}"; then
    log "Operator roles already exist for prefix ${cluster_name}; skipping creation."
    return 0
  fi

  log "Creating operator roles for ${cluster_name}..."
  rosa create operator-roles \
    --hosted-cp \
    --prefix "${cluster_name}" \
    --oidc-config-id "${oidc_id}" \
    --installer-role-arn "${installer_role_arn}" \
    --region "${AWS_PRIMARY_REGION}" \
    --mode auto \
    --yes
}

create_cluster() {
  local cluster_name="$1"
  local region="$2"
  local machine_cidr="$3"
  local service_cidr="$4"
  local pod_cidr="$5"
  local host_prefix="$6"
  local subnet_csv="$7"
  local oidc_id="$8"
  local billing_account="$9"
  local installer_role_arn="${10}"
  local support_role_arn="${11}"
  local worker_role_arn="${12}"

  log "Creating ROSA cluster ${cluster_name} in ${region} with billing account ${billing_account}..."

  local create_out
  local admin_user=""
  local admin_password=""

  create_out="$(
    rosa create cluster \
      --cluster-name "${cluster_name}" \
      --mode auto \
      --create-admin-user \
      --role-arn "${installer_role_arn}" \
      --support-role-arn "${support_role_arn}" \
      --worker-iam-role "${worker_role_arn}" \
      --operator-roles-prefix "${cluster_name}" \
      --oidc-config-id "${oidc_id}" \
      --region "${region}" \
      --version "${OPENSHIFT_VERSION}" \
      --ec2-metadata-http-tokens "${EC2_METADATA_HTTP_TOKENS}" \
      --replicas "${REPLICAS}" \
      --compute-machine-type "${COMPUTE_MACHINE_TYPE}" \
      --machine-cidr "${machine_cidr}" \
      --service-cidr "${service_cidr}" \
      --pod-cidr "${pod_cidr}" \
      --host-prefix "${host_prefix}" \
      --subnet-ids "${subnet_csv}" \
      --hosted-cp \
      --billing-account "${billing_account}" \
      --yes 2>&1
  )"

  printf '%s\n' "${create_out}" >&2

  admin_user="$(
    printf '%s\n' "${create_out}" \
      | sed -nE 's/.*cluster admin user is[[:space:]]+(.+)/\1/p' \
      | tail -n1
  )"

  admin_password="$(
    printf '%s\n' "${create_out}" \
      | sed -nE 's/.*cluster admin password is[[:space:]]+(.+)/\1/p' \
      | tail -n1
  )"

  if [[ "${cluster_name}" == "${SYD_CLUSTER_NAME}" ]]; then
    SYD_ADMIN_USER="${admin_user:-created-but-not-captured}"
    SYD_ADMIN_PASSWORD="${admin_password:-created-but-not-captured}"
    SYD_STATUS="created"
  elif [[ "${cluster_name}" == "${MEL_CLUSTER_NAME}" ]]; then
    MEL_ADMIN_USER="${admin_user:-created-but-not-captured}"
    MEL_ADMIN_PASSWORD="${admin_password:-created-but-not-captured}"
    MEL_STATUS="created"
  fi
}

########################################
# VPC creation
########################################
create_vpc_stack() {
  local name="$1"
  local region="$2"
  local vpc_cidr="$3"
  local pub1_cidr="$4"
  local pub2_cidr="$5"
  local pub3_cidr="$6"
  local priv1_cidr="$7"
  local priv2_cidr="$8"
  local priv3_cidr="$9"

  log "Creating VPC for ${name} in ${region}..."

  local azs
  read -r -a azs <<< "$(get_three_azs "${region}")"
  if [[ "${#azs[@]}" -lt 3 ]]; then
    echo "ERROR: Need at least 3 AZs in ${region}." >&2
    exit 1
  fi

  local az1="${azs[0]}"
  local az2="${azs[1]}"
  local az3="${azs[2]}"

  local vpc_id
  vpc_id="$(aws ec2 create-vpc \
    --cidr-block "${vpc_cidr}" \
    --region "${region}" \
    --query 'Vpc.VpcId' \
    --output text)"

  aws ec2 modify-vpc-attribute --vpc-id "${vpc_id}" --enable-dns-support --region "${region}" >/dev/null
  aws ec2 modify-vpc-attribute --vpc-id "${vpc_id}" --enable-dns-hostnames --region "${region}" >/dev/null
  aws ec2 create-tags --resources "${vpc_id}" --region "${region}" --tags Key=Name,Value="${name}-vpc" >/dev/null

  local pub1 pub2 pub3 priv1 priv2 priv3
  pub1="$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${pub1_cidr}"  --availability-zone "${az1}" --region "${region}" --query 'Subnet.SubnetId' --output text)"
  pub2="$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${pub2_cidr}"  --availability-zone "${az2}" --region "${region}" --query 'Subnet.SubnetId' --output text)"
  pub3="$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${pub3_cidr}"  --availability-zone "${az3}" --region "${region}" --query 'Subnet.SubnetId' --output text)"
  priv1="$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${priv1_cidr}" --availability-zone "${az1}" --region "${region}" --query 'Subnet.SubnetId' --output text)"
  priv2="$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${priv2_cidr}" --availability-zone "${az2}" --region "${region}" --query 'Subnet.SubnetId' --output text)"
  priv3="$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${priv3_cidr}" --availability-zone "${az3}" --region "${region}" --query 'Subnet.SubnetId' --output text)"

  for subnet in "${pub1}" "${pub2}" "${pub3}"; do
    aws ec2 modify-subnet-attribute --subnet-id "${subnet}" --map-public-ip-on-launch --region "${region}" >/dev/null
  done

  aws ec2 create-tags --resources "${pub1}"  --region "${region}" --tags Key=Name,Value="${name}-public-a"  Key=kubernetes.io/role/elb,Value=1 >/dev/null
  aws ec2 create-tags --resources "${pub2}"  --region "${region}" --tags Key=Name,Value="${name}-public-b"  Key=kubernetes.io/role/elb,Value=1 >/dev/null
  aws ec2 create-tags --resources "${pub3}"  --region "${region}" --tags Key=Name,Value="${name}-public-c"  Key=kubernetes.io/role/elb,Value=1 >/dev/null
  aws ec2 create-tags --resources "${priv1}" --region "${region}" --tags Key=Name,Value="${name}-private-a" Key=kubernetes.io/role/internal-elb,Value=1 >/dev/null
  aws ec2 create-tags --resources "${priv2}" --region "${region}" --tags Key=Name,Value="${name}-private-b" Key=kubernetes.io/role/internal-elb,Value=1 >/dev/null
  aws ec2 create-tags --resources "${priv3}" --region "${region}" --tags Key=Name,Value="${name}-private-c" Key=kubernetes.io/role/internal-elb,Value=1 >/dev/null

  local igw
  igw="$(aws ec2 create-internet-gateway --region "${region}" --query 'InternetGateway.InternetGatewayId' --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "${igw}" --vpc-id "${vpc_id}" --region "${region}" >/dev/null

  local public_rt
  public_rt="$(aws ec2 create-route-table --vpc-id "${vpc_id}" --region "${region}" --query 'RouteTable.RouteTableId' --output text)"
  aws ec2 create-route --route-table-id "${public_rt}" --destination-cidr-block 0.0.0.0/0 --gateway-id "${igw}" --region "${region}" >/dev/null

  for subnet in "${pub1}" "${pub2}" "${pub3}"; do
    aws ec2 associate-route-table --subnet-id "${subnet}" --route-table-id "${public_rt}" --region "${region}" >/dev/null
  done

  local eip_alloc nat_gw private_rt
  eip_alloc="$(aws ec2 allocate-address --domain vpc --region "${region}" --query 'AllocationId' --output text)"
  nat_gw="$(aws ec2 create-nat-gateway --subnet-id "${pub1}" --allocation-id "${eip_alloc}" --region "${region}" --query 'NatGateway.NatGatewayId' --output text)"
  aws ec2 wait nat-gateway-available --nat-gateway-ids "${nat_gw}" --region "${region}"

  private_rt="$(aws ec2 create-route-table --vpc-id "${vpc_id}" --region "${region}" --query 'RouteTable.RouteTableId' --output text)"
  aws ec2 create-route --route-table-id "${private_rt}" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${nat_gw}" --region "${region}" >/dev/null

  for subnet in "${priv1}" "${priv2}" "${priv3}"; do
    aws ec2 associate-route-table --subnet-id "${subnet}" --route-table-id "${private_rt}" --region "${region}" >/dev/null
  done

  printf '%s\n' "${vpc_id}|${pub1},${pub2},${pub3},${priv1},${priv2},${priv3}"
}

########################################
# Per-cluster workflow
########################################
deploy_cluster_if_missing() {
  local cluster_name="$1"
  local region="$2"
  local vpc_cidr="$3"
  local machine_cidr="$4"
  local service_cidr="$5"
  local pod_cidr="$6"
  local host_prefix="$7"
  local pub1="$8"
  local pub2="$9"
  local pub3="${10}"
  local priv1="${11}"
  local priv2="${12}"
  local priv3="${13}"

  if ! ensure_region_enabled "${region}"; then
    log "Skipping ${cluster_name} because region ${region} is not available."
    if [[ "${cluster_name}" == "${SYD_CLUSTER_NAME}" ]]; then
      SYD_STATUS="skipped-region-unavailable"
      SYD_ADMIN_USER="skipped"
      SYD_ADMIN_PASSWORD="region-unavailable"
    elif [[ "${cluster_name}" == "${MEL_CLUSTER_NAME}" ]]; then
      MEL_STATUS="skipped-region-unavailable"
      MEL_ADMIN_USER="skipped"
      MEL_ADMIN_PASSWORD="region-unavailable"
    fi
    return 0
  fi

  if cluster_exists "${cluster_name}"; then
    log "Cluster ${cluster_name} already exists; skipping cluster creation."
    if [[ "${cluster_name}" == "${SYD_CLUSTER_NAME}" ]]; then
      SYD_STATUS="already-exists"
      SYD_ADMIN_USER="existing-cluster"
      SYD_ADMIN_PASSWORD="not-retrieved"
    elif [[ "${cluster_name}" == "${MEL_CLUSTER_NAME}" ]]; then
      MEL_STATUS="already-exists"
      MEL_ADMIN_USER="existing-cluster"
      MEL_ADMIN_PASSWORD="not-retrieved"
    fi
    return 0
  fi

  local oidc_id
  local result
  local vpc_id
  local subnets_csv

  oidc_id="$(ensure_cluster_oidc_id "${cluster_name}")"
  log "${cluster_name} OIDC_ID=${oidc_id}"

  result="$(create_vpc_stack \
    "${cluster_name}" \
    "${region}" \
    "${vpc_cidr}" \
    "${pub1}" "${pub2}" "${pub3}" \
    "${priv1}" "${priv2}" "${priv3}")"

  vpc_id="${result%%|*}"
  subnets_csv="${result##*|}"

  log "${cluster_name} VPC_ID=${vpc_id}"
  log "${cluster_name} SUBNETS=${subnets_csv}"

  if [[ "${cluster_name}" == "${SYD_CLUSTER_NAME}" ]]; then
    SYD_VPC_ID="${vpc_id}"
    SYD_OIDC_ID="${oidc_id}"
  elif [[ "${cluster_name}" == "${MEL_CLUSTER_NAME}" ]]; then
    MEL_VPC_ID="${vpc_id}"
    MEL_OIDC_ID="${oidc_id}"
  fi

  create_operator_roles_if_needed "${cluster_name}" "${oidc_id}" "${INSTALLER_ROLE_ARN}"
  create_cluster \
    "${cluster_name}" \
    "${region}" \
    "${machine_cidr}" \
    "${service_cidr}" \
    "${pod_cidr}" \
    "${host_prefix}" \
    "${subnets_csv}" \
    "${oidc_id}" \
    "${BILLING_ACCOUNT}" \
    "${INSTALLER_ROLE_ARN}" \
    "${SUPPORT_ROLE_ARN}" \
    "${WORKER_ROLE_ARN}"
}

########################################
# Main
########################################
ensure_aws_creds
ensure_ocm_auth

export AWS_REGION="${AWS_PRIMARY_REGION}"
export AWS_DEFAULT_REGION="${AWS_PRIMARY_REGION}"

rosa_login_if_needed

AWS_ACCOUNT_ID="$(get_aws_account_id)"
BILLING_ACCOUNT="$(get_billing_account)"

INSTALLER_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role"
SUPPORT_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Support-Role"
WORKER_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Worker-Role"

log "Discovered AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}"
log "Selected BILLING_ACCOUNT=${BILLING_ACCOUNT}"
log "Using AWS_PRIMARY_REGION=${AWS_PRIMARY_REGION}"

ensure_account_roles

deploy_cluster_if_missing \
  "${SYD_CLUSTER_NAME}" \
  "${SYD_REGION}" \
  "${SYD_VPC_CIDR}" \
  "${SYD_MACHINE_CIDR}" \
  "${SYD_SERVICE_CIDR}" \
  "${SYD_POD_CIDR}" \
  "${SYD_HOST_PREFIX}" \
  "10.0.1.0/24" "10.0.2.0/24" "10.0.3.0/24" \
  "10.0.11.0/24" "10.0.12.0/24" "10.0.13.0/24"

deploy_cluster_if_missing \
  "${MEL_CLUSTER_NAME}" \
  "${MEL_REGION}" \
  "${MEL_VPC_CIDR}" \
  "${MEL_MACHINE_CIDR}" \
  "${MEL_SERVICE_CIDR}" \
  "${MEL_POD_CIDR}" \
  "${MEL_HOST_PREFIX}" \
  "10.1.1.0/24" "10.1.2.0/24" "10.1.3.0/24" \
  "10.1.11.0/24" "10.1.12.0/24" "10.1.13.0/24"

echo
echo "Done."
echo "AWS account:         ${AWS_ACCOUNT_ID}"
echo "Billing account:     ${BILLING_ACCOUNT}"
echo
echo "Sydney status:       ${SYD_STATUS}"
echo "Sydney cluster:      ${SYD_CLUSTER_NAME}"
echo "Sydney OIDC:         ${SYD_OIDC_ID:-n/a}"
echo "Sydney VPC:          ${SYD_VPC_ID:-n/a}"
echo "Sydney admin user:   ${SYD_ADMIN_USER:-n/a}"
echo "Sydney password:     ${SYD_ADMIN_PASSWORD:-n/a}"
echo
echo "Melbourne status:    ${MEL_STATUS}"
echo "Melbourne cluster:   ${MEL_CLUSTER_NAME}"
echo "Melbourne OIDC:      ${MEL_OIDC_ID:-n/a}"
echo "Melbourne VPC:       ${MEL_VPC_ID:-n/a}"
echo "Melbourne admin user:${MEL_ADMIN_USER:-n/a}"
echo "Melbourne password:  ${MEL_ADMIN_PASSWORD:-n/a}"
echo
echo "Check status with:"
echo "  rosa list clusters"
echo "  rosa describe cluster -c ${SYD_CLUSTER_NAME}"
echo "  rosa describe cluster -c ${MEL_CLUSTER_NAME}"
echo "  rosa logs install -c ${SYD_CLUSTER_NAME}"
echo "  rosa logs install -c ${MEL_CLUSTER_NAME}"
