---
date: '2026-07-22'
title: Installing Red Hat OpenShift AI 3.x on Azure Red Hat OpenShift
tags: ["ARO", "Azure", "AI", "ML", "GPU", "OpenShift AI", "RHOAI"]
authors:
  - Kumudu Herath
  - Paul Czarkowski
---

**Planning a POC?** Review the [ARO POC Guide for OpenShift AI](https://github.com/rh-mobb/poc-guides/blob/main/aro/04-special-considerations/04b-AI.md) for scenario planning, infrastructure sizing, and success criteria before starting installation.

---

# Installing Red Hat OpenShift AI 3.x on Azure Red Hat OpenShift

# AI

## Overview

Red Hat OpenShift AI provides a comprehensive platform for developing, training, and deploying AI/ML models on Azure Red Hat OpenShift (ARO). This guide covers deploying **OpenShift AI Self-Managed** (version 3.4+) on ARO clusters, including configuration for GPU workloads, storage options, and deployment patterns for both connected and egress-restricted environments.

**Why this matters:** This guide covers OpenShift AI Self-Managed deployment patterns optimized for Azure infrastructure, including:

- **GPU Support** - NVIDIA GPU Operator configuration for Azure NC/ND-series VMs
- **Storage Integration** - Azure Disk, Azure Files, OpenShift Data Foundation (ODF), and object storage for pipeline artifacts
- **Egress-Restricted Deployments** - Leveraging ARO egress lockdown for private clusters
- **Model Serving** - KServe and ModelMesh for production inference workloads
- **Data Science Pipelines** - Kubeflow Pipelines integration with Azure Blob Storage or S3-compatible backends

---

## 🗺️ Quick Start Navigator

**New to OpenShift AI?** Choose your deployment path based on your needs:

### Decision Tree

```
                    OpenShift AI on ARO
                            │
                            ▼
              ┌─────────────────────────┐
              │ Do you need GPU support?│
              └─────────────────────────┘
                    │             │
              ┌─────┘             └─────┐
              NO                        YES
              │                           │
              ▼                           ▼
    ┌──────────────────┐        ┌──────────────────┐
    │Need Model Serving│        │ Full Deployment  │
    │or Pipelines?     │        │ (Path C)         │
    └──────────────────┘        │ • GPU Workers    │
         │         │             │ • Training       │
    ┌────┘         └────┐        │ • ⏱️ 120 min     │
    NO                 YES       └──────────────────┘
    │                   │
    ▼                   ▼
┌─────────────┐   ┌─────────────┐
│   Minimal   │   │  Standard   │
│  (Path A)   │   │  (Path B)   │
│ • Dashboard │   │ • KServe    │
│ • Notebooks │   │ • Pipelines │
│ • ⏱️ 30 min  │   │ • ⏱️ 60 min  │
└─────────────┘   └─────────────┘
```

### 📋 Deployment Paths Overview

| Path | Time | Workers | Monthly Cost* | What You Get | Best For |
|------|------|---------|---------------|--------------|----------|
| **[Path A: Minimal](#path-a-minimal-deployment-dashboard--workbenches)** | 30 min | 2-3 (D8s_v3) | ~$276 | Dashboard + Notebooks | Learning, development, POCs |
| **[Path B: Standard](#path-b-standard-deployment--model-serving--pipelines)** | 60 min | 3-4 (D16s_v3) | ~$1,686 | + Model Serving + Pipelines | Production ML workflows |
| **[Path C: Full](#path-c-full-deployment--gpu--advanced-features)** | 120 min | 5+ (+ GPU) | ~$2,454 | + GPU Training + Advanced | Large-scale ML platform |

*Estimated Azure costs based on pay-as-you-go pricing

### 🎯 Quick Links by Scenario

**I want to...**
- **Just try OpenShift AI** → Start with [Path A: Minimal](#path-a-minimal-deployment-dashboard--workbenches)
- **Deploy models to production** → Go to [Path B: Standard](#path-b-standard-deployment--model-serving--pipelines)
- **Train large ML models with GPUs** → Jump to [Path C: Full](#path-c-full-deployment--gpu--advanced-features)
- **Use OpenShift Data Foundation storage** → See [Part 3: Optional Enhancements](#part-3-optional-enhancements)
- **Deploy in air-gapped/private cluster** → Check [Part 4: Advanced Topics](#part-4-advanced-topics)
- **Troubleshoot an issue** → Visit [Part 5: Troubleshooting](#part-5-reference--troubleshooting)

### 📖 Guide Structure

This guide is organized into 5 parts:

1. **[Part 1: Foundation](#part-1-foundation-required-for-all-paths)** - Prerequisites and base OpenShift AI installation (required for all paths)
2. **[Part 2: Deployment Paths](#part-2-deployment-paths)** - Choose Path A, B, or C based on your needs
3. **[Part 3: Optional Enhancements](#part-3-optional-enhancements)** - ODF storage, GPU advanced features, TrustyAI
4. **[Part 4: Advanced Topics](#part-4-advanced-topics)** - Egress-restricted deployments, upgrades, uninstall
5. **[Part 5: Reference & Troubleshooting](#part-5-reference--troubleshooting)** - Complete matrices, validation, troubleshooting

---

## Part 1: Foundation (Required for All Paths)

This section covers prerequisites and initial setup required regardless of which deployment path you choose.

### Prerequisites

Before installing OpenShift AI on ARO, ensure the following requirements are met:

### Cluster Requirements

- [ ] **ARO cluster** with supported OpenShift version for OpenShift AI
- [ ] **Worker node capacity** for AI workloads:
  - Minimum 3 worker nodes
  - Recommended: 16+ vCPUs, 64+ GB RAM per node for AI workloads
  - For GPU workloads: NC-series or ND-series VMs (see GPU Support section)
  - **High-memory instances** (D-series v5 with 8:1 memory-to-vCPU ratio): Cost-effective alternative to GPUs for large model inference and training that can take advantage of increased memory without GPU acceleration
- [ ] **Cluster admin access** to install operators and configure components

### Storage Requirements

- [ ] **Persistent storage** configured:
  - Azure Disk CSI driver (default on ARO, supports RWO volumes)
  - For RWX (ReadWriteMany) volumes, choose one of:
    - Azure Files CSI driver (default on ARO)
    - OpenShift Data Foundation (ODF) in Internal mode
- [ ] **Object storage** for Data Science Pipelines (required for pipeline artifacts and data):
  - Azure Blob Storage (recommended for ARO)
  - Azure Data Lake Storage Gen2 (better for large-scale data science workloads)
  - Self-hosted MinIO
  - External S3-compatible providers with proxy solutions
  - Requires: endpoint URL, access key, secret key, container/bucket name

### Operator Dependencies

OpenShift AI requires the following operators to be installed manually via OperatorHub before enabling certain features:

- [ ] **Red Hat OpenShift Serverless Operator** - Required for KServe model serving
- [ ] **Red Hat OpenShift Service Mesh Operator** - Required for KServe model serving
- [ ] **Red Hat OpenShift Pipelines Operator** - Required for Data Science Pipelines

**Important:** The operators themselves must be installed manually via OperatorHub. OpenShift AI then automatically provisions the necessary configuration resources (ServiceMeshControlPlane, KNativeServing) when you enable KServe or Data Science Pipelines in your DataScienceCluster.

### Component-to-Operator Dependency Matrix

This table shows which operators are required for each OpenShift AI component:

| OpenShift AI Component | Required Operators | Installation Type | Auto-Configured Resources | Notes |
|------------------------|-------------------|-------------------|---------------------------|-------|
| **Dashboard** | • OpenShift AI Operator<br>• Service Mesh Operator | • Manual (Step 2)<br>• Auto-installed | • Gateway routes<br>• OAuth proxy | Core UI component |
| **Workbenches** | • OpenShift AI Operator | • Manual (Step 2) | • Jupyter notebook images<br>• PVC templates | Interactive development environments |
| **Data Science Pipelines** | • OpenShift AI Operator<br>• OpenShift Pipelines Operator<br>• S3-compatible storage | • Manual (Step 2)<br>• Manual (Step 3.2)<br>• Manual (Step 4) | • Tekton pipelines<br>• Pipeline definitions | Requires S3 bucket configuration |
| **KServe (Model Serving)** | • OpenShift AI Operator<br>• OpenShift Serverless Operator<br>• Service Mesh Operator<br>• Custom Metrics Autoscaler (optional) | • Manual (Step 2)<br>• Manual (Step 3.1)<br>• Auto-installed<br>• Manual (Step 3.7) | • KNativeServing<br>• ServiceMeshControlPlane<br>• Istio gateways<br>• KEDA autoscaling | Multi-model serving platform |
| **Training Operator** | • OpenShift AI Operator<br>• Cert-Manager<br>• JobSet Operator<br>• Kueue Operator (optional) | • Manual (Step 2)<br>• Manual (Step 3.4)<br>• Manual (Step 3.6)<br>• Manual (Step 3.5) | • Kubeflow Training CRDs<br>• Distributed training jobs<br>• Job batching | PyTorch, TensorFlow training |
| **Ray** | • OpenShift AI Operator<br>• Cert-Manager<br>• Kueue Operator | • Manual (Step 2)<br>• Manual (Step 3.4)<br>• Manual (Step 3.5) | • Ray cluster CRDs<br>• Ray operator<br>• Job queuing | Distributed compute framework |
| **Kueue (Component)** | • OpenShift AI Operator<br>• Cert-Manager<br>• Kueue Operator | • Manual (Step 2)<br>• Manual (Step 3.4)<br>• Manual (Step 3.5) | • Kueue CRDs<br>• Job queuing system | Batch job scheduling |
| **Model Registry** | • OpenShift AI Operator | • Manual (Step 2) | • MLflow integration<br>• Model metadata storage | Model versioning and tracking |
| **TrustyAI** | • OpenShift AI Operator<br>• MariaDB Operator (database mode) | • Manual (Step 2)<br>• Manual (Step 3.8) | • Model monitoring<br>• Bias detection | Model explainability and fairness |
| **CodeFlare** | • OpenShift AI Operator<br>• Ray (optional) | • Manual (Step 2)<br>• Optional | • Distributed workload SDK<br>• Ray cluster integration | Distributed ML workloads |

### Operator Installation Summary

| Operator Name | Installation Namespace | Required/Optional | Installed By | Install Step | Approval Mode |
|---------------|----------------------|-------------------|--------------|--------------|---------------|
| **Red Hat OpenShift AI** | `redhat-ods-operator` | **Required** | Manual | Step 2 | Manual |
| **Red Hat OpenShift Service Mesh 3** | `redhat-ods-operator` | **Required** (for KServe) | Auto (OpenShift AI dependency) | Step 2 | Automatic |
| **Red Hat OpenShift Serverless** | `openshift-serverless` | **Required** (for KServe) | Manual | Step 3.1 | Automatic |
| **Red Hat OpenShift Pipelines** | `openshift-operators` | **Required** (for DSP) | Manual | Step 3.2 | Automatic |
| **Red Hat Cert-Manager** | `cert-manager-operator` | **Required** (for Trainer/Ray/Kueue) | Manual | Step 3.4 | Automatic |
| **Kueue Operator** | `openshift-kueue-operator` | **Recommended** (for Ray/Trainer) | Manual | Step 3.5 | Automatic |
| **JobSet Operator** | `openshift-jobset-operator` | **Recommended** (for Trainer) | Manual | Step 3.6 | Automatic |
| **Leader Worker Set** | `openshift-lws-operator` | **Optional** (for distributed inference) | Manual | Step 3.7 | Automatic |
| **Custom Metrics Autoscaler (KEDA)** | `openshift-keda` | **Optional** (for autoscaling) | Manual | Step 3.8 | Automatic |
| **MariaDB Operator** | `mariadb-operator` | **Optional** (for TrustyAI database mode) | Manual | Step 3.9 | Automatic |
| **Node Feature Discovery (NFD)** | `openshift-nfd` | **Optional** (GPU only) | Manual | Step 3.10 | Automatic |
| **NVIDIA GPU Operator** | `nvidia-gpu-operator` | **Optional** (GPU only) | Manual | Step 3.11 | Automatic |

**Note:** ARO clusters may have governance policies that require manual InstallPlan approval even when `installPlanApproval: Automatic` is set. All operator installation scripts in Step 3 include automatic InstallPlan detection and approval to handle this.

### Minimal vs Full Installation

**Minimal Installation (Dashboard + Workbenches only):**
```
Required Operators:
  ✓ Red Hat OpenShift AI Operator
  ✓ Red Hat OpenShift Service Mesh Operator (auto-installed)

Components Enabled:
  - Dashboard
  - Workbenches
```

**Standard Installation (Model Serving + Pipelines):**
```
Required Operators:
  ✓ Red Hat OpenShift AI Operator
  ✓ Red Hat OpenShift Service Mesh Operator (auto-installed)
  ✓ Red Hat OpenShift Serverless Operator
  ✓ Red Hat OpenShift Pipelines Operator
  ✓ S3-compatible storage (Azure Blob/MinIO/AWS S3)

Components Enabled:
  - Dashboard
  - Workbenches
  - Data Science Pipelines
  - KServe (Model Serving)
  - Model Registry
```

**Full Installation (All Features + Training):**
```
Required Operators:
  ✓ Red Hat OpenShift AI Operator
  ✓ Red Hat OpenShift Service Mesh Operator (auto-installed)
  ✓ Red Hat OpenShift Serverless Operator
  ✓ Red Hat OpenShift Pipelines Operator
  ✓ Red Hat Cert-Manager Operator
  ✓ Kueue Operator
  ✓ JobSet Operator
  ✓ S3-compatible storage (Azure Blob/MinIO/AWS S3)

Recommended (Advanced Features):
  ✓ Leader Worker Set Operator (distributed inference)
  ✓ Custom Metrics Autoscaler (autoscaling)
  ✓ MariaDB Operator (TrustyAI database mode)

Optional (GPU Workloads):
  ✓ Node Feature Discovery Operator
  ✓ NVIDIA GPU Operator

Components Enabled:
  - Dashboard
  - Workbenches
  - Data Science Pipelines
  - KServe (Model Serving)
  - Training Operator (with distributed training)
  - Ray (distributed compute)
  - Kueue (job queuing)
  - Model Registry
  - TrustyAI
```

**References:**
- [Installing the Single-Model Serving Platform](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.22/html/installing_and_uninstalling_openshift_ai_self-managed/installing-the-single-model-serving-platform_component-install) - Service Mesh and Serverless configuration
- [Working with Data Science Pipelines](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/2.8/html/working_on_data_science_projects/working-with-data-science-pipelines_ds-pipelines) - Pipelines operator requirement

### Foundation: Deployment Options

Before starting installation, understand your deployment environment:

### Connected Deployment (Standard)

Standard ARO clusters with internet egress can install OpenShift AI directly from Red Hat OperatorHub. This is the simplest deployment method and supports automatic operator updates.

**Use Cases:**
- Development and testing environments
- Production workloads with internet access
- Azure commercial cloud deployments

### Egress-Restricted Deployment (ARO Egress Lockdown)

ARO provides an **egress lockdown** feature that proxies calls to required Azure and Red Hat domains through the ARO service using Azure private endpoints. This enables clusters with restricted egress (including zero public IPs) to function without direct internet access.

**How Egress Lockdown Works:**
- Proxies traffic to required domains (management.azure.com, Red Hat registries) through ARO service
- Uses Azure private endpoints within the cluster resource group
- Doesn't require customer internet access for ARO services to function
- Requires Server Name Indication (SNI) extension to TLS for customer workloads
- Enabled by default for new ARO clusters

**Verify Egress Lockdown Status:**
```bash
oc get cluster.aro.openshift.io cluster -o go-template='{{ if .spec.gatewayDomains }}{{ "Egress Lockdown Feature Enabled" }}{{ else }}{{ "Egress Lockdown Feature Disabled" }}{{ end }}{{ "\n" }}'
```

**Use Cases:**
- Azure Government (MAG) deployments
- Private clusters with UserDefinedRouting egress
- Compliance requirements restricting internet access
- Defense, government, healthcare, financial services sectors

**Reference:** [ARO Egress Lockdown Overview](https://learn.microsoft.com/en-us/azure/openshift/concepts-egress-lockdown)

### Disconnected/Air-Gapped Deployment Considerations

**⚠️ Important Limitation for ARO:**

ARO is a jointly managed service operated by Microsoft and Red Hat, which requires connectivity to management infrastructure for cluster operations, monitoring, and support. While ARO supports **egress lockdown** to eliminate direct internet access from cluster nodes, it cannot operate in a fully disconnected/air-gapped environment.

**For truly air-gapped OpenShift AI deployments:**
- Use **self-managed OpenShift Container Platform (OCP)** on Azure VMs
- Deploy mirror registry for container images
- Use oc-mirror plugin to mirror operator catalogs and images
- Follow Red Hat's disconnected installation procedures

**Key Distinction:**
- **ARO with Egress Lockdown**: Private cluster, zero public IPs, proxied access to required services ✅
- **Fully Air-Gapped ARO**: Not supported due to managed service architecture ❌

**Reference:** [How to operate OpenShift in air-gapped environments](https://developers.redhat.com/articles/2026/03/19/how-operate-openshift-air-gapped-environments)

### Foundation: Installation Steps

**Complete Steps 1-2 before choosing your deployment path.**

## Configuration Steps

### 1. Verify Cluster Resources

Before installing operators, verify cluster has sufficient resources:

```bash
# Check cluster version
oc version

# Verify storage classes
oc get storageclass

# Check worker node capacity (formatted table with memory in GB)
oc get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory' | awk 'NR==1{printf "%-55s %-10s %-6s%s\n",$1,$2,"vCPUs","MEMORY(GB)"}NR>1{mem=$4; gsub(/Ki/,"",mem); printf "%-55s %-10s %-6s %.0f GB\n",$1,$2,$3,mem/1024/1024}'

# Expected: At least 2 workers with 8+ vCPUs, 32+ GiB RAM each
```

### 2. Install OpenShift AI Operator

Install the OpenShift AI Self-Managed operator from OperatorHub:

```bash
# Create namespace for OpenShift AI operator
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-ods-operator
  namespace: redhat-ods-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable-3.x  # Self-Managed 3.x channel
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual
  # startingCSV: rhods-operator.3.3.4  # Optional: Pin to specific version, or omit for latest 3.x
EOF

# Approve InstallPlan (manual control)
# Wait for InstallPlan to be created (may take 10-30 seconds)
echo "Waiting for InstallPlan to be created..."
for i in {1..30}; do
  INSTALL_PLAN=$(oc get installplan -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' 2>/dev/null | head -1)
  if [ -n "$INSTALL_PLAN" ]; then
    echo "Found InstallPlan: $INSTALL_PLAN"
    oc patch installplan $INSTALL_PLAN -n redhat-ods-operator --type merge --patch '{"spec":{"approved":true}}'
    echo "InstallPlan approved"
    break
  fi
  echo "Waiting... ($i/30)"
  sleep 10
done

if [ -z "$INSTALL_PLAN" ]; then
  echo "Warning: No pending InstallPlan found after 5 minutes. Check if it was auto-approved or if there's an error."
  oc get installplan -n redhat-ods-operator
fi

# Verify operator installation
oc get csv -n redhat-ods-operator
oc wait --for=condition=Ready pod -l name=rhods-operator -n redhat-ods-operator --timeout=600s
```

**Important Configuration Notes:**
- `channel: stable-3.x` - Uses the Self-Managed 3.x channel (latest compatible 3.x version)
  - **DO NOT use `channel: stable`** - This is for older versions, always use `stable-3.x` or version-specific channels
  - For OpenShift AI 3.3.x specifically, use `channel: stable-3.3`
  - For latest 3.x (currently 3.4.x), use `channel: stable-3.x`
- `installPlanApproval: Manual` - Prevents automatic upgrades, giving you control over version updates
- `startingCSV` - Optional field to pin to specific operator version
  - **Omit this field** to get the latest version in the channel
  - **Or specify version** like `rhods-operator.3.3.4` for version pinning
  - If the specified version doesn't exist in the catalog, installation will fail with "constraints not satisfiable"

### 3. Install Required Dependent Operators

**📚 This is the comprehensive reference section** for all 11 operators. If you're following a deployment path, install only the operators your path requires and use this section for detailed instructions.

**Path-based installation guide:**
- **Path A (Minimal):** No additional operators needed — skip to [Part 2: Path A](#path-a-minimal-deployment)
- **Path B (Standard):** Install operators 3.1, 3.2, 3.4, 3.5, 3.6 — see [Part 2: Path B](#path-b-standard-deployment) for your streamlined guide
- **Path C (Full):** Install all operators (3.1-3.11) — see [Part 2: Path C](#path-c-full-deployment) for your streamlined guide

**Operator Quick Reference:**

| Operator | Path | Purpose |
|----------|------|---------|
| 3.1 Serverless | B, C | KServe model serving |
| 3.2 Pipelines | B, C | Data Science Pipelines |
| 3.3 Service Mesh | Auto | Auto-installed with OpenShift AI |
| 3.4 Cert-Manager | B, C | Certificate management for Training Operator |
| 3.5 Kueue | B, C | Job queuing and resource management |
| 3.6 JobSet | B, C | Distributed training job management |
| 3.7 Leader Worker Set | C | Advanced distributed inference (optional) |
| 3.8 KEDA | C | Event-driven autoscaling (optional) |
| 3.9 MariaDB | C | TrustyAI database mode (optional) |
| 3.10 NFD | C | GPU node detection (required for GPU) |
| 3.11 GPU Operator | C | NVIDIA GPU support (required for GPU) |

---

#### 3.1. Install Red Hat OpenShift Serverless Operator

**🔵 Required for:** Path B, Path C (KServe model serving)

```bash
# Create namespace
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-serverless
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: serverless-operators
  namespace: openshift-serverless
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-serverless
spec:
  channel: stable
  installPlanApproval: Automatic
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n openshift-serverless -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n openshift-serverless --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Verify installation (operator installs quickly)
oc get csv -n openshift-serverless
oc get pods -n openshift-serverless
```

**Note:** Do NOT create a `KnativeServing` resource manually - OpenShift AI creates it automatically when you enable KServe in the DataScienceCluster.

#### 3.2. Install Red Hat OpenShift Pipelines Operator

**🔵 Required for:** Path B, Path C (Data Science Pipelines)

```bash
# Create Subscription (installs in openshift-operators namespace)
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n openshift-operators -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n openshift-operators --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Verify installation (operator installs quickly)
oc get csv -n openshift-operators | grep pipelines
oc get pods -n openshift-pipelines
```

#### 3.3. Verify Red Hat OpenShift Service Mesh Operator

**⚙️ Auto-installed:** All paths (KServe model serving)

```bash
# Check Service Mesh operator
oc get csv -n redhat-ods-operator | grep servicemesh

# Expected output: servicemeshoperator3.vX.Y.Z ... Succeeded
```

**Note:** Service Mesh v3 is automatically installed when you install OpenShift AI operator. Do NOT create a `ServiceMeshControlPlane` manually - OpenShift AI creates it automatically.

#### 3.4. Install Red Hat Cert-Manager Operator

**🔵 Required for:** Path B, Path C (certificate management for Training Operator, Kueue, JobSet)

```bash
# Create namespace
oc create namespace cert-manager-operator

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n cert-manager-operator -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n cert-manager-operator --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Verify installation (operator installs quickly)
oc get csv -n cert-manager-operator
oc get pods -n cert-manager
```

**Note:** Cert-Manager is a foundational operator required by multiple OpenShift AI components. It automatically creates certificates for secure communication between components.

#### 3.5. Install Kueue Operator

**🔵 Required for:** Path B, Path C (job queuing and resource management for Training Operator)

```bash
# Create namespace
oc create namespace openshift-kueue-operator

# Create OperatorGroup (AllNamespaces mode - IMPORTANT!)
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kueue-operator
  namespace: openshift-kueue-operator
spec: {}
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kueue-operator
  namespace: openshift-kueue-operator
spec:
  channel: stable-v1.3
  installPlanApproval: Automatic
  name: kueue-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n openshift-kueue-operator -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n openshift-kueue-operator --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Verify installation (operator installs quickly)
oc get csv -n openshift-kueue-operator
oc get pods -n openshift-kueue-system
```

**Important:** Kueue OperatorGroup must have empty `spec: {}` (AllNamespaces mode). Using `targetNamespaces` causes installation failure with "OwnNamespace InstallModeType not supported".

#### 3.6. Install JobSet Operator

**🔵 Required for:** Path B, Path C (distributed training job management)

```bash
# Create namespace
oc create namespace openshift-jobset-operator

# Create OperatorGroup (namespace-scoped, NOT AllNamespaces)
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: jobset-operator
  namespace: openshift-jobset-operator
spec:
  targetNamespaces:
  - openshift-jobset-operator
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: job-set
  namespace: openshift-jobset-operator
spec:
  channel: stable-v1.0
  installPlanApproval: Automatic
  name: job-set
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n openshift-jobset-operator -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n openshift-jobset-operator --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Verify installation (operator installs quickly)
oc get csv -n openshift-jobset-operator
oc get pods -n openshift-jobset-system
```

#### 3.7. Install Leader Worker Set Operator (Optional)

**🟣 Optional for:** Path C (advanced distributed inference workloads)

```bash
# Create namespace
oc create namespace openshift-lws-operator

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: lws-operator
  namespace: openshift-lws-operator
spec: {}
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lws-operator
  namespace: openshift-lws-operator
spec:
  channel: stable-v1.0
  installPlanApproval: Automatic
  name: lws-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n openshift-lws-operator -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n openshift-lws-operator --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Wait for operator installation
sleep 10
oc wait --for=condition=Ready csv -l operators.coreos.com/lws-operator.openshift-lws-operator -n openshift-lws-operator --timeout=600s

# Verify installation
oc get csv -n openshift-lws-operator
oc get pods -n openshift-lws-system
```

#### 3.8. Install Custom Metrics Autoscaler (KEDA) (Optional)

**🟣 Optional for:** Path C (event-driven autoscaling for advanced workloads)

```bash
# Create namespace
oc create namespace openshift-keda

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: keda-operator
  namespace: openshift-keda
spec: {}
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-custom-metrics-autoscaler-operator
  namespace: openshift-keda
spec:
  channel: stable
  installPlanApproval: Automatic
  name: openshift-custom-metrics-autoscaler-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n openshift-keda -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n openshift-keda --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Wait for operator installation
sleep 10
oc wait --for=condition=Ready csv -l operators.coreos.com/openshift-custom-metrics-autoscaler-operator.openshift-keda -n openshift-keda --timeout=600s

# Verify installation
oc get csv -n openshift-keda
oc get pods -n openshift-keda
```

#### 3.9. Install MariaDB Operator (Optional)

**🟣 Optional for:** Path C (TrustyAI database mode - required only if using TrustyAI with database persistence)

```bash
# Create namespace
oc create namespace mariadb-operator

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: mariadb-operator
  namespace: mariadb-operator
spec: {}
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mariadb-operator
  namespace: mariadb-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: mariadb-operator
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n mariadb-operator -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n mariadb-operator --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Wait for operator installation
sleep 10
oc wait --for=condition=Ready csv -l operators.coreos.com/mariadb-operator.mariadb-operator -n mariadb-operator --timeout=600s

# Verify installation
oc get csv -n mariadb-operator
oc get pods -n mariadb-operator
```

**Note:** MariaDB Operator is from `certified-operators` catalog, not `redhat-operators`.

#### 3.10. Install Node Feature Discovery Operator

**🔴 Required for:** Path C with GPU (GPU hardware detection - mandatory for GPU support)

```bash
# Create namespace
oc create namespace openshift-nfd

# Create OperatorGroup (namespace-scoped, NOT AllNamespaces)
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nfd-operators
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n openshift-nfd -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n openshift-nfd --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Wait for operator installation
sleep 10
oc wait --for=condition=Ready csv -l operators.coreos.com/nfd.openshift-nfd -n openshift-nfd --timeout=600s

# Create NFD instance (DO NOT specify image version - let operator manage it)
cat <<EOF | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    servicePort: 12000
  workerConfig:
    configData: |
      sources:
        pci:
          deviceClassWhitelist:
            - "0200"
            - "03"
            - "12"
          deviceLabelFields:
            - "vendor"
EOF

# Verify installation
oc get csv -n openshift-nfd
oc get pods -n openshift-nfd
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true  # Check GPU-labeled nodes
```

**Important:** Do NOT specify a hardcoded image version in the NFD instance - let the operator manage the image version to avoid compatibility issues.

#### 3.11. Install NVIDIA GPU Operator

**🔴 Required for:** Path C with GPU (NVIDIA GPU drivers and device plugin - mandatory for GPU support)

**⚠️ IMPORTANT:** Do NOT create a ClusterPolicy until GPU nodes exist in the cluster. Create the operator subscription now, but wait to create ClusterPolicy in the GPU Support section after GPU nodes are provisioned.

```bash
# Create namespace
oc create namespace nvidia-gpu-operator

# Create OperatorGroup
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
EOF

# Create Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF

# Check for pending InstallPlan and approve if needed
sleep 10
INSTALL_PLAN=$(oc get installplan -n nvidia-gpu-operator -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' | head -1)
if [ -n "$INSTALL_PLAN" ]; then
  echo "Approving InstallPlan: $INSTALL_PLAN"
  oc patch installplan $INSTALL_PLAN -n nvidia-gpu-operator --type merge --patch '{"spec":{"approved":true}}'
else
  echo "No pending InstallPlan found (may already be approved)"
fi

# Wait for operator installation
sleep 10
oc wait --for=condition=Ready csv -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator -n nvidia-gpu-operator --timeout=600s

# Verify installation
oc get csv -n nvidia-gpu-operator
oc get pods -n nvidia-gpu-operator
```

**Note:** ClusterPolicy creation is documented in the GPU Support section. Creating ClusterPolicy before GPU nodes exist causes operator errors.

#### 3.12. Verify All Installed Operators

Run this comprehensive verification script to check all operators:

```bash
#!/bin/bash

echo "=== OpenShift AI Operator Installation Verification ==="
echo ""

# Function to check operator
check_operator() {
  local name=$1
  local namespace=$2
  local csv_label=$3
  
  echo -n "Checking $name in $namespace... "
  if oc get csv -n $namespace -l $csv_label &>/dev/null; then
    local phase=$(oc get csv -n $namespace -l $csv_label -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [ "$phase" = "Succeeded" ]; then
      echo "✅ Running ($phase)"
      return 0
    else
      echo "⚠️  $phase"
      return 1
    fi
  else
    echo "⚠️  Not Found"
    return 1
  fi
}

# Required operators
check_operator "OpenShift AI" "redhat-ods-operator" "operators.coreos.com/rhods-operator.redhat-ods-operator"
check_operator "Service Mesh" "redhat-ods-operator" "operators.coreos.com/servicemeshoperator.redhat-ods-operator"
check_operator "Serverless" "openshift-serverless" "operators.coreos.com/serverless-operator.openshift-serverless"
check_operator "Pipelines" "openshift-operators" "operators.coreos.com/openshift-pipelines-operator-rh.openshift-operators"
check_operator "Cert-Manager" "cert-manager-operator" "operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator"
check_operator "Kueue" "openshift-kueue-operator" "operators.coreos.com/kueue-operator.openshift-kueue-operator"
check_operator "JobSet" "openshift-jobset-operator" "operators.coreos.com/job-set.openshift-jobset-operator"

# Optional operators
echo ""
echo "Optional Operators:"
check_operator "Leader Worker Set" "openshift-lws-operator" "operators.coreos.com/lws-operator.openshift-lws-operator" || true
check_operator "KEDA" "openshift-keda" "operators.coreos.com/openshift-custom-metrics-autoscaler-operator.openshift-keda" || true
check_operator "MariaDB" "mariadb-operator" "operators.coreos.com/mariadb-operator.mariadb-operator" || true
check_operator "NFD" "openshift-nfd" "operators.coreos.com/nfd.openshift-nfd" || true
check_operator "GPU Operator" "nvidia-gpu-operator" "operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator" || true

echo ""
echo "=== Verification Complete ==="
```

---

## Part 2: Deployment Paths

**Foundation complete?** ✅ Now choose your deployment path based on your requirements.

Each path builds on the previous one. You can start with Path A and upgrade to B or C later.

---

### Path A: Minimal Deployment (Dashboard + Workbenches)

**⏱️ Time:** 30 minutes | **💰 Cost:** ~$276/month | **👥 Best for:** Learning, development, POCs

#### What You Get
- ✅ OpenShift AI Dashboard
- ✅ Jupyter Notebooks (Workbenches)  
- ✅ Model Registry
- ✅ Basic data science development environment

#### Prerequisites
- ✅ Foundation Steps 1-2 completed
- ✅ 2-3 worker nodes (minimum: Standard_D8s_v3)
- ✅ Default storage class configured

#### Installation Steps

**Step 1: Verify Operators**

Path A only needs **2 operators** (already installed):
- ✅ OpenShift AI Operator (Step 2)
- ✅ Service Mesh v3 (auto-installed with OpenShift AI)

```bash
# Verify both operators are running
oc get csv -n redhat-ods-operator

# Expected: rhods-operator and servicemeshoperator3 both "Succeeded"
```

**Step 2: Configure DataScienceCluster (Minimal)**

Create a minimal DataScienceCluster with just Dashboard and Workbenches:

```bash
cat <<EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    workbenches:
      managementState: Managed
    modelregistry:
      managementState: Managed
    # All other components disabled
    datasciencepipelines:
      managementState: Removed
    kserve:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    codeflare:
      managementState: Removed
    ray:
      managementState: Removed
    kueue:
      managementState: Removed
    trainingoperator:
      managementState: Removed
EOF
```

**Step 3: Validate Installation**

```bash
# Check DataScienceCluster status
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'
# Expected: Ready

# Get dashboard URL
DASHBOARD_URL=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')
echo "OpenShift AI Dashboard: https://$DASHBOARD_URL"

# Access dashboard and verify workbench creation works
```

#### ✅ Path A Complete!

**What's Next?**
- Create your first Jupyter notebook workbench
- Explore pre-built notebook images
- Ready for production ML? → [Upgrade to Path B](#path-b-standard-deployment)

---

### Path B: Standard Deployment (+ Model Serving + Pipelines)

**⏱️ Time:** 60 minutes | **💰 Cost:** ~$1,686/month | **👥 Best for:** Production ML workflows

#### What You Get
- ✅ Everything in Path A, plus:
- ✅ **KServe Model Serving** - Deploy models to production endpoints
- ✅ **Data Science Pipelines** - Kubeflow Pipelines for ML workflows
- ✅ **Training Operator** - Distributed training (PyTorch, TensorFlow)
- ✅ **Production-ready ML platform**

#### Prerequisites
- ✅ Path A completed **OR** Foundation Steps 1-2
- ✅ 3-4 worker nodes (recommended: Standard_D16s_v3)
- ✅ **S3-compatible object storage** (Azure Blob, MinIO, or AWS S3)

#### Installation Steps

**Step 1: Install Additional Operators**

Path B requires **6 operators**. Install these from [Step 3](#3-install-required-dependent-operators):

```bash
# Required operators for Path B:
# - 3.1: Serverless (KServe requirement)
# - 3.2: Pipelines (Data Science Pipelines)
# - 3.3: Service Mesh (verify auto-installed)
# - 3.4: Cert-Manager (Training operator requirement)
# - 3.5: Kueue (job queuing)
# - 3.6: JobSet (distributed training)
```

Follow the detailed installation instructions in Step 3 for each operator, then return here.

**Step 2: Configure Object Storage**

Data Science Pipelines requires S3-compatible object storage. Choose one option from [Step 5](#5-configure-object-storage-for-data-science-pipelines):

- **Option A:** Azure Blob Storage + MinIO gateway
- **Option B:** Self-hosted MinIO
- **Option C:** External S3 (AWS S3 or compatible)

**Step 3: Configure DataScienceCluster (Standard)**

Enable model serving and pipelines:

```bash
cat <<EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    workbenches:
      managementState: Managed
    modelregistry:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
    kserve:
      managementState: Managed
      serving:
        ingressGateway:
          certificate:
            type: OpenshiftDefaultIngress
        managementState: Managed
        name: knative-serving
    trainingoperator:
      managementState: Managed
    # Disabled components
    modelmeshserving:
      managementState: Removed
    codeflare:
      managementState: Removed
    ray:
      managementState: Removed
    kueue:
      managementState: Removed
EOF

# Wait for DataScienceCluster to be ready (this may take 5-10 minutes)
echo "Waiting for DataScienceCluster to be ready..."
oc wait --for=condition=Ready datasciencecluster/default-dsc --timeout=600s
```

**Step 4: Validate Installation**

```bash
# Check DataScienceCluster
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'

# Verify KServe
oc get knativeserving knative-serving -n knative-serving

# Verify namespaces
oc get projects | grep -E 'rhods|redhat-ods|knative|istio'

# Dashboard URL
DASHBOARD_URL=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')
echo "Dashboard: https://$DASHBOARD_URL"
```

#### ✅ Path B Complete!

**What's Next?**
- Deploy your first model with KServe
- Create a Data Science Pipeline
- Need GPU training? → [Upgrade to Path C](#path-c-full-deployment-gpu--training)

---

### Path C: Full Deployment (+ GPU + Advanced Features)

**⏱️ Time:** 2 hours | **💰 Cost:** ~$2,454/month | **👥 Best for:** Large-scale ML platform with GPU training

#### What You Get
- ✅ Everything in Path B, plus:
- ✅ **GPU-accelerated training** - NVIDIA T4, V100, or A100 GPUs
- ✅ **Distributed training** - Multi-GPU training jobs
- ✅ **Ray framework** - Distributed compute for large workloads
- ✅ **Advanced autoscaling** - KEDA for event-driven scaling
- ✅ **Complete ML platform** - All OpenShift AI features

#### Prerequisites
- ✅ Path B completed **OR** Foundation Steps 1-2 + Path B operators
- ✅ 5+ worker nodes (CPU + GPU workers)
- ✅ **Azure GPU quota** - Request quota for NC/ND-series VMs
- ✅ **GPU workers** - NC8as_T4_v3 or better (see GPU Support section)

#### Installation Steps

**Step 1: Create GPU Worker Nodes**

Create GPU-enabled MachineSets. See [GPU Support section](#gpu-support) for detailed instructions:

```bash
# Create GPU MachineSet (example for T4)
# Follow "Create GPU MachineSet" section below for full instructions

# Verify GPU nodes
oc get nodes -l nvidia.com/gpu.present=true
```

**Step 2: Install GPU Operators**

Install NFD and GPU Operator from [Step 3](#3-install-required-dependent-operators):

```bash
# Required for Path C:
# - 3.10: NFD (GPU detection)
# - 3.11: NVIDIA GPU Operator
```

**Step 3: Install Optional Operators** (if needed)

```bash
# Optional operators from Step 3:
# - 3.7: Leader Worker Set (distributed inference)
# - 3.8: KEDA (event-driven autoscaling)
# - 3.9: MariaDB (TrustyAI database mode)
```

**Step 4: Verify GPU Setup**

```bash
# Check GPU nodes are labeled
oc describe node | egrep 'Roles|nvidia.com/gpu'

# Test GPU with sample workload
oc project nvidia-gpu-operator
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cuda-test
spec:
  restartPolicy: OnFailure
  containers:
  - name: cuda
    image: nvcr.io/nvidia/cuda:12.0.0-base-ubi8
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Check output
oc logs cuda-test
oc delete pod cuda-test
```

**Step 5: Configure DataScienceCluster (Full)**

Enable all components including Ray and distributed training:

```bash
cat <<EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    workbenches:
      managementState: Managed
    modelregistry:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
    kserve:
      managementState: Managed
      serving:
        ingressGateway:
          certificate:
            type: OpenshiftDefaultIngress
        managementState: Managed
        name: knative-serving
    trainingoperator:
      managementState: Managed
    ray:
      managementState: Managed
    codeflare:
      managementState: Managed
    # Note: Kueue component left as Removed unless you want cluster-wide job queuing
    kueue:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
EOF

# Wait for DataScienceCluster to be ready (this may take 5-10 minutes)
echo "Waiting for DataScienceCluster to be ready..."
oc wait --for=condition=Ready datasciencecluster/default-dsc --timeout=600s
```

**Step 6: Validate Full Installation**

```bash
# Check all components
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components}' | jq

# Verify GPU workloads can be created
# Try creating a workbench with GPU in the dashboard

# Check Ray operator
oc get pods -n redhat-ods-applications | grep ray
```

#### ✅ Path C Complete!

**What's Next?**
- Deploy GPU-accelerated training jobs
- Use Ray for distributed compute
- Configure GPU time-slicing → [Part 3: Optional Enhancements](#part-3-optional-enhancements)
- Set up Multi-Instance GPU (MIG) for A100s

---

## Part 2 Summary

You've completed one of the deployment paths! Here's what each path enabled:

| Feature | Path A | Path B | Path C |
|---------|--------|--------|--------|
| Dashboard | ✅ | ✅ | ✅ |
| Jupyter Workbenches | ✅ | ✅ | ✅ |
| Model Serving (KServe) | ❌ | ✅ | ✅ |
| Data Science Pipelines | ❌ | ✅ | ✅ |
| GPU Training | ❌ | ❌ | ✅ |
| Ray / Distributed Compute | ❌ | ❌ | ✅ |
| Operators Installed | 2 | 6 | 11 |

**Continue to:**
- [Part 3: Optional Enhancements](#part-3-optional-enhancements) - ODF storage, GPU advanced features
- [Part 5: Validation & Troubleshooting](#part-5-reference--troubleshooting) - Verify your installation

---

### 4. Configure DataScienceCluster

**Note:** If you followed a Path above, you've already configured DataScienceCluster. This section provides the reference configuration.

Create a DataScienceCluster resource to enable OpenShift AI components:

```bash
cat <<EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    workbenches:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed  # Set to Removed if not needed
    kserve:
      managementState: Managed
      serving:
        ingressGateway:
          certificate:
            type: SelfSigned  # Or OpenshiftDefaultIngress for cluster certs
        managementState: Managed
        name: knative-serving
    modelmeshserving:
      managementState: Removed  # Deprecated, use KServe
    codeflare:
      managementState: Removed  # Enable if using distributed workloads
    ray:
      managementState: Removed  # Enable for Ray framework
    kueue:
      managementState: Removed  # Enable for job queueing
    trainingoperator:
      managementState: Managed  # Enable for distributed training
EOF
```

**Component Management States:**
- `Managed` - Operator installs and manages the component
- `Removed` - Operator actively removes the component if present

**Customization Strategy:**
1. Start with minimal components (dashboard, workbenches, kserve)
2. Add components incrementally based on workload requirements
3. `Removed` state reduces resource consumption and attack surface

### 5. Configure Object Storage for Data Science Pipelines

Data Science Pipelines require object storage for storing pipeline artifacts, datasets, and models. Configure one of the following options:

#### Option A: Azure Blob Storage (Recommended for ARO)

**Step 1: Create Azure Storage Account and Container**
```bash
# Set variables
RESOURCE_GROUP="aro-rg"
STORAGE_ACCOUNT="aroaipipelines"
CONTAINER_NAME="pipelines"
LOCATION="eastus"

# Create storage account
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2

# Get storage account key
STORAGE_KEY=$(az storage account keys list \
  --account-name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query '[0].value' -o tsv)

# Create container
az storage container create \
  --name $CONTAINER_NAME \
  --account-name $STORAGE_ACCOUNT \
  --account-key $STORAGE_KEY
```

**Step 2: Create OpenShift Secret**
```bash
# Azure Blob Storage uses Azure-native SDK, not S3 API
# For Data Science Pipelines, configure with connection string or use MinIO as S3-compatible layer

# Get connection string
CONNECTION_STRING=$(az storage account show-connection-string \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query connectionString -o tsv)

# Create secret (format depends on pipeline server configuration)
oc create secret generic azure-blob-connection \
  -n <your-data-science-project> \
  --from-literal=AZURE_STORAGE_ACCOUNT=${STORAGE_ACCOUNT} \
  --from-literal=AZURE_STORAGE_ACCESS_KEY=${STORAGE_KEY} \
  --from-literal=AZURE_STORAGE_CONTAINER=${CONTAINER_NAME}
```

**⚠️ Note:** Azure Blob Storage does not natively support S3 API. For S3-compatible access required by some Data Science Pipeline components, consider:
- Using Azure Data Lake Storage Gen2 with S3-compatible proxy
- Deploying MinIO as S3-compatible layer (see Option B)
- Using external S3-compatible providers (see Option C)

**Reference:** [Azure Blob Storage Documentation](https://learn.microsoft.com/en-us/azure/storage/blobs/)

#### Option B: Azure Data Lake Storage Gen2 (for Data Science Workloads)

Azure Data Lake Storage Gen2 is built on Blob Storage but adds hierarchical namespace, making it ideal for data science and analytics workloads.

```bash
# Create storage account with hierarchical namespace enabled
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --hierarchical-namespace true

# Create filesystem (container equivalent)
az storage fs create \
  --name $CONTAINER_NAME \
  --account-name $STORAGE_ACCOUNT \
  --account-key $STORAGE_KEY
```

**Advantages for Data Science:**
- Optimized for big data analytics (Spark, Synapse integration)
- Folder-like semantics for organizing datasets
- Better performance for large-scale data processing
- Native integration with Azure ML and analytics services

#### Option C: Self-Hosted MinIO (S3-Compatible)

**Step 1: Deploy MinIO on OpenShift**
```bash
# Create MinIO namespace
oc new-project minio

# Deploy MinIO (simple single-node setup for development)
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: managed-csi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: quay.io/minio/minio:latest
        command:
        - /bin/bash
        - -c
        args: 
        - minio server /data --console-address :9001
        env:
        - name: MINIO_ROOT_USER
          value: "minio"
        - name: MINIO_ROOT_PASSWORD
          value: "minio123"
        ports:
        - containerPort: 9000
        - containerPort: 9001
        volumeMounts:
        - mountPath: /data
          name: storage
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  ports:
  - port: 9000
    targetPort: 9000
    name: api
  - port: 9001
    targetPort: 9001
    name: console
  selector:
    app: minio
EOF

# Create route for MinIO
oc create route edge minio-api --service=minio --port=9000 -n minio
```

**Step 2: Create Bucket and Credentials**
```bash
# Access MinIO console
oc get route minio-api -n minio -o jsonpath='{.spec.host}'

# Login with MINIO_ROOT_USER/MINIO_ROOT_PASSWORD
# Create bucket via UI or MinIO client

# Create OpenShift secret
MINIO_ENDPOINT=$(oc get route minio-api -n minio -o jsonpath='{.spec.host}')

oc create secret generic aws-connection-minio \
  -n <your-data-science-project> \
  --from-literal=AWS_ACCESS_KEY_ID=minio \
  --from-literal=AWS_SECRET_ACCESS_KEY=minio123 \
  --from-literal=AWS_S3_BUCKET=pipelines \
  --from-literal=AWS_S3_ENDPOINT=https://${MINIO_ENDPOINT}
```

**⚠️ Production Considerations for MinIO:**
- Use distributed mode (4+ nodes) for high availability
- Configure TLS certificates properly
- Use strong credentials (not default minio/minio123)
- Implement backup and disaster recovery
- Consider managed alternatives for production

#### Option D: External S3-Compatible Providers

For AWS S3, MinIO Cloud, or other S3-compatible providers:

```bash
# Generic S3-compatible secret template
oc create secret generic aws-connection-external \
  -n <your-data-science-project> \
  --from-literal=AWS_ACCESS_KEY_ID=<access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<secret-key> \
  --from-literal=AWS_S3_BUCKET=<bucket-name> \
  --from-literal=AWS_S3_ENDPOINT=<s3-endpoint-url>
```

**Common S3-Compatible Endpoints:**
- AWS S3: `https://s3.<region>.amazonaws.com`
- MinIO Cloud: Provided by your MinIO Cloud account
- Other providers: Check provider documentation

### 6. Deploy OpenShift Data Foundation (Optional, for Advanced Storage)

OpenShift Data Foundation (ODF) provides unified storage for **block, file, and object storage** on ARO. Unlike basic CSI drivers, ODF is particularly valuable for OpenShift AI because it delivers all three storage types from a single platform, optimized for AI/ML workloads.

#### Why ODF Matters for OpenShift AI

Different OpenShift AI components require different storage types. ODF provides superior performance and native compatibility for many AI/ML scenarios:

| Component | Storage Type | Why Needed | Azure-Native Option | ODF Advantage |
|-----------|-------------|-----------|-------------------|---------------|
| **Workbenches (Jupyter)** | RWO | Single user notebooks | Azure Disk CSI ✅ | Faster provisioning, better IOPS |
| **Shared Datasets** | RWX | Multiple pods read same data | Azure Files CSI | **CephFS: 5-10x faster for large files** |
| **Model Registry** | RWX | Multiple workbenches access models | Azure Files CSI | **CephFS: Better concurrent access** |
| **Data Science Pipelines** | S3-compatible | Pipeline artifacts, versioning | Azure Blob (not S3-native) | **NooBaa: Native S3 API** |
| **Distributed Training** | RWX | Multi-GPU checkpoint sharing | Azure Files CSI | **CephFS: Optimized for parallel I/O** |
| **MLflow Artifact Store** | S3-compatible | Model versioning | MinIO (separate deployment) | **NooBaa: Integrated S3** |

#### ODF Storage Classes for OpenShift AI

ODF creates three storage classes, each serving specific AI/ML use cases:

**1. ocs-storagecluster-ceph-rbd (Block Storage - RWO)**
- **Use Cases:** Individual Jupyter notebooks, single-pod training jobs, GPU workload storage
- **Performance:** 10,000-100,000 IOPS, 500-2000 MB/s throughput
- **Advantages over Azure Disk:** Faster provisioning (no Azure API calls), snapshots for ML experiments

**2. ocs-storagecluster-cephfs (File Storage - RWX)**
- **Use Cases:** Shared datasets (ImageNet, COCO), model registries, distributed training checkpoints, team collaboration
- **Performance:** 1-2 GB/s per client for sequential reads, 5,000-50,000 IOPS
- **Advantages over Azure Files:** 5-10x faster for large files, better concurrency, data stays within cluster, optimized for container workloads

**3. openshift-storage.noobaa.io (Object Storage - S3-compatible)**
- **Use Cases:** Data Science Pipelines artifacts, MLflow model registry, dataset staging, immutable model versioning
- **Performance:** S3-compatible API with low latency (in-cluster)
- **Advantages over Azure Blob:** Native S3 API (no S3Proxy needed), Kubernetes-native, multi-cloud federation

#### When to Use ODF vs. Azure-Native Storage

**✅ Use ODF when:**
- Multiple AI teams sharing infrastructure
- Need RWX storage for shared datasets > 100GB
- Running Data Science Pipelines (requires S3-compatible storage)
- Distributed training with multi-GPU checkpoint sharing
- High-performance file I/O for large datasets (TB-scale)
- Data stays within cluster (no egress to external storage)
- Prefer Kubernetes-native storage management
- Need both RWX file storage AND S3-compatible object storage

**✅ Use Azure-native storage when:**
- Single-user or small team (< 5 data scientists)
- Mostly RWO workloads (individual notebooks only)
- Small RWX needs < 100GB (Azure Files sufficient)
- Minimal operational overhead (no storage cluster to manage)
- Leveraging Azure-native services (Azure ML, Synapse)

#### Prerequisites

Before deploying ODF:
- [ ] 3 additional worker nodes (recommended: one per Azure availability zone)
- [ ] Minimum: 16 vCPUs, 64 GB RAM per ODF node
- [ ] Azure Premium Managed Disks (managed-csi storage class)
- [ ] Dedicated nodes for storage isolation (best practice)

**Step 1: Provision ODF Nodes**

**Note:** ARO uses MachineSets, not `az aro machinepool` (which doesn't exist).

```bash
# Install required tools (if not already installed)
# Linux: sudo dnf install jq moreutils
# macOS: brew install jq moreutils

# Get existing MachineSet as template
MACHINESET=$(oc get machineset -n openshift-machine-api -o=jsonpath='{.items[0].metadata.name}')
CLUSTER_NAME=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].metadata.labels.machine\.openshift\.io/cluster-api-cluster}')
REGION=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.location}')

# Create ODF MachineSet for Zone 1
oc get machineset -n openshift-machine-api $MACHINESET -o json | \
jq --arg name "${CLUSTER_NAME}-odf-${REGION}1" \
   '.metadata.name = $name |
    .spec.replicas = 1 |
    .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.metadata.labels.app = "odf" |
    .spec.template.spec.providerSpec.value.vmSize = "Standard_D16s_v3" |
    .spec.template.spec.providerSpec.value.zone = "1" |
    .spec.template.spec.providerSpec.value.osDisk.diskSizeGB = 512 |
    del(.status)' | oc create -f -

# Create ODF MachineSet for Zone 2
oc get machineset -n openshift-machine-api $MACHINESET -o json | \
jq --arg name "${CLUSTER_NAME}-odf-${REGION}2" \
   '.metadata.name = $name |
    .spec.replicas = 1 |
    .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.metadata.labels.app = "odf" |
    .spec.template.spec.providerSpec.value.vmSize = "Standard_D16s_v3" |
    .spec.template.spec.providerSpec.value.zone = "2" |
    .spec.template.spec.providerSpec.value.osDisk.diskSizeGB = 512 |
    del(.status)' | oc create -f -

# Create ODF MachineSet for Zone 3
oc get machineset -n openshift-machine-api $MACHINESET -o json | \
jq --arg name "${CLUSTER_NAME}-odf-${REGION}3" \
   '.metadata.name = $name |
    .spec.replicas = 1 |
    .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.metadata.labels.app = "odf" |
    .spec.template.spec.providerSpec.value.vmSize = "Standard_D16s_v3" |
    .spec.template.spec.providerSpec.value.zone = "3" |
    .spec.template.spec.providerSpec.value.osDisk.diskSizeGB = 512 |
    del(.status)' | oc create -f -

# Wait for nodes to be created (10-15 minutes)
watch oc get machineset -n openshift-machine-api | grep odf

# Once machines are Ready, label nodes for ODF
oc label nodes -l app=odf cluster.ocs.openshift.io/openshift-storage=''

# Taint nodes to dedicate to ODF
oc adm taint nodes -l app=odf node.ocs.openshift.io/storage=true:NoSchedule
```

**Step 2: Install ODF Operators**
```bash
# Create openshift-storage namespace
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: openshift-storage
spec:
  channel: stable-4.15
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# Wait for operators to be ready (~5 minutes)
oc wait --for=condition=Ready pod -l app=ocs-operator -n openshift-storage --timeout=600s
oc wait --for=condition=Ready pod -l app=odf-operator -n openshift-storage --timeout=600s
```

**Step 3: Create Storage Cluster**
```bash
cat <<EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  storageDeviceSets:
  - name: ocs-deviceset
    count: 3  # One per zone
    replica: 3
    dataPVCTemplate:
      spec:
        storageClassName: managed-csi
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 512Gi
    portable: false
  nodeTopologies:
    labels:
      cluster.ocs.openshift.io/openshift-storage: ""
EOF

# Verify storage cluster (takes ~10-15 minutes)
oc get storagecluster -n openshift-storage
oc get pods -n openshift-storage

# Verify storage classes created
oc get storageclass | grep ocs
```

**Expected Storage Classes:**
- `ocs-storagecluster-ceph-rbd` - Block storage (RWO) - Individual workbenches, GPU training jobs
- `ocs-storagecluster-cephfs` - File storage (RWX) - Shared datasets, model registries, distributed training
- `openshift-storage.noobaa.io` - Object storage (S3-compatible) - Data Science Pipelines, MLflow artifacts

#### ODF Integration with OpenShift AI Components

**1. Shared Dataset Example (CephFS - RWX)**
```bash
# Create PVC for team-shared ImageNet dataset
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: imagenet-dataset
  namespace: data-science-team
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ocs-storagecluster-cephfs
  resources:
    requests:
      storage: 2Ti  # ImageNet is ~1.2TB
EOF

# Multiple data scientists can now mount this in their workbenches
# Via OpenShift AI dashboard: Data Connections > Attach existing PVC
```

**Benefits:** 10+ data scientists access same dataset, 5-10x faster than Azure Files for large files, data remains in-cluster.

**2. Data Science Pipelines with ODF NooBaa (S3-compatible)**
```bash
# Get NooBaa S3 credentials
NOOBAA_ACCESS_KEY=$(oc get secret noobaa-admin -n openshift-storage -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
NOOBAA_SECRET_KEY=$(oc get secret noobaa-admin -n openshift-storage -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
NOOBAA_ENDPOINT=$(oc get route s3 -n openshift-storage -o jsonpath='{.spec.host}')

# Create pipeline server secret
oc create secret generic aws-connection-odf \
  -n <your-data-science-project> \
  --from-literal=AWS_ACCESS_KEY_ID=${NOOBAA_ACCESS_KEY} \
  --from-literal=AWS_SECRET_ACCESS_KEY=${NOOBAA_SECRET_KEY} \
  --from-literal=AWS_S3_BUCKET=pipelines \
  --from-literal=AWS_S3_ENDPOINT=https://${NOOBAA_ENDPOINT}

# Create bucket via NooBaa UI or CLI
# Pipeline artifacts are now stored in ODF S3 (no external dependencies)
```

**Benefits:** Native S3 API (no MinIO deployment needed), in-cluster storage (lower latency), integrated with ODF monitoring.

**3. Model Registry for KServe (CephFS - RWX)**
```bash
# Create model registry PVC
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-registry
  namespace: model-serving
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ocs-storagecluster-cephfs
  resources:
    requests:
      storage: 500Gi
EOF

# KServe InferenceService references model from PVC
cat <<EOF | oc apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: sklearn-iris
  namespace: model-serving
spec:
  predictor:
    sklearn:
      storageUri: pvc://model-registry/sklearn-iris/v1
EOF
```

**Benefits:** Multiple model server replicas access same PVC, fast model loading from CephFS, model updates visible to all pods immediately.

**4. Distributed Training Checkpoints (CephFS - RWX)**
```bash
# Training job with multi-GPU checkpoint sharing
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: distributed-training
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      template:
        spec:
          containers:
          - name: pytorch
            image: pytorch/pytorch:latest
            volumeMounts:
            - name: checkpoints
              mountPath: /checkpoints
          volumes:
          - name: checkpoints
            persistentVolumeClaim:
              claimName: training-checkpoints
    Worker:
      replicas: 4
      template:
        spec:
          containers:
          - name: pytorch
            image: pytorch/pytorch:latest
            resources:
              limits:
                nvidia.com/gpu: 1
            volumeMounts:
            - name: checkpoints
              mountPath: /checkpoints
          volumes:
          - name: checkpoints
            persistentVolumeClaim:
              claimName: training-checkpoints  # Same RWX PVC
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: training-checkpoints
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ocs-storagecluster-cephfs
  resources:
    requests:
      storage: 200Gi
```

**Benefits:** All training pods (master + 4 workers) write/read checkpoints to shared storage, fast recovery on pod failure, CephFS optimized for parallel I/O.

#### ODF Performance for AI Workloads

**Read Performance (Sequential - Large Files):**
- ODF CephFS: 1-2 GB/s per client - Loading ImageNet, model files
- Azure Files Premium: 100-400 MB/s per share - Shared file access
- Azure Disk Premium: 200-900 MB/s - Single-node training

**Write Performance (Checkpointing):**
- ODF RBD (block): 500-2000 MB/s - Single-GPU training checkpoints
- ODF CephFS: 500-1500 MB/s - Multi-GPU distributed training
- Azure Disk Premium: 250-900 MB/s - Single-node training

**IOPS (Random Access):**
- ODF RBD: 10,000-100,000 - Database-like workloads, metadata
- ODF CephFS: 5,000-50,000 - Parallel file access
- Azure Disk Premium: 5,000-20,000 - General workloads

#### ODF Operational Considerations

**Ongoing Maintenance:**
```bash
# Monitor Ceph cluster health
oc get storagecluster -n openshift-storage
oc get cephcluster -n openshift-storage

# Check capacity utilization
oc get cephcluster -n openshift-storage -o jsonpath='{.status.ceph.capacity}'

# View ODF dashboard
oc get route odf-dashboard -n openshift-storage
```

**Capacity Planning:**
- Expect **30-40% storage overhead** for Ceph metadata and 3x replication
- Plan for **20-30% growth per quarter** for AI workloads (datasets accumulate)
- Reserve **15-20% free space** for Ceph rebalancing operations
- Example: 3 nodes × 512GB disks = 1,536GB raw → ~512GB usable after replication

**High Availability:**
- Data replicated 3x across availability zones
- Self-healing: Automatic recovery from node failures
- Rolling updates: No downtime for ODF component upgrades
- Disaster recovery: Snapshots and backups for datasets/models

**Scaling ODF:**
```bash
# Add more storage capacity by increasing OSD count
oc patch storagecluster ocs-storagecluster -n openshift-storage \
  --type merge \
  --patch '{"spec":{"storageDeviceSets":[{"count":6,"name":"ocs-deviceset"}]}}'

# Or expand existing PVC sizes
oc patch storagecluster ocs-storagecluster -n openshift-storage \
  --type merge \
  --patch '{"spec":{"storageDeviceSets":[{"dataPVCTemplate":{"spec":{"resources":{"requests":{"storage":"1Ti"}}}}}]}}'
```

#### ODF Deployment Architecture for OpenShift AI

**Recommended Setup:**
```
ARO Cluster
├─ GPU Worker Pool (NC/ND-series)
│  ├─ NC8as_T4_v3 (2 nodes) - Training workloads
│  └─ Standard_D8s_v3 (3 nodes) - CPU inference
│
└─ ODF Storage Pool (Dedicated)
   ├─ Standard_D16s_v3 (Zone 1) - 16 vCPU, 64GB RAM, 512GB disk
   ├─ Standard_D16s_v3 (Zone 2) - 16 vCPU, 64GB RAM, 512GB disk
   └─ Standard_D16s_v3 (Zone 3) - 16 vCPU, 64GB RAM, 512GB disk
```

**Why Dedicated ODF Nodes:**
- **Isolation** - Storage performance not impacted by AI workload spikes
- **Taints** - Prevents AI pods from scheduling on storage nodes
- **Predictability** - Guaranteed resources for storage operations
- **High Availability** - One node per Azure availability zone ensures data resilience

**Reference:** [Configure ARO with OpenShift Data Foundation](https://cloud.redhat.com/experts/aro/odf/)

### 7. Verify Installation

```bash
# Check DataScienceCluster status
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'
# Expected: Ready

# List enabled components
oc get datasciencecluster default-dsc -o jsonpath='{.spec.components}' | jq

# Verify namespaces created
oc get projects | grep -E 'rhods|redhat-ods'

# Check operator logs for issues
oc logs -n redhat-ods-operator deployment/rhods-operator --tail=50

# Validate dashboard route
oc get route rhods-dashboard -n redhat-ods-applications
```

### 8. Upgrade OpenShift AI

Self-managed deployments require manual upgrade approval:

```bash
# Check available upgrades
oc get installplan -n redhat-ods-operator

# Review upgrade plan
oc describe installplan <installplan-name> -n redhat-ods-operator

# Approve upgrade (after testing in non-production)
oc patch installplan <installplan-name> -n redhat-ods-operator \
  --type merge --patch '{"spec":{"approved":true}}'

# Monitor upgrade progress
oc get csv -n redhat-ods-operator -w
```

**⚠️ Important:** New components added in upgrades are NOT automatically enabled in the DataScienceCluster. Manually update the DataScienceCluster CR to enable new components.

### 9. Uninstall OpenShift AI

Complete removal procedure:

```bash
# 1. Delete DataScienceCluster
oc delete datasciencecluster default-dsc

# 2. Wait for component cleanup (may take several minutes)
oc get projects | grep -E 'rhods|redhat-ods'

# 3. Delete operator subscription
oc delete subscription rhods-operator -n redhat-ods-operator

# 4. Delete ClusterServiceVersion
oc delete csv -n redhat-ods-operator -l operators.coreos.com/rhods-operator.redhat-ods-operator

# 5. Delete operator namespace
oc delete project redhat-ods-operator

# 6. Delete CRDs (optional - only if complete removal required)
oc get crd | grep datasciencecluster
oc delete crd datascienceclusters.datasciencecluster.opendatahub.io
```

## GPU Support

OpenShift AI workloads benefit significantly from GPU acceleration. ARO supports NVIDIA GPUs via Azure NC-series and ND-series VMs.

### Supported Azure GPU VM Sizes

| VM Size | GPU | GPU Memory | vCPUs | RAM | Use Case |
|---------|-----|------------|-------|-----|----------|
| **NC T4 v3 Series** | | | | | |
| Standard_NC4as_T4_v3 | 1x T4 | 16 GB | 4 | 28 GB | Development, inference |
| Standard_NC8as_T4_v3 | 1x T4 | 16 GB | 8 | 56 GB | Inference, training |
| Standard_NC16as_T4_v3 | 1x T4 | 16 GB | 16 | 110 GB | Training, inference |
| Standard_NC64as_T4_v3 | 4x T4 | 64 GB | 64 | 440 GB | Distributed training |
| **NC A100 v4 Series** | | | | | |
| Standard_NC24ads_A100_v4 | 1x A100 | 80 GB | 24 | 220 GB | Large model training |
| Standard_NC48ads_A100_v4 | 2x A100 | 160 GB | 48 | 440 GB | Multi-GPU training |
| Standard_NC96ads_A100_v4 | 4x A100 | 320 GB | 96 | 880 GB | Distributed training |
| **ND A100 v4 Series** | | | | | |
| Standard_ND96asr_v4 | 8x A100 | 640 GB | 96 | 900 GB | HPC, large-scale training |
| Standard_ND96amsr_A100_v4 | 8x A100 | 640 GB | 96 | 1900 GB | Memory-intensive training |

**Important Notes:**
- Azure quota is per-core - request quota in multiples matching VM size
- NC24ads_A100_v4 and above require Generation 2 VM images
- GPU provisioning takes 10-15 minutes

**Reference:** [Use GPU workloads with ARO](https://learn.microsoft.com/en-us/azure/openshift/howto-gpu-workloads)

### Create GPU MachineSet

**Important:** ARO uses OpenShift MachineSets (not Azure CLI commands) to create worker nodes. The `az aro machinepool create` command does not exist.

This procedure creates a GPU-enabled MachineSet based on an existing worker MachineSet:

```bash
# Install required tools (if not already installed)
# Linux: sudo dnf install jq moreutils gettext
# macOS: brew install jq moreutils gettext

# Get the first existing MachineSet as a template
MACHINESET=$(oc get machineset -n openshift-machine-api -o=jsonpath='{.items[0].metadata.name}')

# Export it to JSON
oc get machineset -n openshift-machine-api $MACHINESET -o json > gpu_machineset.json

# Get cluster info for naming
CLUSTER_NAME=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].metadata.labels.machine\.openshift\.io/cluster-api-cluster}')
REGION=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.location}')
ZONE="1"  # Choose availability zone (1, 2, or 3)

# Set new MachineSet name
NEW_MACHINESET_NAME="${CLUSTER_NAME}-nvidia-worker-${REGION}${ZONE}"

# Modify the MachineSet for GPU
jq --arg name "$NEW_MACHINESET_NAME" \
   '.metadata.name = $name |
    .spec.replicas = 2 |
    .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $name |
    .spec.template.spec.providerSpec.value.vmSize = "Standard_NC8as_T4_v3" |
    .spec.template.spec.providerSpec.value.zone = "1" |
    del(.status)' \
   gpu_machineset.json | sponge gpu_machineset.json

# Create the GPU MachineSet
oc create -f gpu_machineset.json

# Monitor MachineSet creation (takes 10-15 minutes)
oc get machineset -n openshift-machine-api
oc get machine -n openshift-machine-api -w

# Once machines are provisioned, verify GPU nodes
oc get nodes -l machine.openshift.io/cluster-api-machineset=$NEW_MACHINESET_NAME
```

**Alternative: Manual YAML Creation**

If you prefer to create the MachineSet manually, use this template:

```yaml
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  name: <cluster-name>-nvidia-worker-<region><zone>
  namespace: openshift-machine-api
  labels:
    machine.openshift.io/cluster-api-cluster: <cluster-name>
spec:
  replicas: 2
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: <cluster-name>
      machine.openshift.io/cluster-api-machineset: <cluster-name>-nvidia-worker-<region><zone>
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: <cluster-name>
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: <cluster-name>-nvidia-worker-<region><zone>
    spec:
      metadata: {}
      providerSpec:
        value:
          apiVersion: machine.openshift.io/v1beta1
          kind: AzureMachineProviderSpec
          vmSize: Standard_NC8as_T4_v3
          zone: "1"
          # Copy other fields from existing MachineSet:
          # - location, resourceGroup, subnet, vnet, image, etc.
```

**Important Notes:**
- Replace `<cluster-name>`, `<region>`, and `<zone>` with your values
- For A100 VMs (NC24ads_A100_v4+), you **must use Generation 2 VM images**
  - Check image SKU: `az vm image list --offer aro4 --publisher azureopenshift -o table`
  - Use SKU with `-v2` suffix (e.g., `v410-v2` instead of `aro_410`)
- Verify Azure GPU quota before creating MachineSet (see Common Pitfalls section)

**Reference:** [Use GPU workloads with ARO](https://learn.microsoft.com/en-us/azure/openshift/howto-gpu-workloads)

### Install Node Feature Discovery (NFD)

NFD detects hardware features (including GPUs) and labels nodes accordingly:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nfd-operator-group
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# Wait for NFD operator
oc wait --for=condition=Ready pod -l app=nfd-operator -n openshift-nfd --timeout=300s

# Create NFD instance
cat <<EOF | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery:v4.15
    servicePort: 12000
  workerConfig:
    configData: |
      sources:
        pci:
          deviceClassWhitelist:
            - "0200"
            - "03"
            - "12"
          deviceLabelFields:
            - "vendor"
EOF

# Verify GPU nodes are labeled
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
```

### Install NVIDIA GPU Operator

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: stable
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# Wait for GPU operator
oc wait --for=condition=Ready pod -l app=gpu-operator -n nvidia-gpu-operator --timeout=600s

# Create ClusterPolicy to deploy GPU stack
cat <<EOF | oc apply -f -
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
  dcgmExporter:
    enabled: true
  gfd:
    enabled: true
  dcgm:
    enabled: true
  driver:
    enabled: true
    licensingConfig:
      nlsEnabled: false
    repoConfig:
      configMapName: ""
    virtualTopology:
      config: ""
  devicePlugin:
    enabled: true
  mig:
    strategy: single  # Use 'mixed' for MIG partitioning on A100
  toolkit:
    enabled: true
  validator:
    plugin:
      env:
        - name: WITH_WORKLOAD
          value: "true"
EOF

# Monitor GPU stack deployment (takes ~5-10 minutes)
oc get pods -n nvidia-gpu-operator -w
```

### Verify GPU Setup

```bash
# Check GPU nodes
oc get nodes -l nvidia.com/gpu.present=true

# View GPU resources
oc describe node <gpu-node-name> | grep -A 10 "Allocatable"

# Expected output should show:
# nvidia.com/gpu: 1 (or more depending on VM size)

# Run test GPU workload
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
spec:
  restartPolicy: OnFailure
  containers:
  - name: cuda-vectoradd
    image: "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1-ubuntu20.04"
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Check pod logs
oc logs cuda-vectoradd

# Expected output: "Test PASSED"

# Cleanup
oc delete pod cuda-vectoradd
```

### GPU Time-Slicing Configuration (T4, V100, L4)

GPU time-slicing allows multiple workloads to share a single GPU by time-multiplexing. Useful for development and inference workloads.

```bash
# Create ConfigMap for time-slicing
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: nvidia-gpu-operator
data:
  tesla-t4: |-
    version: v1
    sharing:
      timeSlicing:
        replicas: 4  # Divide GPU into 4 virtual GPUs
EOF

# Update ClusterPolicy to enable time-slicing
oc patch clusterpolicy gpu-cluster-policy \
  -n nvidia-gpu-operator \
  --type merge \
  --patch '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"tesla-t4"}}}}'

# Verify time-sliced GPUs
oc describe node <gpu-node-name> | grep nvidia.com/gpu
# Should show: nvidia.com/gpu: 4 (instead of 1)
```

**⚠️ Time-Slicing Limitations:**
- Does not isolate GPU memory between workloads
- Performance degrades with concurrent workloads
- Best for inference, development, not training
- A100 GPUs should use MIG instead

### Multi-Instance GPU (MIG) for A100

MIG partitions a single A100 GPU into multiple isolated instances with dedicated memory and compute resources.

```bash
# Enable MIG mode on A100 nodes
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mig-parted-config
  namespace: nvidia-gpu-operator
data:
  config.yaml: |
    version: v1
    mig-configs:
      all-1g.5gb:
        - devices: all
          mig-enabled: true
          mig-devices:
            "1g.5gb": 7  # Create 7x 1g.5gb instances per A100
      all-2g.10gb:
        - devices: all
          mig-enabled: true
          mig-devices:
            "2g.10gb": 3  # Create 3x 2g.10gb instances per A100
EOF

# Update ClusterPolicy for MIG
oc patch clusterpolicy gpu-cluster-policy \
  --type merge \
  --patch '{"spec":{"mig":{"strategy":"mixed"},"migManager":{"enabled":true,"config":{"name":"mig-parted-config"}}}}'

# Label nodes with MIG configuration
oc label node <a100-node> nvidia.com/mig.config=all-1g.5gb --overwrite

# Verify MIG instances
oc exec -n nvidia-gpu-operator <nvidia-device-plugin-pod> -- nvidia-smi -L
```

**MIG Profiles for A100 80GB:**
- `1g.10gb`: 7 instances (1/7 compute, 10GB memory each)
- `2g.20gb`: 3 instances (2/7 compute, 20GB memory each)
- `3g.40gb`: 2 instances (3/7 compute, 40GB memory each)
- `7g.80gb`: 1 instance (full GPU)

**Reference:** [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/)

## Validation

### Pre-Deployment Validation

Before installing OpenShift AI, verify prerequisites:

```bash
# 1. Verify cluster version
oc version

# Expected: Server Version >= 4.12.0

# 2. Check cluster capacity
oc describe nodes | grep -A 5 "Allocatable"

# Ensure sufficient CPU/Memory available

# 3. Verify storage classes
oc get storageclass

# Expected: managed-csi (default), azurefile-csi, ocs-storagecluster-* (if ODF installed)

# 4. Check for GPU nodes (if using GPU)
oc get nodes -l nvidia.com/gpu.present=true

# 5. Verify operator catalog sources
oc get catalogsource -n openshift-marketplace

# Expected: redhat-operators, certified-operators
```

### Post-Deployment Validation

After installing OpenShift AI, verify all components:

```bash
# 1. Verify operator running
oc get csv -n redhat-ods-operator | grep rhods

# Expected: rhods-operator.x.y.z - Succeeded

# 2. Check DataScienceCluster status
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# Expected: True

# 3. Verify all component namespaces
oc get projects | grep -E 'rhods|redhat-ods|istio|knative'

# Expected namespaces:
# - redhat-ods-operator
# - redhat-ods-applications
# - redhat-ods-monitoring
# - istio-system (if KServe enabled)
# - knative-serving (if KServe enabled)

# 4. Check dashboard route
DASHBOARD_URL=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}')
echo "OpenShift AI Dashboard: https://$DASHBOARD_URL"

# 5. Access dashboard (requires cluster authentication)
# Open browser to dashboard URL and login with OpenShift credentials

# 6. Verify KServe installation (if enabled)
oc get knativeserving knative-serving -n knative-serving
oc get servicemeshcontrolplane -n istio-system

# 7. Test GPU access (if GPU nodes configured)
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
  namespace: redhat-ods-applications
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: nvcr.io/nvidia/cuda:12.0.0-base-ubi8
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF

# Check logs
oc logs gpu-test -n redhat-ods-applications

# Cleanup
oc delete pod gpu-test -n redhat-ods-applications
```

### Data Science Pipeline Validation

```bash
# Create test data science project
oc new-project test-ds-project

# Verify pipeline server can be created
# This is typically done through the OpenShift AI dashboard

# CLI validation: check pipeline CRDs
oc get crd | grep kubeflow

# Expected CRDs:
# - pipelines.kubeflow.org
# - runs.kubeflow.org
# - experiments.kubeflow.org
```

### Model Serving Validation

```bash
# Verify KServe ServingRuntime CRDs
oc get crd | grep serving.kserve.io

# Expected:
# - servingruntimes.serving.kserve.io
# - inferenceservices.serving.kserve.io

# Create test ServingRuntime
cat <<EOF | oc apply -f -
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: kserve-ovms
  namespace: test-ds-project
spec:
  supportedModelFormats:
    - name: openvino_ir
      version: opset13
    - name: onnx
      version: "1"
  protocolVersions:
    - v2
  containers:
    - name: kserve-container
      image: quay.io/opendatahub/openvino_model_server:stable
      args:
        - --model_name={{.Name}}
        - --port=8001
        - --rest_port=8888
        - --model_path=/mnt/models
        - --file_system_poll_wait_seconds=0
        - --grpc_bind_address=0.0.0.0
        - --rest_bind_address=0.0.0.0
      resources:
        limits:
          cpu: "2"
          memory: 8Gi
        requests:
          cpu: "1"
          memory: 4Gi
EOF

# Verify ServingRuntime created
oc get servingruntime -n test-ds-project

# Cleanup
oc delete project test-ds-project
```

## Common Pitfalls

### 1. Operator Dependency Not Installed

**Problem:** KServe or Data Science Pipelines fail to initialize because required operators (Serverless, Service Mesh, Pipelines) are not installed.

**Example/Impact:**
- DataScienceCluster shows KServe component in error state
- Dashboard shows "KServe requires OpenShift Serverless" warning
- InferenceService creation fails with validation errors

**Solution:**
```bash
# Check if required operators are installed
oc get subscription -n openshift-serverless serverless-operator
oc get subscription -n openshift-operators servicemeshoperator
oc get subscription -n openshift-operators openshift-pipelines-operator-rh

# If missing, install following the steps in Configuration Steps section

# Verify operator pods are running
oc get pods -n openshift-serverless
oc get pods -n openshift-operators | grep -E 'istio|pipelines'

# After operators are ready, DataScienceCluster should auto-reconcile
# Force reconciliation if needed:
oc annotate datasciencecluster default-dsc "reconcile-trigger=$(date +%s)" --overwrite
```

**Prevention:**
- Install all prerequisite operators before enabling KServe/Pipelines in DataScienceCluster
- Use `installPlanApproval: Automatic` for dependency operators to ensure timely updates
- Monitor operator health in `openshift-operators` namespace

**Reference:** [Installing the Single-Model Serving Platform](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.22/html/installing_and_uninstalling_openshift_ai_self-managed/installing-the-single-model-serving-platform_component-install)

### 2. Storage Class Not Configured for Notebooks

**Problem:** Data Science workbenches (Jupyter notebooks) fail to start because default storage class is missing or incorrect.

**Example/Impact:**
- PVC remains in `Pending` state
- Notebook pod shows `FailedScheduling` event: "persistentvolumeclaim not found"
- Dashboard shows "PVC provisioning failed" error

**Solution:**
```bash
# Check available storage classes
oc get storageclass

# Verify default storage class exists
oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'

# If no default storage class, set one
oc patch storageclass managed-csi -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# For RWX requirements, verify Azure Files or ODF is available
oc get storageclass | grep -E 'azurefile|ocs-storagecluster-cephfs'

# If using custom storage class, update notebook to reference it explicitly:
# Edit Notebook spec.template.spec.volumes[].persistentVolumeClaim.storageClassName
```

**Prevention:**
- Validate storage class before OpenShift AI installation
- For shared datasets requiring RWX access:
  - Deploy ODF for internal RWX storage (recommended for production)
  - Use Azure Files CSI driver (default on ARO, suitable for small workloads)
- Document required storage class in project onboarding

### 3. GPU Driver Version Incompatibility

**Problem:** GPU workloads fail to start or crash due to driver/CUDA version mismatches.

**Example/Impact:**
- Pod logs show `CUDA driver version is insufficient for CUDA runtime version`
- GPU not detected by containers despite `nvidia.com/gpu` resource request
- `nvidia-smi` command fails inside containers

**Solution:**
```bash
# Check GPU operator version and driver version
oc get csv -n nvidia-gpu-operator | grep gpu-operator

# Check driver version on GPU nodes
oc exec -n nvidia-gpu-operator <nvidia-driver-daemonset-pod> -- nvidia-smi

# If driver version is outdated, update GPU operator
oc patch subscription gpu-operator-certified -n nvidia-gpu-operator \
  --type merge --patch '{"spec":{"channel":"stable"}}'

# Verify container image CUDA version compatibility
# Container CUDA version must be <= driver CUDA version

# Example: If driver supports CUDA 12.2, container can use CUDA 12.0, 11.8, but not 12.3

# Update workload container image to compatible CUDA version
# E.g., change from nvcr.io/nvidia/pytorch:23.10-py3 (CUDA 12.3)
#            to nvcr.io/nvidia/pytorch:23.08-py3 (CUDA 12.2)
```

**Prevention:**
- Pin GPU operator version in production
- Test GPU workloads in development cluster before production deployment
- Maintain inventory of driver and CUDA version compatibility matrix
- Use NVIDIA container images from nvcr.io with known compatible CUDA versions

**Reference:** [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/openshift/contents.html)

### 4. Insufficient GPU Quota

**Problem:** GPU MachineSet creation fails due to Azure regional quota limits.

**Example/Impact:**
- Machine creation fails with "QuotaExceeded", "SkuNotAvailable", or "OperationNotAllowed" error
- Error message: "Current Limit: 0, Current Usage: 0, Additional Required: 8"
- GPU nodes stuck in `Pending` or `Failed` state
- MachineSet shows machines that won't provision

**Solution:**
```bash
# Check current GPU quota
az vm list-usage --location <region> --output table | grep NC

# Request quota increase via Azure portal:
# 1. Navigate to: Azure Portal > Subscriptions > Usage + quotas
# 2. Filter: Provider = "Microsoft.Compute", Location = <region>
# 3. Search for VM family (e.g., "Standard NCSv3 Family vCPUs")
# 4. Click "Request increase" and specify required cores
# 5. Wait for approval (typically 1-3 business days)

# Alternative: Use Azure CLI
az support tickets create \
  --ticket-name "GPU Quota Increase" \
  --title "Request NC-series GPU quota increase" \
  --description "Requesting 64 Standard_NC8as_T4_v3 cores for OpenShift AI workloads" \
  --severity minimal \
  --contact-first-name "<name>" \
  --contact-last-name "<name>" \
  --contact-method email \
  --contact-email "<email>"

# After quota increase, retry machine pool creation
```

**Prevention:**
- Request GPU quota early in project planning phase
- Start with smaller GPU VM sizes for development (NC4as_T4_v3)
- Use time-slicing to maximize GPU utilization before scaling
- Monitor quota usage in Azure portal

### 5. ODF Storage Cluster Not Ready

**Problem:** OpenShift Data Foundation storage cluster fails to reach healthy state, blocking RWX storage provisioning.

**Example/Impact:**
- ODF pods in `CrashLoopBackOff` or `Pending` state
- `ocs-storagecluster-cephfs` storage class not created
- Notebooks requiring RWX volumes fail to start

**Solution:**
```bash
# Check storage cluster status
oc get storagecluster -n openshift-storage
oc describe storagecluster ocs-storagecluster -n openshift-storage

# Common issues and fixes:

# Issue 1: Insufficient nodes
# Ensure 3 ODF nodes exist (one per zone)
oc get nodes -l cluster.ocs.openshift.io/openshift-storage=''
# If < 3 nodes, provision additional workers

# Issue 2: Node taints not configured
oc adm taint nodes -l cluster.ocs.openshift.io/openshift-storage='' \
  node.ocs.openshift.io/storage=true:NoSchedule

# Issue 3: Storage devices not found
# Verify PVCs for OSD (Object Storage Daemon) exist
oc get pvc -n openshift-storage | grep ocs-deviceset

# Issue 4: Pods not scheduled
oc get pods -n openshift-storage -o wide
oc describe pod <failing-pod> -n openshift-storage

# Force storage cluster reconciliation
oc delete pod -l app=rook-ceph-operator -n openshift-storage

# Monitor cluster health (takes 10-15 minutes)
watch "oc get pods -n openshift-storage | grep -v Running | grep -v Completed"
```

**Prevention:**
- Provision ODF on dedicated nodes with sufficient resources (16 vCPU, 64 GB RAM minimum)
- Deploy one ODF node per Azure availability zone for high availability
- Use Azure Premium Managed Disks (managed-csi storage class)
- Monitor ODF health proactively: `oc get storagecluster -n openshift-storage`

### 6. Azure Blob Storage Not S3-Compatible

**Problem:** Data Science Pipelines fail to connect to Azure Blob Storage due to missing S3 API compatibility.

**Example/Impact:**
- Pipeline runs fail with "S3 connection error"
- Artifact storage shows "Access Denied" or "Invalid endpoint"
- Pipeline server logs show "boto3.exceptions.NoCredentialsError"

**Solution:**

**Option A: Use Azure Data Lake Storage Gen2 + S3-compatible proxy**
```bash
# Deploy S3Proxy to translate S3 API to Azure Blob
# Reference: https://github.com/gaul/s3proxy

# Or use Flexify.IO commercial solution
# Reference: https://flexify.io/how-to-run-amazon-s3-apps-on-azure
```

**Option B: Deploy MinIO as S3-compatible layer**
```bash
# Follow MinIO deployment in Configuration Steps section
# MinIO provides native S3 API and can use Azure Blob as backend

# Create MinIO deployment with Azure Blob backend
# Reference: https://min.io/docs/minio/kubernetes/upstream/
```

**Option C: Use external S3-compatible service**
```bash
# Use AWS S3, MinIO Cloud, or other S3-compatible provider
# Configure with standard S3 credentials in pipeline server
```

**Prevention:**
- Plan object storage strategy early in deployment
- For ARO, prefer MinIO (self-hosted S3-compatible) or external S3 providers
- Azure Data Lake Storage Gen2 is better for data science workloads than plain Blob Storage
- Document storage architecture in deployment guide

**Reference:** [Azure Blob Storage and S3 API Compatibility](https://learn.microsoft.com/en-us/answers/questions/1512015/compatibility-between-azure-blob-storage-and-s3-pr)

### 7. KServe Ingress Certificate Issues

**Problem:** Model serving endpoints fail with SSL/TLS certificate errors.

**Example/Impact:**
- InferenceService shows `Ready=False` with certificate error
- Inference requests fail with "SSL certificate verification failed"
- `curl` to model endpoint returns certificate errors

**Solution:**
```bash
# Check InferenceService status
oc get inferenceservice -A
oc describe inferenceservice <inference-service-name> -n <namespace>

# Check certificate configuration in DataScienceCluster
oc get datasciencecluster default-dsc -o yaml | grep certificate

# Option 1: Use self-signed certificates (development only)
oc patch datasciencecluster default-dsc --type merge \
  --patch '{"spec":{"components":{"kserve":{"serving":{"ingressGateway":{"certificate":{"type":"SelfSigned"}}}}}}}'

# Option 2: Use OpenShift default ingress certificates (recommended)
oc patch datasciencecluster default-dsc --type merge \
  --patch '{"spec":{"components":{"kserve":{"serving":{"ingressGateway":{"certificate":{"type":"OpenshiftDefaultIngress"}}}}}}}'

# Option 3: Provide custom certificate
oc create secret tls custom-cert \
  --cert=path/to/tls.crt \
  --key=path/to/tls.key \
  -n istio-system

oc patch datasciencecluster default-dsc --type merge \
  --patch '{"spec":{"components":{"kserve":{"serving":{"ingressGateway":{"certificate":{"type":"Provided","secretName":"custom-cert"}}}}}}}'

# Verify Knative Serving gateway
oc get gateway knative-ingress-gateway -n knative-serving -o yaml
```

**Prevention:**
- Configure certificate strategy in DataScienceCluster from initial deployment
- Use OpenshiftDefaultIngress for production to leverage ARO's managed certificates
- Test model serving endpoints with SSL verification enabled
- Document certificate renewal procedures

### 8. Network Policy Blocking Model Traffic

**Problem:** Multi-tenant environments with NetworkPolicies block traffic between data science projects and model serving endpoints.

**Example/Impact:**
- Applications cannot reach InferenceService endpoints
- Curl from pod to model URL times out
- Service mesh shows connection refused errors

**Solution:**
```bash
# Check existing network policies
oc get networkpolicy -A

# Identify blocking policy
oc describe networkpolicy <policy-name> -n <namespace>

# Create network policy to allow traffic to KServe
cat <<EOF | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kserve-inference
  namespace: <data-science-project>
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          knative.openshift.io/part-of: "OpenShift Serverless"
    ports:
    - protocol: TCP
      port: 8080
    - protocol: TCP
      port: 8443
  - to:
    - namespaceSelector:
        matchLabels:
          istio.io/rev: default
EOF

# Verify connectivity
oc run test-pod --image=curlimages/curl --rm -it --restart=Never \
  -- curl -k https://<inference-service-url>/v2/health/ready
```

**Prevention:**
- Design NetworkPolicy strategy before multi-tenant deployment
- Create template NetworkPolicies for data science projects
- Test model serving connectivity in isolated namespace
- Document required NetworkPolicy rules in project onboarding

## Related Sections

- **Cluster Sizing** - Worker node sizing for AI workloads, GPU machine pool configuration
- **Storage Configuration** - Azure Disk, Azure Files, ODF deployment, object storage
- **Networking** - Service mesh configuration, ingress routes for model endpoints, egress lockdown
- **IAM Configuration** - Managed identities for workload identity, Azure permissions for storage
- **Monitoring** - GPU metrics collection, model serving observability
- **Security/Compliance** - Pod security standards, network policies for multi-tenant AI projects

## Additional Resources

### Official Documentation
- [Red Hat OpenShift AI Self-Managed 3.4 Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4)
- [Installing and Uninstalling OpenShift AI Self-Managed](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install)
- [Installing and Managing OpenShift AI Components](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.5/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-managing-openshift-ai-components_component-install)

### GPU and Hardware Acceleration
- [Use GPU workloads with ARO](https://learn.microsoft.com/en-us/azure/openshift/howto-gpu-workloads)
- [ARO with NVIDIA GPU Workloads - Red Hat Cloud Experts](https://cloud.redhat.com/experts/aro/gpu/)
- [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/openshift/contents.html)
- [Node Feature Discovery Operator](https://docs.openshift.com/container-platform/4.14/hardware_enablement/psap-node-feature-discovery-operator.html)
- [NVIDIA Multi-Instance GPU (MIG) User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/)
- [GPU Time-Slicing Configuration](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html)

### Storage
- [Configure ARO with OpenShift Data Foundation](https://cloud.redhat.com/experts/aro/odf/)
- [Deploying ODF using Microsoft Azure](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.9/html-single/deploying_openshift_data_foundation_using_microsoft_azure/index)
- [Azure Disk CSI Driver](https://learn.microsoft.com/en-us/azure/aks/azure-disk-csi)
- [Azure Files CSI Driver](https://learn.microsoft.com/en-us/azure/aks/azure-files-csi)
- [Azure Blob Storage Documentation](https://learn.microsoft.com/en-us/azure/storage/blobs/)
- [Azure Data Lake Storage Gen2](https://learn.microsoft.com/en-us/azure/storage/blobs/data-lake-storage-introduction)
- [MinIO Object Storage](https://min.io/docs/minio/kubernetes/upstream/)

### ARO-Specific
- [ARO Egress Lockdown Overview](https://learn.microsoft.com/en-us/azure/openshift/concepts-egress-lockdown)
- [Create Private ARO Cluster](https://learn.microsoft.com/en-us/azure/openshift/howto-create-private-cluster-4x)
- [ARO Documentation](https://learn.microsoft.com/en-us/azure/openshift/)
- [Azure Red Hat OpenShift - Red Hat Cloud Experts](https://cloud.redhat.com/experts/aro/)

### Disconnected Deployments
- [How to operate OpenShift in air-gapped environments](https://developers.redhat.com/articles/2026/03/19/how-operate-openshift-air-gapped-environments)
- [Simplify OpenShift installation in air-gapped environments](https://developers.redhat.com/articles/2025/10/14/simplify-openshift-installation-air-gapped-environments)
- [Deploy GPU Operators in disconnected environment](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/mirror-gpu-ocp-disconnected.html)

### Community Resources
- [Red Hat MOBB Guides](https://mobb.ninja/) - Validated field content for OpenShift
- [OpenShift AI GitHub](https://github.com/opendatahub-io/opendatahub-operator)
- [KServe Documentation](https://kserve.github.io/website/)
