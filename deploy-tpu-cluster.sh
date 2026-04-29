#!/usr/bin/env bash
#
# deploy-tpu-cluster.sh
#
# Deploys a GKE cluster with an autoscaling TPU node pool.
# Iterates across zones and TPU configurations until one succeeds,
# or exhausts all options and exits with a clear report.
#
# Usage:
#   ./deploy-tpu-cluster.sh                        # interactive, uses defaults
#   ./deploy-tpu-cluster.sh --project my-project   # override project
#   ./deploy-tpu-cluster.sh --teardown             # destroy everything
#
# Requires: gcloud CLI authenticated with sufficient permissions.

set -euo pipefail

# ─── Defaults (override via flags) ───────────────────────────────────────────

PROJECT="${PROJECT:-vllm-tpu-benchmark}"
CLUSTER_NAME="${CLUSTER_NAME:-tpu-cluster}"
CPU_MACHINE_TYPE="${CPU_MACHINE_TYPE:-e2-standard-4}"
CPU_NUM_NODES="${CPU_NUM_NODES:-1}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-rapid}"
TPU_POOL_NAME="${TPU_POOL_NAME:-tpu-pool}"
AUTOSCALE_MIN="${AUTOSCALE_MIN:-0}"
AUTOSCALE_MAX="${AUTOSCALE_MAX:-2}"
USE_SPOT="${USE_SPOT:-false}"
RECORD_FILE="${RECORD_FILE:-tpu-cluster-resources.json}"
TEARDOWN=false
NODE_POOL_TIMEOUT=2400  # 40 min max wait for node pool provisioning
CLUSTER_TIMEOUT=1800    # 30 min max wait for cluster creation
DRY_RUN=false

# ─── TPU configurations to attempt, in priority order ────────────────────────
# Each entry: "machine_type|topology_flag|tpu_label"
# topology_flag is empty for single-host types.
TPU_CONFIGS=(
  "ct5lp-hightpu-4t|--tpu-topology=2x2|v5litepod-4"
  "ct5lp-hightpu-8t||v5litepod-8"
  "ct6e-standard-4t||v6e-4"
  "ct6e-standard-8t||v6e-8"
  "ct5lp-hightpu-4t||v5litepod-4-no-topo"
)

# Zones ordered by typical TPU availability (broadest type support first).
ZONE_ORDER=(
  us-central1-a
  europe-west4-a
  us-east5-a
  us-east5-b
  us-east5-c
  us-central1-b
  us-central1-c
  europe-west4-b
  us-west4-a
)

# ─── Colors / helpers ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
header(){ echo -e "\n${BOLD}── $* ──${NC}"; }

# ─── Parse arguments ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)       PROJECT="$2"; shift 2 ;;
    --cluster)       CLUSTER_NAME="$2"; shift 2 ;;
    --tpu-pool)      TPU_POOL_NAME="$2"; shift 2 ;;
    --cpu-type)      CPU_MACHINE_TYPE="$2"; shift 2 ;;
    --min-nodes)     AUTOSCALE_MIN="$2"; shift 2 ;;
    --max-nodes)     AUTOSCALE_MAX="$2"; shift 2 ;;
    --spot)          USE_SPOT=true; shift ;;
    --teardown)      TEARDOWN=true; shift ;;
    --record-file)   RECORD_FILE="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --project NAME       GCP project ID          (default: vllm-tpu-benchmark)"
      echo "  --cluster NAME       GKE cluster name        (default: tpu-cluster)"
      echo "  --tpu-pool NAME      TPU node pool name      (default: tpu-pool)"
      echo "  --cpu-type TYPE      CPU node machine type   (default: e2-standard-4)"
      echo "  --min-nodes N        Autoscaler min nodes    (default: 0)"
      echo "  --max-nodes N        Autoscaler max nodes    (default: 2)"
      echo "  --spot               Use spot/preemptible TPU VMs"
      echo "  --teardown           Destroy all resources listed in the record file"
      echo "  --record-file PATH   Resource record file    (default: tpu-cluster-resources.json)"
      echo "  --dry-run            Print what would be done without executing"
      echo "  --help               Show this help"
      exit 0
      ;;
    *) fail "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Utility functions ───────────────────────────────────────────────────────

write_record() {
  # Writes a JSON record of all created resources for teardown.
  local zone="$1" machine_type="$2" tpu_label="$3"
  cat > "$RECORD_FILE" <<EOF
{
  "project": "$PROJECT",
  "cluster_name": "$CLUSTER_NAME",
  "zone": "$zone",
  "cpu_machine_type": "$CPU_MACHINE_TYPE",
  "tpu_pool_name": "$TPU_POOL_NAME",
  "tpu_machine_type": "$machine_type",
  "tpu_label": "$tpu_label",
  "use_spot": $USE_SPOT,
  "autoscale_min": $AUTOSCALE_MIN,
  "autoscale_max": $AUTOSCALE_MAX,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  ok "Resource record written to ${BOLD}$RECORD_FILE${NC}"
}

wait_for_operation() {
  # Polls a GKE operation until DONE or timeout.
  # Returns 0 on success, 1 on error/timeout.
  local op_name="$1" zone="$2" timeout_secs="$3"
  local elapsed=0
  local poll_interval=30

  while (( elapsed < timeout_secs )); do
    local result
    result=$(gcloud container operations describe "$op_name" \
      --zone="$zone" --project="$PROJECT" \
      --format="value(status)" 2>&1) || true

    if [[ "$result" == "DONE" ]]; then
      # Check if it completed with an error
      local error_msg
      error_msg=$(gcloud container operations describe "$op_name" \
        --zone="$zone" --project="$PROJECT" \
        --format="value(error.message)" 2>&1) || true
      if [[ -n "$error_msg" ]]; then
        fail "Operation completed with error: $error_msg"
        return 1
      fi
      return 0
    fi

    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))
    printf "."
  done

  fail "Operation timed out after ${timeout_secs}s"
  return 1
}

check_zone_has_tpu_machine_type() {
  # Checks if a given zone has the specified TPU machine type.
  local zone="$1" machine_type="$2"
  local result
  result=$(gcloud compute machine-types list \
    --zones="$zone" --project="$PROJECT" \
    --filter="name=$machine_type" \
    --format="value(name)" 2>&1) || true
  [[ -n "$result" ]]
}

check_tpu_quota() {
  # Returns 0 if the region has non-zero TPU podslice quota.
  local region="${1%-*}"  # strip zone suffix to get region
  local quota_json
  quota_json=$(gcloud compute regions describe "$region" \
    --project="$PROJECT" --format=json 2>&1) || return 1

  local has_quota
  has_quota=$(echo "$quota_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for q in data.get('quotas', []):
    m = q.get('metric', '')
    if 'TPU' in m and 'PODSLICE' in m and q.get('limit', 0) > 0:
        print('yes')
        sys.exit(0)
    if 'TPU' in m and 'DEVICE' in m and q.get('limit', 0) > 0:
        print('yes')
        sys.exit(0)
print('no')
" 2>/dev/null) || has_quota="no"

  [[ "$has_quota" == "yes" ]]
}

cleanup_failed_pool() {
  local pool="$1" zone="$2"
  info "Cleaning up failed node pool '$pool'..."
  gcloud container node-pools delete "$pool" \
    --cluster="$CLUSTER_NAME" --zone="$zone" \
    --project="$PROJECT" --quiet 2>/dev/null || true
}

cleanup_cluster() {
  local zone="$1"
  info "Cleaning up cluster '$CLUSTER_NAME' in $zone..."
  gcloud container clusters delete "$CLUSTER_NAME" \
    --zone="$zone" --project="$PROJECT" --quiet 2>&1 || true
}

# ─── Teardown mode ───────────────────────────────────────────────────────────

if [[ "$TEARDOWN" == true ]]; then
  header "TEARDOWN MODE"

  if [[ ! -f "$RECORD_FILE" ]]; then
    fail "Record file '$RECORD_FILE' not found."
    warn "Falling back to listing all clusters in project '$PROJECT'..."
    gcloud container clusters list --project="$PROJECT" 2>&1
    echo ""
    echo "To delete manually:"
    echo "  gcloud container clusters delete CLUSTER_NAME --zone=ZONE --project=$PROJECT --quiet"
    exit 1
  fi

  info "Reading resource record from $RECORD_FILE"
  TEARDOWN_PROJECT=$(python3 -c "import json; d=json.load(open('$RECORD_FILE')); print(d['project'])")
  TEARDOWN_CLUSTER=$(python3 -c "import json; d=json.load(open('$RECORD_FILE')); print(d['cluster_name'])")
  TEARDOWN_ZONE=$(python3 -c "import json; d=json.load(open('$RECORD_FILE')); print(d['zone'])")
  TEARDOWN_TPU_POOL=$(python3 -c "import json; d=json.load(open('$RECORD_FILE')); print(d['tpu_pool_name'])")

  echo ""
  echo "  Project:    $TEARDOWN_PROJECT"
  echo "  Cluster:    $TEARDOWN_CLUSTER"
  echo "  Zone:       $TEARDOWN_ZONE"
  echo "  TPU Pool:   $TEARDOWN_TPU_POOL"
  echo ""

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would delete:"
    echo "  gcloud container node-pools delete $TEARDOWN_TPU_POOL --cluster=$TEARDOWN_CLUSTER --zone=$TEARDOWN_ZONE --project=$TEARDOWN_PROJECT --quiet"
    echo "  gcloud container clusters delete $TEARDOWN_CLUSTER --zone=$TEARDOWN_ZONE --project=$TEARDOWN_PROJECT --quiet"
    exit 0
  fi

  read -r -p "Proceed with teardown? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    info "Aborted."
    exit 0
  fi

  info "Deleting TPU node pool '$TEARDOWN_TPU_POOL'..."
  gcloud container node-pools delete "$TEARDOWN_TPU_POOL" \
    --cluster="$TEARDOWN_CLUSTER" --zone="$TEARDOWN_ZONE" \
    --project="$TEARDOWN_PROJECT" --quiet 2>&1 || warn "Node pool deletion failed (may already be deleted)"

  info "Deleting cluster '$TEARDOWN_CLUSTER'..."
  gcloud container clusters delete "$TEARDOWN_CLUSTER" \
    --zone="$TEARDOWN_ZONE" --project="$TEARDOWN_PROJECT" --quiet 2>&1

  ok "All resources destroyed."
  info "You may remove the record file: rm $RECORD_FILE"
  exit 0
fi

# ─── Deploy mode ─────────────────────────────────────────────────────────────

header "GKE TPU Cluster Deployment"
echo "  Project:        $PROJECT"
echo "  Cluster:        $CLUSTER_NAME"
echo "  CPU type:       $CPU_MACHINE_TYPE"
echo "  Autoscale:      $AUTOSCALE_MIN - $AUTOSCALE_MAX nodes"
echo "  Spot TPUs:      $USE_SPOT"
echo "  Zones to try:   ${#ZONE_ORDER[@]}"
echo "  TPU configs:    ${#TPU_CONFIGS[@]}"
echo ""

# Preflight: verify gcloud is working and project is accessible
info "Verifying project access..."
if ! gcloud projects describe "$PROJECT" --format="value(projectId)" &>/dev/null; then
  fail "Cannot access project '$PROJECT'. Check gcloud auth and permissions."
  exit 1
fi
ok "Project '$PROJECT' is accessible."

# Preflight: check required APIs
info "Checking required APIs..."
for api in compute.googleapis.com container.googleapis.com tpu.googleapis.com; do
  if ! gcloud services list --enabled --project="$PROJECT" --filter="name=$api" --format="value(name)" 2>/dev/null | grep -q "$api"; then
    warn "API $api is not enabled. Enabling..."
    if [[ "$DRY_RUN" == false ]]; then
      gcloud services enable "$api" --project="$PROJECT" 2>&1
    fi
  fi
done
ok "Required APIs are enabled."

# ─── Scan zones for quota + machine type availability ────────────────────────

header "Scanning zones for TPU quota and machine type availability"

declare -A ZONE_CONFIGS  # zone -> comma-separated list of valid configs

for zone in "${ZONE_ORDER[@]}"; do
  region="${zone%-*}"
  printf "  %-20s " "$zone"

  # Check quota
  if ! check_tpu_quota "$zone" 2>/dev/null; then
    echo -e "${RED}no quota${NC}"
    continue
  fi

  # Check which TPU machine types exist in this zone
  valid_configs=()
  for config_str in "${TPU_CONFIGS[@]}"; do
    IFS='|' read -r machine_type topo_flag tpu_label <<< "$config_str"
    if check_zone_has_tpu_machine_type "$zone" "$machine_type" 2>/dev/null; then
      valid_configs+=("$config_str")
    fi
  done

  if [[ ${#valid_configs[@]} -eq 0 ]]; then
    echo -e "${YELLOW}quota ok, no matching machine types${NC}"
    continue
  fi

  # Store valid configs for this zone
  ZONE_CONFIGS[$zone]=$(IFS=';'; echo "${valid_configs[*]}")
  labels=()
  for vc in "${valid_configs[@]}"; do
    IFS='|' read -r _ _ lbl <<< "$vc"
    labels+=("$lbl")
  done
  echo -e "${GREEN}quota ok, types: ${labels[*]}${NC}"
done

if [[ ${#ZONE_CONFIGS[@]} -eq 0 ]]; then
  fail "No zones found with both TPU quota and matching machine types."
  fail "Request TPU quota at: https://console.cloud.google.com/iam-admin/quotas"
  exit 1
fi

echo ""
info "Found ${#ZONE_CONFIGS[@]} viable zone(s). Starting deployment attempts..."

# ─── Iterate zones and configs ───────────────────────────────────────────────

DEPLOYED=false
DEPLOYED_ZONE=""

# We iterate zones in the original priority order, not hash order.
for zone in "${ZONE_ORDER[@]}"; do
  [[ -z "${ZONE_CONFIGS[$zone]+x}" ]] && continue

  header "Attempting zone: $zone"

  # ── Step 1: Create the GKE cluster ──
  info "Creating GKE cluster '$CLUSTER_NAME' in $zone..."

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] gcloud container clusters create $CLUSTER_NAME --zone=$zone ..."
    DEPLOYED=true
    DEPLOYED_ZONE="$zone"
    break
  fi

  cluster_output=$(gcloud container clusters create "$CLUSTER_NAME" \
    --zone="$zone" \
    --release-channel="$RELEASE_CHANNEL" \
    --machine-type="$CPU_MACHINE_TYPE" \
    --num-nodes="$CPU_NUM_NODES" \
    --project="$PROJECT" 2>&1) || true

  # Verify cluster is RUNNING
  cluster_status=$(gcloud container clusters describe "$CLUSTER_NAME" \
    --zone="$zone" --project="$PROJECT" \
    --format="value(status)" 2>/dev/null) || cluster_status="FAILED"

  if [[ "$cluster_status" != "RUNNING" ]]; then
    fail "Cluster creation failed in $zone (status: $cluster_status)"
    warn "Cleaning up..."
    cleanup_cluster "$zone"
    continue
  fi

  ok "Cluster '$CLUSTER_NAME' is RUNNING in $zone"

  # ── Step 2: Try each TPU config in this zone ──
  IFS=';' read -ra configs <<< "${ZONE_CONFIGS[$zone]}"
  pool_created=false

  for config_str in "${configs[@]}"; do
    IFS='|' read -r machine_type topo_flag tpu_label <<< "$config_str"

    info "Trying TPU config: $tpu_label ($machine_type)..."

    # Build the node pool creation command
    cmd=(gcloud container node-pools create "$TPU_POOL_NAME"
      --cluster="$CLUSTER_NAME"
      --zone="$zone"
      --machine-type="$machine_type"
      --num-nodes=1
      --enable-autoscaling
      --min-nodes="$AUTOSCALE_MIN"
      --max-nodes="$AUTOSCALE_MAX"
      --project="$PROJECT"
    )

    if [[ -n "$topo_flag" ]]; then
      cmd+=("$topo_flag")
    fi

    if [[ "$USE_SPOT" == true ]]; then
      cmd+=(--spot)
    fi

    # Launch the node pool creation
    pool_output=$("${cmd[@]}" 2>&1) || pool_output_rc=$?

    # If the command returned quickly with an error, check it
    if echo "$pool_output" | grep -qi "unsupported TPU configuration\|Invalid machine type\|INVALID_PARAMETER\|FAILED_PRECONDITION"; then
      fail "Config $tpu_label rejected: unsupported in $zone"
      cleanup_failed_pool "$TPU_POOL_NAME" "$zone"
      continue
    fi

    # If it returned with RESOURCE_EXHAUSTED or GCE_STOCKOUT
    if echo "$pool_output" | grep -qi "RESOURCE_EXHAUSTED\|GCE_STOCKOUT\|lack of capacity\|not available"; then
      fail "Config $tpu_label: no capacity in $zone"
      cleanup_failed_pool "$TPU_POOL_NAME" "$zone"
      continue
    fi

    # Check if the pool ended up in a good state
    pool_status=$(gcloud container node-pools describe "$TPU_POOL_NAME" \
      --cluster="$CLUSTER_NAME" --zone="$zone" --project="$PROJECT" \
      --format="value(status)" 2>/dev/null) || pool_status="UNKNOWN"

    if [[ "$pool_status" == "RUNNING" ]]; then
      ok "TPU node pool '$TPU_POOL_NAME' ($tpu_label) is RUNNING!"
      pool_created=true
      write_record "$zone" "$machine_type" "$tpu_label"
      break
    elif [[ "$pool_status" == "PROVISIONING" || "$pool_status" == "RECONCILING" ]]; then
      # Pool exists but node is still being provisioned -- could be capacity wait.
      # Check if the latest operation had an error.
      latest_op=$(gcloud container operations list \
        --zone="$zone" --project="$PROJECT" \
        --filter="operationType=CREATE_NODE_POOL" \
        --sort-by="~startTime" --limit=1 \
        --format="value(name)" 2>/dev/null) || true

      if [[ -n "$latest_op" ]]; then
        op_error=$(gcloud container operations describe "$latest_op" \
          --zone="$zone" --project="$PROJECT" \
          --format="value(error.message)" 2>/dev/null) || op_error=""

        if echo "$op_error" | grep -qi "capacity\|stockout\|exhausted"; then
          fail "Config $tpu_label: no capacity in $zone (pool created but nodes pending)"
          cleanup_failed_pool "$TPU_POOL_NAME" "$zone"
          continue
        fi
      fi

      # Might still be legitimately provisioning
      warn "Pool status: $pool_status. Waiting up to ${NODE_POOL_TIMEOUT}s..."
      start_time=$(date +%s)
      success=false
      while true; do
        current_time=$(date +%s)
        elapsed=$(( current_time - start_time ))
        if (( elapsed >= NODE_POOL_TIMEOUT )); then
          break
        fi
        sleep 30
        ps=$(gcloud container node-pools describe "$TPU_POOL_NAME" \
          --cluster="$CLUSTER_NAME" --zone="$zone" --project="$PROJECT" \
          --format="value(status)" 2>/dev/null) || ps="UNKNOWN"
        if [[ "$ps" == "RUNNING" ]]; then
          success=true
          break
        elif [[ "$ps" == "ERROR" || "$ps" == "STOPPING" ]]; then
          break
        fi
        printf "."
      done
      echo ""

      if [[ "$success" == true ]]; then
        ok "TPU node pool '$TPU_POOL_NAME' ($tpu_label) is RUNNING!"
        pool_created=true
        write_record "$zone" "$machine_type" "$tpu_label"
        break
      else
        fail "Pool did not reach RUNNING state"
        cleanup_failed_pool "$TPU_POOL_NAME" "$zone"
        continue
      fi
    else
      fail "Pool status: $pool_status"
      cleanup_failed_pool "$TPU_POOL_NAME" "$zone"
      continue
    fi
  done

  if [[ "$pool_created" == true ]]; then
    DEPLOYED=true
    DEPLOYED_ZONE="$zone"
    break
  fi

  # None of the TPU configs worked in this zone, clean up the cluster
  fail "All TPU configs exhausted for $zone. Cleaning up cluster..."
  cleanup_cluster "$zone"
done

# ─── Result ──────────────────────────────────────────────────────────────────

echo ""
if [[ "$DEPLOYED" == true ]]; then
  header "DEPLOYMENT SUCCESSFUL"
  echo ""
  echo "  Project:      $PROJECT"
  echo "  Zone:         $DEPLOYED_ZONE"
  echo "  Cluster:      $CLUSTER_NAME"
  echo "  TPU Pool:     $TPU_POOL_NAME"
  echo "  Record file:  $RECORD_FILE"
  echo ""
  info "To get kubectl credentials:"
  echo "  gcloud container clusters get-credentials $CLUSTER_NAME --zone=$DEPLOYED_ZONE --project=$PROJECT"
  echo ""
  info "To tear down all resources:"
  echo "  $0 --teardown --record-file $RECORD_FILE"
  echo ""
else
  header "DEPLOYMENT FAILED"
  fail "Could not find TPU capacity in any zone."
  echo ""
  echo "Zones attempted:"
  for zone in "${ZONE_ORDER[@]}"; do
    [[ -z "${ZONE_CONFIGS[$zone]+x}" ]] && continue
    echo "  - $zone"
  done
  echo ""
  echo "Recommendations:"
  echo "  1. Wait and retry later -- TPU capacity fluctuates hourly"
  echo "  2. Try spot VMs:  $0 --spot"
  echo "  3. Request higher quota: https://console.cloud.google.com/iam-admin/quotas"
  echo "  4. Check capacity dashboard: https://console.cloud.google.com/compute/tpus"
  echo "  5. Consider reserved capacity for production workloads"
  exit 1
fi
