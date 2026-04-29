#!/usr/bin/env bash
#
# check-status.sh -- Quick status check for the vLLM TPU autoscaling demo.
#
# Usage:  ./scripts/check-status.sh
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-vllm}"
PROJECT="${PROJECT:-vllm-tpu-benchmark}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-tpu-cluster}"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

header() { echo -e "\n${BOLD}── $* ──${NC}"; }

header "Cluster"
gcloud container clusters list --project="$PROJECT" --format="table(name,location,status,currentNodeCount)" 2>&1

header "Node Pools"
gcloud container node-pools list --cluster="$CLUSTER" --zone="$ZONE" --project="$PROJECT" \
  --format="table(name,config.machineType,status,autoscaling.enabled,autoscaling.minNodeCount,autoscaling.maxNodeCount)" 2>&1

header "Nodes"
kubectl get nodes -o wide 2>&1

header "vLLM Pods"
kubectl get pods -n "$NAMESPACE" -l app=vllm-tpu -o wide 2>&1

header "HPA Status"
kubectl get hpa -n "$NAMESPACE" 2>&1

header "vLLM Service"
kubectl get svc vllm-service -n "$NAMESPACE" 2>&1

VLLM_IP=$(kubectl get service vllm-service -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || true

if [[ -n "$VLLM_IP" ]]; then
  header "Health Check"
  echo -e "  Endpoint: ${GREEN}http://$VLLM_IP:8000${NC}"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$VLLM_IP:8000/health" 2>/dev/null) || HTTP_CODE="unreachable"
  echo "  /health response: $HTTP_CODE"

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo ""
    echo -e "  ${GREEN}vLLM is ready. Test with:${NC}"
    echo "  curl http://$VLLM_IP:8000/v1/completions \\"
    echo '    -H "Content-Type: application/json" \\'
    echo "    -d '{\"model\":\"google/gemma-4-26B-A4B-it\",\"prompt\":\"Hello\",\"max_tokens\":50}'"
  fi
fi
