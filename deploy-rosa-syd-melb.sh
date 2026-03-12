#!/usr/bin/env bash
set -euo pipefail

########################################
# User-configurable values
########################################
AWS_ACCOUNT_ID="034362043716"
ACCOUNT_ROLES_PREFIX="ManagedOpenShift"
OIDC_ID="26anjg402drs6v8iq1bmq9m1sbj5j0d8"
BILLING_ACCOUNT="029648341837"
OPENSHIFT_VERSION="4.20.15"
COMPUTE_MACHINE_TYPE="m5.xlarge"
REPLICAS="3"
EC2_METADATA_HTTP_TOKENS="optional"

SYD_CLUSTER_NAME="rosa-syd"
SYD_REGION="ap-southeast-2"
SYD_VPC_CIDR="10.0.0.0/16"
SYD_MACHINE_CIDR="10.0.0.0/16"
SYD_SERVICE_CIDR="172.30.0.0/16"
SYD_POD_CIDR="10.128.0.0/14"
SYD_HOST_PREFIX="23"

MEL_CLUSTER_NAME="rosa-melb"
MEL_REGION="ap-southeast-4"
MEL_VPC_CIDR="10.1.0.0/16"
MEL_MACHINE_CIDR="10.1.0.0/16"
MEL_SERVICE_CIDR="172.30.0.0/16"
MEL_POD_CIDR="10.132.0.0/14"
MEL_HOST_PREFIX="23"

########################################
# Prompt for AWS credentials
########################################
echo "Enter AWS credentials for deployment."
read -r -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID_INPUT
read -r -s -p "AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY_INPUT
echo
read -r -p "AWS Session Token (press Enter if not using one): " AWS_SESSION_TOKEN_INPUT

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_INPUT}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_INPUT}"
if [[ -n "${AWS_SESSION_TOKEN_INPUT}" ]]; then
  export AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN_INPUT}"
fi

echo "Verifying AWS credentials..."
aws sts get-caller-identity >/dev/null

########################################
# ROSA login
########################################
echo "Logging into ROSA..."
rosa login --use-auth-code

########################################
# Helper functions
########################################
get_three_azs() {
  local region="$1"
  aws ec2 describe-availability-zones \
    --region "${region}" \
    --filters Name=state,Values=available \
    --query 'AvailabilityZones[0:3].ZoneName' \
    --output text
}

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

  echo "Creating VPC for ${name} in ${region}..."

  local azs
  azs=($(get_three_azs "${region}"))
  if [[ "${#azs[@]}" -lt 3 ]]; then
    echo "Need at least 3 AZs in ${region}."
    exit 1
  fi

  local az1="${azs[0]}"
  local az2="${azs[1]}"
  local az3="${azs[2]}"

  local vpc_id
  vpc_id=$(aws ec2 create-vpc \
    --cidr-block "${vpc_cidr}" \
    --region "${region}" \
    --query 'Vpc.VpcId' \
    --output text)

  aws ec2 modify-vpc-attribute --vpc-id "${vpc_id}" --enable-dns-support --region "${region}"
  aws ec2 modify-vpc-attribute --vpc-id "${vpc_id}" --enable-dns-hostnames --region "${region}"
  aws ec2 create-tags --resources "${vpc_id}" --region "${region}" --tags Key=Name,Value="${name}-vpc"

  local pub1 pub2 pub3 priv1 priv2 priv3
  pub1=$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${pub1_cidr}"  --availability-zone "${az1}" --region "${region}" --query 'Subnet.SubnetId' --output text)
  pub2=$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${pub2_cidr}"  --availability-zone "${az2}" --region "${region}" --query 'Subnet.SubnetId' --output text)
  pub3=$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${pub3_cidr}"  --availability-zone "${az3}" --region "${region}" --query 'Subnet.SubnetId' --output text)
  priv1=$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${priv1_cidr}" --availability-zone "${az1}" --region "${region}" --query 'Subnet.SubnetId' --output text)
  priv2=$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${priv2_cidr}" --availability-zone "${az2}" --region "${region}" --query 'Subnet.SubnetId' --output text)
  priv3=$(aws ec2 create-subnet --vpc-id "${vpc_id}" --cidr-block "${priv3_cidr}" --availability-zone "${az3}" --region "${region}" --query 'Subnet.SubnetId' --output text)

  for subnet in "${pub1}" "${pub2}" "${pub3}"; do
    aws ec2 modify-subnet-attribute --subnet-id "${subnet}" --map-public-ip-on-launch --region "${region}"
  done

  aws ec2 create-tags --resources "${pub1}"  --region "${region}" --tags Key=Name,Value="${name}-public-a"  Key=kubernetes.io/role/elb,Value=1
  aws ec2 create-tags --resources "${pub2}"  --region "${region}" --tags Key=Name,Value="${name}-public-b"  Key=kubernetes.io/role/elb,Value=1
  aws ec2 create-tags --resources "${pub3}"  --region "${region}" --tags Key=Name,Value="${name}-public-c"  Key=kubernetes.io/role/elb,Value=1
  aws ec2 create-tags --resources "${priv1}" --region "${region}" --tags Key=Name,Value="${name}-private-a" Key=kubernetes.io/role/internal-elb,Value=1
  aws ec2 create-tags --resources "${priv2}" --region "${region}" --tags Key=Name,Value="${name}-private-b" Key=kubernetes.io/role/internal-elb,Value=1
  aws ec2 create-tags --resources "${priv3}" --region "${region}" --tags Key=Name,Value="${name}-private-c" Key=kubernetes.io/role/internal-elb,Value=1

  local igw
  igw=$(aws ec2 create-internet-gateway --region "${region}" --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "${igw}" --vpc-id "${vpc_id}" --region "${region}"

  local public_rt
  public_rt=$(aws ec2 create-route-table --vpc-id "${vpc_id}" --region "${region}" --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route --route-table-id "${public_rt}" --destination-cidr-block 0.0.0.0/0 --gateway-id "${igw}" --region "${region}"

  for subnet in "${pub1}" "${pub2}" "${pub3}"; do
    aws ec2 associate-route-table --subnet-id "${subnet}" --route-table-id "${public_rt}" --region "${region}" >/dev/null
  done

  local eip_alloc nat_gw private_rt
  eip_alloc=$(aws ec2 allocate-address --domain vpc --region "${region}" --query 'AllocationId' --output text)
  nat_gw=$(aws ec2 create-nat-gateway --subnet-id "${pub1}" --allocation-id "${eip_alloc}" --region "${region}" --query 'NatGateway.NatGatewayId' --output text)
  aws ec2 wait nat-gateway-available --nat-gateway-ids "${nat_gw}" --region "${region}"

  private_rt=$(aws ec2 create-route-table --vpc-id "${vpc_id}" --region "${region}" --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route --route-table-id "${private_rt}" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${nat_gw}" --region "${region}"

  for subnet in "${priv1}" "${priv2}" "${priv3}"; do
    aws ec2 associate-route-table --subnet-id "${subnet}" --route-table-id "${private_rt}" --region "${region}" >/dev/null
  done

  echo "${vpc_id}|${pub1},${pub2},${pub3},${priv1},${priv2},${priv3}"
}

create_operator_roles() {
  local cluster_name="$1"

  echo "Creating operator roles for ${cluster_name}..."
  rosa create operator-roles \
    --hosted-cp \
    --prefix "${cluster_name}" \
    --oidc-config-id "${OIDC_ID}" \
    --installer-role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role" \
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

  echo "Creating ROSA cluster ${cluster_name}..."
  rosa create cluster \
    --cluster-name "${cluster_name}" \
    --mode auto \
    --create-admin-user \
    --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role" \
    --support-role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Support-Role" \
    --worker-iam-role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Worker-Role" \
    --operator-roles-prefix "${cluster_name}" \
    --oidc-config-id "${OIDC_ID}" \
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
    --billing-account "${BILLING_ACCOUNT}"
}

########################################
# Sydney
########################################
SYD_RESULT=$(create_vpc_stack \
  "${SYD_CLUSTER_NAME}" \
  "${SYD_REGION}" \
  "${SYD_VPC_CIDR}" \
  "10.0.1.0/24" "10.0.2.0/24" "10.0.3.0/24" \
  "10.0.11.0/24" "10.0.12.0/24" "10.0.13.0/24")

SYD_VPC_ID="${SYD_RESULT%%|*}"
SYD_SUBNETS_CSV="${SYD_RESULT##*|}"

create_operator_roles "${SYD_CLUSTER_NAME}"
create_cluster \
  "${SYD_CLUSTER_NAME}" \
  "${SYD_REGION}" \
  "${SYD_MACHINE_CIDR}" \
  "${SYD_SERVICE_CIDR}" \
  "${SYD_POD_CIDR}" \
  "${SYD_HOST_PREFIX}" \
  "${SYD_SUBNETS_CSV}"

########################################
# Melbourne
########################################
MEL_RESULT=$(create_vpc_stack \
  "${MEL_CLUSTER_NAME}" \
  "${MEL_REGION}" \
  "${MEL_VPC_CIDR}" \
  "10.1.1.0/24" "10.1.2.0/24" "10.1.3.0/24" \
  "10.1.11.0/24" "10.1.12.0/24" "10.1.13.0/24")

MEL_VPC_ID="${MEL_RESULT%%|*}"
MEL_SUBNETS_CSV="${MEL_RESULT##*|}"

create_operator_roles "${MEL_CLUSTER_NAME}"
create_cluster \
  "${MEL_CLUSTER_NAME}" \
  "${MEL_REGION}" \
  "${MEL_MACHINE_CIDR}" \
  "${MEL_SERVICE_CIDR}" \
  "${MEL_POD_CIDR}" \
  "${MEL_HOST_PREFIX}" \
  "${MEL_SUBNETS_CSV}"

########################################
# Summary
########################################
echo
echo "Done."
echo "Sydney VPC:    ${SYD_VPC_ID}"
echo "Sydney cluster:${SYD_CLUSTER_NAME}"
echo "Melbourne VPC: ${MEL_VPC_ID}"
echo "Melb cluster:  ${MEL_CLUSTER_NAME}"
echo
echo "Check status with:"
echo "  rosa list clusters"
echo "  rosa describe cluster -c ${SYD_CLUSTER_NAME}"
echo "  rosa describe cluster -c ${MEL_CLUSTER_NAME}"
echo "  rosa logs install -c ${SYD_CLUSTER_NAME}"
echo "  rosa logs install -c ${MEL_CLUSTER_NAME}"
