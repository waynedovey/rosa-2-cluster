#!/usr/bin/env bash
set -euo pipefail

#############################################
# Dynamic Portworx setup for ROSA/OpenShift on AWS
#
# Fixes included:
# - certManager.enabled=false
# - Portworx IAM role creation/update
# - IAM trust repair from actual Portworx projected token
# - Security group rules for:
#     TCP 17000-17022
#     TCP 9001-9030
# - Security groups discovered from all OpenShift nodes
# - Node labelling for selected Portworx storage nodes
# - Optional Portworx Operator install
# - Optional KubeVirt StorageClasses
#############################################

prompt() {
  local var_name="$1"
  local message="$2"
  local default_value="${3:-}"
  local input=""

  if [[ -n "$default_value" ]]; then
    read -r -p "$message [$default_value]: " input
    printf -v "$var_name" '%s' "${input:-$default_value}"
  else
    while [[ -z "$input" ]]; do
      read -r -p "$message: " input
    done
    printf -v "$var_name" '%s' "$input"
  fi
}

confirm() {
  local message="$1"
  local default="${2:-y}"
  local prompt_text="[y/N]"
  local answer=""

  if [[ "$default" == "y" ]]; then
    prompt_text="[Y/n]"
  fi

  read -r -p "$message $prompt_text: " answer
  answer="${answer:-$default}"

  [[ "$answer" =~ ^[Yy]$ ]]
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found."
    exit 1
  fi
}

trim() {
  echo "$1" | xargs
}

make_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    date +%s
  fi
}

array_contains() {
  local seeking="$1"
  shift

  local item
  for item in "$@"; do
    [[ "$item" == "$seeking" ]] && return 0
  done

  return 1
}

get_infra_id() {
  oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || true
}

get_node_provider_id() {
  local node="$1"
  oc get node "$node" -o jsonpath='{.spec.providerID}' 2>/dev/null || true
}

get_node_instance_id() {
  local node="$1"
  local provider_id
  provider_id="$(get_node_provider_id "$node")"
  echo "${provider_id##*/}"
}

detect_region_from_node() {
  local node="$1"
  local provider_id zone region

  provider_id="$(get_node_provider_id "$node")"

  # Expected AWS providerID:
  # aws:///ap-southeast-2a/i-xxxxxxxxxxxxxxxxx
  zone="$(echo "$provider_id" | awk -F/ '{print $(NF-1)}')"
  region="$(echo "$zone" | sed 's/[a-z]$//')"

  echo "$region"
}

detect_oidc_issuer() {
  local issuer

  issuer="$(oc get authentication.config.openshift.io cluster \
    -o jsonpath='{.spec.serviceAccountIssuer}' 2>/dev/null || true)"

  issuer="${issuer%/}"

  if [[ -z "$issuer" || "$issuer" == "https://kubernetes.default.svc" ]]; then
    echo ""
  else
    echo "$issuer"
  fi
}

write_initial_iam_trust_policy() {
  local file="$1"
  local oidc_hostpath="$2"
  local provider_arn="$3"
  local namespace="$4"

  cat > "$file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${provider_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_hostpath}:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "${oidc_hostpath}:sub": "system:serviceaccount:${namespace}:*"
        }
      }
    }
  ]
}
EOF
}

write_portworx_iam_policy() {
  local file="$1"

  cat > "$file" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PortworxEBSCloudDrive",
      "Effect": "Allow",
      "Action": [
        "ec2:AttachVolume",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteVolume",
        "ec2:DeleteTags",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeRegions",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumeAttribute",
        "ec2:DescribeVolumeStatus",
        "ec2:DescribeVolumesModifications",
        "ec2:DetachVolume",
        "ec2:ModifyVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot",
        "ec2:DescribeSnapshots"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

create_or_update_iam_role() {
  local role_name="$1"
  local trust_policy_file="$2"
  local permission_policy_file="$3"

  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    echo "IAM role already exists: $role_name" >&2
    echo "Updating initial trust policy..." >&2

    aws iam update-assume-role-policy \
      --role-name "$role_name" \
      --policy-document "file://${trust_policy_file}" >/dev/null
  else
    echo "Creating IAM role: $role_name" >&2

    aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document "file://${trust_policy_file}" >/dev/null
  fi

  echo "Adding/updating Portworx EBS inline IAM policy..." >&2

  aws iam put-role-policy \
    --role-name "$role_name" \
    --policy-name "${role_name}-portworx-ebs" \
    --policy-document "file://${permission_policy_file}" >/dev/null

  aws iam get-role \
    --role-name "$role_name" \
    --query 'Role.Arn' \
    --output text
}

add_sg_rule() {
  local dst_sg="$1"
  local src_sg="$2"
  local from_port="$3"
  local to_port="$4"
  local region="$5"
  local output rc

  echo "Adding SG rule: dst=$dst_sg src=$src_sg tcp/$from_port-$to_port"

  set +e
  output="$(aws ec2 authorize-security-group-ingress \
    --region "$region" \
    --group-id "$dst_sg" \
    --ip-permissions "IpProtocol=tcp,FromPort=${from_port},ToPort=${to_port},UserIdGroupPairs=[{GroupId=${src_sg}}]" 2>&1)"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    echo "  OK"
  elif echo "$output" | grep -q "InvalidPermission.Duplicate"; then
    echo "  Already exists"
  else
    echo "  ERROR adding security group rule"
    echo "$output"
    exit "$rc"
  fi
}

wait_for_crd() {
  local crd="$1"
  local retries="${2:-60}"
  local sleep_seconds="${3:-10}"

  echo "Waiting for CRD: $crd"

  for _ in $(seq 1 "$retries"); do
    if oc get crd "$crd" >/dev/null 2>&1; then
      echo "CRD found: $crd"
      return 0
    fi
    sleep "$sleep_seconds"
  done

  echo "ERROR: CRD not found after waiting: $crd"
  return 1
}

wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"
  local retries="${3:-60}"
  local sleep_seconds="${4:-10}"

  echo "Waiting for deployment/$deployment in namespace $namespace"

  for _ in $(seq 1 "$retries"); do
    if oc -n "$namespace" get deploy "$deployment" >/dev/null 2>&1; then
      oc -n "$namespace" rollout status deploy/"$deployment" --timeout=120s || true
      return 0
    fi
    sleep "$sleep_seconds"
  done

  echo "WARNING: deployment/$deployment was not found after waiting."
  return 1
}

install_portworx_operator_if_needed() {
  local namespace="$1"

  if oc -n "$namespace" get deploy portworx-operator >/dev/null 2>&1; then
    echo "Portworx Operator already installed in namespace: $namespace"
    return 0
  fi

  if ! confirm "Portworx Operator not found. Install it via OperatorHub Subscription?" "y"; then
    echo "Skipping operator install."
    return 0
  fi

  prompt PX_OPERATOR_PACKAGE "Portworx Operator package name" "portworx-certified"
  prompt PX_OPERATOR_CHANNEL "Portworx Operator channel" "stable"
  prompt PX_OPERATOR_SOURCE "Operator catalog source" "certified-operators"
  prompt PX_OPERATOR_SOURCE_NS "Operator catalog namespace" "openshift-marketplace"

  echo "Ensuring OperatorGroup exists..."

  if ! oc -n "$namespace" get operatorgroup >/dev/null 2>&1; then
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: portworx-operatorgroup
  namespace: ${namespace}
spec:
  targetNamespaces:
    - ${namespace}
EOF
  else
    echo "OperatorGroup already exists in namespace $namespace"
  fi

  echo "Creating/updating Portworx Operator Subscription..."

  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${PX_OPERATOR_PACKAGE}
  namespace: ${namespace}
spec:
  channel: ${PX_OPERATOR_CHANNEL}
  installPlanApproval: Automatic
  name: ${PX_OPERATOR_PACKAGE}
  source: ${PX_OPERATOR_SOURCE}
  sourceNamespace: ${PX_OPERATOR_SOURCE_NS}
EOF

  wait_for_crd "storageclusters.core.libopenstorage.org" 90 10
  wait_for_deployment "$namespace" "portworx-operator" 60 10 || true
}

discover_all_node_security_groups() {
  local region="$1"
  local tmp_sgs
  tmp_sgs="$(mktemp)"

  echo
  echo "Discovering security groups from all OpenShift nodes..."

  for node in $(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    local iid
    iid="$(get_node_instance_id "$node")"

    if [[ -z "$iid" || "$iid" != i-* ]]; then
      echo "Skipping node with non-AWS or missing instance ID: $node"
      continue
    fi

    echo
    echo "===== $node / $iid ====="

    aws ec2 describe-instances \
      --region "$region" \
      --instance-ids "$iid" \
      --query 'Reservations[].Instances[].SecurityGroups[].{Name:GroupName,Id:GroupId}' \
      --output table

    aws ec2 describe-instances \
      --region "$region" \
      --instance-ids "$iid" \
      --query 'Reservations[].Instances[].SecurityGroups[].GroupId' \
      --output text | tr '\t' '\n' >> "$tmp_sgs"
  done

  sort -u "$tmp_sgs" | grep '^sg-' || true
}

apply_portworx_security_group_rules() {
  local region="$1"
  shift
  local sgs=("$@")

  if [[ "${#sgs[@]}" -eq 0 ]]; then
    echo "ERROR: no security groups discovered."
    exit 1
  fi

  echo
  echo "Discovered unique security groups:"
  printf ' - %s\n' "${sgs[@]}"

  echo
  echo "Adding Portworx node-to-node security group rules."
  echo "Allowing TCP 17000-17022 and TCP 9001-9030 between all discovered OpenShift node SGs."

  for dst_sg in "${sgs[@]}"; do
    for src_sg in "${sgs[@]}"; do
      add_sg_rule "$dst_sg" "$src_sg" 17000 17022 "$region"
      add_sg_rule "$dst_sg" "$src_sg" 9001 9030 "$region"
    done
  done
}

find_px_cluster_pod() {
  local namespace="$1"

  oc -n "$namespace" get pods --no-headers 2>/dev/null | awk '/^px-cluster/ {print $1; exit}'
}

read_px_token() {
  local namespace="$1"
  local px_pod="$2"

  oc -n "$namespace" exec "$px_pod" -c portworx -- sh -c 'cat "$AWS_WEB_IDENTITY_TOKEN_FILE"' 2>/dev/null || true
}

repair_portworx_web_identity_trust() {
  local namespace="$1"
  local role_arn="$2"

  echo
  echo "Repairing/testing Portworx IAM web identity trust from actual projected pod token..."

  local px_pod=""
  local token=""

  for _ in $(seq 1 90); do
    px_pod="$(find_px_cluster_pod "$namespace")"

    if [[ -n "$px_pod" ]]; then
      token="$(read_px_token "$namespace" "$px_pod")"
      if [[ -n "$token" ]]; then
        break
      fi
    fi

    sleep 10
  done

  if [[ -z "$px_pod" || -z "$token" ]]; then
    echo "WARNING: could not read Portworx projected token. Skipping IAM trust repair."
    echo "Check px-cluster pods manually:"
    echo "  oc -n ${namespace} get pods -o wide | grep px-cluster"
    return 0
  fi

  echo "Using PX pod: $px_pod"

  local account_id role_name iss sub aud oidc_hostpath oidc_provider_arn

  account_id="$(aws sts get-caller-identity --query Account --output text)"
  role_name="${role_arn##*/}"

  read -r iss sub aud < <(TOKEN="$token" python3 - <<'PY'
import os, json, base64

token = os.environ["TOKEN"].strip()
payload = token.split(".")[1]
payload += "=" * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))

aud = claims.get("aud")
if isinstance(aud, list):
    aud = "sts.amazonaws.com" if "sts.amazonaws.com" in aud else aud[0]

print(claims["iss"], claims["sub"], aud)
PY
)

  oidc_hostpath="${iss#https://}"
  oidc_provider_arn="arn:aws:iam::${account_id}:oidc-provider/${oidc_hostpath}"

  echo "Role:              $role_name"
  echo "OIDC provider ARN: $oidc_provider_arn"
  echo "Issuer:            $iss"
  echo "Subject:           $sub"
  echo "Audience:          $aud"

  aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$oidc_provider_arn" >/dev/null

  cat > /tmp/portworx-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${oidc_provider_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_hostpath}:aud": "${aud}",
          "${oidc_hostpath}:sub": "${sub}"
        }
      }
    }
  ]
}
EOF

  echo
  echo "Applying repaired trust policy:"
  cat /tmp/portworx-trust-policy.json

  aws iam update-assume-role-policy \
    --role-name "$role_name" \
    --policy-document file:///tmp/portworx-trust-policy.json

  echo
  echo "Testing AssumeRoleWithWebIdentity..."

  aws sts assume-role-with-web-identity \
    --role-arn "$role_arn" \
    --role-session-name portworx-script-test \
    --web-identity-token "$token" \
    --duration-seconds 900 \
    --query 'Credentials.AccessKeyId' \
    --output text >/dev/null

  echo "IAM web identity trust is valid."

  echo "Restarting px-cluster pods so Portworx picks up working IAM trust..."
  oc -n "$namespace" get pods -o name | grep '^pod/px-cluster' | xargs -r oc -n "$namespace" delete
}

create_kubevirt_storageclasses() {
  local repl="$1"
  local virt_default_choice="$2"

  local sc_wffc="px-rwx-block-kubevirt-repl${repl}"
  local sc_immediate="px-rwx-block-kubevirt-repl${repl}-immediate"

  echo
  echo "Creating Portworx KubeVirt StorageClasses with repl=${repl}"

  cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc_wffc}
provisioner: pxd.portworx.com
parameters:
  repl: "${repl}"
  io_profile: "auto"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc_immediate}
provisioner: pxd.portworx.com
parameters:
  repl: "${repl}"
  io_profile: "auto"
volumeBindingMode: Immediate
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF

  oc annotate sc "$sc_wffc" storageclass.kubevirt.io/is-default-virt-class- --overwrite >/dev/null 2>&1 || true
  oc annotate sc "$sc_immediate" storageclass.kubevirt.io/is-default-virt-class- --overwrite >/dev/null 2>&1 || true

  if [[ "$virt_default_choice" == "immediate" ]]; then
    echo "Setting $sc_immediate as default virtualization StorageClass"
    oc annotate sc "$sc_immediate" storageclass.kubevirt.io/is-default-virt-class="true" --overwrite
  elif [[ "$virt_default_choice" == "wait" ]]; then
    echo "Setting $sc_wffc as default virtualization StorageClass"
    oc annotate sc "$sc_wffc" storageclass.kubevirt.io/is-default-virt-class="true" --overwrite
  else
    echo "No default virtualization StorageClass annotation selected."
  fi

  if oc get crd storageprofiles.cdi.kubevirt.io >/dev/null 2>&1; then
    echo "Patching CDI StorageProfiles for RWX Block."

    for sc in "$sc_wffc" "$sc_immediate"; do
      for _ in $(seq 1 30); do
        if oc get storageprofile "$sc" >/dev/null 2>&1; then
          oc patch storageprofile "$sc" --type=merge -p '{
            "spec": {
              "claimPropertySets": [
                {
                  "accessModes": ["ReadWriteMany"],
                  "volumeMode": "Block"
                },
                {
                  "accessModes": ["ReadWriteOnce"],
                  "volumeMode": "Block"
                }
              ],
              "cloneStrategy": "csi-clone"
            }
          }' || true
          break
        fi
        sleep 5
      done
    done
  else
    echo "CDI StorageProfile CRD not found. Skipping StorageProfile patches."
  fi
}

#############################################
# Main
#############################################

require_cmd oc
require_cmd aws
require_cmd python3

echo
echo "=== Dynamic Portworx setup for ROSA/OpenShift on AWS ==="
echo

INFRA_ID="$(get_infra_id)"
DEFAULT_ROLE_NAME="$(echo "${INFRA_ID:-rosa}-portworx" | cut -c1-64)"

prompt NAMESPACE "Portworx namespace" "portworx"

oc get ns "$NAMESPACE" >/dev/null 2>&1 || oc create ns "$NAMESPACE"

EXISTING_SC="$(oc -n "$NAMESPACE" get storagecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
DEFAULT_STORAGECLUSTER_NAME="${EXISTING_SC:-px-cluster-$(make_uuid)}"

prompt STORAGECLUSTER_NAME "StorageCluster name" "$DEFAULT_STORAGECLUSTER_NAME"
prompt PORTWORX_VERSION "Portworx version" "3.6.0.1"
prompt INSTANCE_TYPE "Instance type to use for Portworx storage nodes" "c5.metal"
prompt DEVICE_SPEC "Portworx data device spec" "type=gp3,size=150"
prompt METADATA_DEVICE_SPEC "Portworx metadata device spec" "type=gp3,size=64"
prompt IO_PROFILE "Default IO profile" "6"

CERT_MANAGER_ENABLED="false"

echo
echo "certManager.enabled will be set to false."
echo "This avoids cert-manager CRD ownership conflicts on OpenShift/ROSA."
echo

echo "Current nodes:"
oc get nodes \
  -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone,px/enabled,px/metadata-node,portworx.io/provision-storage-node,portworx.io/provision-storage-node-handled

echo
prompt NODE_MODE "Node selection mode: auto or manual" "auto"

SELECTED_NODES=()

if [[ "$NODE_MODE" == "auto" ]]; then
  echo
  echo "Discovering nodes with instance type: $INSTANCE_TYPE"

  while IFS= read -r node; do
    [[ -n "$node" ]] && SELECTED_NODES+=("$node")
  done < <(oc get nodes -l "node.kubernetes.io/instance-type=${INSTANCE_TYPE}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

  if [[ "${#SELECTED_NODES[@]}" -eq 0 ]]; then
    echo "ERROR: no nodes found with instance type $INSTANCE_TYPE"
    echo "Create the machine pool first, or rerun in manual mode."
    exit 1
  fi

  echo
  echo "Selected Portworx nodes:"
  printf ' - %s\n' "${SELECTED_NODES[@]}"

  if ! confirm "Use these nodes for Portworx?" "y"; then
    echo "Aborted."
    exit 1
  fi
else
  echo
  echo "Enter comma-separated node names."
  prompt MANUAL_NODES "Node names"

  IFS=',' read -ra RAW_NODES <<< "$MANUAL_NODES"
  for raw_node in "${RAW_NODES[@]}"; do
    node="$(trim "$raw_node")"
    [[ -n "$node" ]] && SELECTED_NODES+=("$node")
  done
fi

if [[ "${#SELECTED_NODES[@]}" -lt 3 ]]; then
  echo
  echo "WARNING: fewer than 3 Portworx storage nodes selected."
  echo "For a lab this may be fine, but 3 nodes is the normal HA baseline."
fi

echo
echo "Validating selected nodes..."
for node in "${SELECTED_NODES[@]}"; do
  oc get node "$node" >/dev/null
done

AWS_REGION="$(detect_region_from_node "${SELECTED_NODES[0]}")"

if [[ -z "$AWS_REGION" ]]; then
  prompt AWS_REGION "AWS region" "ap-southeast-2"
else
  echo "Detected AWS region: $AWS_REGION"
fi

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Detected AWS account ID: $AWS_ACCOUNT_ID"

OIDC_ISSUER="$(detect_oidc_issuer)"

if [[ -z "$OIDC_ISSUER" ]]; then
  echo
  echo "Could not auto-detect the external ROSA/OCP OIDC issuer."
  echo "For ROSA, you can usually find it with:"
  echo "  rosa describe cluster -c <cluster-name> | grep -i oidc"
  echo
  prompt OIDC_ISSUER "ROSA/OCP OIDC issuer URL"
fi

OIDC_ISSUER="${OIDC_ISSUER%/}"
OIDC_HOSTPATH="${OIDC_ISSUER#https://}"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_HOSTPATH}"

echo
echo "OIDC issuer: $OIDC_ISSUER"
echo "Expected AWS OIDC provider ARN:"
echo "$OIDC_PROVIDER_ARN"

if ! aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo
  echo "ERROR: OIDC provider was not found in AWS IAM:"
  echo "$OIDC_PROVIDER_ARN"
  echo
  echo "For ROSA STS, the OIDC provider should normally already exist."
  echo "Create/fix the OIDC provider first, then rerun this script."
  exit 1
fi

if confirm "Create or update IAM role for Portworx automatically?" "y"; then
  prompt IAM_ROLE_NAME "IAM role name for Portworx" "$DEFAULT_ROLE_NAME"

  TMP_DIR="$(mktemp -d)"
  TRUST_POLICY_FILE="${TMP_DIR}/trust-policy.json"
  PERMISSION_POLICY_FILE="${TMP_DIR}/portworx-policy.json"

  write_initial_iam_trust_policy "$TRUST_POLICY_FILE" "$OIDC_HOSTPATH" "$OIDC_PROVIDER_ARN" "$NAMESPACE"
  write_portworx_iam_policy "$PERMISSION_POLICY_FILE"

  echo
  echo "Creating or updating IAM role..."
  AWS_ROLE_ARN="$(create_or_update_iam_role "$IAM_ROLE_NAME" "$TRUST_POLICY_FILE" "$PERMISSION_POLICY_FILE")"
else
  prompt AWS_ROLE_ARN "Existing Portworx IAM role ARN"
fi

echo "Using IAM role ARN: $AWS_ROLE_ARN"

install_portworx_operator_if_needed "$NAMESPACE"

echo
if confirm "Reset Portworx labels across all nodes first?" "y"; then
  echo "Disabling Portworx on all nodes..."
  oc label nodes --all px/enabled=false --overwrite || true

  echo "Removing old Portworx selection labels from all nodes..."
  oc label nodes --all \
    px/metadata-node- \
    portworx.io/provision-storage-node- \
    portworx.io/provision-storage-node-handled- \
    --overwrite || true
fi

echo
echo "Labelling selected Portworx nodes..."
for node in "${SELECTED_NODES[@]}"; do
  echo "Labelling $node"

  oc label node "$node" \
    px/enabled=true \
    px/metadata-node=true \
    portworx.io/provision-storage-node=true \
    --overwrite

  oc label node "$node" portworx.io/provision-storage-node-handled- --overwrite || true
done

echo
echo "Selected node summary:"
oc get nodes \
  -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone,px/enabled,px/metadata-node,portworx.io/provision-storage-node,portworx.io/provision-storage-node-handled

echo
echo "Discovering all OpenShift node security groups and applying Portworx rules..."

mapfile -t ALL_NODE_SGS < <(discover_all_node_security_groups "$AWS_REGION")

apply_portworx_security_group_rules "$AWS_REGION" "${ALL_NODE_SGS[@]}"

echo
if confirm "Delete stale Portworx StorageNode objects not in the selected node list?" "y"; then
  if oc -n "$NAMESPACE" get storagenodes >/dev/null 2>&1; then
    while IFS= read -r sn; do
      [[ -z "$sn" ]] && continue

      if ! array_contains "$sn" "${SELECTED_NODES[@]}"; then
        echo "Deleting stale StorageNode: $sn"
        oc -n "$NAMESPACE" delete storagenode "$sn" --ignore-not-found
      fi
    done < <(oc -n "$NAMESPACE" get storagenodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  else
    echo "No StorageNode objects found yet."
  fi
fi

echo
if confirm "Clean failed pre-flight/plugin resources? Use this only for failed/retried installs." "n"; then
  echo "Cleaning failed or stale Portworx resources..."

  oc -n "$NAMESPACE" delete ds px-pre-flight --ignore-not-found
  oc -n "$NAMESPACE" delete pod -l name=px-pre-flight --ignore-not-found
  oc -n "$NAMESPACE" delete pod -l app=px-pre-flight --ignore-not-found

  oc -n "$NAMESPACE" delete deploy px-cache-agent px-plugin px-plugin-proxy --ignore-not-found
  oc -n "$NAMESPACE" delete svc px-cache-agent-service px-plugin px-plugin-proxy --ignore-not-found
fi

if oc -n "$NAMESPACE" get storagecluster "$STORAGECLUSTER_NAME" >/dev/null 2>&1; then
  echo
  echo "Existing StorageCluster found: $STORAGECLUSTER_NAME"
  echo "Backing it up to /tmp/${STORAGECLUSTER_NAME}-backup.yaml"

  oc -n "$NAMESPACE" get storagecluster "$STORAGECLUSTER_NAME" -o yaml > "/tmp/${STORAGECLUSTER_NAME}-backup.yaml"

  if confirm "Delete and recreate existing StorageCluster?" "n"; then
    oc -n "$NAMESPACE" delete storagecluster "$STORAGECLUSTER_NAME"

    echo "Waiting for StorageCluster deletion..."
    while oc -n "$NAMESPACE" get storagecluster "$STORAGECLUSTER_NAME" >/dev/null 2>&1; do
      sleep 5
    done
  fi
fi

OUT_FILE="storagecluster-${STORAGECLUSTER_NAME}.yaml"

echo
echo "Writing StorageCluster to: $OUT_FILE"

cat <<EOF > "$OUT_FILE"
kind: StorageCluster
apiVersion: core.libopenstorage.org/v1
metadata:
  name: ${STORAGECLUSTER_NAME}
  namespace: ${NAMESPACE}
  annotations:
    portworx.io/install-source: "generated-by-dynamic-rosa-script"
    portworx.io/is-openshift: "true"
    portworx.io/is-eks: "true"
    portworx.io/misc-args: " -T px-storev2 "
    portworx.io/preflight-check: "true"
    portworx.io/portworx-proxy: "false"

spec:
  image: docker.io/portworx/oci-monitor:${PORTWORX_VERSION}
  imagePullPolicy: Always

  kvdb:
    internal: true
    enableTLS: true

  cloudStorage:
    provider: aws
    deviceSpecs:
      - "${DEVICE_SPEC}"
    systemMetadataDeviceSpec: "${METADATA_DEVICE_SPEC}"

  workloadIdentity:
    credentials:
      - cloudProvider: "aws"
        key: "eks.amazonaws.com/role-arn"
        value: "${AWS_ROLE_ARN}"

  secretsProvider: k8s

  placement:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: px/enabled
                operator: In
                values:
                  - "true"
              - key: node.kubernetes.io/instance-type
                operator: In
                values:
                  - ${INSTANCE_TYPE}

  stork:
    enabled: true
    args:
      webhook-controller: "true"

  autopilot:
    enabled: true

  runtimeOptions:
    default-io-profile: "${IO_PROFILE}"

  csi:
    enabled: true
    installSnapshotController: true

  monitoring:
    telemetry:
      enabled: true
      metricsCollector:
        enabled: true
    prometheus:
      enabled: true
      exportMetrics: true

  certManager:
    enabled: ${CERT_MANAGER_ENABLED}
EOF

echo
echo "Generated StorageCluster:"
echo "-------------------------"
cat "$OUT_FILE"

echo
if confirm "Apply this StorageCluster now?" "y"; then
  oc apply -f "$OUT_FILE"
fi

echo
if confirm "Repair/test Portworx IAM web identity trust from actual pod token?" "y"; then
  repair_portworx_web_identity_trust "$NAMESPACE" "$AWS_ROLE_ARN"
fi

echo
if confirm "Create KubeVirt Portworx StorageClasses for VM disks and bootable images?" "y"; then
  DEFAULT_REPL="${#SELECTED_NODES[@]}"

  if [[ "$DEFAULT_REPL" -gt 3 ]]; then
    DEFAULT_REPL="3"
  fi

  if [[ "$DEFAULT_REPL" -lt 1 ]]; then
    DEFAULT_REPL="1"
  fi

  prompt KUBEVIRT_REPL "Portworx replica count for KubeVirt StorageClasses" "$DEFAULT_REPL"

  echo
  echo "Choose default virtualization StorageClass:"
  echo "  immediate = best for bootable image imports"
  echo "  wait      = best general behaviour for normal VM scheduling"
  echo "  none      = create classes but do not set virt default"
  prompt VIRT_DEFAULT_CHOICE "Virt default choice: immediate, wait, or none" "immediate"

  create_kubevirt_storageclasses "$KUBEVIRT_REPL" "$VIRT_DEFAULT_CHOICE"
fi

echo
echo "Validation commands:"
echo
echo "oc -n ${NAMESPACE} get pods -o wide -w"
echo "oc -n ${NAMESPACE} logs deploy/portworx-operator -f"
echo "oc -n ${NAMESPACE} get storagecluster ${STORAGECLUSTER_NAME} -o wide"
echo "oc -n ${NAMESPACE} get storagenodes -o wide"
echo "oc -n ${NAMESPACE} get pods -o wide | egrep 'px-cluster|portworx-api|px-csi|kvdb'"
echo
echo "Check Portworx status:"
echo "PX_POD=\$(oc -n ${NAMESPACE} get pods -o name | grep '^pod/px-cluster' | head -1)"
echo "oc -n ${NAMESPACE} exec \"\$PX_POD\" -c portworx -- /opt/pwx/bin/pxctl status"
echo
echo "Check IAM role annotation:"
echo "oc -n ${NAMESPACE} get sa portworx -o yaml | egrep -A5 'annotations|eks.amazonaws.com/role-arn'"
echo
echo "Check selected nodes:"
echo "oc get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone,px/enabled,px/metadata-node,portworx.io/provision-storage-node,portworx.io/provision-storage-node-handled"
echo
echo "Check EBS disks on selected nodes:"
echo "for n in ${SELECTED_NODES[*]}; do iid=\$(oc get node \$n -o jsonpath='{.spec.providerID}' | awk -F/ '{print \$NF}'); echo ===== \$n / \$iid =====; aws ec2 describe-instances --region ${AWS_REGION} --instance-ids \$iid --query 'Reservations[].Instances[].BlockDeviceMappings[].{Device:DeviceName,Volume:Ebs.VolumeId}' --output table; done"
echo
echo "Done."
