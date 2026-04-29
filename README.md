# Autoscaling LLM Inference on GKE with TPU v5e and vLLM

A deployment guide covering quota management, capacity planning, model compatibility, and HPA-based autoscaling for vLLM on Google Kubernetes Engine with Cloud TPU.

**[Read the full article](https://xprilion.com/gemma3-vllm-tpu-gke-autoscaling/)**

## What This Is

A practical walkthrough of deploying LLM inference on GKE with TPU autoscaling -- from first quota check to a live, autoscaling endpoint. Covers the real experience, including every quota gate, capacity constraint, and Gemma 4 compatibility failure encountered along the way.

**Deployed:** vLLM serving Gemma 3 4B on TPU v5e with HPA autoscaling on `num_requests_waiting`.

**Designed to scale:** When `GPUS_ALL_REGIONS >= 8`, change five config values and serve Gemma 3 27B or Gemma 4 26B on 8 chips.

## Architecture

```
                 Load Balancer (:8000)
                        |
                  vllm-service
                        |
                  vllm-tpu pod         <-- HPA on num_requests_waiting
                        |
                  TPU v5e node         <-- Node pool autoscales 0-N
                        |
              GCS FUSE (model cache)
```

## Quick Start

```bash
# 1. Create cluster with addons pre-enabled
gcloud container clusters create tpu-cluster \
  --zone=us-central1-a --release-channel=rapid \
  --machine-type=e2-standard-4 --num-nodes=1 \
  --workload-pool=YOUR_PROJECT.svc.id.goog \
  --addons=GcsFuseCsiDriver --project=YOUR_PROJECT

# 2. Add TPU node pool
gcloud container node-pools create tpu-v5e-pool \
  --cluster=tpu-cluster --zone=us-central1-a \
  --machine-type=ct5lp-hightpu-1t \
  --num-nodes=1 --enable-autoscaling --min-nodes=0 --max-nodes=1 \
  --project=YOUR_PROJECT

# 3. Deploy (after setting up namespace, SA, secrets -- see full article)
kubectl apply -f k8s/vllm-deployment.yaml
kubectl apply -f k8s/pod-monitoring.yaml
kubectl apply -f k8s/hpa.yaml
```

See the [full article](https://xprilion.com/gemma3-vllm-tpu-gke-autoscaling/) for complete setup including GCS bucket, Workload Identity, HF token, and metrics adapter.

## Repository Structure

```
.
├── docs/
│   └── index.html                  # Full article (GitHub Pages)
├── k8s/
│   ├── vllm-deployment.yaml        # vLLM Deployment + LoadBalancer Service
│   ├── pod-monitoring.yaml         # Prometheus metric scraping
│   └── hpa.yaml                    # HorizontalPodAutoscaler
├── scripts/
│   ├── load-test.sh                # Parallel load generator
│   ├── check-status.sh             # Quick status check
│   └── teardown.sh                 # Destroy all resources
├── deploy-tpu-cluster.sh           # Automated cluster deployment (zone scanning)
└── README.md
```

## Key Findings

- **`GPUS_ALL_REGIONS` quota blocks TPUs**, not just GPUs. Default is 0. Counted per chip.
- **More than 1 chip requires Google Cloud Sales** for quota approval.
- **Capacity errors auto-retry**; quota errors don't. Know the difference.
- **GKE Warden requires two nodeSelector labels** (`gke-tpu-accelerator` AND `gke-tpu-topology`).
- **Gemma 4 fails on vLLM TPU** due to shared/tied weight layers. Gemma 3 works.
- **`--accelerator` is for GPUs**; TPUs use `--machine-type`.

## Scripts

| Script | Purpose |
|---|---|
| `./scripts/check-status.sh` | Cluster, pods, HPA, health at a glance |
| `./scripts/load-test.sh 30` | Send 30 concurrent requests to trigger autoscaling |
| `./scripts/teardown.sh` | Remove all GCP resources |
| `./deploy-tpu-cluster.sh` | Scan zones for quota+capacity and deploy |

## License

MIT

## Shoutout 

This project was a part of #TPUSprint by Google's AI Developer Programs team. Google Cloud credits were provided for this project.

I thank the team for their invaluable support! <3
