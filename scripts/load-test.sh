#!/usr/bin/env bash
#
# load-test.sh -- Generates parallel requests against the vLLM endpoint
# to demonstrate HPA autoscaling on GKE TPU.
#
# Usage:
#   ./scripts/load-test.sh            # 20 parallel workers (default)
#   ./scripts/load-test.sh 50         # 50 parallel workers
#   ./scripts/load-test.sh 50 stop    # kill background load generators
#
set -euo pipefail

NAMESPACE="${NAMESPACE:-vllm}"
N="${1:-20}"
ACTION="${2:-start}"

if [[ "$ACTION" == "stop" ]]; then
  echo "Stopping all background load generators..."
  pkill -f "load-test-worker" 2>/dev/null || true
  echo "Done."
  exit 0
fi

VLLM_IP=$(kubectl get service vllm-service -n "$NAMESPACE" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [[ -z "$VLLM_IP" ]]; then
  echo "ERROR: Could not get vllm-service external IP. Is the service running?"
  exit 1
fi

MODEL="${MODEL:-google/gemma-3-4b-it}"

echo "=== vLLM Load Test ==="
echo "  Endpoint:  http://$VLLM_IP:8000"
echo "  Model:     $MODEL"
echo "  Workers:   $N"
echo ""
echo "Press Ctrl+C to stop, or run: $0 0 stop"
echo ""

for i in $(seq 1 "$N"); do
  (
    while true; do
      curl -s --max-time 120 \
        "http://$VLLM_IP:8000/v1/completions" \
        -H "Content-Type: application/json" \
        -d "{
          \"model\": \"$MODEL\",
          \"prompt\": \"Write a comprehensive essay about the history of artificial intelligence, covering its origins, key milestones, and future directions.\",
          \"max_tokens\": 500,
          \"temperature\": 0.7
        }" > /dev/null 2>&1
    done
  ) &
done

echo "Load test running with $N workers (PIDs in background)."
echo "Monitor autoscaling with:  kubectl get hpa -n $NAMESPACE --watch"
wait
