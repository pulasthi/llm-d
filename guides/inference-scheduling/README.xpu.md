# Intel XPU Inference Scheduling Complete Deployment Guide

This document provides complete steps for deploying Intel XPU inference scheduling service on Kubernetes cluster using Qwen/Qwen3-0.6B model.

**Last Validated**: October 15, 2025

## Prerequisites

### Hardware Requirements
- Intel Data Center GPU Max 1550 or compatible Intel XPU device
- At least 8GB system memory
- Sufficient disk space (recommended at least 50GB available)

### Software Requirements
- Kubernetes cluster (v1.34.0+ recommended)
- Intel GPU Plugin deployed
- kubectl access with cluster-admin privileges

**⚠️ Important Kubernetes Version Notes:**
- **Kubernetes v1.30.0+** is required to avoid routingProxy container hang issues that occur in v1.28.x
- **Kubernetes v1.33.0+** is recommended for complete sidecar init container support (restartPolicy: Always)
- If using Kubernetes v1.28.x or below, pods may get stuck in Init:0/1 state due to incomplete sidecar support

## Step 0: Build Intel XPU Docker Image (Optional - For Development Only)

**⚠️ This step is NOT required for normal deployment!** 

Only build a custom image if you need to:
- Customize the vLLM version
- Modify the base image or dependencies
- Test development changes

### Clone Repository
```bash
# Clone the llm-d repository
git clone https://github.com/llm-d/llm-d
cd llm-d
```

### Build Custom Image
```bash
# Build with default vLLM version (commit: 3cd36660f7)
# Note: This creates ghcr.io/llm-d/llm-d-xpu-dev:v0.3.0 (dev tag)
make image-build DEVICE=xpu VERSION=v0.3.0
```
### Available Build Arguments
- `VLLM_VERSION`: vLLM version to build (default: 3cd36660f72f75b888c82a8feac93ea9f17c8e1e)
- `ONEAPI_VERSION`: Intel OneAPI toolkit version (default: 2025.1.3-0)
- `VERSION`: Docker image tag version (default: v0.3.0)

**⚠️ Important**: 
- **For production deployments, skip this step** and use the pre-built release image `ghcr.io/llm-d/llm-d-xpu:v0.3.0`
- If you build a custom image, it will be tagged as `ghcr.io/llm-d/llm-d-xpu-dev:v0.3.0` (note the `-dev` suffix)
- Remember to load custom images into your cluster (see Step 2 for Kind cluster loading instructions)
 

## Step 1: Install Tool Dependencies

```bash
# Navigate to llm-d repository (clone if needed)
git clone https://github.com/llm-d/llm-d
cd llm-d

# Install necessary tools (helm, helmfile, kubectl, yq, git, etc.)
./guides/prereq/client-setup/install-deps.sh

# Optional: Install development tools (including chart-testing)
./guides/prereq/client-setup/install-deps.sh --dev
```

**Installed tools include:**
- helm (v3.18.0+)
- helmfile (v1.1.3+)
- kubectl (v1.33.0+)
- yq (v4+)
- git (v2.30.0+)


## Step 2: Create Kubernetes Cluster (Optional)

If you don't have a Kubernetes cluster, you can create one using Kind:

```bash
# Create Kind cluster with Kubernetes v1.34.0 for full sidecar support
kind create cluster --name llm-d-cluster --image kindest/node:v1.34.0

# Verify cluster is running
kubectl cluster-info
kubectl get nodes
```

**Note**: If you need to upgrade an existing Kind cluster:
```bash
# Delete old cluster
kind delete cluster --name llm-d-cluster

# Create new cluster with v1.34.0
kind create cluster --name llm-d-cluster --image kindest/node:v1.34.0
```

### Load Built Image into Cluster (Only if you built a custom image in Step 0)

**Skip this if using the pre-built release image** - Kind/Kubernetes will automatically pull `ghcr.io/llm-d/llm-d-xpu:v0.3.0` when needed.

If you built a custom Intel XPU image in Step 0, load it into the Kind cluster:

```bash
# Load the custom built image into Kind cluster (note the -dev tag)
kind load docker-image ghcr.io/llm-d/llm-d-xpu-dev:v0.3.0 --name llm-d-cluster

# Verify image is loaded
docker exec -it llm-d-cluster-control-plane crictl images | grep llm-d
```

**Note**: If you use a custom image, you'll also need to update the image reference in `values_xpu.yaml` to use the `-dev` tag.

 

**⚠️ Critical: Intel GPU Plugin Required**

For Intel XPU deployments, you **MUST** have the Intel GPU Plugin deployed on your cluster **before** deploying the inference service. The plugin provides the `gpu.intel.com/i915` resource that Intel XPU workloads require.

### Deploy Intel GPU Plugin:
```bash
# Deploy Intel GPU Device Plugin v0.32.1
kubectl apply -k 'https://github.com/intel/intel-device-plugins-for-kubernetes/deployments/gpu_plugin?ref=v0.32.1'

# Verify plugin is running
kubectl get pods -n kube-system | grep intel-gpu-plugin

# Verify GPU resources are available
kubectl describe nodes | grep -A 5 "gpu.intel.com/i915"
```

**Expected output**: You should see available GPU resources like:
```
gpu.intel.com/i915:  4
```
  
**Note**: If you already have a Kubernetes cluster (v1.30.0+) with Intel GPU Plugin deployed, you can skip this step.


## Step 3: Install Gateway API Dependencies

```bash
# Navigate to gateway provider directory
cd guides/prereq/gateway-provider

# Install Gateway API CRDs and Gateway API Inference Extension
./install-gateway-provider-dependencies.sh
```

## Step 4: Deploy Gateway Control Plane

```bash
# Deploy Istio Gateway control plane
cd guides/prereq/gateway-provider
helmfile apply -f istio.helmfile.yaml

# Or deploy only control plane (if CRDs already exist)
helmfile apply -f istio.helmfile.yaml --selector kind=gateway-control-plane
```

## Step 5: Install Monitoring Stack (Optional)

Install Prometheus and Grafana for monitoring the inference service:

```bash
# Navigate to monitoring directory
cd docs/monitoring

# Install Prometheus and Grafana
./scripts/install-prometheus-grafana.sh
```

**Note**: This step is optional but recommended for production deployments. The monitoring stack provides:
- Prometheus for metrics collection
- Grafana for visualization dashboards
- Service monitors for llm-d components

## Step 6: Create HuggingFace Token Secret

```bash
# Set environment variables
export NAMESPACE=llm-d-xpu-is
export RELEASE_NAME_POSTFIX=r1
export HF_TOKEN_NAME=${HF_TOKEN_NAME:-llm-d-hf-token}
export HF_TOKEN=${HF_TOKEN:-your-hf-token}

# Create namespace
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Create HuggingFace token secret
kubectl create secret generic $HF_TOKEN_NAME \
    --from-literal="HF_TOKEN=${HF_TOKEN}" \
    --namespace ${NAMESPACE}
```

**Note**: For public models, you can use any valid HuggingFace token or leave it empty.

## Step 7: Deploy Intel XPU Inference Scheduling

```bash
# Navigate to inference-scheduling directory
cd guides/inference-scheduling

# Set environment variables
export NAMESPACE=llm-d-xpu-is
export RELEASE_NAME_POSTFIX=r1

# Deploy Intel XPU configuration using environment variables and parameters
helmfile apply -e xpu -n ${NAMESPACE}
```

**Important**: After deployment, it may take several minutes for the model to download from HuggingFace and load into memory. Monitor the pod logs to track progress.

This will deploy three main components:
1. **infra-r1**: Gateway infrastructure
2. **gaie-r1**: Gateway API inference extension  
3. **ms-r1**: Model service with Intel XPU support

## Step 8: Verify Deployment

### Check Helm Releases
```bash
helm list -n ${NAMESPACE}
```

Expected output:
```
NAME     NAMESPACE       REVISION   STATUS     CHART                     APP VERSION
gaie-r1  llm-d-xpu-is    1          deployed   inferencepool-v1.0.1      v1.0.1
infra-r1 llm-d-xpu-is    1          deployed   llm-d-infra-v1.3.3        v0.3.0
ms-r1    llm-d-xpu-is    1          deployed   llm-d-modelservice-v0.2.10 v0.2.0
```

### Check All Resources
```bash
kubectl get all -n ${NAMESPACE}
```

### Monitor Pod Startup Status
```bash
# Check decode pod status
kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode

# Monitor pod startup (real-time)
kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode -w
```

### View vLLM Startup Logs
```bash
# Get pod name
POD_NAME=$(kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode -o jsonpath='{.items[0].metadata.name}')

# View vLLM container logs
kubectl logs -n ${NAMESPACE} ${POD_NAME} -c vllm -f

# View recent logs
kubectl logs -n ${NAMESPACE} ${POD_NAME} -c vllm --tail=50
```

## Step 9: Test Inference Service

### Get Gateway External IP
```bash
kubectl get service -n ${NAMESPACE} infra-r1-inference-gateway-istio
```

### Perform Inference Requests

#### Method 1: Using Port Forwarding (Recommended)
```bash
# Port forward to local
kubectl port-forward -n ${NAMESPACE} service/infra-r1-inference-gateway-istio 8082:80 &

# Perform inference test
curl -X POST "http://localhost:8082/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "messages": [
      {
        "role": "user", 
        "content": "Hello, please introduce yourself"
      }
    ],
    "max_tokens": 100,
    "temperature": 0.7
  }'
```