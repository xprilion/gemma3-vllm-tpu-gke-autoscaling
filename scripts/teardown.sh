#!/usr/bin/env bash
#
# teardown.sh -- Removes all resources created by this demo.
#
# Usage:
#   ./scripts/teardown.sh           # interactive confirmation
#   ./scripts/teardown.sh --force   # skip confirmation
#
set -euo pipefail

PROJECT="${PROJECT:-vllm-tpu-benchmark}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-tpu-cluster}"
NAMESPACE="${NAMESPACE:-vllm}"
BUCKET="${BUCKET:-vllm-tpu-benchmark-model-cache}"
FORCE=false

[[ "${1:-}" == "--force" ]] && FORCE=true

RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}=== Teardown: vLLM TPU Autoscaling Demo ===${NC}"
echo ""
echo "  Project:   $PROJECT"
echo "  Zone:      $ZONE"
echo "  Cluster:   $CLUSTER"
echo "  Namespace: $NAMESPACE"
echo "  Bucket:    gs://$BUCKET"
echo ""

if [[ "$FORCE" != true ]]; then
  read -r -p "This will DELETE everything listed above. Proceed? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""

echo "[1/5] Deleting Kubernetes resources in namespace '$NAMESPACE'..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>&1 || true

echo "[2/5] Deleting Custom Metrics Adapter..."
kubectl delete -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml 2>&1 || true

echo "[3/5] Deleting GCS bucket gs://$BUCKET..."
gcloud storage rm --recursive "gs://$BUCKET" --project="$PROJECT" 2>&1 || true

echo "[4/5] Deleting TPU node pool..."
gcloud container node-pools delete tpu-v5e-pool \
  --cluster="$CLUSTER" --zone="$ZONE" --project="$PROJECT" --quiet 2>&1 || true

echo "[5/5] Deleting GKE cluster..."
gcloud container clusters delete "$CLUSTER" \
  --zone="$ZONE" --project="$PROJECT" --quiet 2>&1 || true

echo ""
echo -e "${BOLD}Teardown complete.${NC}"
