#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ROSA + Amazon FSx for NetApp ONTAP + NetApp Trident setup
#
# Modes:
#   1. Create a new FSx for ONTAP file system, then create SVM, then configure Trident
#   2. Use an existing FSx/SVM, then configure Trident
#
# Defaults:
#   KCTX=rosa-melb
#   AWS_REGION=ap-southeast-4
#   FSX_REGION=ap-southeast-4
###############################################################################

###############################################################################
# Helpers
###############################################################################

log() {
  echo
  echo "==> $*"
}

warn() {
  echo
  echo "WARN: $*" >&2
}

die() {
  echo
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

prompt_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local input_value

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt_text [$default_value]: " input_value
    input_value="${input_value:-$default_value}"
  else
    read -r -p "$prompt_text: " input_value
  fi

  printf -v "$var_name" '%s' "$input_value"
}

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local input_value

  read -r -s -p "$prompt_text: " input_value
  echo
  printf -v "$var_name" '%s' "$input_value"
}

prompt_secret_optional() {
  local var_name="$1"
  local prompt_text="$2"
  local input_value

  read -r -s -p "$prompt_text, leave blank to skip: " input_value
  echo
  printf -v "$var_name" '%s' "$input_value"
}

prompt_yes_no() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-false}"
  local input_value
  local label

  if [[ "$default_value" == "true" ]]; then
    label="Y/n"
  else
    label="y/N"
  fi

  read -r -p "$prompt_text [$label]: " input_value

  if [[ -z "$input_value" ]]; then
    printf -v "$var_name" '%s' "$default_value"
    return
  fi

  case "$input_value" in
    y|Y|yes|YES|Yes)
      printf -v "$var_name" '%s' "true"
      ;;
    *)
      printf -v "$var_name" '%s' "false"
      ;;
  esac
}

aws_ignore_duplicate() {
  local output
  set +e
  output="$("$@" 2>&1)"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    [[ -n "$output" ]] && echo "$output"
    return 0
  fi

  if echo "$output" | grep -q "InvalidPermission.Duplicate"; then
    echo "Rule already exists; continuing."
    return 0
  fi

  echo "$output" >&2
  return $rc
}

contains_item() {
  local needle="$1"
  shift
  local item

  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done

  return 1
}

sanitize_token() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

get_subnet_az() {
  local subnet_id="$1"

  aws ec2 describe-subnets \
    --region "$AWS_REGION" \
    --subnet-ids "$subnet_id" \
    --query 'Subnets[0].AvailabilityZone' \
    --output text
}

wait_for_fsx_available() {
  local fsx_id="$1"
  local max_attempts="${2:-90}"
  local sleep_seconds="${3:-60}"
  local lifecycle=""

  log "Waiting for FSx file system $fsx_id to become AVAILABLE"

  for ((i=1; i<=max_attempts; i++)); do
    lifecycle="$(aws fsx describe-file-systems \
      --region "$FSX_REGION" \
      --file-system-ids "$fsx_id" \
      --query 'FileSystems[0].Lifecycle' \
      --output text 2>/dev/null || true)"

    echo "Attempt $i/$max_attempts: FSx lifecycle=$lifecycle"

    case "$lifecycle" in
      AVAILABLE)
        echo "FSx file system is AVAILABLE."
        return 0
        ;;
      FAILED|MISCONFIGURED|MISCONFIGURED_UNAVAILABLE)
        aws fsx describe-file-systems \
          --region "$FSX_REGION" \
          --file-system-ids "$fsx_id" \
          --query 'FileSystems[0].{Lifecycle:Lifecycle,FailureDetails:FailureDetails,AdministrativeActions:AdministrativeActions}' \
          --output json || true
        die "FSx file system entered failure state: $lifecycle"
        ;;
    esac

    sleep "$sleep_seconds"
  done

  die "Timed out waiting for FSx file system $fsx_id to become AVAILABLE."
}

wait_for_svm_created() {
  local svm_id="$1"
  local max_attempts="${2:-60}"
  local sleep_seconds="${3:-30}"
  local lifecycle=""

  log "Waiting for SVM $svm_id to become CREATED"

  for ((i=1; i<=max_attempts; i++)); do
    lifecycle="$(aws fsx describe-storage-virtual-machines \
      --region "$FSX_REGION" \
      --storage-virtual-machine-ids "$svm_id" \
      --query 'StorageVirtualMachines[0].Lifecycle' \
      --output text 2>/dev/null || true)"

    echo "Attempt $i/$max_attempts: SVM lifecycle=$lifecycle"

    case "$lifecycle" in
      CREATED)
        echo "SVM is CREATED."
        return 0
        ;;
      FAILED|MISCONFIGURED)
        aws fsx describe-storage-virtual-machines \
          --region "$FSX_REGION" \
          --storage-virtual-machine-ids "$svm_id" \
          --query 'StorageVirtualMachines[0].{Lifecycle:Lifecycle,LifecycleTransitionReason:LifecycleTransitionReason}' \
          --output json || true
        die "SVM entered failure state: $lifecycle"
        ;;
    esac

    sleep "$sleep_seconds"
  done

  die "Timed out waiting for SVM $svm_id to become CREATED."
}

###############################################################################
# Pre-flight
###############################################################################

require_cmd oc
require_cmd aws
require_cmd awk
require_cmd sort
require_cmd tr
require_cmd base64
require_cmd sed

echo
echo "ROSA + FSx ONTAP + Trident setup"
echo "--------------------------------"

###############################################################################
# Core prompts
###############################################################################

prompt_default KCTX "OpenShift context" "rosa-melb"
prompt_default AWS_REGION "AWS/ROSA worker region" "ap-southeast-4"
prompt_default FSX_REGION "FSx region" "ap-southeast-4"

if [[ "$AWS_REGION" != "$FSX_REGION" ]]; then
  warn "AWS_REGION and FSX_REGION are different."
  warn "Create-new-FSx mode expects ROSA and FSx in the same region."
fi

prompt_yes_no CREATE_NEW_FSX "Create a new FSx for ONTAP file system?" "true"

prompt_default SVM_NAME "SVM name" "fsx"
prompt_default SVM_USERNAME "SVM admin username for Trident" "vsadmin"
prompt_secret SVM_ADMIN_PASSWORD "Enter SVM password for $SVM_USERNAME"

[[ -n "$SVM_ADMIN_PASSWORD" ]] || die "SVM password cannot be empty."

if [[ "$CREATE_NEW_FSX" == "true" ]]; then
  prompt_default FSX_NAME "New FSx file system name" "rosa-melb-fsx-ontap"
  prompt_default FSX_DEPLOYMENT_TYPE "FSx deployment type" "MULTI_AZ_1"
  prompt_default FSX_STORAGE_CAPACITY_GIB "FSx storage capacity GiB" "1024"
  prompt_default FSX_THROUGHPUT_MBPS "FSx throughput capacity MBps" "128"
  prompt_default FSX_ENDPOINT_RANGE "FSx Multi-AZ endpoint IP range" "10.1.255.0/24"
  prompt_default FSX_SG_NAME "FSx security group name" "${FSX_NAME}-sg"
  prompt_secret_optional FSX_ADMIN_PASSWORD "Enter FSx fsxadmin password"
else
  prompt_default FSX_ID "Existing FSx file system ID" ""
  [[ -n "$FSX_ID" ]] || die "Existing FSx file system ID is required."

  prompt_default SVM_ID "Existing SVM ID, or leave blank to auto-detect if this FSx has one SVM" ""
fi

prompt_default TRIDENT_NS "Trident runtime namespace" "trident"
prompt_default TRIDENT_OPERATOR_NS "Trident Operator namespace" "openshift-operators"

prompt_default BACKEND_NAME "Trident backend name" "fsx-ontap-nas"
prompt_default SECRET_NAME "Trident ONTAP secret name" "fsx-ontap-secret"
prompt_default STORAGE_CLASS_NAME "StorageClass name" "fsx-ontap-nas"

prompt_yes_no ENABLE_ISCSI_NODE_PREP "Enable Trident iSCSI nodePrep as well?" "false"
prompt_yes_no RECREATE_STORAGECLASS "Delete/recreate StorageClass if it already exists?" "false"

prompt_yes_no CREATE_TEST_PVC "Create a test PVC?" "true"
prompt_default TEST_NAMESPACE "Test namespace" "default"
prompt_default TEST_PVC_NAME "Test PVC name" "fsx-ontap-test"
prompt_default TEST_PVC_SIZE "Test PVC size" "10Gi"

prompt_yes_no CREATE_SMOKE_TEST_POD "Create a smoke-test pod that mounts the PVC?" "true"
prompt_default TEST_POD_NAME "Smoke-test pod name" "fsx-ontap-test-pod"

prompt_yes_no RUN_NODE_CONNECTIVITY_TEST "Run node connectivity test to FSx before backend creation?" "true"
prompt_yes_no ATTEMPT_OPERATOR_INSTALL "Attempt to install Trident Operator if CRD is missing?" "false"

OC=(oc --context="$KCTX")

###############################################################################
# Validate access
###############################################################################

log "Validating OpenShift and AWS access"

"${OC[@]}" whoami --show-server

aws sts get-caller-identity \
  --query '{Account:Account,Arn:Arn}' \
  --output table

###############################################################################
# Discover ROSA worker instances
###############################################################################

log "Discovering ROSA worker EC2 instance IDs"

INSTANCE_IDS=($("${OC[@]}" get nodes \
  -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' \
  | awk -F/ '{print $NF}' \
  | sort -u))

[[ ${#INSTANCE_IDS[@]} -gt 0 ]] || die "No EC2 instance IDs found from OpenShift nodes."

printf 'Worker instance IDs:\n'
printf '  %s\n' "${INSTANCE_IDS[@]}"

###############################################################################
# Validate AWS region from providerID
###############################################################################

DISCOVERED_AZ="$("${OC[@]}" get nodes \
  -o jsonpath='{.items[0].spec.providerID}' \
  | awk -F/ '{print $(NF-1)}')"

DISCOVERED_AWS_REGION="${DISCOVERED_AZ%[a-z]}"

if [[ -n "$DISCOVERED_AWS_REGION" && "$DISCOVERED_AWS_REGION" != "$AWS_REGION" ]]; then
  echo
  warn "AWS_REGION=$AWS_REGION but OpenShift node providerID suggests $DISCOVERED_AWS_REGION."
  read -r -p "Use discovered ROSA region $DISCOVERED_AWS_REGION instead? [Y/n]: " USE_DISCOVERED_REGION

  if [[ -z "$USE_DISCOVERED_REGION" || "$USE_DISCOVERED_REGION" =~ ^[Yy]$ ]]; then
    AWS_REGION="$DISCOVERED_AWS_REGION"
    echo "Using AWS_REGION=$AWS_REGION"
  fi
fi

if [[ "$CREATE_NEW_FSX" == "true" && "$AWS_REGION" != "$FSX_REGION" ]]; then
  die "Create-new-FSx mode requires AWS_REGION and FSX_REGION to match. Current: AWS_REGION=$AWS_REGION FSX_REGION=$FSX_REGION"
fi

###############################################################################
# Discover ROSA VPC/subnets/SGs
###############################################################################

log "Discovering ROSA VPC, subnets and worker security groups"

ROSA_VPCS=($(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "${INSTANCE_IDS[@]}" \
  --query 'Reservations[].Instances[].VpcId' \
  --output text | tr '\t' '\n' | sort -u))

ROSA_SUBNETS=($(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "${INSTANCE_IDS[@]}" \
  --query 'Reservations[].Instances[].SubnetId' \
  --output text | tr '\t' '\n' | sort -u))

ROSA_WORKER_SGS=($(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "${INSTANCE_IDS[@]}" \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' \
  --output text | tr '\t' '\n' | sort -u))

[[ ${#ROSA_VPCS[@]} -eq 1 ]] || die "Expected one ROSA VPC. Found: ${ROSA_VPCS[*]:-none}"
[[ ${#ROSA_SUBNETS[@]} -gt 0 ]] || die "No ROSA worker subnets found."
[[ ${#ROSA_WORKER_SGS[@]} -gt 0 ]] || die "No ROSA worker SGs found."

ROSA_VPC="${ROSA_VPCS[0]}"

echo "ROSA VPC: $ROSA_VPC"
echo "ROSA subnets:"
printf '  %s\n' "${ROSA_SUBNETS[@]}"
echo "ROSA worker SGs:"
printf '  %s\n' "${ROSA_WORKER_SGS[@]}"

log "ROSA subnet details"

aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --subnet-ids "${ROSA_SUBNETS[@]}" \
  --query 'Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' \
  --output table

###############################################################################
# Discover ROSA route tables
###############################################################################

log "Discovering ROSA route tables"

ROSA_RTBS=()

for subnet in "${ROSA_SUBNETS[@]}"; do
  rtb="$(aws ec2 describe-route-tables \
    --region "$AWS_REGION" \
    --filters "Name=association.subnet-id,Values=$subnet" \
    --query 'RouteTables[0].RouteTableId' \
    --output text)"

  if [[ -z "$rtb" || "$rtb" == "None" ]]; then
    rtb="$(aws ec2 describe-route-tables \
      --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$ROSA_VPC" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' \
      --output text)"
  fi

  [[ -n "$rtb" && "$rtb" != "None" ]] && ROSA_RTBS+=("$rtb")
done

ROSA_RTBS=($(printf '%s\n' "${ROSA_RTBS[@]}" | sort -u))

[[ ${#ROSA_RTBS[@]} -gt 0 ]] || die "No ROSA route tables found."

echo "ROSA route tables:"
printf '  %s\n' "${ROSA_RTBS[@]}"

###############################################################################
# Create or discover FSx
###############################################################################

if [[ "$CREATE_NEW_FSX" == "true" ]]; then
  log "Preparing to create new FSx for ONTAP file system"

  if [[ "$FSX_DEPLOYMENT_TYPE" == MULTI_AZ* ]]; then
    DEFAULT_PREFERRED_SUBNET="${ROSA_SUBNETS[0]}"
    PREFERRED_AZ="$(get_subnet_az "$DEFAULT_PREFERRED_SUBNET")"

    DEFAULT_STANDBY_SUBNET=""

    for subnet in "${ROSA_SUBNETS[@]}"; do
      subnet_az="$(get_subnet_az "$subnet")"
      if [[ "$subnet_az" != "$PREFERRED_AZ" ]]; then
        DEFAULT_STANDBY_SUBNET="$subnet"
        break
      fi
    done

    [[ -n "$DEFAULT_STANDBY_SUBNET" ]] || die "Could not find a second ROSA subnet in a different AZ for Multi-AZ FSx."

    prompt_default FSX_PREFERRED_SUBNET_ID "FSx preferred subnet ID" "$DEFAULT_PREFERRED_SUBNET"
    prompt_default FSX_STANDBY_SUBNET_ID "FSx standby subnet ID" "$DEFAULT_STANDBY_SUBNET"

    FSX_SUBNET_IDS=("$FSX_PREFERRED_SUBNET_ID" "$FSX_STANDBY_SUBNET_ID")
  else
    DEFAULT_PREFERRED_SUBNET="${ROSA_SUBNETS[0]}"
    prompt_default FSX_PREFERRED_SUBNET_ID "FSx subnet ID" "$DEFAULT_PREFERRED_SUBNET"
    FSX_SUBNET_IDS=("$FSX_PREFERRED_SUBNET_ID")
  fi

  log "Creating or reusing FSx security group"

  EXISTING_FSX_SG="$(aws ec2 describe-security-groups \
    --region "$FSX_REGION" \
    --filters "Name=vpc-id,Values=$ROSA_VPC" "Name=group-name,Values=$FSX_SG_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true)"

  if [[ -n "$EXISTING_FSX_SG" && "$EXISTING_FSX_SG" != "None" ]]; then
    FSX_SG="$EXISTING_FSX_SG"
    echo "Using existing FSx SG: $FSX_SG"
  else
    FSX_SG="$(aws ec2 create-security-group \
      --region "$FSX_REGION" \
      --group-name "$FSX_SG_NAME" \
      --description "FSx ONTAP access from ROSA workers" \
      --vpc-id "$ROSA_VPC" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$FSX_SG_NAME}]" \
      --query 'GroupId' \
      --output text)"

    echo "Created FSx SG: $FSX_SG"
  fi

  FSX_SGS=("$FSX_SG")

  log "Configuring FSx SG ingress before FSx creation"

  for worker_sg in "${ROSA_WORKER_SGS[@]}"; do
    aws_ignore_duplicate aws ec2 authorize-security-group-ingress \
      --region "$FSX_REGION" \
      --group-id "$FSX_SG" \
      --ip-permissions "[
        {
          \"IpProtocol\": \"tcp\",
          \"FromPort\": 443,
          \"ToPort\": 443,
          \"UserIdGroupPairs\": [
            {
              \"GroupId\": \"$worker_sg\",
              \"Description\": \"ROSA workers to FSx ONTAP management\"
            }
          ]
        }
      ]"

    aws_ignore_duplicate aws ec2 authorize-security-group-ingress \
      --region "$FSX_REGION" \
      --group-id "$FSX_SG" \
      --ip-permissions "[
        {
          \"IpProtocol\": \"tcp\",
          \"FromPort\": 2049,
          \"ToPort\": 2049,
          \"UserIdGroupPairs\": [
            {
              \"GroupId\": \"$worker_sg\",
              \"Description\": \"ROSA workers to FSx ONTAP NFS\"
            }
          ]
        }
      ]"
  done

  if [[ "$FSX_DEPLOYMENT_TYPE" == MULTI_AZ* ]]; then
    log "Tagging route tables for Amazon FSx route management"

    aws ec2 create-tags \
      --region "$AWS_REGION" \
      --resources "${ROSA_RTBS[@]}" \
      --tags Key=AmazonFSx,Value=ManagedByAmazonFSx
  fi

  FSX_CLIENT_TOKEN="create-$(sanitize_token "$FSX_NAME")"

  ONTAP_CONFIG="DeploymentType=$FSX_DEPLOYMENT_TYPE,ThroughputCapacity=$FSX_THROUGHPUT_MBPS,PreferredSubnetId=$FSX_PREFERRED_SUBNET_ID"

  if [[ "$FSX_DEPLOYMENT_TYPE" == MULTI_AZ* ]]; then
    ROUTE_TABLE_CSV="$(IFS=,; echo "${ROSA_RTBS[*]}")"
    ONTAP_CONFIG="${ONTAP_CONFIG},EndpointIpAddressRange=$FSX_ENDPOINT_RANGE,RouteTableIds=$ROUTE_TABLE_CSV"
  fi

  if [[ -n "${FSX_ADMIN_PASSWORD:-}" ]]; then
    ONTAP_CONFIG="${ONTAP_CONFIG},FsxAdminPassword=$FSX_ADMIN_PASSWORD"
  fi

  log "Creating FSx for ONTAP file system"

  echo "FSx name:              $FSX_NAME"
  echo "Deployment type:       $FSX_DEPLOYMENT_TYPE"
  echo "Storage capacity GiB:  $FSX_STORAGE_CAPACITY_GIB"
  echo "Throughput MBps:       $FSX_THROUGHPUT_MBPS"
  echo "Subnets:               ${FSX_SUBNET_IDS[*]}"
  echo "Security group:        $FSX_SG"
  echo "Client token:          $FSX_CLIENT_TOKEN"

  FSX_ID="$(aws fsx create-file-system \
    --region "$FSX_REGION" \
    --client-request-token "$FSX_CLIENT_TOKEN" \
    --file-system-type ONTAP \
    --storage-capacity "$FSX_STORAGE_CAPACITY_GIB" \
    --storage-type SSD \
    --subnet-ids "${FSX_SUBNET_IDS[@]}" \
    --security-group-ids "$FSX_SG" \
    --tags Key=Name,Value="$FSX_NAME" \
    --ontap-configuration "$ONTAP_CONFIG" \
    --query 'FileSystem.FileSystemId' \
    --output text)"

  [[ -n "$FSX_ID" && "$FSX_ID" != "None" ]] || die "FSx create-file-system did not return a FileSystemId."

  echo "FSx file system ID: $FSX_ID"

  wait_for_fsx_available "$FSX_ID"

  log "Checking whether SVM '$SVM_NAME' already exists on FSx $FSX_ID"

  EXISTING_SVM_ID="$(aws fsx describe-storage-virtual-machines \
    --region "$FSX_REGION" \
    --query "StorageVirtualMachines[?FileSystemId=='$FSX_ID' && Name=='$SVM_NAME'].StorageVirtualMachineId | [0]" \
    --output text 2>/dev/null || true)"

  if [[ -n "$EXISTING_SVM_ID" && "$EXISTING_SVM_ID" != "None" ]]; then
    SVM_ID="$EXISTING_SVM_ID"
    echo "Using existing SVM: $SVM_ID"
  else
    log "Creating SVM $SVM_NAME"

    SVM_ID="$(aws fsx create-storage-virtual-machine \
      --region "$FSX_REGION" \
      --file-system-id "$FSX_ID" \
      --name "$SVM_NAME" \
      --svm-admin-password "$SVM_ADMIN_PASSWORD" \
      --query 'StorageVirtualMachine.StorageVirtualMachineId' \
      --output text)"

    [[ -n "$SVM_ID" && "$SVM_ID" != "None" ]] || die "SVM create-storage-virtual-machine did not return a StorageVirtualMachineId."

    echo "SVM ID: $SVM_ID"
  fi

  wait_for_svm_created "$SVM_ID"

else
  log "Using existing FSx file system"

  wait_for_fsx_available "$FSX_ID"

  if [[ -z "${SVM_ID:-}" ]]; then
    log "Auto-detecting SVM for FSx file system $FSX_ID"

    SVM_IDS=($(aws fsx describe-storage-virtual-machines \
      --region "$FSX_REGION" \
      --query "StorageVirtualMachines[?FileSystemId=='$FSX_ID'].StorageVirtualMachineId" \
      --output text | tr '\t' '\n' | sort -u))

    if [[ ${#SVM_IDS[@]} -eq 1 ]]; then
      SVM_ID="${SVM_IDS[0]}"
      echo "Auto-detected SVM ID: $SVM_ID"
    else
      echo "Found SVM IDs:"
      printf '  %s\n' "${SVM_IDS[@]:-}"
      die "Could not auto-detect a single SVM. Re-run and provide SVM_ID."
    fi
  fi

  wait_for_svm_created "$SVM_ID"
fi

###############################################################################
# Discover SVM endpoints
###############################################################################

log "Discovering SVM endpoints"

SVM_NAME="$(aws fsx describe-storage-virtual-machines \
  --region "$FSX_REGION" \
  --storage-virtual-machine-ids "$SVM_ID" \
  --query 'StorageVirtualMachines[0].Name' \
  --output text)"

SVM_DNS="$(aws fsx describe-storage-virtual-machines \
  --region "$FSX_REGION" \
  --storage-virtual-machine-ids "$SVM_ID" \
  --query 'StorageVirtualMachines[0].Endpoints.Management.DNSName' \
  --output text)"

SVM_MGMT_IP="$(aws fsx describe-storage-virtual-machines \
  --region "$FSX_REGION" \
  --storage-virtual-machine-ids "$SVM_ID" \
  --query 'StorageVirtualMachines[0].Endpoints.Management.IpAddresses[0]' \
  --output text)"

SVM_NFS_DNS="$(aws fsx describe-storage-virtual-machines \
  --region "$FSX_REGION" \
  --storage-virtual-machine-ids "$SVM_ID" \
  --query 'StorageVirtualMachines[0].Endpoints.Nfs.DNSName' \
  --output text)"

SVM_NFS_IP="$(aws fsx describe-storage-virtual-machines \
  --region "$FSX_REGION" \
  --storage-virtual-machine-ids "$SVM_ID" \
  --query 'StorageVirtualMachines[0].Endpoints.Nfs.IpAddresses[0]' \
  --output text)"

[[ "$SVM_NAME" != "None" && -n "$SVM_NAME" ]] || die "Could not discover SVM name."
[[ "$SVM_DNS" != "None" && -n "$SVM_DNS" ]] || die "Could not discover SVM management DNS."
[[ "$SVM_MGMT_IP" != "None" && -n "$SVM_MGMT_IP" ]] || die "Could not discover SVM management IP."

if [[ "$SVM_NFS_DNS" == "None" || -z "$SVM_NFS_DNS" ]]; then
  SVM_NFS_DNS="$SVM_DNS"
fi

if [[ "$SVM_NFS_IP" == "None" || -z "$SVM_NFS_IP" ]]; then
  SVM_NFS_IP="$SVM_MGMT_IP"
fi

echo "FSx ID:          $FSX_ID"
echo "SVM name:        $SVM_NAME"
echo "SVM ID:          $SVM_ID"
echo "Management DNS:  $SVM_DNS"
echo "Management IP:   $SVM_MGMT_IP"
echo "NFS DNS:         $SVM_NFS_DNS"
echo "NFS IP:          $SVM_NFS_IP"

###############################################################################
# Discover FSx ENIs/VPC/SGs
###############################################################################

log "Discovering FSx ENIs and security groups"

FSX_ENIS=($(aws fsx describe-file-systems \
  --region "$FSX_REGION" \
  --file-system-ids "$FSX_ID" \
  --query 'FileSystems[0].NetworkInterfaceIds' \
  --output text | tr '\t' '\n' | sort -u))

[[ ${#FSX_ENIS[@]} -gt 0 ]] || die "No FSx ENIs found."

FSX_VPCS=($(aws ec2 describe-network-interfaces \
  --region "$FSX_REGION" \
  --network-interface-ids "${FSX_ENIS[@]}" \
  --query 'NetworkInterfaces[].VpcId' \
  --output text | tr '\t' '\n' | sort -u))

FSX_SGS=($(aws ec2 describe-network-interfaces \
  --region "$FSX_REGION" \
  --network-interface-ids "${FSX_ENIS[@]}" \
  --query 'NetworkInterfaces[].Groups[].GroupId' \
  --output text | tr '\t' '\n' | sort -u))

[[ ${#FSX_VPCS[@]} -eq 1 ]] || die "Expected one FSx VPC. Found: ${FSX_VPCS[*]:-none}"
[[ ${#FSX_SGS[@]} -gt 0 ]] || die "No FSx SGs found."

FSX_VPC="${FSX_VPCS[0]}"

FSX_DEPLOYMENT_TYPE_DISCOVERED="$(aws fsx describe-file-systems \
  --region "$FSX_REGION" \
  --file-system-ids "$FSX_ID" \
  --query 'FileSystems[0].OntapConfiguration.DeploymentType' \
  --output text)"

FSX_ENDPOINT_RANGE_DISCOVERED="$(aws fsx describe-file-systems \
  --region "$FSX_REGION" \
  --file-system-ids "$FSX_ID" \
  --query 'FileSystems[0].OntapConfiguration.EndpointIpAddressRange' \
  --output text)"

echo "FSx VPC: $FSX_VPC"
echo "FSx ENIs:"
printf '  %s\n' "${FSX_ENIS[@]}"
echo "FSx SGs:"
printf '  %s\n' "${FSX_SGS[@]}"
echo "FSx deployment type: $FSX_DEPLOYMENT_TYPE_DISCOVERED"
echo "FSx endpoint IP range: $FSX_ENDPOINT_RANGE_DISCOVERED"

###############################################################################
# Ensure FSx SG ingress
###############################################################################

log "Ensuring FSx SG ingress for TCP 443 and TCP 2049"

if [[ "$ROSA_VPC" == "$FSX_VPC" && "$AWS_REGION" == "$FSX_REGION" ]]; then
  echo "ROSA and FSx are in the same VPC/region. Using SG-to-SG ingress rules."

  for fsx_sg in "${FSX_SGS[@]}"; do
    for worker_sg in "${ROSA_WORKER_SGS[@]}"; do
      aws_ignore_duplicate aws ec2 authorize-security-group-ingress \
        --region "$FSX_REGION" \
        --group-id "$fsx_sg" \
        --ip-permissions "[
          {
            \"IpProtocol\": \"tcp\",
            \"FromPort\": 443,
            \"ToPort\": 443,
            \"UserIdGroupPairs\": [
              {
                \"GroupId\": \"$worker_sg\",
                \"Description\": \"ROSA workers to FSx ONTAP management\"
              }
            ]
          }
        ]"

      aws_ignore_duplicate aws ec2 authorize-security-group-ingress \
        --region "$FSX_REGION" \
        --group-id "$fsx_sg" \
        --ip-permissions "[
          {
            \"IpProtocol\": \"tcp\",
            \"FromPort\": 2049,
            \"ToPort\": 2049,
            \"UserIdGroupPairs\": [
              {
                \"GroupId\": \"$worker_sg\",
                \"Description\": \"ROSA workers to FSx ONTAP NFS\"
              }
            ]
          }
        ]"
    done
  done
else
  warn "ROSA and FSx are not in the same VPC/region. Using ROSA subnet CIDR ingress rules."

  ROSA_CIDRS=($(aws ec2 describe-subnets \
    --region "$AWS_REGION" \
    --subnet-ids "${ROSA_SUBNETS[@]}" \
    --query 'Subnets[].CidrBlock' \
    --output text | tr '\t' '\n' | sort -u))

  for fsx_sg in "${FSX_SGS[@]}"; do
    for cidr in "${ROSA_CIDRS[@]}"; do
      aws_ignore_duplicate aws ec2 authorize-security-group-ingress \
        --region "$FSX_REGION" \
        --group-id "$fsx_sg" \
        --ip-permissions "[
          {
            \"IpProtocol\": \"tcp\",
            \"FromPort\": 443,
            \"ToPort\": 443,
            \"IpRanges\": [
              {
                \"CidrIp\": \"$cidr\",
                \"Description\": \"ROSA worker CIDR to FSx ONTAP management\"
              }
            ]
          }
        ]"

      aws_ignore_duplicate aws ec2 authorize-security-group-ingress \
        --region "$FSX_REGION" \
        --group-id "$fsx_sg" \
        --ip-permissions "[
          {
            \"IpProtocol\": \"tcp\",
            \"FromPort\": 2049,
            \"ToPort\": 2049,
            \"IpRanges\": [
              {
                \"CidrIp\": \"$cidr\",
                \"Description\": \"ROSA worker CIDR to FSx ONTAP NFS\"
              }
            ]
          }
        ]"
    done
  done
fi

###############################################################################
# Ensure Multi-AZ route table association
###############################################################################

if [[ "$FSX_DEPLOYMENT_TYPE_DISCOVERED" == *"MULTI_AZ"* ]]; then
  if [[ "$ROSA_VPC" == "$FSX_VPC" && "$AWS_REGION" == "$FSX_REGION" ]]; then
    log "Ensuring ROSA route tables are associated with Multi-AZ FSx"

    CURRENT_FSX_RTBS=($(aws fsx describe-file-systems \
      --region "$FSX_REGION" \
      --file-system-ids "$FSX_ID" \
      --query 'FileSystems[0].OntapConfiguration.RouteTableIds' \
      --output text | tr '\t' '\n' | sort -u))

    MISSING_RTBS=()

    for rtb in "${ROSA_RTBS[@]}"; do
      if ! contains_item "$rtb" "${CURRENT_FSX_RTBS[@]:-}"; then
        MISSING_RTBS+=("$rtb")
      fi
    done

    if [[ ${#MISSING_RTBS[@]} -gt 0 ]]; then
      echo "Adding missing route tables to FSx:"
      printf '  %s\n' "${MISSING_RTBS[@]}"

      aws ec2 create-tags \
        --region "$AWS_REGION" \
        --resources "${MISSING_RTBS[@]}" \
        --tags Key=AmazonFSx,Value=ManagedByAmazonFSx

      MISSING_RTBS_CSV="$(IFS=,; echo "${MISSING_RTBS[*]}")"

      aws fsx update-file-system \
        --region "$FSX_REGION" \
        --file-system-id "$FSX_ID" \
        --ontap-configuration "AddRouteTableIds=$MISSING_RTBS_CSV"

      echo "Waiting 60 seconds for route propagation..."
      sleep 60
    else
      echo "ROSA route tables are already associated with FSx."
    fi
  else
    warn "FSx is Multi-AZ, but ROSA and FSx are not in the same VPC/region."
    warn "Skipping FSx route table association. Ensure TGW/VPC peering/VPN routing exists."
  fi
else
  echo "FSx is not Multi-AZ. Skipping FSx route table association."
fi

###############################################################################
# Optional connectivity test
###############################################################################

if [[ "$RUN_NODE_CONNECTIVITY_TEST" == "true" ]]; then
  log "Testing connectivity from a ROSA worker node to FSx"

  NODE="$("${OC[@]}" get nodes -o jsonpath='{.items[0].metadata.name}')"

  set +e
  "${OC[@]}" debug "node/$NODE" -- chroot /host /bin/bash -lc "
    echo 'DNS test:'
    getent hosts '$SVM_DNS'
    echo
    echo 'HTTPS management test:'
    curl -k --connect-timeout 5 -I 'https://$SVM_MGMT_IP'
    echo
    echo 'NFS 2049 test:'
    nc -vz -w 5 '$SVM_NFS_IP' 2049 || nc -vz -w 5 '$SVM_MGMT_IP' 2049
  "
  DEBUG_RC=$?
  set -e

  if [[ $DEBUG_RC -ne 0 ]]; then
    warn "Connectivity test failed. Continuing, but backend creation may fail if 443/2049 is still blocked."
  fi
fi

###############################################################################
# Trident namespace and operator check/install
###############################################################################

log "Creating Trident namespace"

"${OC[@]}" apply -f - <<EOF
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  name: $TRIDENT_NS
EOF

log "Checking TridentOrchestrator CRD"

if ! "${OC[@]}" get crd tridentorchestrators.trident.netapp.io >/dev/null 2>&1; then
  if [[ "$ATTEMPT_OPERATOR_INSTALL" == "true" ]]; then
    log "Attempting to install Trident Operator from OperatorHub"

    TRIDENT_PKG="$("${OC[@]}" get packagemanifests -n openshift-marketplace --no-headers 2>/dev/null \
      | awk 'BEGIN{IGNORECASE=1} /netapp.*trident|trident.*operator|trident/ {print $1; exit}')"

    [[ -n "$TRIDENT_PKG" ]] || die "Could not find Trident Operator package in OperatorHub."

    TRIDENT_CHANNEL="$("${OC[@]}" get packagemanifest "$TRIDENT_PKG" -n openshift-marketplace \
      -o jsonpath='{.status.defaultChannel}')"

    TRIDENT_SOURCE="$("${OC[@]}" get packagemanifest "$TRIDENT_PKG" -n openshift-marketplace \
      -o jsonpath='{.status.catalogSource}')"

    TRIDENT_SOURCE_NS="$("${OC[@]}" get packagemanifest "$TRIDENT_PKG" -n openshift-marketplace \
      -o jsonpath='{.status.catalogSourceNamespace}')"

    echo "Package: $TRIDENT_PKG"
    echo "Channel: $TRIDENT_CHANNEL"
    echo "Source: $TRIDENT_SOURCE"
    echo "Source namespace: $TRIDENT_SOURCE_NS"

    "${OC[@]}" apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $TRIDENT_PKG
  namespace: $TRIDENT_OPERATOR_NS
spec:
  channel: $TRIDENT_CHANNEL
  installPlanApproval: Automatic
  name: $TRIDENT_PKG
  source: $TRIDENT_SOURCE
  sourceNamespace: $TRIDENT_SOURCE_NS
EOF

    echo "Waiting for TridentOrchestrator CRD..."
    for i in {1..90}; do
      if "${OC[@]}" get crd tridentorchestrators.trident.netapp.io >/dev/null 2>&1; then
        break
      fi
      sleep 5
    done
  fi
fi

"${OC[@]}" get crd tridentorchestrators.trident.netapp.io >/dev/null 2>&1 \
  || die "Trident Operator/CRD not found. Install NetApp Trident Operator into $TRIDENT_OPERATOR_NS, then rerun."

###############################################################################
# TridentOrchestrator
###############################################################################

log "Creating/updating TridentOrchestrator"

if [[ "$ENABLE_ISCSI_NODE_PREP" == "true" ]]; then
  "${OC[@]}" apply -f - <<EOF
apiVersion: trident.netapp.io/v1
kind: TridentOrchestrator
metadata:
  name: trident
  namespace: $TRIDENT_OPERATOR_NS
spec:
  namespace: $TRIDENT_NS
  debug: false
  IPv6: false
  nodePrep:
    - iscsi
  silenceAutosupport: false
EOF
else
  "${OC[@]}" apply -f - <<EOF
apiVersion: trident.netapp.io/v1
kind: TridentOrchestrator
metadata:
  name: trident
  namespace: $TRIDENT_OPERATOR_NS
spec:
  namespace: $TRIDENT_NS
  debug: false
  IPv6: false
  silenceAutosupport: false
EOF
fi

echo "Waiting for Trident controller deployment..."
for i in {1..90}; do
  if "${OC[@]}" get deployment trident-controller -n "$TRIDENT_NS" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

"${OC[@]}" get deployment trident-controller -n "$TRIDENT_NS" >/dev/null 2>&1 \
  || die "trident-controller deployment not found."

"${OC[@]}" rollout status deployment/trident-controller -n "$TRIDENT_NS" --timeout=600s

###############################################################################
# Secret, backend, StorageClass
###############################################################################

log "Creating/updating Trident ONTAP secret"

USERNAME_B64="$(printf '%s' "$SVM_USERNAME" | base64 | tr -d '\n')"
PASSWORD_B64="$(printf '%s' "$SVM_ADMIN_PASSWORD" | base64 | tr -d '\n')"

"${OC[@]}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $TRIDENT_NS
type: Opaque
data:
  username: $USERNAME_B64
  password: $PASSWORD_B64
EOF

log "Creating/updating TridentBackendConfig"

"${OC[@]}" apply -f - <<EOF
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: $BACKEND_NAME
  namespace: $TRIDENT_NS
spec:
  version: 1
  storageDriverName: ontap-nas
  backendName: $BACKEND_NAME
  managementLIF: $SVM_DNS
  dataLIF: $SVM_NFS_DNS
  svm: $SVM_NAME
  nfsMountOptions: "vers=4.1"
  credentials:
    name: $SECRET_NAME
EOF

log "Creating/updating StorageClass"

if "${OC[@]}" get storageclass "$STORAGE_CLASS_NAME" >/dev/null 2>&1; then
  if [[ "$RECREATE_STORAGECLASS" == "true" ]]; then
    "${OC[@]}" delete storageclass "$STORAGE_CLASS_NAME"
  else
    echo "StorageClass $STORAGE_CLASS_NAME already exists. Leaving it in place."
  fi
fi

if ! "${OC[@]}" get storageclass "$STORAGE_CLASS_NAME" >/dev/null 2>&1; then
  "${OC[@]}" apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $STORAGE_CLASS_NAME
provisioner: csi.trident.netapp.io
parameters:
  backendType: ontap-nas
  storagePools: "$BACKEND_NAME:.*"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
EOF
fi

###############################################################################
# Restart Trident and wait for backend
###############################################################################

log "Restarting Trident controller"

"${OC[@]}" rollout restart deployment/trident-controller -n "$TRIDENT_NS"
"${OC[@]}" rollout status deployment/trident-controller -n "$TRIDENT_NS" --timeout=600s

log "Waiting for backend to become Bound / Success"

BACKEND_READY="false"

for i in {1..60}; do
  PHASE="$("${OC[@]}" get tbc "$BACKEND_NAME" -n "$TRIDENT_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  STATUS="$("${OC[@]}" get tbc "$BACKEND_NAME" -n "$TRIDENT_NS" -o jsonpath='{.status.lastOperationStatus}' 2>/dev/null || true)"

  if [[ "$PHASE" == "Bound" && "$STATUS" == "Success" ]]; then
    BACKEND_READY="true"
    echo "Backend is Bound / Success."
    break
  fi

  echo "Backend not ready yet. phase=$PHASE status=$STATUS"
  sleep 10
done

"${OC[@]}" get tbc "$BACKEND_NAME" -n "$TRIDENT_NS"
"${OC[@]}" describe tbc "$BACKEND_NAME" -n "$TRIDENT_NS"

if [[ "$BACKEND_READY" != "true" ]]; then
  warn "Backend did not become Bound / Success within the wait period."
  warn "Check Trident logs:"
  echo "oc --context=$KCTX logs -n $TRIDENT_NS deployment/trident-controller -c trident-main --tail=200"
fi

###############################################################################
# Test PVC
###############################################################################

if [[ "$CREATE_TEST_PVC" == "true" ]]; then
  log "Creating test PVC"

  "${OC[@]}" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $TEST_PVC_NAME
  namespace: $TEST_NAMESPACE
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: $STORAGE_CLASS_NAME
  resources:
    requests:
      storage: $TEST_PVC_SIZE
EOF

  echo "Waiting for PVC to bind..."

  PVC_BOUND="false"

  for i in {1..60}; do
    PVC_PHASE="$("${OC[@]}" get pvc "$TEST_PVC_NAME" -n "$TEST_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "$PVC_PHASE" == "Bound" ]]; then
      PVC_BOUND="true"
      echo "PVC is Bound."
      break
    fi
    echo "PVC phase: $PVC_PHASE"
    sleep 5
  done

  "${OC[@]}" get pvc "$TEST_PVC_NAME" -n "$TEST_NAMESPACE"
  "${OC[@]}" describe pvc "$TEST_PVC_NAME" -n "$TEST_NAMESPACE"

  if [[ "$PVC_BOUND" != "true" ]]; then
    warn "PVC did not bind within the wait period."
    echo "oc --context=$KCTX get events -n $TEST_NAMESPACE --sort-by=.lastTimestamp | tail -30"
  fi
fi

###############################################################################
# Smoke test pod
###############################################################################

if [[ "$CREATE_SMOKE_TEST_POD" == "true" ]]; then
  log "Creating smoke-test pod"

  "${OC[@]}" delete pod "$TEST_POD_NAME" -n "$TEST_NAMESPACE" --ignore-not-found --wait=true

  "${OC[@]}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $TEST_POD_NAME
  namespace: $TEST_NAMESPACE
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi
    command:
      - /bin/sh
      - -c
      - |
        echo "FSx ONTAP Trident smoke test: \$(date)" > /mnt/fsx/test.txt
        cat /mnt/fsx/test.txt
        sleep 3600
    volumeMounts:
    - name: fsx
      mountPath: /mnt/fsx
  volumes:
  - name: fsx
    persistentVolumeClaim:
      claimName: $TEST_PVC_NAME
EOF

  "${OC[@]}" wait --for=condition=Ready pod/"$TEST_POD_NAME" -n "$TEST_NAMESPACE" --timeout=180s || true

  echo "Smoke-test file content:"
  "${OC[@]}" exec -n "$TEST_NAMESPACE" "$TEST_POD_NAME" -- cat /mnt/fsx/test.txt || true
fi

###############################################################################
# Final status
###############################################################################

log "Final status"

"${OC[@]}" get pods -n "$TRIDENT_NS"
"${OC[@]}" get tbc -n "$TRIDENT_NS"
"${OC[@]}" get storageclass "$STORAGE_CLASS_NAME"
"${OC[@]}" get pvc "$TEST_PVC_NAME" -n "$TEST_NAMESPACE" 2>/dev/null || true

echo
echo "Created/used FSx details:"
echo "  FSx ID:          $FSX_ID"
echo "  SVM ID:          $SVM_ID"
echo "  SVM name:        $SVM_NAME"
echo "  Management DNS:  $SVM_DNS"
echo "  Management IP:   $SVM_MGMT_IP"
echo "  NFS DNS:         $SVM_NFS_DNS"
echo "  NFS IP:          $SVM_NFS_IP"
echo
echo "Useful checks:"
echo "  aws fsx describe-file-systems --region $FSX_REGION --file-system-ids $FSX_ID --query 'FileSystems[0].{Lifecycle:Lifecycle,DeploymentType:OntapConfiguration.DeploymentType,RouteTables:OntapConfiguration.RouteTableIds}' --output table"
echo "  aws fsx describe-storage-virtual-machines --region $FSX_REGION --storage-virtual-machine-ids $SVM_ID --output table"
echo "  oc --context=$KCTX get tbc $BACKEND_NAME -n $TRIDENT_NS"
echo "  oc --context=$KCTX describe tbc $BACKEND_NAME -n $TRIDENT_NS"
echo "  oc --context=$KCTX get pvc -A | grep $STORAGE_CLASS_NAME"
echo "  oc --context=$KCTX logs -n $TRIDENT_NS deployment/trident-controller -c trident-main --tail=200"
echo
echo "Completed."
