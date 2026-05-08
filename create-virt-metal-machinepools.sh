#!/usr/bin/env bash
set -euo pipefail

# Create one Spot-backed ROSA machine pool per cluster using c5.metal
# and the current Spot price in the target region/AZ at runtime.
#
# Clusters:
#   - rosa-syd-2 (ap-southeast-2)
#   - rosa-melb-2 (ap-southeast-4)
#
# Fixes:
# - Uses ROSA-safe machine pool names (<=15 chars)
# - Filters AZs to standard availability zones only
# - Uses current Spot price with a small safety buffer
#
# Usage:
#   chmod +x create-virt-metal-machinepools.sh
#   ./create-virt-metal-machinepools.sh
#
# Optional overrides:
#   DISK_SIZE=300GiB ./create-virt-metal-machinepools.sh
#   SPOT_BUFFER_PCT=10 ./create-virt-metal-machinepools.sh

DISK_SIZE="${DISK_SIZE:-300GiB}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c5.metal}"
SPOT_BUFFER_PCT="${SPOT_BUFFER_PCT:-10}"

declare -A CLUSTER_REGION=(
  [rosa-syd-2]="ap-southeast-2"
  [rosa-melb-2]="ap-southeast-4"
)

# Keep names <= 15 chars for ROSA/Hypershift nodepools.
declare -A CLUSTER_POOL_NAME=(
  [rosa-syd-2]="virtspotsyd"
  [rosa-melb-2]="virtspotmelb"
)

machinepool_exists() {
  local cluster="$1"
  local machinepool="$2"
  rosa list machinepools --cluster "$cluster" 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$machinepool"
}

list_azs() {
  local region="$1"
  aws ec2 describe-availability-zones \
    --region "$region" \
    --all-availability-zones \
    --filters Name=region-name,Values="$region" Name=state,Values=available \
    --query 'AvailabilityZones[?ZoneType==`availability-zone`].ZoneName' \
    --output text | tr '\t' '\n' | grep -E "^${region}[a-z]$" | sort
}

current_spot_price() {
  local region="$1"
  local az="$2"
  local instance_type="$3"

  aws ec2 describe-spot-price-history \
    --region "$region" \
    --availability-zone "$az" \
    --instance-types "$instance_type" \
    --product-descriptions "Linux/UNIX" \
    --max-items 20 \
    --query 'reverse(sort_by(SpotPriceHistory,&Timestamp))[0].SpotPrice' \
    --output text 2>/dev/null || true
}

buffered_price() {
  local price="$1"
  local pct="$2"
  python3 - <<PY
price = float("$price")
pct = float("$pct")
print(f"{price * (1 + pct/100):.6f}")
PY
}

try_create_pool() {
  local cluster="$1"
  local pool_name="$2"
  local az="$3"
  local max_price="$4"

  local out rc
  out="$(mktemp)"
  set +e
  rosa create machinepool \
    --cluster="$cluster" \
    --name="$pool_name" \
    --replicas=1 \
    --instance-type="$INSTANCE_TYPE" \
    --availability-zone="$az" \
    --disk-size="$DISK_SIZE" \
    --use-spot-instances \
    --spot-max-price="$max_price" >"$out" 2>&1
  rc=$?
  set -e

  cat "$out"

  if [[ $rc -eq 0 ]]; then
    rm -f "$out"
    return 0
  fi

  if grep -Eq "not supported in availability zone|not supported in region|InsufficientInstanceCapacity|Unsupported|not available" "$out"; then
    rm -f "$out"
    return 2
  fi

  rm -f "$out"
  return 1
}

for cluster in "${!CLUSTER_REGION[@]}"; do
  region="${CLUSTER_REGION[$cluster]}"
  pool_name="${CLUSTER_POOL_NAME[$cluster]}"

  echo "=== ${cluster} (${region}) ==="

  if machinepool_exists "$cluster" "$pool_name"; then
    echo "Machine pool ${pool_name} already exists on ${cluster}; skipping."
    echo
    continue
  fi

  mapfile -t AZS < <(list_azs "$region")
  if [[ ${#AZS[@]} -eq 0 ]]; then
    echo "ERROR: Could not find standard AZs in ${region}." >&2
    exit 1
  fi

  created=0

  for az in "${AZS[@]}"; do
    spot_price="$(current_spot_price "$region" "$az" "$INSTANCE_TYPE")"

    if [[ -z "${spot_price:-}" || "$spot_price" == "None" || "$spot_price" == "null" ]]; then
      echo "No current Spot price found for ${INSTANCE_TYPE} in ${az}; skipping."
      continue
    fi

    max_price="$(buffered_price "$spot_price" "$SPOT_BUFFER_PCT")"

    echo "Trying ${INSTANCE_TYPE} in ${az}"
    echo "  Current Spot price: USD ${spot_price}/hour"
    echo "  Spot max price:     USD ${max_price}/hour"

    if try_create_pool "$cluster" "$pool_name" "$az" "$max_price"; then
      echo "Created machine pool ${pool_name} on ${cluster} using ${INSTANCE_TYPE} in ${az}"
      created=1
      break
    else
      rc=$?
      if [[ $rc -eq 2 ]]; then
        echo "  -> ${INSTANCE_TYPE} not accepted in ${az}, trying next AZ"
        continue
      else
        echo "ERROR: ROSA returned a non-retryable error while creating ${pool_name} on ${cluster}." >&2
        exit 1
      fi
    fi
  done

  if [[ $created -ne 1 ]]; then
    echo "ERROR: Could not create a Spot machine pool for ${cluster} in ${region} using ${INSTANCE_TYPE}." >&2
    exit 1
  fi

  echo
done

echo "Done."
