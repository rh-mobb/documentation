---
date: '2026-03-26'
title: 'Azure Red Hat OpenShift Operations Guide'
tags: ["ARO"]
authors:
  - Kevin Collins
  - Kumudu Herath
validated_version: "4.20"
---

# Azure Red Hat OpenShift Operations Guide

**Day 1 Deployment & Day 2 Operations**

---

## Table of Contents

- [Introduction](#introduction)
- [Quick Reference](#quick-reference)
- [Part 1: Pre-Deployment Planning](#part-1-pre-deployment-planning)
  - [Prerequisites & Requirements](#prerequisites--requirements)
  - [Identity & Access Strategy](#identity--access-strategy)
  - [Network Architecture Planning](#network-architecture-planning)
  - [Network Security Groups](#network-security-groups)
  - [Cluster Configuration Planning](#cluster-configuration-planning)
  - [Storage Planning](#storage-planning)
  - [Compliance & Governance](#compliance--governance)
- [Part 2: Cluster Deployment (Day 1)](#part-2-cluster-deployment-day-1)
  - [Pre-Deployment Verification](#pre-deployment-verification)
  - [Network Infrastructure Deployment](#network-infrastructure-deployment)
  - [Managed Identity Setup](#managed-identity-setup)
  - [ARO Cluster Creation](#aro-cluster-creation)
  - [Post-Deployment Validation](#post-deployment-validation)
  - [Initial Configuration](#initial-configuration)
  - [Optional: Custom Domain Configuration](#optional-custom-domain-configuration)
  - [Optional: Private Cluster Access](#optional-private-cluster-access)
- [Part 3: Day 2 Operations](#part-3-day-2-operations)
  - [Tier 1: Critical Operations](#tier-1-critical-operations)
  - [Tier 2: Standard Operations](#tier-2-standard-operations)
  - [Tier 3: Optional Enhancements](#tier-3-optional-enhancements)
- [Part 4: Operational Excellence (Day N)](#part-4-operational-excellence-day-n)
- [Appendices](#appendices)
  - [Appendix A: Network Security Groups Deep Dive](#appendix-a-network-security-groups-deep-dive)
  - [Appendix B: Certificate Management](#appendix-b-certificate-management)
  - [Appendix C: Troubleshooting Guide](#appendix-c-troubleshooting-guide)
  - [Appendix D: Reference Information](#appendix-d-reference-information)

---

## Introduction

This technical guide provides comprehensive guidance for planning, deploying, and operating Azure Red Hat OpenShift (ARO) clusters. Whether you're deploying your first ARO cluster or managing production workloads, this guide covers the essential tasks and best practices for successful operations.

### Purpose of This Guide

This guide is designed to:
- Provide a structured approach to ARO cluster deployment and operations
- Establish best practices for production-ready ARO environments
- Serve as a reference for day-to-day operational tasks
- Guide troubleshooting and problem resolution
- Support both initial deployment (Day 1) and ongoing operations (Day 2 and beyond)

### Who Should Use This Guide

This guide is intended for:
- **Cloud Architects** planning ARO deployments
- **Platform Engineers** deploying and configuring ARO clusters
- **Site Reliability Engineers (SREs)** operating ARO environments
- **DevOps Engineers** integrating ARO with CI/CD pipelines
- **Security Teams** implementing security controls and compliance

### How to Use This Guide

The guide is organized chronologically to match the ARO lifecycle:

1. **Pre-Deployment Planning** - Review prerequisites, plan architecture, and make design decisions
2. **Day 1 Deployment** - Deploy infrastructure and create your ARO cluster
3. **Day 2 Operations** - Configure, secure, and integrate your cluster (organized by priority tier)
4. **Day N Operations** - Maintain and optimize your production environment
5. **Appendices** - Deep dives on specialized topics and comprehensive troubleshooting

**Checkboxes** throughout the guide indicate actionable tasks. Use them to track your progress through deployment and configuration.

**Priority Tiers** in Day 2 Operations help you focus:
- **Tier 1 (Critical)**: Essential operations required for production readiness
- **Tier 2 (Standard)**: Recommended operations for robust production environments
- **Tier 3 (Optional)**: Enhancements for specific use cases

### Document Conventions

| Convention | Meaning |
|------------|---------|
| - [ ] Checkbox | Actionable task or verification step |
| `code block` | Commands to execute or configuration snippets |
| **IMPORTANT** | Critical information requiring special attention |
| ⚠️ Warning | Actions that can cause issues if not carefully followed |
| 💡 Tip | Helpful suggestions and best practices |
| 📚 Reference | Links to additional documentation |

---

## Quick Reference

### Essential Commands

```bash
# Verify prerequisites
az provider show -n Microsoft.RedHatOpenShift --query "registrationState"
az aro get-versions --location <location>

# Create cluster (with managed identity)
az aro create \
  --resource-group <rg> \
  --name <cluster-name> \
  --vnet <vnet-name> \
  --vnet-resource-group <vnet-rg> \
  --master-subnet <master-subnet> \
  --worker-subnet <worker-subnet> \
  --enable-managed-identity \
  --assign-cluster-identity <cluster-identity-resource-id> \
  --assign-platform-workload-identity <operator> <identity-resource-id>

# Get cluster credentials
az aro list-credentials --name <cluster> --resource-group <rg>

# Get cluster console URL
az aro show --name <cluster> --resource-group <rg> --query consoleProfile.url -o tsv

# Login to cluster
oc login <api-url> --username kubeadmin --password <password>

# Check cluster health
oc get nodes
oc get co  # cluster operators
oc get clusterversion
```

### Critical Prerequisites Checklist

- [ ] Azure subscription with 40+ available vCPU quota
- [ ] `Microsoft.RedHatOpenShift` resource provider registered
- [ ] Azure CLI version 2.30.0 or later installed
- [ ] Red Hat pull secret obtained (recommended)
- [ ] Network architecture planned (VNet, subnets, IP ranges)
- [ ] Identity strategy selected (Managed Identity strongly recommended)
- [ ] Cluster visibility decision made (Private vs Public)

### Resource Requirements (Minimum)

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| vCPU Quota | 40 cores | 60+ cores |
| VNet CIDR | /20 | /16 or larger |
| Master Subnet | /27 (32 IPs) | /26 (64 IPs) |
| Worker Subnet | /27 (32 IPs) | /24 (256 IPs) |
| Master Nodes | 3x Standard_D8s_v5 | 3x Standard_D16s_v5 |
| Worker Nodes | 3x Standard_D4s_v5 | 6x Standard_D8s_v5 or larger |

### Emergency Contacts & Resources

| Resource | Link/Contact |
|----------|--------------|
| ARO Documentation | https://docs.microsoft.com/azure/openshift/ |
| OpenShift Documentation | https://docs.openshift.com/ |
| Microsoft Support | Azure Portal > Support |
| Red Hat Support | https://access.redhat.com/ |
| Managed Identity Guide | https://learn.microsoft.com/en-us/azure/openshift/howto-understand-managed-identities |
| ARO GitHub | https://github.com/Azure/ARO-RP |

---

## Part 1: Pre-Deployment Planning

Proper planning is essential for a successful ARO deployment. This section covers all the decisions and prerequisites you need to address before creating your cluster.

### Prerequisites & Requirements

#### Azure Subscription Requirements

- [ ] **Verify Core Quota**
  ```bash
  # Check current quota usage
  az vm list-usage --location <location> --query "[?name.value=='standardDSv3Family']"
  
  # Request quota increase if needed (minimum 40 cores required)
  # Navigate to: Azure Portal > Subscriptions > Usage + quotas
  ```
  - Minimum: 40 vCPU cores (3x D8s_v5 masters + 3x D4s_v5 workers)
  - Recommended: 60+ vCPU cores for production workloads
  - Consider future scaling requirements

- [ ] **Register Azure Resource Providers**
  ```bash
  # Register Microsoft.RedHatOpenShift provider
  az provider register --namespace Microsoft.RedHatOpenShift --wait
  
  # Verify registration
  az provider show -n Microsoft.RedHatOpenShift --query "registrationState"
  # Should return: "Registered"
  
  # Also register other required providers
  az provider register --namespace Microsoft.Compute --wait
  az provider register --namespace Microsoft.Network --wait
  az provider register --namespace Microsoft.Storage --wait
  ```

- [ ] **Verify Required Permissions**
  
  For the user/service principal deploying the cluster:
  - **Contributor** role on the cluster resource group
  - **User Access Administrator** role on the cluster resource group
  - **Network Contributor** role on the VNet resource group (if different)
  
  ```bash
  # Check role assignments
  az role assignment list \
    --assignee <user-or-sp-object-id> \
    --scope /subscriptions/<sub-id>/resourceGroups/<rg>
  ```

#### Tools Installation

- [ ] **Azure CLI** (version 2.30.0 or later)
  ```bash
  # Install Azure CLI
  # macOS: brew install azure-cli
  # Linux: https://docs.microsoft.com/cli/azure/install-azure-cli
  # Windows: https://aka.ms/installazurecliwindows
  
  # Verify version
  az --version
  
  # Login to Azure
  az login
  az account set --subscription <subscription-id>
  ```

- [ ] **OpenShift CLI (oc)**
  ```bash
  # Download from Red Hat
  # https://mirror.openshift.com/pub/openshift-v4/clients/ocp/
  
  # Or install via Azure
  az aro get-admin-kubeconfig --name <cluster> --resource-group <rg> -f kubeconfig
  
  # Verify oc is installed
  oc version
  ```

- [ ] **kubectl** (optional, for Kubernetes-native commands)
  ```bash
  # Install kubectl
  az aks install-cli
  
  # Verify installation
  kubectl version --client
  ```

- [ ] **Other Useful Tools**
  - `jq` - JSON processing (for parsing Azure CLI output)
  - `git` - For GitOps workflows
  - `helm` - For Helm chart deployments
  - `terraform` - If using Infrastructure as Code

#### Red Hat Integration

- [ ] **Obtain Red Hat Pull Secret** (Strongly Recommended)
  
  **Why it's important:**
  - Provides access to Red Hat Operator Hub and certified operators
  - Enables access to Red Hat Container Registry
  - Required for many enterprise features
  - Free with Red Hat account
  
  **How to obtain:**
  1. Create a Red Hat account at https://console.redhat.com/
  2. Navigate to https://console.redhat.com/openshift/install/pull-secret
  3. Download your pull secret
  4. Save as `pull-secret.txt`
  
  ```bash
  # Verify pull secret format (should be valid JSON)
  cat pull-secret.txt | jq
  ```

- [ ] **Access to Red Hat Hybrid Cloud Console**
  - Account creation: https://console.redhat.com/
  - Useful for cluster insights, vulnerability scanning, and support

---

### Identity & Access Strategy

**CRITICAL DECISION:** Choose your identity model for the ARO cluster. **Managed Identity is strongly recommended** for all new deployments.

#### Decision: Managed Identity vs Service Principal

| Factor | Managed Identity (RECOMMENDED) | Service Principal (Legacy) |
|--------|-------------------------------|---------------------------|
| **Credential Management** | ✅ No long-lived credentials | ❌ Manual - requires rotation |
| **Security** | ✅ Short-lived OIDC tokens | ❌ Long-lived secrets |
| **Role Assignments** | ARO built-in roles (least privilege) | Broad Contributor roles |
| **Setup** | Create identities + assign roles before cluster creation | Create SP + assign roles before cluster creation |
| **Expiration** | ✅ Tokens auto-rotate | ❌ Credentials expire, need rotation |
| **Operational Overhead** | ✅ Low (no credential rotation) | ❌ High (credential lifecycle) |
| **Production Readiness** | ✅ Recommended | ⚠️ Not recommended |

#### Option 1: Managed Identity (RECOMMENDED)

**Overview:**
- ARO uses 9 user-assigned managed identities (1 cluster identity + 8 platform workload identities)
- You create the identities and assign ARO built-in roles **before** cluster creation
- ARO operators use these identities with workload identity/federated credentials
- No long-lived credentials to manage or rotate
- Follows principle of least privilege with operator-specific roles

**Architecture:**
```
Cluster Identity (aro-cluster)
├─ Creates federated credentials for platform operator identities
└─ ARO built-in role: Azure Red Hat OpenShift Federated Credential (on each of the 8 identities below)

Platform Workload Identities (OpenShift Operators):
├─ cloud-controller-manager → Manages load balancers, IPs
├─ ingress → Manages ingress resources
├─ machine-api → Creates/manages VMs
├─ disk-csi-driver → Manages disk storage
├─ cloud-network-config → Manages networking
├─ image-registry → Manages registry storage
├─ file-csi-driver → Manages file storage
└─ aro-operator → Manages ARO service resources
```

**Step 1: Create 9 User-Assigned Managed Identities**
  
```bash
# Set variables
SUBSCRIPTION_ID=$(az account show --query 'id' -o tsv)
RESOURCE_GROUP=<rg>
CLUSTER_NAME=<cluster-name>
LOCATION=<location>

# Create cluster identity (enables federated credential management)
az identity create \
  --resource-group ${RESOURCE_GROUP} \
  --name aro-cluster \
  --location ${LOCATION}

# Create 8 platform workload identities for OpenShift operators
az identity create --resource-group ${RESOURCE_GROUP} --name cloud-controller-manager --location ${LOCATION}
az identity create --resource-group ${RESOURCE_GROUP} --name ingress --location ${LOCATION}
az identity create --resource-group ${RESOURCE_GROUP} --name machine-api --location ${LOCATION}
az identity create --resource-group ${RESOURCE_GROUP} --name disk-csi-driver --location ${LOCATION}
az identity create --resource-group ${RESOURCE_GROUP} --name cloud-network-config --location ${LOCATION}
az identity create --resource-group ${RESOURCE_GROUP} --name image-registry --location ${LOCATION}
az identity create --resource-group ${RESOURCE_GROUP} --name file-csi-driver --location ${LOCATION}
az identity create --resource-group ${RESOURCE_GROUP} --name aro-operator --location ${LOCATION}
```

**Step 2: Assign ARO Built-in Roles to Identities**

⚠️ **IMPORTANT:** These role assignments MUST be created **before** cluster creation.

```bash
# Get VNet information (adjust if using existing VNet)
VNET_NAME=<vnet-name>
VNET_RG=<vnet-resource-group>  # Can be different from cluster RG
MASTER_SUBNET=<master-subnet-name>
WORKER_SUBNET=<worker-subnet-name>

# Grant cluster identity the Federated Credential role on all 8 operator identities
# This allows aro-cluster to create federated credentials for workload identities

for IDENTITY in aro-operator cloud-controller-manager ingress machine-api disk-csi-driver cloud-network-config image-registry file-csi-driver; do
  az role assignment create \
    --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name aro-cluster --query principalId -o tsv)" \
    --assignee-principal-type ServicePrincipal \
    --role "Azure Red Hat OpenShift Federated Credential" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${IDENTITY}"
done

# Grant operator-specific roles at subnet or VNet scope

# cloud-controller-manager: Manages Azure load balancers and public IPs
az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name cloud-controller-manager --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Cloud Controller Manager" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${MASTER_SUBNET}"

az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name cloud-controller-manager --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Cloud Controller Manager" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${WORKER_SUBNET}"

# ingress: Manages ingress load balancers
az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ingress --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Cluster Ingress Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${MASTER_SUBNET}"

az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ingress --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Cluster Ingress Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${WORKER_SUBNET}"

# machine-api: Creates and manages VMs
az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name machine-api --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Machine API Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${MASTER_SUBNET}"

az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name machine-api --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Machine API Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${WORKER_SUBNET}"

# cloud-network-config: Manages networking resources
az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name cloud-network-config --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Network Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"

# file-csi-driver: Manages Azure Files storage
az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name file-csi-driver --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift File Storage Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"

# image-registry: Manages registry storage
az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name image-registry --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Image Registry Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"

# aro-operator: Manages ARO service operations
az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name aro-operator --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Service Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${MASTER_SUBNET}"

az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name aro-operator --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Service Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${WORKER_SUBNET}"

# Grant Azure Red Hat OpenShift RP service principal permissions on VNet
az role assignment create \
  --assignee-object-id "$(az ad sp list --display-name "Azure Red Hat OpenShift RP" --query '[0].id' -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Cluster" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"
```

**Step 3: Create Cluster with Managed Identity Flags**

During `az aro create`, reference the identities you created:

```bash
az aro create \
  --resource-group ${RESOURCE_GROUP} \
  --name ${CLUSTER_NAME} \
  --vnet ${VNET_NAME} \
  --vnet-resource-group ${VNET_RG} \
  --master-subnet ${MASTER_SUBNET} \
  --worker-subnet ${WORKER_SUBNET} \
  --enable-managed-identity \
  --assign-cluster-identity aro-cluster \
  --assign-platform-workload-identity file-csi-driver file-csi-driver \
  --assign-platform-workload-identity cloud-controller-manager cloud-controller-manager \
  --assign-platform-workload-identity ingress ingress \
  --assign-platform-workload-identity image-registry image-registry \
  --assign-platform-workload-identity machine-api machine-api \
  --assign-platform-workload-identity cloud-network-config cloud-network-config \
  --assign-platform-workload-identity aro-operator aro-operator \
  --assign-platform-workload-identity disk-csi-driver disk-csi-driver
```

**Additional Network Resources (if using BYO NSG, Route Table, NAT Gateway):**

If you attach NSG, Route Table, or NAT Gateway to subnets, grant additional permissions:

```bash
# Example: If using BYO NSG on master subnet
NSG_NAME=<master-nsg-name>

az role assignment create \
  --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name aro-operator --query principalId -o tsv)" \
  --assignee-principal-type ServicePrincipal \
  --role "Azure Red Hat OpenShift Service Operator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RG}/providers/Microsoft.Network/networkSecurityGroups/${NSG_NAME}"

# Repeat for worker NSG, route tables, NAT gateways as needed
```

**Benefits:**
- ✅ **No service principal required** - eliminates long-lived credential management
- ✅ **Short-lived tokens only** - workload identity uses federated credentials (OIDC tokens)
- ✅ Least privilege access with operator-specific ARO built-in roles
- ✅ No credential rotation required
- ✅ Significantly better security posture
- ✅ Recommended for all production environments

**References:**
- Official Guide: https://learn.microsoft.com/en-us/azure/openshift/howto-create-openshift-cluster
- Managed Identity Overview: https://learn.microsoft.com/en-us/azure/openshift/howto-understand-managed-identities
- Red Hat Guide: https://cloud.redhat.com/experts/aro/miwi/

#### Option 2: Service Principal (Legacy, Not Recommended)

**Only use if managed identity is not an option due to specific organizational constraints.**

- [ ] **Create Azure AD Service Principal for ARO**
  ```bash
  # Create service principal
  az ad sp create-for-rbac \
    --name ${CLUSTER_NAME}-sp \
    --role Contributor \
    --scopes /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}
  
  # Save the output (appId and password) securely
  # WARNING: These credentials must be rotated before expiration
  ```

- [ ] **Assign Contributor role to VNet resource group**
  ```bash
  az role assignment create \
    --assignee <service-principal-app-id> \
    --role Contributor \
    --scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/<vnet-rg>
  ```

- [ ] **Assign Network Contributor to route table** (if using BYO route table)

- [ ] **Securely store credentials in Azure Key Vault**
  ```bash
  az keyvault secret set \
    --vault-name <keyvault-name> \
    --name "${CLUSTER_NAME}-sp-appid" \
    --value <app-id>
  
  az keyvault secret set \
    --vault-name <keyvault-name> \
    --name "${CLUSTER_NAME}-sp-password" \
    --value <password>
  ```

- [ ] **Set up credential rotation process**
  - Service principals expire (default: 1 year)
  - Must be rotated before expiration to avoid cluster outage
  - Document rotation procedure
  - Set calendar reminders

**Drawbacks:**
- ❌ Requires manual credential rotation
- ❌ Credentials can be leaked if not properly secured
- ❌ Broader permissions than necessary (Contributor role vs. operator-specific roles)
- ❌ More operational overhead

---

### Network Architecture Planning

ARO clusters require careful network planning. This section helps you design your network topology.

#### Network Topology Decisions

- [ ] **Choose Network Topology**

  **Option A: Single VNet (Simpler)**
  - ARO cluster and all resources in one VNet
  - Easier to manage
  - Suitable for: Development, testing, small deployments
  
  **Option B: Hub-Spoke Topology (Enterprise)**
  - Hub VNet contains shared services (firewall, VPN gateway, DNS)
  - Spoke VNet contains ARO cluster
  - VNet peering connects hub and spoke
  - Suitable for: Production, multi-cluster, enterprise environments
  
  ```
  Hub-Spoke Example:
  
  Hub VNet (10.0.0.0/16)
  ├─ Firewall Subnet (10.0.1.0/24)
  ├─ Gateway Subnet (10.0.2.0/24)
  └─ DNS Subnet (10.0.3.0/24)
       │
       │ (VNet Peering)
       ↓
  Spoke VNet (10.1.0.0/16) - ARO Cluster
  ├─ Master Subnet (10.1.0.0/24)
  └─ Worker Subnet (10.1.1.0/24)
  ```

- [ ] **Choose Cluster Visibility**

  | Visibility | API Server | Ingress (*.apps) | Use Case |
  |-----------|------------|------------------|----------|
  | **Private** (Recommended) | Private IP | Private IP | Production, enterprise, security-sensitive |
  | **Public** | Public IP | Public IP | Development, testing, demos |
  
  **Private Cluster Considerations:**
  - Requires VPN, ExpressRoute, or Azure Bastion for access
  - API server only accessible from VNet or peered networks
  - Applications not directly exposed to internet (use Azure Front Door or App Gateway)
  - **Recommended for all production deployments**
  
  **Public Cluster Considerations:**
  - API server and applications publicly accessible
  - Easier initial setup
  - **Only recommended for sandbox/development environments**

- [ ] **Choose Egress/Outbound Connectivity Strategy**

  | Option | Description | Use Case |
  |--------|-------------|----------|
  | **LoadBalancer** (Default) | Public IP on Azure Load Balancer | Simple deployments, development |
  | **UserDefinedRouting (UDR)** | Custom route table, typically via firewall/NVA | Production, controlled egress, security compliance |
  | **Azure Firewall** | Managed firewall service | Enterprise, centralized security, logging |
  | **NAT Gateway** | Dedicated outbound connectivity | High-throughput scenarios, predictable IPs |
  
  **Egress Lockdown Feature:**
  - **NEW:** ARO clusters with Egress Lockdown enabled do NOT need direct internet access
  - All required Azure/Red Hat connections are proxied through the ARO service
  - Endpoints proxied automatically (no firewall rules needed):
    - `arosvc.azurecr.io` - System container images
    - `management.azure.com` - Azure APIs
    - `login.microsoftonline.com` - Authentication
    - Geneva monitoring endpoints
  - **Optional endpoints** for additional features (require firewall allowlist):
    - `registry.redhat.io`, `quay.io` - Red Hat operators from OperatorHub
    - `cert-api.access.redhat.com` - Red Hat Telemetry (opt-in only)
    - `api.openshift.com` - Check for cluster updates
  - See [Egress Restrictions](#egress-restrictions-and-firewall-configuration) for detailed endpoint list
  
  **UserDefinedRouting (UDR) for Private Clusters without Public IP:**
  - Create fully private cluster with NO public IP address
  - Requires `--outbound-type UserDefinedRouting` during cluster creation
  - **MUST** pre-configure route table with proper routes to Azure endpoints
  - Only works with `--apiserver-visibility Private` and `--ingress-visibility Private`
  - Customer is fully responsible for egress routing (ARO cannot manage it)
  - Supports configuring egress IPs per namespace/pod
  - See [Private Cluster without Public IP](#private-cluster-without-public-ip) for implementation

#### IP Address Planning

**CRITICAL:** Plan IP address ranges carefully. Overlapping ranges cause connectivity issues.

- [ ] **Plan VNet and Subnet CIDRs**

  | Resource | Minimum Size | Recommended Size | Example CIDR |
  |----------|--------------|------------------|--------------|
  | VNet | /20 (4,096 IPs) | /16 (65,536 IPs) | 10.0.0.0/16 |
  | Master Subnet | /27 (32 IPs) | /26 (64 IPs) | 10.0.0.0/26 |
  | Worker Subnet | /27 (32 IPs) | /24 (256 IPs) | 10.0.1.0/24 |
  
  **Master Subnet Sizing:**
  - Minimum 3 master nodes
  - Each master has 1 primary IP + potential for additional IPs
  - Plan for Azure reserved IPs (first 4 and last 1 in each subnet)
  
  **Worker Subnet Sizing:**
  - Initial: Minimum 3 worker nodes
  - Scaling: Plan for autoscaling (e.g., up to 100 nodes)
  - Each node: 1 primary IP
  - Load balancers: Additional IPs needed

- [ ] **Plan OpenShift Network CIDRs**

  | Network | Default | Must Not Overlap With |
  |---------|---------|----------------------|
  | **Pod CIDR** | 10.128.0.0/14 | VNet, Peered VNets, On-Premises |
  | **Service CIDR** | 172.30.0.0/16 | VNet, Peered VNets, On-Premises |
  
  **Pod CIDR:**
  - Must be minimum /18 or larger
  - Default provides 16,384 pod IPs
  - Cannot be changed after cluster creation
  
  **Service CIDR:**
  - Must be minimum /18 or larger
  - Default provides 65,536 service IPs
  - Cannot be changed after cluster creation
  
  ```bash
  # Specify custom CIDRs during cluster creation
  az aro create \
    ... \
    --pod-cidr <custom-pod-cidr> \
    --service-cidr <custom-service-cidr>
  ```

- [ ] **Verify No IP Overlap**
  
  Check for overlaps between:
  - VNet CIDR ↔ On-premises networks
  - VNet CIDR ↔ Peered VNets
  - Pod CIDR ↔ VNet/Peered VNets/On-premises
  - Service CIDR ↔ VNet/Peered VNets/On-premises
  
  **Common Overlap Issues:**
  - Default Pod CIDR (10.128.0.0/14) overlaps with on-prem 10.0.0.0/8
  - Default Service CIDR (172.30.0.0/16) overlaps with common VPN ranges
  - Solution: Use non-standard CIDRs like 100.64.0.0/14 for pods

#### Connectivity Planning

- [ ] **Plan Inbound Connectivity** (for private clusters)

  | Option | Use Case | Setup Complexity |
  |--------|----------|------------------|
  | **Point-to-Site VPN** | Individual developer access | Low |
  | **Site-to-Site VPN** | Office/datacenter connectivity | Medium |
  | **ExpressRoute** | Dedicated, high-bandwidth connection | High |
  | **Azure Bastion** | Jump box access (no VPN client needed) | Low |
  
  - See [Optional: Private Cluster Access](#optional-private-cluster-access) for setup details

- [ ] **Plan Application Exposure** (for private clusters)

  | Option | Use Case |
  |--------|----------|
  | **Azure Front Door** | Global load balancing, WAF, SSL offload, caching |
  | **Azure Application Gateway** | Regional load balancing, WAF, path-based routing |
  | **OpenShift Route** | Simple HTTP/HTTPS exposure (internal only for private clusters) |

---

### Network Security Groups

**DECISION POINT:** ARO-managed NSG vs. Bring Your Own NSG (BYO NSG)

#### Decision: ARO-Managed NSG vs BYO NSG

- [ ] **Choose NSG Management Model**

  | Factor | ARO-Managed NSG (RECOMMENDED) | BYO NSG |
  |--------|-------------------------------|---------|
  | **Setup Complexity** | ✅ Minimal - ARO creates and manages | ❌ Complex - pre-create and configure |
  | **Operational Overhead** | ✅ Low - ARO maintains rules | ❌ High - manual rule management |
  | **Compliance** | Suitable for most environments | Required if pre-creation mandated |
  | **Customization** | Limited (ARO controls) | Full control over rules |
  | **Risk of Misconfiguration** | ✅ Low | ⚠️ High - can break cluster |
  
  **Recommendation:**
  - Use **ARO-managed NSG** unless compliance/governance requires pre-creation
  - ARO automatically creates NSGs and maintains required rules
  - Reduces operational burden and configuration errors

#### If Using BYO NSG

⚠️ **WARNING:** Misconfigured NSGs can prevent cluster deployment or cause operational issues.

For complete BYO NSG setup, see [Appendix A: Network Security Groups Deep Dive](#appendix-a-network-security-groups-deep-dive)

**Summary of Requirements:**
- Pre-create NSGs before cluster deployment
- Attach to master and worker subnets (not individual NICs)
- Configure all required ARO service tag rules
- **Never delete or modify ARO-required rules** (priorities 500-3000)
- Identity permissions:
  - **With Managed Identity:** ARO built-in roles automatically assigned (no action needed)
  - **With Service Principal:** Manually assign Network Contributor role

---

### Cluster Configuration Planning

#### Cluster Sizing

- [ ] **Plan Master Node Configuration**

  | Scenario | VM Size | vCPU | Memory | Notes |
  |----------|---------|------|--------|-------|
  | **Minimum** | Standard_D8s_v5 | 8 | 32 GB | Required minimum |
  | **Production** | Standard_D16s_v5 | 16 | 64 GB | Recommended |
  | **Large Scale** | Standard_D32s_v5 | 32 | 128 GB | For very large clusters |
  
  - Master nodes: Always 3 nodes (fixed, cannot be changed)
  - Control plane etcd and API server run on master nodes
  - Cannot be scaled horizontally after creation
  - Vertical scaling (resize) possible but complex

- [ ] **Plan Worker Node Configuration**

  | Workload Type | VM Size | vCPU | Memory | Example Use Case |
  |---------------|---------|------|--------|------------------|
  | **General Purpose** | Standard_D4s_v5 | 4 | 16 GB | Web apps, APIs, microservices |
  | **Compute Intensive** | Standard_F8s_v2 | 8 | 16 GB | Batch processing, analytics |
  | **Memory Intensive** | Standard_E8s_v5 | 8 | 64 GB | Databases, in-memory caches |
  | **GPU Workloads** | Standard_NC6s_v3 | 6 | 112 GB | ML training, inference |
  
  - Minimum: 3 worker nodes recommended
  - Can be scaled after cluster creation
  - Consider autoscaling requirements
  - Mix VM sizes using multiple MachineSets if needed

- [ ] **GPU Planning** (if required)

  ARO supports GPU workloads:
  - NC-series VMs (NVIDIA GPUs)
  - Requires NVIDIA GPU Operator
  - Requires NVIDIA device plugin
  - Plan for GPU node pools separate from general compute
  
  See [Tier 3: AI/ML and Advanced Workloads](#ai-ml-and-advanced-workloads) for GPU setup

#### Version Selection

- [ ] **Choose OpenShift Version**

  ```bash
  # List available ARO versions for your region
  az aro get-versions --location <location>
  ```
  
  **Version Selection Strategy:**
  - Use latest stable version for new deployments
  - For production: Use n-1 version (one behind latest) for proven stability
  - Check [OpenShift lifecycle](https://access.redhat.com/support/policy/updates/openshift) for support windows
  - Plan for regular upgrades (quarterly recommended)

#### Domain Configuration

- [ ] **Decide: Custom Domain vs Default Domain**

  | Option | Format | Use Case |
  |--------|--------|----------|
  | **Default Domain** | `<random>.aroapp.io` | Quick setup, development, testing |
  | **Custom Domain** | `apps.mycompany.com` | Production, branded URLs |
  
  **Custom Domain Requirements:**
  - Control over DNS zone
  - Ability to create A records
  - Custom TLS certificates (or use cert-manager)
  - Post-deployment configuration required
  
  See [Optional: Custom Domain Configuration](#optional-custom-domain-configuration) for setup

---

### Storage Planning

#### Storage Requirements Assessment

- [ ] **Identify Storage Needs**

  | Application Type | Storage Type | Performance Tier |
  |------------------|--------------|------------------|
  | Stateless apps | None required | N/A |
  | Databases | Block storage (Azure Disk) | Premium SSD |
  | Shared files | File storage (Azure Files) | Premium or Standard |
  | Large objects | Blob storage (Azure Blob) | Hot/Cool tier |
  | High IOPS | Ultra Disk or managed Lustre | Ultra performance |

#### Default Storage Classes

ARO includes these storage classes by default:

| Storage Class | Provisioner | Use Case | Reclaim Policy |
|---------------|-------------|----------|----------------|
| `managed-csi` | Azure Disk CSI | General purpose block storage | Delete |
| `managed-premium` | Azure Disk CSI | High-performance block storage | Delete |
| `azurefile-csi` | Azure Files CSI | Shared file storage (RWX) | Delete |

**Note:** With managed identities enabled, the default `azurefile` StorageClass is disabled. Create custom StorageClass if needed.

- [ ] **Plan Additional Storage** (if required)

  **Azure Files CSI Driver:**
  - ReadWriteMany (RWX) access mode
  - Shared across multiple pods
  - Suitable for shared application data
  
  **Azure Blob CSI Driver:**
  - Large object storage
  - Mounting blob containers as volumes
  - Suitable for ML datasets, media files
  
  **OpenShift Data Foundation (ODF):**
  - Software-defined storage on ARO
  - Block, file, and object storage
  - Self-contained storage solution
  
  **NetApp Files:**
  - Enterprise NFS storage
  - High performance and features
  - Requires NetApp account

#### Encryption Planning

- [ ] **Plan Disk Encryption**

  **Option A: Azure Managed Keys (Default)**
  - Microsoft-managed encryption keys
  - No additional configuration
  - Enabled by default
  
  **Option B: Customer-Managed Keys (BYOK/CMK)**
  - Full control over encryption keys
  - Requires Azure Key Vault with purge protection
  - Encrypts both OS disks and data disks
  - **CRITICAL:** Customer responsible for key maintenance - key loss = cluster failure
  - Cannot be enabled on existing clusters (master nodes only for new clusters)
  - See [Encryption with Customer-Managed Keys](#encryption-with-customer-managed-keys) for implementation
  - Requires Disk Encryption Set
  
  **To use CMK:**
  ```bash
  # Create Key Vault and key
  az keyvault create -n <keyvault-name> -g <rg> -l <location> --enable-purge-protection
  az keyvault key create --vault-name <keyvault-name> -n <key-name> --protection software
  
  # Create Disk Encryption Set
  az disk-encryption-set create \
    -n <des-name> \
    -g <rg> \
    -l <location> \
    --source-vault <keyvault-id> \
    --key-url <key-url>
  
  # Use with ARO cluster creation
  az aro create ... --disk-encryption-set <des-id>
  ```
  
  See [ARO-RP Disk Encryption documentation](~/Documents/GitHub/ARO-RP/docs/disk-encryption-set.md) for details

---

### Compliance & Governance

#### Azure Policy

- [ ] **Plan Policy Enforcement**
  
  Common policies for ARO:
  - Enforce resource tagging
  - Require specific Azure regions
  - Enforce encryption at rest
  - Require diagnostic logging
  - Prevent public IP creation
  
  ```bash
  # Assign built-in policy to resource group
  az policy assignment create \
    --name <assignment-name> \
    --policy <policy-definition-id> \
    --scope /subscriptions/<sub-id>/resourceGroups/<rg>
  ```

#### Tagging Strategy

- [ ] **Define Resource Tags**

  | Tag Key | Example Value | Purpose |
  |---------|---------------|---------|
  | Environment | Production, Development, Test | Environment classification |
  | CostCenter | IT-001, Engineering-002 | Chargeback/showback |
  | Owner | teamname@company.com | Accountability |
  | Application | myapp | Application grouping |
  | Criticality | Critical, High, Medium, Low | SLA/support tier |
  
  ```bash
  # Apply tags during cluster creation
  az aro create ... --tags "Environment=Production" "CostCenter=IT" "Owner=platform-team"
  ```

#### Backup and DR Planning

- [ ] **Plan Backup Strategy**
  
  **What to back up:**
  - etcd (control plane state)
  - Persistent Volumes (application data)
  - Cluster configuration (GitOps recommended)
  - Application manifests
  
  **Backup tools:**
  - OpenShift API for Data Protection (OADP) - Recommended
  - Velero (underlying OADP technology)
  - Azure Backup (for Azure-native backups)
  
  **Backup frequency:**
  - etcd: Daily minimum, hourly for critical workloads
  - PVs: Based on RPO requirements (e.g., every 6 hours)
  - Configuration: On every change (GitOps)

- [ ] **Plan Disaster Recovery**
  
  **DR Strategies:**
  - **Backup/Restore:** Restore cluster in different region
  - **Active/Passive:** Standby cluster in DR region
  - **Active/Active:** Multi-cluster with traffic distribution
  
  **RPO/RTO targets:**
  - Recovery Point Objective (RPO): Maximum acceptable data loss
  - Recovery Time Objective (RTO): Maximum acceptable downtime
  - Document requirements and align backup strategy

---

## Part 2: Cluster Deployment (Day 1)

This section guides you through the actual deployment of your ARO cluster.

### Pre-Deployment Verification

Before creating your cluster, verify all prerequisites are in place.

- [ ] **Verify Authentication**
  ```bash
  # Ensure you're logged in to Azure
  az account show
  
  # Set correct subscription
  az account set --subscription <subscription-id>
  
  # Verify subscription
  az account show --query "{Name:name, ID:id, State:state}" -o table
  ```

- [ ] **Verify Azure CLI Version**
  ```bash
  # Check version (must be 2.30.0 or later)
  az --version | grep azure-cli
  
  # Update if needed
  # macOS: brew upgrade azure-cli
  # Others: see https://docs.microsoft.com/cli/azure/update-azure-cli
  ```

- [ ] **Create Resource Groups**
  ```bash
  # Resource group for ARO cluster
  az group create \
    --name <resource-group> \
    --location <location>
  
  # Resource group for VNet (if separate)
  az group create \
    --name <vnet-resource-group> \
    --location <location>
  ```

---

### Network Infrastructure Deployment

#### VNet and Subnets Creation

- [ ] **Create Virtual Network**
  ```bash
  # Create VNet
  az network vnet create \
    --resource-group <vnet-rg> \
    --name <vnet-name> \
    --address-prefixes <vnet-cidr>  # e.g., 10.0.0.0/16
  ```

- [ ] **Create Master Subnet**
  ```bash
  # Create master subnet with service endpoints
  az network vnet subnet create \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <master-subnet-name> \
    --address-prefixes <master-subnet-cidr> \
    --service-endpoints Microsoft.ContainerRegistry
  
  # Disable private link service network policies on master subnet
  az network vnet subnet update \
    --name <master-subnet-name> \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --private-link-service-network-policies Disabled
  ```
  
  **Master Subnet Requirements:**
  - Minimum /27 (32 IPs)
  - Service endpoint for Microsoft.ContainerRegistry
  - Private link service network policies must be disabled

- [ ] **Create Worker Subnet**
  ```bash
  # Create worker subnet with service endpoints
  az network vnet subnet create \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <worker-subnet-name> \
    --address-prefixes <worker-subnet-cidr> \
    --service-endpoints Microsoft.ContainerRegistry
  ```
  
  **Worker Subnet Requirements:**
  - Minimum /27 (32 IPs), recommended /24 for scaling
  - Service endpoint for Microsoft.ContainerRegistry

#### BYO NSG Configuration (If Applicable)

⚠️ **Skip this section if using ARO-managed NSG (recommended)**

If you chose to bring your own NSG in the planning phase:

- [ ] **Create Network Security Groups**
  ```bash
  # Create NSG for master subnet
  az network nsg create \
    --resource-group <vnet-rg> \
    --name <cluster-name>-master-nsg \
    --location <location>
  
  # Create NSG for worker subnet
  az network nsg create \
    --resource-group <vnet-rg> \
    --name <cluster-name>-worker-nsg \
    --location <location>
  ```

- [ ] **Attach NSGs to Subnets**
  ```bash
  # Attach to master subnet
  az network vnet subnet update \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <master-subnet-name> \
    --network-security-group <cluster-name>-master-nsg
  
  # Attach to worker subnet
  az network vnet subnet update \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <worker-subnet-name> \
    --network-security-group <cluster-name>-worker-nsg
  ```

- [ ] **Configure Required NSG Rules**
  
  See [Appendix A: Network Security Groups Deep Dive](#appendix-a-network-security-groups-deep-dive) for complete rule configuration.
  
  **Critical rules include:**
  - Master ↔ Worker communication (ports 6443, 22623, 2379-2380, etc.)
  - Azure service tags (AzureLoadBalancer, AzureCloud)
  - Ingress traffic (ports 80, 443)

- [ ] **Grant Identity Permissions on NSGs**
  
  **With Managed Identity:**
  - ARO built-in roles are automatically assigned during cluster creation
  - No manual action required
  
  **With Service Principal:**
  ```bash
  # Assign Network Contributor to service principal on NSGs
  az role assignment create \
    --assignee <service-principal-id> \
    --role "Network Contributor" \
    --scope /subscriptions/<sub-id>/resourceGroups/<vnet-rg>/providers/Microsoft.Network/networkSecurityGroups/<master-nsg-name>
  
  az role assignment create \
    --assignee <service-principal-id> \
    --role "Network Contributor" \
    --scope /subscriptions/<sub-id>/resourceGroups/<vnet-rg>/providers/Microsoft.Network/networkSecurityGroups/<worker-nsg-name>
  ```

---

### Managed Identity Setup

If you chose Managed Identity in planning (recommended), these identities should already be created. Verify they exist:

- [ ] **Verify Managed Identities Exist**
  ```bash
  # List all identities in resource group
  az identity list --resource-group <rg> -o table
  
  # Should see 9 identities:
  # - <cluster-name>-aro-cluster
  # - <cluster-name>-cloud-controller-manager
  # - <cluster-name>-ingress
  # - <cluster-name>-machine-api
  # - <cluster-name>-disk-csi-driver
  # - <cluster-name>-cloud-network-config
  # - <cluster-name>-image-registry
  # - <cluster-name>-file-csi-driver
  # - <cluster-name>-aro-operator
  ```

If not created yet, create them now (see [Identity & Access Strategy](#identity--access-strategy) for commands).

---

### ARO Cluster Creation

Now we're ready to create the actual ARO cluster.

#### Recommended: Private Cluster with Managed Identity

This is the recommended configuration for production environments.

- [ ] **Create Private ARO Cluster**

  ```bash
  # Set variables
  SUBSCRIPTION_ID=<subscription-id>
  RESOURCE_GROUP=<rg>
  CLUSTER_NAME=<cluster-name>
  VNET_NAME=<vnet-name>
  VNET_RG=<vnet-resource-group>
  LOCATION=<location>
  
  # Create private ARO cluster with managed identities
  # Prerequisites: Identities and role assignments must be created BEFORE running this command
  # See "Identity & Access Strategy" section for identity creation and role assignment steps
  az aro create \
    --resource-group ${RESOURCE_GROUP} \
    --name ${CLUSTER_NAME} \
    --vnet ${VNET_NAME} \
    --vnet-resource-group ${VNET_RG} \
    --master-subnet <master-subnet-name> \
    --worker-subnet <worker-subnet-name> \
    --apiserver-visibility Private \
    --ingress-visibility Private \
    --pull-secret @pull-secret.txt \
    --enable-managed-identity \
    --assign-cluster-identity /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-aro-cluster \
    --assign-platform-workload-identity file-csi-driver /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-file-csi-driver \
    --assign-platform-workload-identity cloud-controller-manager /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-cloud-controller-manager \
    --assign-platform-workload-identity ingress /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-ingress \
    --assign-platform-workload-identity image-registry /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-image-registry \
    --assign-platform-workload-identity machine-api /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-machine-api \
    --assign-platform-workload-identity cloud-network-config /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-cloud-network-config \
    --assign-platform-workload-identity aro-operator /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-aro-operator \
    --assign-platform-workload-identity disk-csi-driver /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-disk-csi-driver
  
  # Optional parameters (add as needed):
  # --domain <custom-domain>                    # Custom domain prefix
  # --tags "key=value"                          # Resource tags
  # --worker-count <number>                     # Worker node count (default: 3)
  # --worker-vm-size <size>                     # Worker VM size (default: Standard_D4s_v5)
  # --master-vm-size <size>                     # Master VM size (default: Standard_D8s_v5)
  # --pod-cidr <cidr>                           # Pod CIDR (default: 10.128.0.0/14)
  # --service-cidr <cidr>                       # Service CIDR (default: 172.30.0.0/16)
  # --cluster-resource-group <rg-name>          # Infrastructure resource group name
  # --outbound-type UserDefinedRouting          # If using custom routing
  ```
  
  **Deployment Time:** 30-45 minutes
  
  Monitor deployment:
  ```bash
  # Check deployment status
  az aro show --name ${CLUSTER_NAME} --resource-group ${RESOURCE_GROUP} --query provisioningState
  
  # Watch for completion
  watch az aro show --name ${CLUSTER_NAME} --resource-group ${RESOURCE_GROUP} --query provisioningState -o tsv
  ```

#### Alternative: Public Cluster

⚠️ **Only use for development/testing. Not recommended for production.**

- [ ] **Create Public ARO Cluster**

  ```bash
  # Set variables (same as above)
  
  # Create public ARO cluster - omit visibility flags for public access
  az aro create \
    --resource-group ${RESOURCE_GROUP} \
    --name ${CLUSTER_NAME} \
    --vnet ${VNET_NAME} \
    --vnet-resource-group ${VNET_RG} \
    --master-subnet <master-subnet-name> \
    --worker-subnet <worker-subnet-name> \
    --pull-secret @pull-secret.txt \
    --enable-managed-identity \
    --assign-cluster-identity /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-aro-cluster \
    --assign-platform-workload-identity file-csi-driver /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-file-csi-driver \
    --assign-platform-workload-identity cloud-controller-manager /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-cloud-controller-manager \
    --assign-platform-workload-identity ingress /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-ingress \
    --assign-platform-workload-identity image-registry /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-image-registry \
    --assign-platform-workload-identity machine-api /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-machine-api \
    --assign-platform-workload-identity cloud-network-config /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-cloud-network-config \
    --assign-platform-workload-identity aro-operator /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-aro-operator \
    --assign-platform-workload-identity disk-csi-driver /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${CLUSTER_NAME}-disk-csi-driver
  ```

#### Legacy: Service Principal Deployment

⚠️ **Not recommended. Only use if managed identity is absolutely not an option.**

- [ ] **Create ARO Cluster with Service Principal**

  ```bash
  # Only use if managed identity is not an option
  az aro create \
    --resource-group ${RESOURCE_GROUP} \
    --name ${CLUSTER_NAME} \
    --vnet ${VNET_NAME} \
    --vnet-resource-group ${VNET_RG} \
    --master-subnet <master-subnet-name> \
    --worker-subnet <worker-subnet-name> \
    --client-id <service-principal-app-id> \
    --client-secret <service-principal-password> \
    --pull-secret @pull-secret.txt
  ```

---

### Post-Deployment Validation

After cluster creation completes, validate everything is working correctly.

- [ ] **Verify Cluster Status**
  ```bash
  # Check cluster provisioning state
  az aro show \
    --name ${CLUSTER_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --query "{Name:name, State:provisioningState, Visibility:apiserverProfile.visibility}" -o table
  
  # Should show: provisioningState = "Succeeded"
  ```

- [ ] **Get Cluster Credentials**
  ```bash
  # Get admin credentials
  az aro list-credentials \
    --name ${CLUSTER_NAME} \
    --resource-group ${RESOURCE_GROUP}
  
  # Save kubeadmin username and password
  ```

- [ ] **Get API Server and Console URLs**
  ```bash
  # Get API server URL
  az aro show \
    --name ${CLUSTER_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --query "{API:apiserverProfile.url, Console:consoleProfile.url}" -o table
  ```

- [ ] **Login to Cluster**
  
  **For Private Clusters:**
  - Must be connected via VPN, ExpressRoute, or Bastion
  - See [Optional: Private Cluster Access](#optional-private-cluster-access)
  
  ```bash
  # Get API server URL
  API_SERVER=$(az aro show -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --query apiserverProfile.url -o tsv)
  
  # Get credentials
  KUBEADMIN_PASSWD=$(az aro list-credentials -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --query kubeadminPassword -o tsv)
  
  # Login
  oc login ${API_SERVER} --username kubeadmin --password ${KUBEADMIN_PASSWD}
  ```

- [ ] **Verify Cluster Operators**
  ```bash
  # Check all cluster operators are available
  oc get clusteroperators
  
  # All operators should show:
  # AVAILABLE=True, PROGRESSING=False, DEGRADED=False
  
  # If any operators are not available, investigate:
  oc describe clusteroperator <operator-name>
  ```

- [ ] **Verify Nodes**
  ```bash
  # Check all nodes are Ready
  oc get nodes
  
  # Should see 3 master nodes and N worker nodes, all Ready
  
  # Check node details
  oc describe node <node-name>
  ```

- [ ] **Verify Cluster Version**
  ```bash
  # Check installed OpenShift version
  oc get clusterversion
  
  # Should match the version you requested
  ```

- [ ] **Access Console**
  
  ```bash
  # Open console URL in browser
  CONSOLE_URL=$(az aro show -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --query consoleProfile.url -o tsv)
  echo "Console URL: ${CONSOLE_URL}"
  
  # Login with kubeadmin credentials
  ```

---

### Initial Configuration

These configurations are best done immediately after deployment to establish a baseline for operations.

#### Enable User Workload Monitoring

- [ ] **Enable User Workload Monitoring**
  ```bash
  # Create ConfigMap to enable user workload monitoring
  cat <<EOF | oc apply -f -
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: cluster-monitoring-config
    namespace: openshift-monitoring
  data:
    config.yaml: |
      enableUserWorkload: true
  EOF
  
  # Verify user workload monitoring pods are created
  oc -n openshift-user-workload-monitoring get pods
  ```

#### Deploy Cluster Logging Operator

- [ ] **Install Cluster Logging Operator**
  ```bash
  # Create namespace
  oc create namespace openshift-logging
  
  # Create OperatorGroup
  cat <<EOF | oc apply -f -
  apiVersion: operators.coreos.com/v1
  kind: OperatorGroup
  metadata:
    name: cluster-logging
    namespace: openshift-logging
  spec:
    targetNamespaces:
    - openshift-logging
  EOF
  
  # Create Subscription
  cat <<EOF | oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
    name: cluster-logging
    namespace: openshift-logging
  spec:
    channel: stable
    name: cluster-logging
    source: redhat-operators
    sourceNamespace: openshift-marketplace
  EOF
  
  # Wait for operator to install
  oc -n openshift-logging get csv
  ```

- [ ] **Create ClusterLogging Instance**
  ```bash
  # Create ClusterLogging instance with default configuration
  cat <<EOF | oc apply -f -
  apiVersion: logging.openshift.io/v1
  kind: ClusterLogging
  metadata:
    name: instance
    namespace: openshift-logging
  spec:
    managementState: Managed
    logStore:
      type: lokistack
      lokistack:
        name: logging-loki
    collection:
      type: vector
  EOF
  
  # Note: This requires LokiStack. For simpler setup, can use Elasticsearch
  # See documentation for alternative configurations
  ```

#### Configure Audit Logging

- [ ] **Enable API Audit Logging**
  ```bash
  # Update API server with audit policy
  cat <<EOF | oc apply -f -
  apiVersion: config.openshift.io/v1
  kind: APIServer
  metadata:
    name: cluster
  spec:
    audit:
      profile: Default  # Options: Default, WriteRequestBodies, AllRequestBodies
  EOF
  
  # Verify audit logs are being generated
  oc adm node-logs --role=master --path=openshift-apiserver/audit.log
  ```

#### Create Initial Admin Users

⚠️ **IMPORTANT:** The kubeadmin account is for initial access only. Create proper admin users/groups.

- [ ] **Create Cluster Admin Group and Users**
  ```bash
  # This example uses Azure AD. Adjust for your IdP.
  
  # Create cluster-admins group
  oc adm groups new cluster-admins
  
  # Add Azure AD users to group
  oc adm groups add-users cluster-admins <user@domain.com>
  
  # Grant cluster-admin role to group
  oc adm policy add-cluster-role-to-group cluster-admin cluster-admins
  
  # Verify
  oc get groups cluster-admins
  oc describe group cluster-admins
  ```

- [ ] **Disable kubeadmin Account** (after verifying admin access)
  ```bash
  # ONLY do this after confirming you can login with a proper admin account
  oc delete secret kubeadmin -n kube-system
  
  # WARNING: This cannot be undone easily. Ensure you have alternative admin access!
  ```

---

### Optional: Custom Domain Configuration

If you plan to use a custom domain instead of the default `*.aroapp.io`:

- [ ] **Get Cluster IP Addresses**
  ```bash
  # Get API server IP and ingress IP
  az aro show \
    --name ${CLUSTER_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --query '{"API":apiserverProfile.ip, "Ingress":ingressProfiles[0].ip}' -o table
  ```

- [ ] **Create DNS A Records**
  
  In your DNS zone, create:
  - `api.<your-domain>` → API server IP
  - `*.apps.<your-domain>` → Ingress IP
  
  Example:
  ```
  api.openshift.mycompany.com    A   10.0.0.100
  *.apps.openshift.mycompany.com A   10.0.1.100
  ```

- [ ] **Update API Server Certificate**
  ```bash
  # Create or obtain TLS certificate for api.<your-domain>
  # Update API server with custom certificate
  
  oc create secret tls api-cert \
    --cert=api-cert.pem \
    --key=api-key.pem \
    -n openshift-config
  
  oc patch apiserver cluster \
    --type=merge \
    --patch='{"spec":{"servingCerts":{"namedCertificates":[{"names":["api.<your-domain>"],"servingCertificate":{"name":"api-cert"}}]}}}'
  ```

- [ ] **Update Ingress Controller Certificate**
  ```bash
  # Create or obtain wildcard TLS certificate for *.apps.<your-domain>
  
  oc create secret tls apps-cert \
    --cert=apps-cert.pem \
    --key=apps-key.pem \
    -n openshift-ingress
  
  oc patch ingresscontroller default \
    -n openshift-ingress-operator \
    --type=merge \
    --patch='{"spec":{"defaultCertificate":{"name":"apps-cert"}}}'
  ```

---

### Optional: Private Cluster Access

For private clusters, you need a way to access the API server and console. Choose one or more:

#### Option 1: Point-to-Site VPN

- [ ] **Create VPN Gateway**
  ```bash
  # Create gateway subnet
  az network vnet subnet create \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name GatewaySubnet \
    --address-prefixes <gateway-subnet-cidr>  # e.g., 10.0.255.0/27
  
  # Create public IP for VPN gateway
  az network public-ip create \
    --resource-group <vnet-rg> \
    --name <vpn-gw-pip-name> \
    --allocation-method Static \
    --sku Standard
  
  # Create VPN gateway (takes 30-45 minutes)
  az network vnet-gateway create \
    --resource-group <vnet-rg> \
    --name <vpn-gw-name> \
    --vnet <vnet-name> \
    --public-ip-addresses <vpn-gw-pip-name> \
    --gateway-type Vpn \
    --vpn-type RouteBased \
    --sku VpnGw1 \
    --vpn-gateway-generation Generation1
  ```

- [ ] **Configure Point-to-Site VPN**
  ```bash
  # Generate root and client certificates
  # See: https://docs.microsoft.com/azure/vpn-gateway/vpn-gateway-certificates-point-to-site
  
  # Upload root certificate to VPN gateway
  az network vnet-gateway root-cert create \
    --resource-group <vnet-rg> \
    --gateway-name <vpn-gw-name> \
    --name <root-cert-name> \
    --public-cert-data <base64-encoded-cert>
  
  # Set address pool for VPN clients
  az network vnet-gateway update \
    --resource-group <vnet-rg> \
    --name <vpn-gw-name> \
    --address-prefixes <vpn-client-pool>  # e.g., 172.16.0.0/24
  
  # Download VPN client configuration
  az network vnet-gateway vpn-client generate \
    --resource-group <vnet-rg> \
    --name <vpn-gw-name> \
    --processor-architecture Amd64
  ```

#### Option 2: Azure Bastion

- [ ] **Create Azure Bastion**
  ```bash
  # Create bastion subnet
  az network vnet subnet create \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name AzureBastionSubnet \
    --address-prefixes <bastion-subnet-cidr>  # e.g., 10.0.254.0/26 (must be /26 or larger)
  
  # Create public IP for bastion
  az network public-ip create \
    --resource-group <vnet-rg> \
    --name <bastion-pip-name> \
    --sku Standard \
    --allocation-method Static
  
  # Create bastion host
  az network bastion create \
    --resource-group <vnet-rg> \
    --name <bastion-name> \
    --public-ip-address <bastion-pip-name> \
    --vnet-name <vnet-name> \
    --location <location>
  ```

- [ ] **Create Jump Box VM**
  ```bash
  # Create VM in VNet for bastion access
  az vm create \
    --resource-group <vnet-rg> \
    --name jumpbox \
    --image Ubuntu2204 \
    --vnet-name <vnet-name> \
    --subnet <subnet-name> \
    --public-ip-address "" \
    --admin-username azureuser \
    --generate-ssh-keys
  
  # Access via Bastion in Azure Portal
  # Install oc CLI on jump box
  # Access ARO from jump box
  ```

#### Option 3: ExpressRoute

For production environments with on-premises connectivity:

- [ ] **Set up ExpressRoute Circuit**
  - Work with network team to provision ExpressRoute circuit
  - Connect VNet to ExpressRoute gateway
  - Configure BGP peering
  - See: https://docs.microsoft.com/azure/expressroute/

---

### Optional: Private Cluster without Public IP

Create a fully private ARO cluster with **NO public IP address** using User-Defined Routing (UDR). This is required for organizations with strict security policies prohibiting public IPs.

⚠️ **IMPORTANT:** This configuration requires advanced networking knowledge. You are fully responsible for egress routing.

**Prerequisites:**
- Private API server (`--apiserver-visibility Private`)
- Private ingress (`--ingress-visibility Private`)  
- Pre-configured route table with routes to Azure endpoints
- Network Firewall or NVA for internet egress (if needed)

#### Implementation

- [ ] **Create Route Table with Required Routes**
  ```bash
  # Create route table
  az network route-table create \
    --resource-group <vnet-rg> \
    --name ${CLUSTER_NAME}-rt \
    --location <location>
  
  # Add route to Azure Resource Manager (required)
  az network route-table route create \
    --resource-group <vnet-rg> \
    --route-table-name ${CLUSTER_NAME}-rt \
    --name ToARM \
    --address-prefix management.azure.com/32 \
    --next-hop-type Internet
  
  # If using Azure Firewall for egress
  az network route-table route create \
    --resource-group <vnet-rg> \
    --route-table-name ${CLUSTER_NAME}-rt \
    --name ToInternet \
    --address-prefix 0.0.0.0/0 \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address <firewall-private-ip>
  
  # Associate route table with worker subnet
  az network vnet subnet update \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <worker-subnet-name> \
    --route-table ${CLUSTER_NAME}-rt
  ```

- [ ] **Create Cluster with UDR Outbound Type**
  ```bash
  az aro create \
    --resource-group ${RESOURCE_GROUP} \
    --name ${CLUSTER_NAME} \
    --vnet <vnet-name> \
    --master-subnet <master-subnet-name> \
    --worker-subnet <worker-subnet-name> \
    --apiserver-visibility Private \
    --ingress-visibility Private \
    --outbound-type UserDefinedRouting \
    --enable-managed-identity \
    --assign-cluster-identity <cluster-identity> \
    --assign-platform-workload-identity file-csi-driver <file-csi-identity> \
    # ... (other platform workload identities)
  ```

- [ ] **Configure Egress IPs (Optional)**
  
  For private clusters with UDR, you can configure egress IPs per namespace:
  
  ```bash
  # Configure egress IP for a namespace
  cat <<EOF | oc apply -f -
  apiVersion: k8s.ovn.org/v1
  kind: EgressIP
  metadata:
    name: production-egress
  spec:
    egressIPs:
    - <ip-from-worker-subnet>
    namespaceSelector:
      matchLabels:
        env: production
  EOF
  ```

**References:**
- Official Guide: https://learn.microsoft.com/en-us/azure/openshift/howto-create-private-cluster-4x
- OpenShift Egress IPs: https://docs.openshift.com/container-platform/4.13/networking/ovn_kubernetes_network_provider/configuring-egress-ips-ovn.html

---

### Optional: Encryption with Customer-Managed Keys

Encrypt ARO cluster disks (OS and data) with your own encryption keys stored in Azure Key Vault. This provides full control over encryption keys but adds operational responsibility.

⚠️ **CRITICAL WARNINGS:**
- **Cannot be enabled on existing clusters** - Only during cluster creation
- **Only master nodes** for new clusters; workers can be added later via MachineSets
- **Customer is fully responsible** for key maintenance
- **Key loss = permanent cluster failure** - ARO SREs cannot recover
- **Key deletion/disabling = immediate cluster outage**

#### Prerequisites

- [ ] **Enable EncryptionAtHost Feature**
  ```bash
  # Register feature on subscription
  az feature register --namespace Microsoft.Compute --name EncryptionAtHost
  
  # Wait for registration
  az feature show --namespace Microsoft.Compute --name EncryptionAtHost
  # Wait until: "state": "Registered"
  
  # Re-register provider
  az provider register -n Microsoft.Compute
  ```

#### Implementation

- [ ] **Step 1: Create Azure Key Vault with Purge Protection**
  ```bash
  # Set variables
  export KEYVAULT_NAME="${CLUSTER_NAME}-kv-$(openssl rand -hex 2)"
  export KEYVAULT_KEY_NAME="${CLUSTER_NAME}-key"
  export DISK_ENCRYPTION_SET_NAME="${CLUSTER_NAME}-des"
  
  # Create Key Vault with purge protection (REQUIRED)
  az keyvault create \
    --name ${KEYVAULT_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --location ${LOCATION} \
    --enable-purge-protection true
  
  # Create encryption key
  az keyvault key create \
    --vault-name ${KEYVAULT_NAME} \
    --name ${KEYVAULT_KEY_NAME} \
    --protection software
  
  # Get Key Vault resource IDs
  KEYVAULT_ID=$(az keyvault show --name ${KEYVAULT_NAME} --query "id" -o tsv)
  KEYVAULT_KEY_URL=$(az keyvault key show \
    --vault-name ${KEYVAULT_NAME} \
    --name ${KEYVAULT_KEY_NAME} \
    --query "key.kid" -o tsv)
  ```

- [ ] **Step 2: Create Disk Encryption Set**
  ```bash
  # Create DES linked to Key Vault
  az disk-encryption-set create \
    --name ${DISK_ENCRYPTION_SET_NAME} \
    --location ${LOCATION} \
    --resource-group ${RESOURCE_GROUP} \
    --source-vault ${KEYVAULT_ID} \
    --key-url ${KEYVAULT_KEY_URL}
  
  # Get DES identity and resource ID
  DES_ID=$(az disk-encryption-set show \
    --name ${DISK_ENCRYPTION_SET_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --query 'id' -o tsv)
  
  DES_IDENTITY=$(az disk-encryption-set show \
    --name ${DISK_ENCRYPTION_SET_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --query "identity.principalId" -o tsv)
  ```

- [ ] **Step 3: Grant DES Access to Key Vault**
  ```bash
  # Grant wrap/unwrap/get permissions to DES identity
  az keyvault set-policy \
    --name ${KEYVAULT_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --object-id ${DES_IDENTITY} \
    --key-permissions wrapkey unwrapkey get
  ```

- [ ] **Step 4: Create Cluster with CMK**
  ```bash
  az aro create \
    --resource-group ${RESOURCE_GROUP} \
    --name ${CLUSTER_NAME} \
    --vnet <vnet-name> \
    --master-subnet <master-subnet> \
    --worker-subnet <worker-subnet> \
    --disk-encryption-set ${DES_ID} \
    --enable-managed-identity \
    # ... (other parameters)
  ```

- [ ] **Step 5: Verify Encryption**
  ```bash
  # Get cluster infrastructure resource group
  CLUSTER_RG=$(az aro show \
    --resource-group ${RESOURCE_GROUP} \
    --name ${CLUSTER_NAME} \
    --query 'clusterProfile.resourceGroupId' -o tsv | cut -d '/' -f 5)
  
  # Verify all disks use the DES
  az disk list \
    --resource-group ${CLUSTER_RG} \
    --query '[].encryption' -o table
  
  # Output should show diskEncryptionSetId pointing to your DES
  ```

- [ ] **Step 6: Enable CMK for Worker Nodes (Post-Deployment)**
  
  To enable CMK on existing or new worker nodes, modify the MachineSet:
  
  ```bash
  # Get existing MachineSet
  oc get machineset -n openshift-machine-api
  
  # Edit MachineSet to add diskEncryptionSet
  oc edit machineset <machineset-name> -n openshift-machine-api
  ```
  
  Add under `spec.template.spec.providerSpec.value`:
  ```yaml
  osDisk:
    diskSizeGB: 128
    managedDisk:
      storageAccountType: Premium_LRS
      diskEncryptionSet:
        id: <DES_ID>
  ```

**Key Maintenance Responsibilities:**
- Monitor key expiration and rotation
- Maintain Key Vault availability
- Test disaster recovery procedures
- Document key recovery procedures
- **Never delete or disable keys while cluster is running**

**References:**
- Official Guide: https://learn.microsoft.com/en-us/azure/openshift/howto-byok
- Disk Encryption Sets: https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption

---

**✅ Day 1 Deployment Complete!**

Your ARO cluster is now deployed and validated. Proceed to [Part 3: Day 2 Operations](#part-3-day-2-operations) to configure and secure your cluster for production use.

---

## Part 3: Day 2 Operations

Day 2 operations cover the configuration, security, and integration tasks performed after initial cluster deployment. Tasks are organized into three tiers based on priority:

- **Tier 1 (Critical)**: Essential for production readiness
- **Tier 2 (Standard)**: Recommended for robust production environments
- **Tier 3 (Optional)**: Enhancements for specific use cases

---

## Tier 1: Critical Operations

These operations are essential for a production-ready ARO cluster.

### Identity & Access Management

#### Azure AD Integration

- [ ] **Configure Azure AD OAuth**
  ```bash
  # Create Azure AD application
  APP_ID=$(az ad app create \
    --display-name "${CLUSTER_NAME}-openshift-auth" \
    --query appId -o tsv)
  
  # Create client secret
  CLIENT_SECRET=$(az ad app credential reset \
    --id ${APP_ID} \
    --query password -o tsv)
  
  # Get tenant ID
  TENANT_ID=$(az account show --query tenantId -o tsv)
  
  # Create OAuth secret in OpenShift
  oc create secret generic azure-ad-client-secret \
    --from-literal=clientSecret=${CLIENT_SECRET} \
    -n openshift-config
  
  # Configure OAuth
  cat <<EOF | oc apply -f -
  apiVersion: config.openshift.io/v1
  kind: OAuth
  metadata:
    name: cluster
  spec:
    identityProviders:
    - name: AzureAD
      type: OpenID
      mappingMethod: claim
      openID:
        clientID: ${APP_ID}
        clientSecret:
          name: azure-ad-client-secret
        issuer: https://login.microsoftonline.com/${TENANT_ID}/v2.0
        claims:
          preferredUsername:
          - preferred_username
          name:
          - name
          email:
          - email
  EOF
  ```

- [ ] **Update Azure AD Application with Redirect URI**
  ```bash
  # Get OAuth callback URL
  OAUTH_CALLBACK=$(oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}')
  
  # Add redirect URI to Azure AD app
  az ad app update \
    --id ${APP_ID} \
    --web-redirect-uris "https://${OAUTH_CALLBACK}/oauth2callback/AzureAD"
  ```

#### RBAC Configuration

- [ ] **Create RBAC Groups**
  ```bash
  # Create groups for different access levels
  oc adm groups new cluster-admins
  oc adm groups new cluster-viewers
  oc adm groups new namespace-developers
  
  # Add users to groups (after Azure AD sync)
  oc adm groups add-users cluster-admins user1@company.com user2@company.com
  oc adm groups add-users cluster-viewers user3@company.com
  ```

- [ ] **Assign Cluster Roles**
  ```bash
  # Cluster admin access
  oc adm policy add-cluster-role-to-group cluster-admin cluster-admins
  
  # Cluster viewer access
  oc adm policy add-cluster-role-to-group view cluster-viewers
  
  # Namespace-specific access (example for development namespace)
  oc adm policy add-role-to-group edit namespace-developers -n development
  ```

- [ ] **Create Custom Roles** (if needed)
  ```yaml
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: custom-deployer
  rules:
  - apiGroups: ["apps", ""]
    resources: ["deployments", "services", "configmaps"]
    verbs: ["get", "list", "create", "update", "patch"]
  ```

---

### Monitoring & Observability

#### Configure Prometheus

- [ ] **Configure Prometheus Retention**
  ```bash
  # Set retention period for Prometheus (default: 15 days)
  cat <<EOF | oc apply -f -
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: cluster-monitoring-config
    namespace: openshift-monitoring
  data:
    config.yaml: |
      enableUserWorkload: true
      prometheusK8s:
        retention: 30d
        volumeClaimTemplate:
          spec:
            storageClassName: managed-premium
            resources:
              requests:
                storage: 100Gi
  EOF
  ```

#### Azure Monitor Integration

- [ ] **Enable Azure Monitor Container Insights**
  ```bash
  # Create Log Analytics workspace
  az monitor log-analytics workspace create \
    --resource-group <rg> \
    --workspace-name <workspace-name> \
    --location <location>
  
  # Get workspace ID and key
  WORKSPACE_ID=$(az monitor log-analytics workspace show -g <rg> -n <workspace-name> --query customerId -o tsv)
  WORKSPACE_KEY=$(az monitor log-analytics workspace get-shared-keys -g <rg> -n <workspace-name> --query primarySharedKey -o tsv)
  
  # Enable Container Insights on ARO
  az aro update \
    --name ${CLUSTER_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --enable-log-analytics-workspace \
    --log-analytics-workspace-id ${WORKSPACE_ID}
  ```

#### Alert Configuration

- [ ] **Create Critical Alerts**
  ```yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: critical-alerts
    namespace: openshift-monitoring
  spec:
    groups:
    - name: cluster-health
      interval: 30s
      rules:
      - alert: NodeDown
        expr: up{job="node-exporter"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Node {{ $labels.instance }} is down"
      
      - alert: HighMemoryUsage
        expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.1
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Node {{ $labels.instance }} has high memory usage"
  ```

---

### Backup & Disaster Recovery

#### OADP Configuration

- [ ] **Install OADP Operator**
  ```bash
  # Create namespace
  oc create namespace openshift-adp
  
  # Create OperatorGroup
  cat <<EOF | oc apply -f -
  apiVersion: operators.coreos.com/v1
  kind: OperatorGroup
  metadata:
    name: openshift-adp
    namespace: openshift-adp
  spec:
    targetNamespaces:
    - openshift-adp
  EOF
  
  # Create Subscription
  cat <<EOF | oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
    name: redhat-oadp-operator
    namespace: openshift-adp
  spec:
    channel: stable-1.3
    name: redhat-oadp-operator
    source: redhat-operators
    sourceNamespace: openshift-marketplace
  EOF
  ```

- [ ] **Configure Azure Blob Storage for Backups**
  ```bash
  # Create storage account
  az storage account create \
    --name <storage-account-name> \
    --resource-group <rg> \
    --location <location> \
    --sku Standard_GRS
  
  # Create blob container
  az storage container create \
    --name aro-backups \
    --account-name <storage-account-name>
  
  # Get storage account key
  STORAGE_KEY=$(az storage account keys list \
    --resource-group <rg> \
    --account-name <storage-account-name> \
    --query '[0].value' -o tsv)
  
  # Create cloud credentials secret
  cat <<EOF | oc apply -f -
  apiVersion: v1
  kind: Secret
  metadata:
    name: cloud-credentials
    namespace: openshift-adp
  type: Opaque
  stringData:
    cloud: |
      [default]
      AZURE_STORAGE_ACCOUNT_ACCESS_KEY=${STORAGE_KEY}
      AZURE_CLOUD_NAME=AzurePublicCloud
  EOF
  ```

- [ ] **Create DataProtectionApplication**
  ```yaml
  apiVersion: oadp.openshift.io/v1alpha1
  kind: DataProtectionApplication
  metadata:
    name: velero
    namespace: openshift-adp
  spec:
    backupLocations:
    - velero:
        config:
          resourceGroup: <rg>
          storageAccount: <storage-account-name>
          subscriptionId: <subscription-id>
        credential:
          key: cloud
          name: cloud-credentials
        default: true
        objectStorage:
          bucket: aro-backups
          prefix: velero
        provider: azure
    configuration:
      velero:
        defaultPlugins:
        - azure
        - openshift
      restic:
        enable: true
    snapshotLocations:
    - velero:
        config:
          resourceGroup: <rg>
          subscriptionId: <subscription-id>
        provider: azure
  ```

#### Backup Schedules

- [ ] **Create etcd Backup Schedule**
  ```yaml
  apiVersion: velero.io/v1
  kind: Schedule
  metadata:
    name: etcd-backup
    namespace: openshift-adp
  spec:
    schedule: "0 2 * * *"  # Daily at 2 AM
    template:
      includedNamespaces:
      - openshift-etcd
      includedResources:
      - secrets
      - configmaps
      storageLocation: velero-1
      ttl: 720h0m0s  # 30 days
  ```

- [ ] **Create Application Backup Schedule**
  ```yaml
  apiVersion: velero.io/v1
  kind: Schedule
  metadata:
    name: app-backup
    namespace: openshift-adp
  spec:
    schedule: "0 */6 * * *"  # Every 6 hours
    template:
      defaultVolumesToRestic: true
      includedNamespaces:
      - production
      - staging
      storageLocation: velero-1
      ttl: 168h0m0s  # 7 days
  ```

---

### Security Hardening

#### Security Context Constraints

- [ ] **Review Default SCCs**
  ```bash
  # List all SCCs
  oc get scc
  
  # Review privileged SCC usage
  oc describe scc privileged
  ```

- [ ] **Create Custom SCC** (if needed)
  ```yaml
  apiVersion: security.openshift.io/v1
  kind: SecurityContextConstraints
  metadata:
    name: custom-restricted
  allowHostDirVolumePlugin: false
  allowHostIPC: false
  allowHostNetwork: false
  allowHostPID: false
  allowHostPorts: false
  allowPrivilegeEscalation: false
  allowPrivilegedContainer: false
  allowedCapabilities: []
  defaultAddCapabilities: []
  fsGroup:
    type: MustRunAs
  priority: null
  readOnlyRootFilesystem: false
  requiredDropCapabilities:
  - KILL
  - MKNOD
  - SETUID
  - SETGID
  runAsUser:
    type: MustRunAsRange
  seLinuxContext:
    type: MustRunAs
  supplementalGroups:
    type: RunAsAny
  volumes:
  - configMap
  - downwardAPI
  - emptyDir
  - persistentVolumeClaim
  - projected
  - secret
  ```

#### Network Policies

- [ ] **Enable Network Policies for Namespaces**
  ```yaml
  # Default deny all ingress
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: deny-all-ingress
    namespace: production
  spec:
    podSelector: {}
    policyTypes:
    - Ingress
  
  ---
  # Allow ingress from specific namespaces
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: allow-from-openshift-ingress
    namespace: production
  spec:
    podSelector: {}
    policyTypes:
    - Ingress
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            network.openshift.io/policy-group: ingress
  ```

#### Secrets Management

- [ ] **Configure External Secrets Operator** (if using Azure Key Vault)
  ```bash
  # Install External Secrets Operator
  # This allows syncing secrets from Azure Key Vault to OpenShift
  
  # Create SecretStore pointing to Azure Key Vault
  cat <<EOF | oc apply -f -
  apiVersion: external-secrets.io/v1beta1
  kind: SecretStore
  metadata:
    name: azure-keyvault
    namespace: production
  spec:
    provider:
      azurekv:
        authType: ManagedIdentity
        vaultUrl: https://<keyvault-name>.vault.azure.net
  EOF
  
  # Create ExternalSecret to sync specific secret
  cat <<EOF | oc apply -f -
  apiVersion: external-secrets.io/v1beta1
  kind: ExternalSecret
  metadata:
    name: db-credentials
    namespace: production
  spec:
    refreshInterval: 1h
    secretStoreRef:
      name: azure-keyvault
      kind: SecretStore
    target:
      name: db-credentials
      creationPolicy: Owner
    data:
    - secretKey: password
      remoteRef:
        key: database-password
  EOF
  ```

---

## Tier 2: Standard Operations

These operations are recommended for robust production environments.

### Egress Restrictions and Firewall Configuration

Control and monitor outbound traffic from your ARO cluster using Azure Firewall, NVA, or User-Defined Routes.

#### Egress Lockdown Feature

With the **Egress Lockdown** feature (enabled by default on newer clusters), ARO clusters proxy all required Azure/Red Hat connections through the ARO service. This eliminates the need for direct internet access for core cluster operations.

**Endpoints Automatically Proxied** (no firewall rules needed):
| Endpoint | Purpose |
|----------|---------|
| `arosvc.azurecr.io` | ARO system container images |
| `arosvc.<region>.data.azurecr.io` | Regional system container images |
| `management.azure.com` | Azure Resource Manager APIs |
| `login.microsoftonline.com` | Azure AD authentication |
| `*.monitor.core.windows.net` | Geneva monitoring (Microsoft) |
| `*.monitoring.core.windows.net` | Geneva monitoring (Microsoft) |
| `*.blob.core.windows.net` | Geneva monitoring storage |
| `*.servicebus.windows.net` | Geneva monitoring service bus |
| `*.table.core.windows.net` | Geneva monitoring tables |

#### Optional Endpoints for Additional Features

If you want additional features (OperatorHub, Red Hat Telemetry, cluster updates), allow these endpoints in your firewall:

- [ ] **Red Hat Container Registries (for OperatorHub)**
  ```
  # Required for Red Hat and certified operators
  registry.redhat.io:443
  quay.io:443
  cdn.quay.io:443
  cdn01.quay.io:443
  cdn02.quay.io:443
  cdn03.quay.io:443
  cdn04.quay.io:443
  cdn05.quay.io:443
  cdn06.quay.io:443
  access.redhat.com:443
  registry.access.redhat.com:443
  registry.connect.redhat.com:443
  ```

- [ ] **Red Hat Telemetry (opt-in only)**
  ```
  cert-api.access.redhat.com:443
  api.access.redhat.com:443
  infogw.api.openshift.com:443
  console.redhat.com:443
  ```
  
  **Note:** Clusters are opted-out by default. To opt-in, update your pull secret.

- [ ] **OpenShift Updates**
  ```
  api.openshift.com:443           # Check for available updates
  mirror.openshift.com:443        # Download update content
  ```

- [ ] **Third-Party Container Registries**
  ```
  docker.io:443                   # Docker Hub
  gcr.io:443                      # Google Container Registry
  ghcr.io:443                     # GitHub Container Registry
  ```

#### Azure Firewall Configuration Example

- [ ] **Create Azure Firewall**
  ```bash
  # Create firewall subnet
  az network vnet subnet create \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name AzureFirewallSubnet \
    --address-prefixes <fw-subnet-cidr>  # Must be named AzureFirewallSubnet
  
  # Create public IP for firewall
  az network public-ip create \
    --name <fw-pip-name> \
    --resource-group <vnet-rg> \
    --location <location> \
    --sku Standard \
    --allocation-method Static
  
  # Create firewall
  az network firewall create \
    --name <fw-name> \
    --resource-group <vnet-rg> \
    --location <location>
  
  # Create firewall IP configuration
  az network firewall ip-config create \
    --firewall-name <fw-name> \
    --name FW-config \
    --public-ip-address <fw-pip-name> \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name>
  
  # Get firewall private IP
  FWPRIVATE_IP=$(az network firewall show \
    --resource-group <vnet-rg> \
    --name <fw-name> \
    --query "ipConfigurations[0].privateIPAddress" -o tsv)
  ```

- [ ] **Create Firewall Application Rules**
  ```bash
  # Create application rule collection for required endpoints
  az network firewall application-rule create \
    --collection-name ARO-Required \
    --firewall-name <fw-name> \
    --name Allow-RedHat-Registries \
    --protocols https=443 \
    --resource-group <vnet-rg> \
    --target-fqdns \
      registry.redhat.io \
      "*.quay.io" \
      quay.io \
      cdn.quay.io \
      cdn0?.quay.io \
      access.redhat.com \
      registry.access.redhat.com \
      registry.connect.redhat.com \
    --source-addresses <worker-subnet-cidr> \
    --priority 100 \
    --action Allow
  
  # Add rule for OpenShift updates
  az network firewall application-rule create \
    --collection-name ARO-Required \
    --firewall-name <fw-name> \
    --name Allow-OpenShift-Updates \
    --protocols https=443 \
    --resource-group <vnet-rg> \
    --target-fqdns \
      api.openshift.com \
      mirror.openshift.com \
    --source-addresses <worker-subnet-cidr> \
    --priority 100 \
    --action Allow
  ```

- [ ] **Create Route Table to Force Traffic Through Firewall**
  ```bash
  # Create route table
  az network route-table create \
    --name <rt-name> \
    --resource-group <vnet-rg> \
    --location <location>
  
  # Create route to firewall
  az network route-table route create \
    --resource-group <vnet-rg> \
    --name RouteToAzureFirewall \
    --route-table-name <rt-name> \
    --address-prefix 0.0.0.0/0 \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address ${FWPRIVATE_IP}
  
  # Associate with worker subnet
  az network vnet subnet update \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <worker-subnet> \
    --route-table <rt-name>
  ```

**References:**
- Egress Lockdown: https://learn.microsoft.com/en-us/azure/openshift/concepts-egress-lockdown
- Restrict Egress: https://learn.microsoft.com/en-us/azure/openshift/howto-restrict-egress
- Azure Firewall: https://learn.microsoft.com/en-us/azure/firewall/

---

### DNS Forwarding Configuration

Configure custom DNS forwarding to allow pods to resolve names from private DNS servers or custom domains. This is useful for hybrid scenarios with on-premises DNS or private DNS zones.

#### Use Cases

- Resolve on-premises DNS names from pods
- Use custom/private DNS servers
- Integrate with Azure Private DNS Zones
- Resolve names from peered VNets with custom DNS

#### Configure DNS Forwarding

ARO uses CoreDNS for cluster DNS resolution. You can configure forwarding by modifying the DNS operator.

- [ ] **Configure DNS Forwarding for Specific Domains**
  ```bash
  # Edit DNS operator configuration
  oc edit dns.operator/default
  ```
  
  Replace `spec: {}` with forwarding configuration:
  ```yaml
  spec:
    servers:
    - name: example-dns
      zones:
      - example.com          # Domain to forward
      - mycompany.local      # Can specify multiple domains
      forwardPlugin:
        policy: Random       # Or: RoundRobin, Sequential
        upstreams:
        - 192.168.100.10     # Your DNS server IP
        - 192.168.100.11     # Backup DNS server (optional)
    - name: azure-private-dns
      zones:
      - privatelink.database.windows.net
      - privatelink.blob.core.windows.net
      forwardPlugin:
        upstreams:
        - 168.63.129.16      # Azure internal DNS resolver
  ```

- [ ] **Configure Global DNS Forwarding**
  
  Forward all DNS queries not matching cluster domains to custom servers:
  ```yaml
  spec:
    servers:
    - name: default-forward
      zones:
      - .                    # Match all domains
      forwardPlugin:
        upstreams:
        - 8.8.8.8            # Google DNS
        - 1.1.1.1            # Cloudflare DNS
  ```

- [ ] **Verify DNS Forwarding**
  ```bash
  # Test DNS resolution from a pod
  oc run -it --rm debug --image=busybox --restart=Never -- nslookup example.com
  
  # Should resolve using your custom DNS server
  ```

#### Advanced DNS Configuration

- [ ] **Configure DNS Cache**
  ```yaml
  spec:
    cache:
      successTTL: 1h       # Cache successful responses for 1 hour
      denialTTL: 30s       # Cache negative responses for 30 seconds
  ```

- [ ] **Configure DNS Logging (for troubleshooting)**
  ```bash
  # Edit DNS operator to enable query logging
  oc edit dns.operator/default
  ```
  
  Add logging configuration:
  ```yaml
  spec:
    logLevel: Debug
  ```
  
  View CoreDNS logs:
  ```bash
  oc logs -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default --tail=100
  ```

#### Common DNS Forwarding Patterns

**Pattern 1: Split-Horizon DNS**
```yaml
spec:
  servers:
  - name: internal-domains
    zones:
    - internal.company.com
    forwardPlugin:
      upstreams:
      - 10.0.0.4           # Internal DNS server
  - name: external-domains
    zones:
    - .                    # Everything else
    forwardPlugin:
      upstreams:
      - 8.8.8.8            # Public DNS
```

**Pattern 2: Azure Private Link DNS**
```yaml
spec:
  servers:
  - name: azure-private-endpoints
    zones:
    - privatelink.azurecr.io
    - privatelink.vaultcore.azure.net
    - privatelink.database.windows.net
    - privatelink.blob.core.windows.net
    - privatelink.file.core.windows.net
    forwardPlugin:
      upstreams:
      - 168.63.129.16      # Azure DNS (for private endpoints)
```

**Pattern 3: On-Premises Integration**
```yaml
spec:
  servers:
  - name: on-prem-dns
    zones:
    - corp.local
    - prod.internal
    forwardPlugin:
      policy: Sequential   # Try servers in order
      upstreams:
      - 10.10.0.10         # Primary on-prem DNS
      - 10.10.0.11         # Secondary on-prem DNS
```

#### Troubleshooting DNS

```bash
# Check DNS operator status
oc get dns.operator/default

# View CoreDNS pods
oc get pods -n openshift-dns

# Check CoreDNS configuration
oc get configmap dns-default -n openshift-dns -o yaml

# Test DNS from within cluster
oc run -it --rm debug --image=nicolaka/netshoot --restart=Never -- bash
# Inside pod:
nslookup example.com
dig example.com
ping -c 3 example.com

# Check if DNS queries are timing out
oc logs -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default | grep -i timeout
```

**Common Issues:**
- **Issue**: DNS queries timeout
  - **Solution**: Check firewall rules allow UDP/53 to upstream DNS servers
- **Issue**: Pods can't resolve custom domains
  - **Solution**: Verify zones are correctly specified in DNS operator config
- **Issue**: DNS resolution slow
  - **Solution**: Enable DNS caching or add more upstream servers

**References:**
- DNS Forwarding Guide: https://learn.microsoft.com/en-us/azure/openshift/dns-forwarding
- OpenShift DNS Operator: https://docs.openshift.com/container-platform/latest/networking/dns-operator.html
- CoreDNS Documentation: https://coredns.io/manual/toc/

---

### Cluster Maintenance and Upgrades

Keep your ARO cluster up-to-date with the latest OpenShift features, security patches, and bug fixes.

#### Understanding ARO Version Support

- **Support Policy**: ARO supports current (n) and previous (n-1) OpenShift minor versions
- **Version Lifecycle**: Versions typically supported for 12-18 months after release
- **Monthly Updates**: Security and bug fix updates released monthly (z-stream)
- **EUS Channels**: Extended Update Support available for select versions (4.16, 4.18, 4.20, etc.)

**Check ARO Lifecycle:** https://access.redhat.com/support/policy/updates/openshift

- [ ] **Check Available Versions for Your Region**
  ```bash
  # List available ARO versions
  az aro get-versions --location <location>
  ```

#### Pre-Upgrade Checklist

- [ ] **Verify Cluster Health**
  ```bash
  # Check cluster operators - all should be Available=True, Degraded=False
  oc get clusteroperators
  
  # Check node status
  oc get nodes
  
  # Check for failing pods
  oc get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded
  
  # Review cluster version status
  oc get clusterversion
  ```

- [ ] **Verify Service Principal/Managed Identity Credentials**
  
  For Service Principal (legacy):
  ```bash
  # Check SP credential expiration
  az ad sp credential list --id <sp-app-id>
  
  # Rotate if needed
  # See: https://learn.microsoft.com/en-us/azure/openshift/howto-service-principal-credential-rotation
  ```
  
  For Managed Identity:
  ```bash
  # Verify identities exist and have correct roles
  az identity list --resource-group <rg> -o table
  
  # Verify role assignments (select one identity to check)
  IDENTITY_PRINCIPAL=$(az identity show \
    --resource-group <rg> \
    --name <identity-name> \
    --query principalId -o tsv)
  
  az role assignment list --assignee ${IDENTITY_PRINCIPAL}
  ```

- [ ] **Backup Critical Data**
  ```bash
  # Backup etcd (if OADP not configured)
  # Backup application PVs
  # Export important configurations
  oc get <resource> -o yaml > backup.yaml
  ```

- [ ] **Review Release Notes**
  - Check OpenShift release notes for breaking changes
  - Review deprecated API versions
  - Identify features requiring post-upgrade configuration

#### Option 1: Upgrade via OpenShift Web Console

- [ ] **Set Update Channel**
  1. Login to OpenShift web console as cluster-admin
  2. Navigate to **Administration** → **Cluster Settings**
  3. Click **Channel** and select desired channel:
     - `stable-4.19` - Stable releases for 4.19
     - `eus-4.18` - Extended Update Support for 4.18
     - `fast-4.19` - Fast channel (not recommended for production)
  4. Click **Save**

- [ ] **Initiate Upgrade**
  1. In **Cluster Settings**, review available updates
  2. Select target version
  3. Click **Update**
  4. Monitor progress in console

#### Option 2: Upgrade via CLI

- [ ] **Initiate Upgrade**
  ```bash
  # Set desired channel
  oc adm upgrade channel stable-4.19
  
  # Check available updates
  oc adm upgrade
  
  # Upgrade to specific version
  oc adm upgrade --to=4.19.15
  
  # Or upgrade to latest in channel
  oc adm upgrade --to-latest=true
  ```

- [ ] **Monitor Upgrade Progress**
  ```bash
  # Watch cluster version
  oc get clusterversion --watch
  
  # Check operator progress
  oc get clusteroperators
  
  # View detailed status
  oc describe clusterversion
  ```

#### Option 3: Scheduled Upgrade via Managed Upgrade Operator (MUO)

Schedule upgrades during maintenance windows using the managed-upgrade-operator.

- [ ] **Create UpgradeConfig**
  ```yaml
  apiVersion: upgrade.managed.openshift.io/v1alpha1
  kind: UpgradeConfig
  metadata:
    name: managed-upgrade-config
    namespace: openshift-managed-upgrade-operator
  spec:
    type: "ARO"
    upgradeAt: "2026-04-15T02:00:00Z"  # UTC time for upgrade
    PDBForceDrainTimeout: 60
    desired:
      channel: "stable-4.19"
      version: "4.19.15"
  ```
  
  Apply the configuration:
  ```bash
  oc create -f upgrade-config.yaml
  
  # Monitor upgrade status
  oc get upgradeconfig -n openshift-managed-upgrade-operator --watch
  ```

#### EUS-to-EUS Upgrades

For Extended Update Support (EUS) version upgrades (e.g., 4.16 → 4.18):

⚠️ **IMPORTANT:** Must upgrade through intermediate versions. Control Plane Only updates are NOT supported.

- [ ] **EUS Upgrade Path Example: 4.16 → 4.18**
  ```bash
  # Step 1: Update channel to 4.17
  oc adm upgrade channel stable-4.17
  
  # Step 2: Upgrade to 4.17 (latest)
  oc adm upgrade --to-latest=true
  # Wait for upgrade to complete
  
  # Step 3: Change channel to EUS-4.18
  oc adm upgrade channel eus-4.18
  
  # Step 4: Upgrade to 4.18
  oc adm upgrade --to-latest=true
  ```

#### Post-Upgrade Validation

- [ ] **Verify Upgrade Success**
  ```bash
  # Confirm new version
  oc get clusterversion
  
  # Check all operators are healthy
  oc get clusteroperators
  
  # Verify nodes updated
  oc get nodes -o wide
  
  # Check for degraded pods
  oc get pods -A --field-selector status.phase!=Running
  
  # Test application functionality
  # Verify monitoring and logging still work
  ```

- [ ] **Update Workload Compatibility**
  ```bash
  # Check for deprecated API versions
  oc get apiservices | grep -i deprecated
  
  # Update any deprecated resources
  # Test application deployments
  ```

#### Upgrade Troubleshooting

**Issue: Upgrade Stuck/Not Progressing**
```bash
# Check cluster operator status
oc get co
oc describe co <degraded-operator>

# Check Machine Config Operator
oc get mcp
oc get nodes -o wide

# Force node drain if stuck
oc adm drain <node-name> --ignore-daemonsets --delete-emptydir-data --force
```

**Issue: Operators Degraded After Upgrade**
```bash
# Check operator logs
oc logs -n openshift-<operator-namespace> <pod-name>

# Restart operator pods
oc delete pod -n openshift-<operator-namespace> <pod-name>
```

**References:**
- Upgrade Guide: https://learn.microsoft.com/en-us/azure/openshift/howto-upgrade
- OpenShift Updates: https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/updating_clusters/
- Upgrade Graph Tool: https://access.redhat.com/labs/ocpupgradegraph/

---

### Cluster Configuration Management

#### Node Pools and MachineSets

- [ ] **Create Infrastructure Nodes MachineSet**
  ```bash
  # Get existing MachineSet as template
  oc get machineset -n openshift-machine-api -o yaml > machinesets-backup.yaml
  
  # Create infrastructure MachineSet
  # Modify the template to create infra nodes
  cat <<EOF | oc apply -f -
  apiVersion: machine.openshift.io/v1beta1
  kind: MachineSet
  metadata:
    name: ${CLUSTER_NAME}-infra-<zone>
    namespace: openshift-machine-api
  spec:
    replicas: 3
    selector:
      matchLabels:
        machine.openshift.io/cluster-api-cluster: ${CLUSTER_NAME}
        machine.openshift.io/cluster-api-machineset: ${CLUSTER_NAME}-infra-<zone>
    template:
      metadata:
        labels:
          machine.openshift.io/cluster-api-cluster: ${CLUSTER_NAME}
          machine.openshift.io/cluster-api-machineset: ${CLUSTER_NAME}-infra-<zone>
          machine.openshift.io/cluster-api-machine-role: infra
          machine.openshift.io/cluster-api-machine-type: infra
      spec:
        metadata:
          labels:
            node-role.kubernetes.io/infra: ""
        taints:
        - key: node-role.kubernetes.io/infra
          effect: NoSchedule
        # ... rest of MachineSet spec
  EOF
  ```

- [ ] **Move Infrastructure Components to Infra Nodes**
  ```bash
  # Move router pods
  oc patch ingresscontroller default -n openshift-ingress-operator \
    --type=merge --patch='{"spec":{"nodePlacement":{"nodeSelector":{"matchLabels":{"node-role.kubernetes.io/infra":""}},"tolerations":[{"key":"node-role.kubernetes.io/infra","effect":"NoSchedule"}]}}}'
  
  # Move registry pods
  oc patch config cluster -n openshift-image-registry \
    --type=merge --patch='{"spec":{"nodeSelector":{"node-role.kubernetes.io/infra":""},"tolerations":[{"key":"node-role.kubernetes.io/infra","effect":"NoSchedule"}]}}'
  
  # Move monitoring pods
  # Edit cluster-monitoring-config ConfigMap
  oc -n openshift-monitoring edit configmap cluster-monitoring-config
  # Add nodeSelector and tolerations for each component
  ```

#### Autoscaling Configuration

- [ ] **Configure Cluster Autoscaler**
  ```yaml
  apiVersion: autoscaling.openshift.io/v1
  kind: ClusterAutoscaler
  metadata:
    name: default
  spec:
    podPriorityThreshold: -10
    resourceLimits:
      maxNodesTotal: 50
      cores:
        min: 16
        max: 200
      memory:
        min: 64
        max: 800
    scaleDown:
      enabled: true
      delayAfterAdd: 10m
      delayAfterDelete: 5m
      delayAfterFailure: 3m
      unneededTime: 10m
  ```

- [ ] **Configure MachineAutoscaler for Each MachineSet**
  ```yaml
  apiVersion: autoscaling.openshift.io/v1beta1
  kind: MachineAutoscaler
  metadata:
    name: worker-autoscaler
    namespace: openshift-machine-api
  spec:
    minReplicas: 3
    maxReplicas: 12
    scaleTargetRef:
      apiVersion: machine.openshift.io/v1beta1
      kind: MachineSet
      name: ${CLUSTER_NAME}-worker-<zone>
  ```

---

### Advanced Storage

#### Azure Files CSI Driver

- [ ] **Create Custom Azure Files StorageClass**
  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: azurefile-premium-retain
  provisioner: file.csi.azure.com
  parameters:
    skuName: Premium_LRS
    resourceGroup: <rg>
  reclaimPolicy: Retain
  volumeBindingMode: Immediate
  allowVolumeExpansion: true
  ```

#### Azure Blob CSI Driver

- [ ] **Install Azure Blob CSI Driver**
  ```bash
  # Install from OperatorHub
  # Or manually deploy from https://github.com/kubernetes-sigs/blob-csi-driver
  
  # Create StorageClass for Blob
  cat <<EOF | oc apply -f -
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: azureblob-fuse-premium
  provisioner: blob.csi.azure.com
  parameters:
    skuName: Premium_LRS
    containerNamePrefix: blob-
    protocol: fuse
  reclaimPolicy: Delete
  volumeBindingMode: Immediate
  allowVolumeExpansion: true
  EOF
  ```

---

### Azure Service Integration

#### Workload Identity for Applications (Recommended for Azure Resource Access)

**Workload Identity** allows your applications running on ARO to securely access Azure resources (Key Vault, Storage, SQL, etc.) without storing credentials in secrets. It uses OIDC federation with managed identities.

**How It Works:**
1. Create a user-assigned managed identity for your application
2. Grant that identity permissions on Azure resources
3. Create a Kubernetes ServiceAccount with identity annotation
4. Create a federated identity credential linking the ServiceAccount to the managed identity
5. Deploy your application with the ServiceAccount - it automatically gets Azure credentials

**Prerequisites:**
- ARO cluster created with managed identity (has OIDC issuer)
- `pod-identity-webhook` running in `openshift-cloud-credential-operator` namespace (automatic on managed identity clusters)

**Example: Application Accessing Azure Key Vault**

- [ ] **Step 1: Get OIDC Issuer URL**
  ```bash
  # Get OIDC issuer from cluster
  export ARO_OIDC_ISSUER="$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')"
  
  # Verify format: https://{region}.oic.aro.azure.net/{tenant_id}/{uuid}
  echo $ARO_OIDC_ISSUER
  ```

- [ ] **Step 2: Create Azure Resources (Example: Key Vault)**
  ```bash
  # Set variables
  export KEYVAULT_NAME="myapp-kv-$(openssl rand -hex 2)"
  export KEYVAULT_RG=<resource-group>
  export KEYVAULT_LOCATION=<location>
  export USER_ASSIGNED_IDENTITY_NAME="myapp-identity"
  export SERVICE_ACCOUNT_NAMESPACE="myapp"
  export SERVICE_ACCOUNT_NAME="myapp-sa"
  export FEDERATED_IDENTITY_NAME="myapp-federated-identity"
  
  # Create Key Vault
  az keyvault create \
    --resource-group ${KEYVAULT_RG} \
    --location ${KEYVAULT_LOCATION} \
    --name ${KEYVAULT_NAME}
  
  # Add a secret
  az keyvault secret set \
    --vault-name ${KEYVAULT_NAME} \
    --name "my-secret" \
    --value "Hello from Azure!"
  
  # Get Key Vault resource ID
  export KEYVAULT_RESOURCE_ID=$(az keyvault show \
    --resource-group ${KEYVAULT_RG} \
    --name ${KEYVAULT_NAME} \
    --query id -o tsv)
  ```

- [ ] **Step 3: Create User-Assigned Managed Identity**
  ```bash
  # Create the identity for your application
  az identity create \
    --name ${USER_ASSIGNED_IDENTITY_NAME} \
    --resource-group ${KEYVAULT_RG}
  
  # Get identity client ID and principal ID
  export USER_ASSIGNED_IDENTITY_CLIENT_ID=$(az identity show \
    --name ${USER_ASSIGNED_IDENTITY_NAME} \
    --resource-group ${KEYVAULT_RG} \
    --query 'clientId' -o tsv)
  
  export USER_ASSIGNED_IDENTITY_OBJECT_ID=$(az identity show \
    --name ${USER_ASSIGNED_IDENTITY_NAME} \
    --resource-group ${KEYVAULT_RG} \
    --query 'principalId' -o tsv)
  ```

- [ ] **Step 4: Grant Identity Permissions on Azure Resource**
  ```bash
  # Assign "Key Vault Secrets User" role to the identity
  az role assignment create \
    --assignee-object-id "${USER_ASSIGNED_IDENTITY_OBJECT_ID}" \
    --role "Key Vault Secrets User" \
    --scope "${KEYVAULT_RESOURCE_ID}" \
    --assignee-principal-type ServicePrincipal
  ```

- [ ] **Step 5: Create Kubernetes ServiceAccount**
  ```bash
  # Create namespace
  oc new-project ${SERVICE_ACCOUNT_NAMESPACE}
  
  # Create ServiceAccount with identity annotation
  cat <<EOF | oc apply -f -
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: ${SERVICE_ACCOUNT_NAME}
    namespace: ${SERVICE_ACCOUNT_NAMESPACE}
    annotations:
      azure.workload.identity/client-id: ${USER_ASSIGNED_IDENTITY_CLIENT_ID}
  EOF
  ```

- [ ] **Step 6: Create Federated Identity Credential**
  ```bash
  # Link the ServiceAccount to the managed identity via OIDC federation
  az identity federated-credential create \
    --name "${FEDERATED_IDENTITY_NAME}" \
    --identity-name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --resource-group "${KEYVAULT_RG}" \
    --issuer "${ARO_OIDC_ISSUER}" \
    --subject "system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
  ```

- [ ] **Step 7: Deploy Application with Workload Identity**
  ```yaml
  cat <<EOF | oc apply -f -
  apiVersion: v1
  kind: Pod
  metadata:
    name: myapp
    namespace: ${SERVICE_ACCOUNT_NAMESPACE}
    labels:
      azure.workload.identity/use: "true"  # REQUIRED label
  spec:
    serviceAccountName: ${SERVICE_ACCOUNT_NAME}  # REQUIRED
    securityContext:
      runAsNonRoot: true
      seccompProfile:
        type: RuntimeDefault
    containers:
    - name: app
      image: ghcr.io/azure/azure-workload-identity/msal-go
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      env:
      - name: KEYVAULT_URL
        value: https://${KEYVAULT_NAME}.vault.azure.net/
      - name: SECRET_NAME
        value: my-secret
      # These are automatically injected by pod-identity-webhook:
      # AZURE_CLIENT_ID
      # AZURE_TENANT_ID
      # AZURE_FEDERATED_TOKEN_FILE: /var/run/secrets/azure/tokens/azure-identity-token
      # AZURE_AUTHORITY_HOST
  EOF
  ```

- [ ] **Step 8: Verify Workload Identity**
  ```bash
  # Check pod has environment variables injected
  oc describe pod myapp -n ${SERVICE_ACCOUNT_NAMESPACE}
  # Look for AZURE_CLIENT_ID, AZURE_FEDERATED_TOKEN_FILE, etc.
  
  # Check pod can access Azure Key Vault
  oc logs myapp -n ${SERVICE_ACCOUNT_NAMESPACE}
  # Should show: successfully got secret "Hello from Azure!"
  
  # Verify projected token volume
  oc get pod myapp -n ${SERVICE_ACCOUNT_NAMESPACE} -o yaml | grep -A 5 "azure-identity-token"
  ```

**What Just Happened:**
1. ✅ Your pod gets a Kubernetes service account token (JWT) signed by ARO's OIDC issuer
2. ✅ The token is projected to `/var/run/secrets/azure/tokens/azure-identity-token`
3. ✅ Azure SDK uses this token to exchange for an Azure AD access token via OIDC federation
4. ✅ The access token has permissions defined by the managed identity's role assignments
5. ✅ **No credentials stored in cluster** - tokens are short-lived and auto-rotated

**Common Use Cases:**
- Access Azure Key Vault secrets from applications
- Read/write to Azure Storage (Blob, Files) without storage account keys
- Connect to Azure SQL Database with managed identity authentication
- Access Azure Service Bus, Event Hubs, Cosmos DB
- Call Azure APIs with proper authentication

**Troubleshooting:**

```bash
# Check if pod-identity-webhook is running
oc get deployment pod-identity-webhook -n openshift-cloud-credential-operator
oc logs -n openshift-cloud-credential-operator deployment/pod-identity-webhook

# Verify ServiceAccount annotation
oc get sa ${SERVICE_ACCOUNT_NAME} -n ${SERVICE_ACCOUNT_NAMESPACE} -o yaml

# Check federated credential
az identity federated-credential show \
  --name "${FEDERATED_IDENTITY_NAME}" \
  --identity-name "${USER_ASSIGNED_IDENTITY_NAME}" \
  --resource-group "${KEYVAULT_RG}"

# Verify role assignment
az role assignment list \
  --assignee ${USER_ASSIGNED_IDENTITY_CLIENT_ID} \
  --all
```

**References:**
- Official Guide: https://learn.microsoft.com/en-us/azure/openshift/howto-deploy-configure-application
- Workload Identity Overview: https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview
- Red Hat Guide: https://cloud.redhat.com/experts/aro/miwi/

---

#### Azure Container Registry Integration

**Option 1: Workload Identity (Recommended for Managed Identity Clusters)**

Use workload identity to authenticate to ACR without storing credentials. See [Workload Identity for Applications](#workload-identity-for-applications-recommended-for-azure-resource-access) section for complete setup.

Example for ACR access:
```bash
# Create managed identity for ACR access
az identity create --name acr-pull-identity --resource-group <rg>

# Grant AcrPull role to identity
az role assignment create \
  --assignee-object-id $(az identity show --name acr-pull-identity --resource-group <rg> --query principalId -o tsv) \
  --role "AcrPull" \
  --scope $(az acr show -n <acr-name> --query id -o tsv) \
  --assignee-principal-type ServicePrincipal

# Create ServiceAccount and federated credential (see Workload Identity section)
# Deploy pods with ServiceAccount to pull from ACR
```

**Option 2: Service Principal Pull Secret (Legacy)**

- [ ] **Configure ACR Pull Secret with Service Principal**
  ```bash
  # Create service principal for ACR
  ACR_NAME=<acr-name>
  ACR_REGISTRY_ID=$(az acr show -n ${ACR_NAME} --query id -o tsv)
  
  SP_PASSWD=$(az ad sp create-for-rbac \
    --name ${ACR_NAME}-aro-pull \
    --scopes ${ACR_REGISTRY_ID} \
    --role acrpull \
    --query password -o tsv)
  
  SP_APP_ID=$(az ad sp list --display-name ${ACR_NAME}-aro-pull --query '[0].appId' -o tsv)
  
  # Create pull secret in OpenShift
  oc create secret docker-registry acr-pull-secret \
    --docker-server=${ACR_NAME}.azurecr.io \
    --docker-username=${SP_APP_ID} \
    --docker-password=${SP_PASSWD} \
    -n openshift-config
  
  # Link secret to global pull secret
  oc set data secret/pull-secret \
    -n openshift-config \
    --from-file=.dockerconfigjson=<(oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq ".auths += {\"${ACR_NAME}.azurecr.io\":{\"auth\":\"$(echo -n ${SP_APP_ID}:${SP_PASSWD} | base64 -w0)\"}}" | base64 -w0)
  ```

**References:**
- ACR with ARO: https://learn.microsoft.com/en-us/azure/openshift/howto-use-acr-with-aro

#### Azure Service Operator (ASO)

- [ ] **Install Azure Service Operator**
  ```bash
  # Install from OperatorHub
  # Search for "Azure Service Operator" in the OpenShift console
  
  # Or install via CLI
  cat <<EOF | oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
    name: azure-service-operator
    namespace: openshift-operators
  spec:
    channel: stable
    name: azure-service-operator
    source: community-operators
    sourceNamespace: openshift-marketplace
  EOF
  ```

- [ ] **Configure ASO Credentials**
  ```bash
  # Create service principal for ASO
  ASO_SP=$(az ad sp create-for-rbac --name aso-${CLUSTER_NAME})
  
  # Create secret with credentials
  cat <<EOF | oc apply -f -
  apiVersion: v1
  kind: Secret
  metadata:
    name: azureoperatorsettings
    namespace: azureoperator-system
  stringData:
    AZURE_SUBSCRIPTION_ID: "${SUBSCRIPTION_ID}"
    AZURE_TENANT_ID: "$(echo ${ASO_SP} | jq -r .tenant)"
    AZURE_CLIENT_ID: "$(echo ${ASO_SP} | jq -r .appId)"
    AZURE_CLIENT_SECRET: "$(echo ${ASO_SP} | jq -r .password)"
  EOF
  ```

---

### Compliance & Auditing

#### Compliance Scanning

- [ ] **Install Compliance Operator**
  ```bash
  # Create namespace
  oc create namespace openshift-compliance
  
  # Install operator
  cat <<EOF | oc apply -f -
  apiVersion: operators.coreos.com/v1alpha1
  kind: Subscription
  metadata:
    name: compliance-operator
    namespace: openshift-compliance
  spec:
    channel: stable
    name: compliance-operator
    source: redhat-operators
    sourceNamespace: openshift-marketplace
  EOF
  ```

- [ ] **Run Compliance Scan**
  ```yaml
  apiVersion: compliance.openshift.io/v1alpha1
  kind: ScanSettingBinding
  metadata:
    name: cis-compliance
    namespace: openshift-compliance
  profiles:
  - name: ocp4-cis-node
    kind: Profile
    apiGroup: compliance.openshift.io/v1alpha1
  - name: ocp4-cis
    kind: Profile
    apiGroup: compliance.openshift.io/v1alpha1
  settingsRef:
    name: default
    kind: ScanSetting
    apiGroup: compliance.openshift.io/v1alpha1
  ```

---

### Cluster Maintenance

#### Upgrade Procedures

- [ ] **Plan Cluster Upgrade**
  ```bash
  # Check available upgrade paths
  oc adm upgrade
  
  # View update graph
  oc get clusterversion version -o json | jq '.status.availableUpdates'
  ```

- [ ] **Perform Cluster Upgrade**
  ```bash
  # Upgrade to specific version
  oc adm upgrade --to=<version>
  
  # Monitor upgrade progress
  oc get clusterversion
  oc get clusteroperators
  
  # Check if any operators are progressing
  watch oc get co
  ```

- [ ] **Pause MachineHealthChecks Before Upgrade**
  ```bash
  # Pause all MachineHealthChecks
  oc annotate mhc --all machine.openshift.io/exclude-node-draining="" -n openshift-machine-api
  
  # Resume after upgrade
  oc annotate mhc --all machine.openshift.io/exclude-node-draining- -n openshift-machine-api
  ```

---

### Cost Optimization

- [ ] **Implement Resource Quotas**
  ```yaml
  apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: compute-quota
    namespace: development
  spec:
    hard:
      requests.cpu: "50"
      requests.memory: 100Gi
      limits.cpu: "100"
      limits.memory: 200Gi
      persistentvolumeclaims: "10"
  ```

- [ ] **Set Up LimitRanges**
  ```yaml
  apiVersion: v1
  kind: LimitRange
  metadata:
    name: resource-limits
    namespace: development
  spec:
    limits:
    - max:
        memory: 2Gi
        cpu: "2"
      min:
        memory: 100Mi
        cpu: 100m
      default:
        memory: 512Mi
        cpu: 500m
      defaultRequest:
        memory: 256Mi
        cpu: 250m
      type: Container
  ```

- [ ] **Monitor Costs with Azure Cost Management**
  ```bash
  # Tag resources for cost tracking
  az aro update \
    --name ${CLUSTER_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --tags "CostCenter=Engineering" "Project=Platform"
  
  # View costs in Azure Portal > Cost Management
  ```

- [ ] **Implement Pod Disruption Budgets**
  ```yaml
  apiVersion: policy/v1
  kind: PodDisruptionBudget
  metadata:
    name: app-pdb
    namespace: production
  spec:
    minAvailable: 2
    selector:
      matchLabels:
        app: myapp
  ```

---

## Tier 3: Optional Enhancements

These enhancements are for specific use cases and advanced requirements.

### AI/ML and Advanced Workloads

For GPU workloads, Red Hat OpenShift AI, and advanced compute scenarios, see specialized guides:
- [GPU Configuration Guide](link)
- [Red Hat OpenShift AI Setup](link)
- [OpenShift Virtualization](link)

### GitOps & CI/CD

For ArgoCD, Tekton, and CI/CD integration, see:
- [GitOps with OpenShift GitOps (ArgoCD)](link)
- [CI/CD with OpenShift Pipelines (Tekton)](link)
- [Azure DevOps Integration](link)

### Multi-Cluster Management

For Advanced Cluster Management, Submariner, and multi-cluster setups, see:
- [Red Hat Advanced Cluster Management Guide](link)
- [Multi-Cluster Networking with Submariner](link)

### Enterprise Applications

For SAP, Maximo, and other enterprise application deployments, see:
- [Enterprise Application Deployment Guides](link)

---

## Part 4: Operational Excellence (Day N)

Ongoing operations to maintain cluster health and performance.

### Daily Operations

- [ ] **Morning Health Check**
  ```bash
  # Check cluster operators
  oc get clusteroperators
  
  # Check node status
  oc get nodes
  
  # Check for degraded resources
  oc get pods --all-namespaces --field-selector status.phase!=Running
  
  # Review recent alerts
  # Check Prometheus Alert Manager or Azure Monitor
  ```

- [ ] **Review Alert Queue**
  - Check Prometheus AlertManager
  - Review Azure Monitor alerts
  - Triage and assign critical alerts
  - Document resolutions

- [ ] **Monitor Resource Utilization**
  ```bash
  # Node resource usage
  oc adm top nodes
  
  # Pod resource usage
  oc adm top pods --all-namespaces
  
  # Check for resource-constrained pods
  oc get events --all-namespaces --field-selector reason=FailedScheduling
  ```

- [ ] **Verify Backup Completion**
  ```bash
  # Check OADP backup status
  oc get backup -n openshift-adp
  
  # Check for failed backups
  oc get backup -n openshift-adp --field-selector status.phase!=Completed
  ```

### Weekly Operations

- [ ] **Security Update Review**
  ```bash
  # Check for available cluster updates
  oc adm upgrade
  
  # Review CVEs and security advisories
  # Check Red Hat security advisories: https://access.redhat.com/security/security-updates/
  ```

- [ ] **Capacity Planning Review**
  ```bash
  # Review node capacity trends
  # Check autoscaler events
  oc get events -n openshift-machine-api | grep -i autoscaler
  
  # Review storage utilization
  oc get pv
  oc get pvc --all-namespaces
  ```

- [ ] **Cost Analysis**
  - Review Azure Cost Management reports
  - Identify cost anomalies
  - Right-size over-provisioned resources
  - Review unused PVs and snapshots

- [ ] **Incident Review Meeting**
  - Review incidents from past week
  - Document root causes
  - Create action items for prevention
  - Update runbooks

### Monthly Operations

- [ ] **Disaster Recovery Test**
  ```bash
  # Test cluster backup restore (in non-prod environment)
  oc create -f test-restore.yaml
  
  # Verify application functionality after restore
  # Document any issues or gaps
  ```

- [ ] **Security Compliance Scan**
  ```bash
  # Run compliance operator scan
  oc annotate scansettingbindings cis-compliance compliance.openshift.io/rescan=""
  
  # Review scan results
  oc get compliancescan -n openshift-compliance
  
  # Remediate findings
  ```

- [ ] **Performance Baseline Review**
  - Review Prometheus metrics trends
  - Update performance baselines
  - Identify degradation patterns
  - Tune resource limits if needed

- [ ] **Documentation Updates**
  - Update operational runbooks
  - Document configuration changes
  - Update network diagrams
  - Review and update disaster recovery procedures

### Quarterly Operations

- [ ] **Major Version Upgrade Planning**
  - Review upcoming OpenShift releases
  - Plan upgrade timeline
  - Test upgrade in non-production environment
  - Schedule maintenance window

- [ ] **Architecture Review**
  - Review cluster architecture
  - Assess scaling requirements
  - Plan for new capabilities
  - Review security posture

- [ ] **Disaster Recovery Drill**
  - Full DR failover test
  - Measure RTO/RPO achievement
  - Document lessons learned
  - Update DR procedures

- [ ] **Training and Knowledge Sharing**
  - Conduct team training on new features
  - Share lessons learned
  - Update team documentation
  - Cross-train team members

### Incident Response

#### Escalation Procedures

**Severity Definitions:**

| Severity | Description | Response Time | Example |
|----------|-------------|---------------|---------|
| **P1 - Critical** | Cluster down, complete service outage | Immediate | API server unreachable |
| **P2 - High** | Major functionality impaired | < 1 hour | Multiple nodes down |
| **P3 - Medium** | Degraded performance, workaround available | < 4 hours | Single node degraded |
| **P4 - Low** | Minor issue, no immediate impact | < 1 business day | Non-critical warning |

**Escalation Path:**
1. On-call engineer (initial response)
2. Team lead (if unresolved in 30 min for P1, 2 hours for P2)
3. Platform architect (if unresolved in 1 hour for P1)
4. Microsoft/Red Hat support (as needed)

#### SLA Targets

| Metric | Target |
|--------|--------|
| Cluster Availability | 99.9% |
| API Server Response Time | < 200ms (p95) |
| Pod Startup Time | < 30s (p95) |
| PV Provisioning Time | < 2 minutes |

#### Change Management Process

- [ ] **Change Request Template**
  1. Change description and justification
  2. Impact assessment
  3. Rollback procedure
  4. Testing plan
  5. Approval from team lead

- [ ] **Change Windows**
  - Standard changes: Tuesday/Thursday 10 AM - 2 PM
  - Emergency changes: As needed with approval
  - Freeze periods: Last week of quarter, major holidays

---

## Appendices

## Appendix A: Network Security Groups Deep Dive

This appendix consolidates all Network Security Group (NSG) content for Azure Red Hat OpenShift deployments.

### Overview

Network Security Groups control network traffic to and from Azure resources in an Azure virtual network. For ARO clusters, NSGs play a critical role in securing communication between cluster components.

#### Decision: ARO-Managed vs BYO NSG

| Factor | ARO-Managed NSG (RECOMMENDED) | Bring Your Own NSG (BYO NSG) |
|--------|-------------------------------|------------------------------|
| **Setup Complexity** | ✅ Minimal - ARO creates automatically | ❌ Complex - manual pre-creation required |
| **Operational Overhead** | ✅ Low - ARO maintains rules | ❌ High - manual rule management |
| **Risk of Misconfiguration** | ✅ Low - ARO controls rules | ⚠️ High - can break cluster if misconfigured |
| **Compliance** | Suitable for most environments | Required if pre-creation mandated by policy |
| **Customization** | Limited (ARO controls priorities 500-3000) | Full control over all rules |
| **Troubleshooting** | ✅ Easier - known good configuration | ❌ Complex - many possible misconfigurations |

**Recommendation:** Use ARO-managed NSG unless organizational compliance requires pre-creation of NSGs.

---

### ARO-Managed NSG (Recommended)

When using ARO-managed NSGs:

- [ ] **Pre-Deployment:**
  - Verify no pre-existing NSGs attached to master or worker subnets
  - Document that NSGs will be created in the cluster infrastructure resource group
  - Plan for limited customization (priorities 3001+ available for custom rules)

- [ ] **During Deployment:**
  - ARO automatically creates NSGs during cluster creation
  - ARO creates required security rules (priorities 500-3000)
  - ARO attaches NSGs to subnets

- [ ] **Post-Deployment:**
  - Verify NSG creation:
    ```bash
    # Get cluster infrastructure resource group
    INFRA_RG=$(az aro show -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --query 'clusterProfile.resourceGroupId' -o tsv | cut -d'/' -f5)
    
    # List NSGs in infrastructure resource group
    az network nsg list -g ${INFRA_RG} -o table
    ```
  
  - View ARO-managed rules:
    ```bash
    # View master NSG rules
    az network nsg rule list \
      --resource-group ${INFRA_RG} \
      --nsg-name <master-nsg-name> \
      -o table
    
    # View worker NSG rules
    az network nsg rule list \
      --resource-group ${INFRA_RG} \
      --nsg-name <worker-nsg-name> \
      -o table
    ```

- [ ] **Adding Custom Rules:**
  
  Use priority range 3001+ for custom application rules:
  ```bash
  # Example: Allow specific application port
  az network nsg rule create \
    --resource-group ${INFRA_RG} \
    --nsg-name <worker-nsg-name> \
    --name AllowApp8080 \
    --priority 3001 \
    --source-address-prefixes 10.0.0.0/16 \
    --destination-port-ranges 8080 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound
  ```

---

### BYO NSG (Bring Your Own NSG)

⚠️ **WARNING:** BYO NSG requires precise configuration. Misconfigured NSGs can prevent cluster deployment or cause operational issues.

#### When to Use BYO NSG

Use BYO NSG only when:
- Organizational security policy requires pre-creation of NSGs
- Compliance mandates prohibit ARO from creating NSGs
- Advanced network segmentation requires custom NSG placement

#### BYO NSG Planning Checklist

- [ ] Understand all required ARO NSG rules
- [ ] Plan priority ranges (ARO uses 500-3000, custom rules use 3001+)
- [ ] Document NSG design and rule purposes
- [ ] Plan for identity permissions on NSGs
- [ ] Set up NSG flow logs for troubleshooting
- [ ] Create testing procedure before production deployment

#### BYO NSG Implementation Guide

##### Step 1: Create NSGs

- [ ] **Create Master Subnet NSG:**
  ```bash
  az network nsg create \
    --resource-group <vnet-rg> \
    --name ${CLUSTER_NAME}-master-nsg \
    --location <location> \
    --tags "Cluster=${CLUSTER_NAME}" "Purpose=ARO-Master"
  ```

- [ ] **Create Worker Subnet NSG:**
  ```bash
  az network nsg create \
    --resource-group <vnet-rg> \
    --name ${CLUSTER_NAME}-worker-nsg \
    --location <location> \
    --tags "Cluster=${CLUSTER_NAME}" "Purpose=ARO-Worker"
  ```

##### Step 2: Configure Master NSG Rules

- [ ] **Allow API Server from Workers (Priority 500):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-master-nsg \
    --name AllowAPIServerFromWorkers \
    --priority 500 \
    --source-address-prefixes <worker-subnet-cidr> \
    --destination-port-ranges 6443 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow API server access from worker nodes"
  ```

- [ ] **Allow Machine Config Server from Workers (Priority 501):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-master-nsg \
    --name AllowMCSFromWorkers \
    --priority 501 \
    --source-address-prefixes <worker-subnet-cidr> \
    --destination-port-ranges 22623 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow Machine Config Server from workers"
  ```

- [ ] **Allow etcd Between Masters (Priority 502):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-master-nsg \
    --name AllowEtcdBetweenMasters \
    --priority 502 \
    --source-address-prefixes <master-subnet-cidr> \
    --destination-port-ranges 2379-2380 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow etcd communication between master nodes"
  ```

- [ ] **Allow Kubernetes API Between Masters (Priority 503):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-master-nsg \
    --name AllowKubeAPIBetweenMasters \
    --priority 503 \
    --source-address-prefixes <master-subnet-cidr> \
    --destination-port-ranges 10250-10259 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow Kubernetes API server communication between masters"
  ```

- [ ] **Allow VXLAN Between Masters (Priority 504):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-master-nsg \
    --name AllowVXLANBetweenMasters \
    --priority 504 \
    --source-address-prefixes <master-subnet-cidr> \
    --destination-port-ranges 4789 \
    --protocol Udp \
    --access Allow \
    --direction Inbound \
    --description "Allow VXLAN overlay network between masters"
  ```

- [ ] **Allow Geneve Between Masters (Priority 505):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-master-nsg \
    --name AllowGeneveBetweenMasters \
    --priority 505 \
    --source-address-prefixes <master-subnet-cidr> \
    --destination-port-ranges 6081 \
    --protocol Udp \
    --access Allow \
    --direction Inbound \
    --description "Allow Geneve overlay network between masters"
  ```

- [ ] **Allow Azure Load Balancer (Priority 506):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-master-nsg \
    --name AllowAzureLoadBalancer \
    --priority 506 \
    --source-address-prefixes AzureLoadBalancer \
    --destination-port-ranges '*' \
    --protocol '*' \
    --access Allow \
    --direction Inbound \
    --description "Allow Azure Load Balancer health probes"
  ```

- [ ] **Allow All Outbound (Priority 100):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-master-nsg \
    --name AllowAllOutbound \
    --priority 100 \
    --destination-address-prefixes '*' \
    --destination-port-ranges '*' \
    --protocol '*' \
    --access Allow \
    --direction Outbound \
    --description "Allow all outbound traffic from master nodes"
  ```

##### Step 3: Configure Worker NSG Rules

- [ ] **Allow HTTPS from Internet (Priority 500) - Public Cluster Only:**
  ```bash
  # Only for public clusters
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowHTTPSFromInternet \
    --priority 500 \
    --source-address-prefixes Internet \
    --destination-port-ranges 443 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow HTTPS ingress from Internet (public cluster)"
  ```

- [ ] **Allow HTTP from Internet (Priority 501) - Public Cluster Only:**
  ```bash
  # Only for public clusters
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowHTTPFromInternet \
    --priority 501 \
    --source-address-prefixes Internet \
    --destination-port-ranges 80 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow HTTP ingress from Internet (public cluster)"
  ```

- [ ] **Allow HTTPS from VNet (Priority 500) - Private Cluster:**
  ```bash
  # For private clusters - restrict to VNet or specific sources
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowHTTPSFromVNet \
    --priority 500 \
    --source-address-prefixes VirtualNetwork \
    --destination-port-ranges 443 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow HTTPS ingress from VNet (private cluster)"
  ```

- [ ] **Allow HTTP from VNet (Priority 501) - Private Cluster:**
  ```bash
  # For private clusters
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowHTTPFromVNet \
    --priority 501 \
    --source-address-prefixes VirtualNetwork \
    --destination-port-ranges 80 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow HTTP ingress from VNet (private cluster)"
  ```

- [ ] **Allow Azure Load Balancer (Priority 502):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowAzureLoadBalancer \
    --priority 502 \
    --source-address-prefixes AzureLoadBalancer \
    --destination-port-ranges '*' \
    --protocol '*' \
    --access Allow \
    --direction Inbound \
    --description "Allow Azure Load Balancer health probes"
  ```

- [ ] **Allow All from Master Subnet (Priority 503):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowFromMasters \
    --priority 503 \
    --source-address-prefixes <master-subnet-cidr> \
    --destination-port-ranges '*' \
    --protocol '*' \
    --access Allow \
    --direction Inbound \
    --description "Allow all traffic from master nodes"
  ```

- [ ] **Allow VXLAN Between Workers (Priority 504):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowVXLANBetweenWorkers \
    --priority 504 \
    --source-address-prefixes <worker-subnet-cidr> \
    --destination-port-ranges 4789 \
    --protocol Udp \
    --access Allow \
    --direction Inbound \
    --description "Allow VXLAN overlay network between workers"
  ```

- [ ] **Allow Geneve Between Workers (Priority 505):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowGeneveBetweenWorkers \
    --priority 505 \
    --source-address-prefixes <worker-subnet-cidr> \
    --destination-port-ranges 6081 \
    --protocol Udp \
    --access Allow \
    --direction Inbound \
    --description "Allow Geneve overlay network between workers"
  ```

- [ ] **Allow Kubelet from Workers (Priority 506):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowKubeletBetweenWorkers \
    --priority 506 \
    --source-address-prefixes <worker-subnet-cidr> \
    --destination-port-ranges 10250 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow Kubelet communication between workers"
  ```

- [ ] **Allow All Outbound (Priority 100):**
  ```bash
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowAllOutbound \
    --priority 100 \
    --destination-address-prefixes '*' \
    --destination-port-ranges '*' \
    --protocol '*' \
    --access Allow \
    --direction Outbound \
    --description "Allow all outbound traffic from worker nodes"
  ```

##### Step 4: Additional Rules for Optional Components

- [ ] **If Using BYO Route Table - Add to Master NSG:**
  ```bash
  # No specific NSG rule needed, but identity needs Network Contributor on route table
  ```

- [ ] **If Using NAT Gateway - Add to Worker NSG:**
  ```bash
  # NAT Gateway handles outbound, ensure outbound rules don't conflict
  # Verify NSG allows outbound to NAT Gateway subnet
  ```

- [ ] **If Using Azure Firewall:**
  ```bash
  # Ensure NSG allows outbound to Azure Firewall subnet
  # Coordinate with User Defined Routes (UDR)
  ```

##### Step 5: Attach NSGs to Subnets

- [ ] **Attach Master NSG to Master Subnet:**
  ```bash
  az network vnet subnet update \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <master-subnet-name> \
    --network-security-group ${CLUSTER_NAME}-master-nsg
  
  # Verify attachment
  az network vnet subnet show \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <master-subnet-name> \
    --query networkSecurityGroup.id -o tsv
  ```

- [ ] **Attach Worker NSG to Worker Subnet:**
  ```bash
  az network vnet subnet update \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <worker-subnet-name> \
    --network-security-group ${CLUSTER_NAME}-worker-nsg
  
  # Verify attachment
  az network vnet subnet show \
    --resource-group <vnet-rg> \
    --vnet-name <vnet-name> \
    --name <worker-subnet-name> \
    --query networkSecurityGroup.id -o tsv
  ```

##### Step 6: Grant Identity Permissions

- [ ] **With Managed Identity (Recommended):**
  - ARO built-in roles are automatically assigned during cluster creation
  - No manual action required
  - Verify after cluster creation:
    ```bash
    # Get aro-operator identity principal ID
    IDENTITY_PRINCIPAL_ID=$(az identity show \
      --resource-group <rg> \
      --name ${CLUSTER_NAME}-aro-operator \
      --query principalId -o tsv)
    
    # Verify role assignments on master NSG
    az role assignment list \
      --assignee ${IDENTITY_PRINCIPAL_ID} \
      --scope /subscriptions/<sub-id>/resourceGroups/<vnet-rg>/providers/Microsoft.Network/networkSecurityGroups/${CLUSTER_NAME}-master-nsg
    
    # Should see "Azure Red Hat OpenShift Service Operator" role
    ```

- [ ] **With Service Principal (Legacy):**
  ```bash
  # Assign Network Contributor to service principal on master NSG
  az role assignment create \
    --assignee <service-principal-app-id> \
    --role "Network Contributor" \
    --scope /subscriptions/<sub-id>/resourceGroups/<vnet-rg>/providers/Microsoft.Network/networkSecurityGroups/${CLUSTER_NAME}-master-nsg
  
  # Assign Network Contributor to service principal on worker NSG
  az role assignment create \
    --assignee <service-principal-app-id> \
    --role "Network Contributor" \
    --scope /subscriptions/<sub-id>/resourceGroups/<vnet-rg>/providers/Microsoft.Network/networkSecurityGroups/${CLUSTER_NAME}-worker-nsg
  
  # Verify assignments
  az role assignment list \
    --assignee <service-principal-app-id> \
    --scope /subscriptions/<sub-id>/resourceGroups/<vnet-rg>
  ```

##### Step 7: Enable NSG Flow Logs (Highly Recommended)

- [ ] **Create Storage Account for Flow Logs:**
  ```bash
  az storage account create \
    --name ${CLUSTER_NAME}nsgflowlogs \
    --resource-group <vnet-rg> \
    --location <location> \
    --sku Standard_LRS \
    --kind StorageV2
  ```

- [ ] **Enable Flow Logs for Master NSG:**
  ```bash
  az network watcher flow-log create \
    --location <location> \
    --name ${CLUSTER_NAME}-master-flow-log \
    --nsg ${CLUSTER_NAME}-master-nsg \
    --resource-group <vnet-rg> \
    --storage-account ${CLUSTER_NAME}nsgflowlogs \
    --enabled true \
    --retention 7 \
    --format JSON \
    --log-version 2
  ```

- [ ] **Enable Flow Logs for Worker NSG:**
  ```bash
  az network watcher flow-log create \
    --location <location> \
    --name ${CLUSTER_NAME}-worker-flow-log \
    --nsg ${CLUSTER_NAME}-worker-nsg \
    --resource-group <vnet-rg> \
    --storage-account ${CLUSTER_NAME}nsgflowlogs \
    --enabled true \
    --retention 7 \
    --format JSON \
    --log-version 2
  ```

- [ ] **Enable Traffic Analytics (Optional):**
  ```bash
  # Create Log Analytics workspace
  az monitor log-analytics workspace create \
    --resource-group <vnet-rg> \
    --workspace-name ${CLUSTER_NAME}-nsg-analytics \
    --location <location>
  
  # Enable Traffic Analytics on flow logs
  az network watcher flow-log update \
    --location <location> \
    --name ${CLUSTER_NAME}-master-flow-log \
    --traffic-analytics true \
    --workspace ${CLUSTER_NAME}-nsg-analytics
  ```

---

### BYO NSG Day 2 Operations

#### Regular Auditing

- [ ] **Review NSG Flow Logs for Anomalies:**
  ```bash
  # List flow log blobs
  az storage blob list \
    --account-name ${CLUSTER_NAME}nsgflowlogs \
    --container-name insights-logs-networksecuritygroupflowevent \
    -o table
  
  # Download recent flow log
  az storage blob download \
    --account-name ${CLUSTER_NAME}nsgflowlogs \
    --container-name insights-logs-networksecuritygroupflowevent \
    --name <blob-name> \
    --file flowlog.json
  
  # Analyze denied flows
  cat flowlog.json | jq '.records[] | select(.properties.flows[].flows[].flowTuples[] | contains("D"))'
  ```

- [ ] **Verify No Unauthorized Rule Changes:**
  ```bash
  # Export current rules for comparison
  az network nsg rule list \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-master-nsg \
    -o json > master-nsg-current.json
  
  # Compare with baseline (create baseline after initial setup)
  diff master-nsg-baseline.json master-nsg-current.json
  ```

- [ ] **Audit Rule Effectiveness:**
  ```bash
  # Check rule hit counts (if diagnostic logs enabled)
  # Query Log Analytics for rule match statistics
  ```

#### Adding Application-Specific Rules

- [ ] **Use Priority Range 3001+ for Custom Rules:**
  ```bash
  # Example: Allow specific application port from Azure Front Door
  az network nsg rule create \
    --resource-group <vnet-rg> \
    --nsg-name ${CLUSTER_NAME}-worker-nsg \
    --name AllowAppFromFrontDoor \
    --priority 3001 \
    --source-address-prefixes AzureFrontDoor.Backend \
    --destination-port-ranges 8080 \
    --protocol Tcp \
    --access Allow \
    --direction Inbound \
    --description "Allow app traffic from Azure Front Door"
  ```

- [ ] **Document Each Custom Rule:**
  - Create documentation spreadsheet with:
    - Rule name
    - Priority
    - Purpose
    - Business justification
    - Date added
    - Owner

#### NSG Monitoring and Alerts

- [ ] **Enable Diagnostic Logs:**
  ```bash
  # Create Log Analytics workspace if not exists
  az monitor log-analytics workspace create \
    --resource-group <vnet-rg> \
    --workspace-name ${CLUSTER_NAME}-diagnostics \
    --location <location>
  
  # Enable diagnostic settings on master NSG
  az monitor diagnostic-settings create \
    --name nsg-diagnostics \
    --resource /subscriptions/<sub-id>/resourceGroups/<vnet-rg>/providers/Microsoft.Network/networkSecurityGroups/${CLUSTER_NAME}-master-nsg \
    --logs '[{"category":"NetworkSecurityGroupEvent","enabled":true},{"category":"NetworkSecurityGroupRuleCounter","enabled":true}]' \
    --workspace /subscriptions/<sub-id>/resourcegroups/<vnet-rg>/providers/microsoft.operationalinsights/workspaces/${CLUSTER_NAME}-diagnostics
  
  # Repeat for worker NSG
  az monitor diagnostic-settings create \
    --name nsg-diagnostics \
    --resource /subscriptions/<sub-id>/resourceGroups/<vnet-rg>/providers/Microsoft.Network/networkSecurityGroups/${CLUSTER_NAME}-worker-nsg \
    --logs '[{"category":"NetworkSecurityGroupEvent","enabled":true},{"category":"NetworkSecurityGroupRuleCounter","enabled":true}]' \
    --workspace /subscriptions/<sub-id>/resourcegroups/<vnet-rg>/providers/microsoft.operationalinsights/workspaces/${CLUSTER_NAME}-diagnostics
  ```

- [ ] **Create Alerts for NSG Changes:**
  ```bash
  # Alert on NSG rule changes
  az monitor metrics alert create \
    --name nsg-rule-change-alert \
    --resource-group <vnet-rg> \
    --scopes /subscriptions/<sub-id>/resourceGroups/<vnet-rg> \
    --condition "total NetworkSecurityGroupEvent > 0" \
    --description "Alert when NSG rules are modified"
  ```

#### Critical Warnings for BYO NSG

⚠️ **NEVER:**
- Delete ARO-required rules (priorities 500-3000)
- Modify master-to-worker or worker-to-master communication rules
- Remove AzureLoadBalancer service tag rules
- Change rule priorities in the 500-3000 range

⚠️ **ALWAYS:**
- Test rule changes in non-production environment first
- Maintain identity permissions on NSGs (managed identities: ARO built-in roles; service principals: Network Contributor)
- Keep NSG flow logs enabled for troubleshooting
- Document all custom rules and their purpose
- Verify changes don't break cluster operations before applying to production

#### Change Management Process

- [ ] **Implement Approval Process:**
  1. Submit change request with justification
  2. Document expected impact
  3. Create rollback procedure
  4. Test in non-production
  5. Get approval from team lead
  6. Apply during approved change window
  7. Monitor for issues
  8. Update documentation

- [ ] **Maintain Change Log:**
  ```
  | Date | Rule Name | Priority | Change Type | Requestor | Approver | Notes |
  |------|-----------|----------|-------------|-----------|----------|-------|
  | 2026-03-01 | AllowApp8080 | 3001 | Add | user1 | lead1 | New app requirement |
  ```

---

### NSG Rule Reference Tables

#### Master Subnet NSG Required Rules

| Priority | Name | Source | Destination Port | Protocol | Direction | Purpose |
|----------|------|--------|------------------|----------|-----------|---------|
| 500 | AllowAPIServerFromWorkers | Worker subnet | 6443 | TCP | Inbound | API server access |
| 501 | AllowMCSFromWorkers | Worker subnet | 22623 | TCP | Inbound | Machine Config Server |
| 502 | AllowEtcdBetweenMasters | Master subnet | 2379-2380 | TCP | Inbound | etcd cluster |
| 503 | AllowKubeAPIBetweenMasters | Master subnet | 10250-10259 | TCP | Inbound | Kubernetes API |
| 504 | AllowVXLANBetweenMasters | Master subnet | 4789 | UDP | Inbound | VXLAN overlay |
| 505 | AllowGeneveBetweenMasters | Master subnet | 6081 | UDP | Inbound | Geneve overlay |
| 506 | AllowAzureLoadBalancer | AzureLoadBalancer | * | * | Inbound | Health probes |
| 100 | AllowAllOutbound | * | * | * | Outbound | Internet/Azure access |

#### Worker Subnet NSG Required Rules

| Priority | Name | Source | Destination Port | Protocol | Direction | Purpose |
|----------|------|--------|------------------|----------|-----------|---------|
| 500 | AllowHTTPS | Internet/VNet | 443 | TCP | Inbound | HTTPS ingress |
| 501 | AllowHTTP | Internet/VNet | 80 | TCP | Inbound | HTTP ingress |
| 502 | AllowAzureLoadBalancer | AzureLoadBalancer | * | * | Inbound | Health probes |
| 503 | AllowFromMasters | Master subnet | * | * | Inbound | All master traffic |
| 504 | AllowVXLANBetweenWorkers | Worker subnet | 4789 | UDP | Inbound | VXLAN overlay |
| 505 | AllowGeneveBetweenWorkers | Worker subnet | 6081 | UDP | Inbound | Geneve overlay |
| 506 | AllowKubeletBetweenWorkers | Worker subnet | 10250 | TCP | Inbound | Kubelet |
| 100 | AllowAllOutbound | * | * | * | Outbound | Internet/Azure access |

---

## Appendix B: Certificate Management

This appendix provides comprehensive guidance on TLS certificate management for ARO clusters.

### Overview

ARO clusters use TLS certificates for:
- **API Server**: Secures the Kubernetes API endpoint
- **Ingress Controller**: Secures application routes (*.apps domain)
- **Internal Components**: Service mesh, operators, monitoring

### Certificate Management Options

| Option | Automation | Complexity | Cost | Recommended For |
|--------|------------|------------|------|-----------------|
| **cert-manager** | ✅ High | Medium | Free (Let's Encrypt) | Production, automated renewal |
| **Manual Certificates** | ❌ Low | Low | Varies | Simple deployments, custom CA |
| **Azure Key Vault** | ⚠️ Partial | High | $$$ | Enterprise, integration with Azure |

---

### Option 1: cert-manager (Recommended)

cert-manager automates certificate issuance and renewal using various CA providers including Let's Encrypt, Azure Key Vault, and HashiCorp Vault.

#### Install cert-manager Operator

- [ ] **Deploy cert-manager from OperatorHub:**
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
    name: openshift-cert-manager-operator
    source: redhat-operators
    sourceNamespace: openshift-marketplace
    installPlanApproval: Automatic
  EOF
  ```

- [ ] **Wait for Installation to Complete:**
  ```bash
  # Check operator status
  oc get csv -n cert-manager-operator
  
  # Should see: PHASE = Succeeded
  
  # Verify cert-manager pods are running
  oc get pods -n cert-manager
  # Should see: cert-manager, cert-manager-cainjector, cert-manager-webhook
  ```

#### Configure Let's Encrypt Issuers

- [ ] **Create Production Let's Encrypt ClusterIssuer:**
  ```yaml
  apiVersion: cert-manager.io/v1
  kind: ClusterIssuer
  metadata:
    name: letsencrypt-prod
  spec:
    acme:
      server: https://acme-v02.api.letsencrypt.org/directory
      email: admin@example.com  # Change to your email
      privateKeySecretRef:
        name: letsencrypt-prod
      solvers:
      - http01:
          ingress:
            class: openshift-default
  ```

- [ ] **Create Staging Let's Encrypt ClusterIssuer (for testing):**
  ```yaml
  apiVersion: cert-manager.io/v1
  kind: ClusterIssuer
  metadata:
    name: letsencrypt-staging
  spec:
    acme:
      server: https://acme-staging-v02.api.letsencrypt.org/directory
      email: admin@example.com  # Change to your email
      privateKeySecretRef:
        name: letsencrypt-staging
      solvers:
      - http01:
          ingress:
            class: openshift-default
  ```

- [ ] **Apply Issuers:**
  ```bash
  oc apply -f letsencrypt-prod-issuer.yaml
  oc apply -f letsencrypt-staging-issuer.yaml
  
  # Verify issuers are ready
  oc get clusterissuer
  # Both should show: READY = True
  ```

#### Configure Azure DNS Issuer (for DNS-01 Challenge)

Use DNS-01 challenge when:
- API server is private (HTTP-01 won't work)
- You need wildcard certificates
- You control Azure DNS zone

- [ ] **Create Managed Identity for DNS Updates:**
  ```bash
  # Create managed identity
  az identity create \
    --name ${CLUSTER_NAME}-cert-manager-dns \
    --resource-group <rg>
  
  # Get identity details
  IDENTITY_CLIENT_ID=$(az identity show \
    --name ${CLUSTER_NAME}-cert-manager-dns \
    --resource-group <rg> \
    --query clientId -o tsv)
  
  IDENTITY_RESOURCE_ID=$(az identity show \
    --name ${CLUSTER_NAME}-cert-manager-dns \
    --resource-group <rg> \
    --query id -o tsv)
  ```

- [ ] **Grant DNS Zone Contributor to Identity:**
  ```bash
  # Get DNS zone resource ID
  DNS_ZONE_ID=$(az network dns zone show \
    --name <domain.com> \
    --resource-group <dns-rg> \
    --query id -o tsv)
  
  # Assign DNS Zone Contributor role
  az role assignment create \
    --assignee ${IDENTITY_CLIENT_ID} \
    --role "DNS Zone Contributor" \
    --scope ${DNS_ZONE_ID}
  ```

- [ ] **Create Azure DNS ClusterIssuer:**
  ```yaml
  apiVersion: cert-manager.io/v1
  kind: ClusterIssuer
  metadata:
    name: letsencrypt-dns
  spec:
    acme:
      server: https://acme-v02.api.letsencrypt.org/directory
      email: admin@example.com
      privateKeySecretRef:
        name: letsencrypt-dns
      solvers:
      - dns01:
          azureDNS:
            subscriptionID: <subscription-id>
            resourceGroupName: <dns-zone-rg>
            hostedZoneName: <domain.com>
            managedIdentity:
              clientID: <identity-client-id>
            # For ROSA or if using service principal:
            # clientID: <sp-app-id>
            # clientSecretSecretRef:
            #   name: azuredns-credentials
            #   key: client-secret
            # tenantID: <tenant-id>
  ```

#### Issue Certificates for API Server

- [ ] **Create Certificate for API Server:**
  ```yaml
  apiVersion: cert-manager.io/v1
  kind: Certificate
  metadata:
    name: api-server-cert
    namespace: openshift-config
  spec:
    secretName: api-server-tls
    duration: 2160h  # 90 days
    renewBefore: 360h  # Renew 15 days before expiry
    subject:
      organizations:
      - Example Organization
    commonName: api.<cluster-domain>.com
    dnsNames:
    - api.<cluster-domain>.com
    issuerRef:
      name: letsencrypt-prod  # or letsencrypt-dns for private clusters
      kind: ClusterIssuer
      group: cert-manager.io
  ```

- [ ] **Apply API Server Certificate:**
  ```bash
  oc apply -f api-server-cert.yaml
  
  # Wait for certificate to be issued
  oc get certificate -n openshift-config
  # STATUS should be "True"
  
  # Verify secret was created
  oc get secret api-server-tls -n openshift-config
  ```

- [ ] **Update API Server to Use Certificate:**
  ```bash
  oc patch apiserver cluster \
    --type=merge \
    --patch='{"spec":{"servingCerts":{"namedCertificates":[{"names":["api.<cluster-domain>.com"],"servingCertificate":{"name":"api-server-tls"}}]}}}'
  
  # Verify configuration
  oc get apiserver cluster -o yaml
  ```

#### Issue Certificates for Ingress Controller

- [ ] **Create Wildcard Certificate for Ingress:**
  ```yaml
  apiVersion: cert-manager.io/v1
  kind: Certificate
  metadata:
    name: ingress-wildcard-cert
    namespace: openshift-ingress
  spec:
    secretName: ingress-tls
    duration: 2160h  # 90 days
    renewBefore: 360h  # Renew 15 days before expiry
    subject:
      organizations:
      - Example Organization
    commonName: "*.apps.<cluster-domain>.com"
    dnsNames:
    - "*.apps.<cluster-domain>.com"
    issuerRef:
      name: letsencrypt-prod  # or letsencrypt-dns for wildcard
      kind: ClusterIssuer
      group: cert-manager.io
  ```
  
  **Note:** Wildcard certificates require DNS-01 challenge. Use `letsencrypt-dns` issuer.

- [ ] **Apply Ingress Certificate:**
  ```bash
  oc apply -f ingress-wildcard-cert.yaml
  
  # Wait for certificate
  oc get certificate -n openshift-ingress
  
  # Verify secret
  oc get secret ingress-tls -n openshift-ingress
  ```

- [ ] **Update Ingress Controller to Use Certificate:**
  ```bash
  oc patch ingresscontroller default \
    -n openshift-ingress-operator \
    --type=merge \
    --patch='{"spec":{"defaultCertificate":{"name":"ingress-tls"}}}'
  
  # Verify ingress controller picked up the certificate
  oc get ingresscontroller default -n openshift-ingress-operator -o yaml
  ```

#### Automated Certificate for Routes

- [ ] **Annotate Routes for Automatic Certificate Issuance:**
  ```yaml
  apiVersion: route.openshift.io/v1
  kind: Route
  metadata:
    name: myapp
    namespace: production
    annotations:
      cert-manager.io/issuer: letsencrypt-prod
      cert-manager.io/issuer-kind: ClusterIssuer
  spec:
    host: myapp.apps.<cluster-domain>.com
    to:
      kind: Service
      name: myapp
      port:
        targetPort: 8080
    tls:
      termination: edge
      insecureEdgeTerminationPolicy: Redirect
  ```
  
  cert-manager will automatically:
  1. Create a Certificate resource
  2. Issue certificate from Let's Encrypt
  3. Store in a Secret
  4. Update the Route with the certificate

- [ ] **Verify Route Certificate:**
  ```bash
  # Check certificate was issued
  oc get certificate -n production
  
  # Test HTTPS access
  curl -v https://myapp.apps.<cluster-domain>.com
  
  # Should show valid Let's Encrypt certificate
  ```

#### Certificate Monitoring

- [ ] **Monitor Certificate Expiration:**
  ```bash
  # List all certificates and their expiration
  oc get certificates -A -o custom-columns=\
  NAMESPACE:.metadata.namespace,\
  NAME:.metadata.name,\
  READY:.status.conditions[0].status,\
  EXPIRY:.status.notAfter
  
  # Check specific certificate details
  oc describe certificate <cert-name> -n <namespace>
  ```

- [ ] **Create Alert for Expiring Certificates:**
  ```yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: certificate-expiry-alerts
    namespace: openshift-monitoring
  spec:
    groups:
    - name: certificates
      interval: 1h
      rules:
      - alert: CertificateExpiryWarning
        expr: certmanager_certificate_expiration_timestamp_seconds - time() < (30 * 24 * 3600)
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Certificate {{ $labels.name }} expires in less than 30 days"
          description: "Certificate {{ $labels.name }} in namespace {{ $labels.namespace }} will expire in {{ $value | humanizeDuration }}"
      
      - alert: CertificateExpiryCritical
        expr: certmanager_certificate_expiration_timestamp_seconds - time() < (7 * 24 * 3600)
        for: 1h
        labels:
          severity: critical
        annotations:
          summary: "Certificate {{ $labels.name }} expires in less than 7 days"
          description: "Certificate {{ $labels.name }} in namespace {{ $labels.namespace }} will expire in {{ $value | humanizeDuration }}"
  ```

---

### Option 2: Manual Certificate Management

For simple deployments or when using a corporate CA.

#### API Server Certificate

- [ ] **Obtain Certificate from CA:**
  - CN (Common Name): `api.<cluster-domain>.com`
  - SAN (Subject Alternative Names): `api.<cluster-domain>.com`
  - Valid for at least 90 days

- [ ] **Create Secret in openshift-config:**
  ```bash
  oc create secret tls api-cert \
    --cert=api-cert.pem \
    --key=api-key.pem \
    -n openshift-config
  ```

- [ ] **Patch API Server:**
  ```bash
  oc patch apiserver cluster \
    --type=merge \
    --patch='{"spec":{"servingCerts":{"namedCertificates":[{"names":["api.<cluster-domain>.com"],"servingCertificate":{"name":"api-cert"}}]}}}'
  ```

- [ ] **Set Renewal Reminder:**
  - Add calendar reminder for 30 days before expiry
  - Document renewal procedure

#### Ingress Controller Certificate

- [ ] **Obtain Wildcard Certificate from CA:**
  - CN: `*.apps.<cluster-domain>.com`
  - SAN: `*.apps.<cluster-domain>.com`

- [ ] **Create Secret in openshift-ingress:**
  ```bash
  oc create secret tls apps-cert \
    --cert=apps-cert.pem \
    --key=apps-key.pem \
    -n openshift-ingress
  ```

- [ ] **Patch Ingress Controller:**
  ```bash
  oc patch ingresscontroller default \
    -n openshift-ingress-operator \
    --type=merge \
    --patch='{"spec":{"defaultCertificate":{"name":"apps-cert"}}}'
  ```

---

## Appendix C: Troubleshooting Guide

Comprehensive troubleshooting for common ARO issues.

### NSG Troubleshooting

See [Appendix A: Network Security Groups Deep Dive](#appendix-a-network-security-groups-deep-dive) for NSG-specific troubleshooting.

---

### Authentication & RBAC Issues

#### Issue: Unable to Login with Azure AD

**Symptoms:**
- OAuth login fails
- "Invalid client" or "redirect URI mismatch" errors
- Users can't authenticate after Azure AD configuration

**Resolution:**
```bash
# Verify OAuth configuration
oc get oauth cluster -o yaml

# Check OAuth pods are running
oc get pods -n openshift-authentication

# Verify Azure AD app redirect URI matches
# Should be: https://oauth-openshift.apps.<cluster-domain>/oauth2callback/AzureAD

# Test OAuth endpoint
curl -k https://oauth-openshift.apps.<cluster-domain>/healthz

# Check for errors in authentication operator
oc logs -n openshift-authentication-operator deployment/authentication-operator

# Recreate OAuth pods if needed
oc delete pods -n openshift-authentication --all
```

#### Issue: User Has No Permissions After Login

**Symptoms:**
- User can login but sees "Forbidden" errors
- User not in expected groups
- RBAC not working as configured

**Resolution:**
```bash
# Check user's groups
oc get groups

# Verify user is in expected group
oc describe group <group-name>

# Check role bindings for the group
oc get rolebindings,clusterrolebindings -A | grep <group-name>

# Manually add user to group if needed
oc adm groups add-users <group-name> <user@domain.com>

# Grant cluster-admin for testing (NOT for production)
oc adm policy add-cluster-role-to-user cluster-admin <user@domain.com>
```

#### Issue: Service Account Permission Errors

**Symptoms:**
- Pods fail with "Forbidden" errors
- Service account can't access resources
- CI/CD pipeline fails due to permissions

**Resolution:**
```bash
# Check if service account exists
oc get sa <sa-name> -n <namespace>

# Check role bindings for service account
oc get rolebindings -n <namespace> -o json | jq '.items[] | select(.subjects[]?.name=="<sa-name>")'

# Grant edit role to service account in namespace
oc adm policy add-role-to-user edit system:serviceaccount:<namespace>:<sa-name> -n <namespace>

# Check SCC for service account
oc get scc -o json | jq '.items[] | select(.users[]? | contains("system:serviceaccount:<namespace>:<sa-name>"))'

# Grant SCC if needed (example: anyuid)
oc adm policy add-scc-to-user anyuid system:serviceaccount:<namespace>:<sa-name>
```

---

### Operator Health Issues

#### Issue: Cluster Operators Degraded

**Symptoms:**
- `oc get co` shows operators with DEGRADED=True
- Cluster functionality impaired
- Warnings or errors in cluster operator status

**Resolution:**
```bash
# List degraded operators
oc get co | grep -v "False.*False.*False"

# Check specific operator details
oc describe co <operator-name>

# Check operator pods
oc get pods -n openshift-<operator-namespace>

# Check operator logs
oc logs -n openshift-<operator-namespace> <pod-name>

# Common operators and their namespaces:
# - authentication: openshift-authentication-operator
# - ingress: openshift-ingress-operator
# - image-registry: openshift-image-registry
# - console: openshift-console-operator

# Force operator reconciliation (delete operator pods)
oc delete pods -n openshift-<operator-namespace> --all

# Check cluster version for upgrade issues
oc get clusterversion
oc describe clusterversion
```

#### Issue: ARO Operator Issues

**Symptoms:**
- `oc get pods -n openshift-azure-operator` shows failing pods
- ARO-specific functionality not working
- Cluster unable to scale or perform Azure operations

**Resolution:**
```bash
# Check ARO operator pods
oc get pods -n openshift-azure-operator

# Check ARO operator logs
oc logs -n openshift-azure-operator deployment/aro-operator-master
oc logs -n openshift-azure-operator deployment/aro-operator-worker

# Check for identity/permission issues
# Verify managed identities have correct roles
az role assignment list --assignee <identity-principal-id>

# Check ARO cluster status in Azure
az aro show -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP} --query provisioningState

# Restart ARO operator if needed
oc delete pods -n openshift-azure-operator --all
```

---

### Storage Issues

#### Issue: PV Provisioning Failures

**Symptoms:**
- Pods stuck in `Pending` state
- PVCs not bound
- Events show "Failed to provision volume"

**Resolution:**
```bash
# Check PVC status
oc get pvc -n <namespace>

# Check PVC events
oc describe pvc <pvc-name> -n <namespace>

# Check available storage classes
oc get storageclass

# Verify CSI driver pods are running
oc get pods -n openshift-cluster-csi-drivers

# Check CSI driver logs
oc logs -n openshift-cluster-csi-drivers <csi-driver-pod>

# For Azure Disk CSI:
oc logs -n openshift-cluster-csi-drivers -l app=azure-disk-csi-driver

# For Azure Files CSI:
oc logs -n openshift-cluster-csi-drivers -l app=azure-file-csi-driver

# Check if identity has permissions (managed identity)
# Disk CSI driver needs permissions on managed resource group
az role assignment list --assignee <disk-csi-driver-identity-principal-id>

# Manually provision if needed (create PV manually)
# See storage documentation for manual PV creation
```

#### Issue: PV Not Mounting to Pod

**Symptoms:**
- Pod stuck in `ContainerCreating`
- Events show "Unable to mount volume"
- MountVolume.SetUp failed

**Resolution:**
```bash
# Check pod events
oc describe pod <pod-name> -n <namespace>

# Check node events
oc get events -n <namespace> --field-selector involvedObject.kind=Node

# Check if CSI node driver is running on the node
oc get pods -n openshift-cluster-csi-drivers -o wide | grep <node-name>

# Check node for disk attachment issues
az vm show -g <managed-rg> -n <vm-name> --query storageProfile.dataDisks

# Check if disk is attached but not mounted
oc debug node/<node-name>
# In debug pod:
lsblk
df -h

# Delete and recreate pod if mount is stuck
oc delete pod <pod-name> -n <namespace>
```

---

### Scaling Issues

#### Issue: Cluster Autoscaler Not Scaling

**Symptoms:**
- Pods pending but no new nodes created
- ClusterAutoscaler not adding nodes
- MachineSet not scaling despite demand

**Resolution:**
```bash
# Check ClusterAutoscaler status
oc get clusterautoscaler

# Check MachineAutoscaler
oc get machineautoscaler -n openshift-machine-api

# Check cluster-autoscaler-operator logs
oc logs -n openshift-machine-api -l cluster-autoscaler=default

# Check pending pods
oc get pods -A --field-selector status.phase=Pending

# Check resource requests causing pending
oc describe pod <pending-pod> -n <namespace>

# Verify MachineSet has correct min/max replicas
oc get machineset -n openshift-machine-api

# Check Azure quota availability
az vm list-usage --location <location> --query "[?name.value=='standardDSv3Family']"

# Manually scale MachineSet for testing
oc scale machineset <machineset-name> -n openshift-machine-api --replicas=<desired>
```

#### Issue: Nodes Stuck in NotReady

**Symptoms:**
- `oc get nodes` shows NotReady state
- Workloads not scheduling on node
- Node conditions show problems

**Resolution:**
```bash
# Check node status and conditions
oc get nodes
oc describe node <node-name>

# Check node conditions (Ready, MemoryPressure, DiskPressure, PIDPressure)
oc get node <node-name> -o jsonpath='{.status.conditions[*].type}{"\n"}{.status.conditions[*].status}'

# SSH to node (via debug pod)
oc debug node/<node-name>

# In debug pod, check:
# - Kubelet status
chroot /host
systemctl status kubelet
journalctl -u kubelet -n 100

# - Network connectivity
ping 8.8.8.8
nslookup api.<cluster-domain>

# - Disk space
df -h

# - Memory
free -h

# Cordon and drain node if needed
oc adm cordon <node-name>
oc adm drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Delete node and machine to trigger replacement
oc delete node <node-name>
oc delete machine <machine-name> -n openshift-machine-api
```

---

### Networking Issues

#### Issue: Pod-to-Pod Communication Failures

**Symptoms:**
- Services can't reach other services
- Network policy blocking traffic
- DNS resolution failures

**Resolution:**
```bash
# Test DNS resolution from pod
oc run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default

# Test service connectivity
oc run -it --rm debug --image=curlimages/curl --restart=Never -- curl http://<service-name>.<namespace>.svc.cluster.local

# Check network policies
oc get networkpolicy -n <namespace>
oc describe networkpolicy <policy-name> -n <namespace>

# Check if SDN pods are running
oc get pods -n openshift-sdn

# Check OVN-Kubernetes pods (if using OVN)
oc get pods -n openshift-ovn-kubernetes

# Check for network plugin errors
oc logs -n openshift-sdn ds/sdn
oc logs -n openshift-ovn-kubernetes ds/ovnkube-node

# Verify pod network connectivity
oc debug node/<node-name>
# In debug pod:
chroot /host
ip route
iptables -L -n
```

#### Issue: External Connectivity Problems

**Symptoms:**
- Pods can't reach internet
- Egress traffic blocked
- DNS lookups to external domains fail

**Resolution:**
```bash
# Test external connectivity from pod
oc run -it --rm debug --image=curlimages/curl --restart=Never -- curl https://www.google.com

# Check egress firewall (if configured)
oc get egressfirewall -A

# Check egress IPs
oc get egressip

# Check Azure NSG outbound rules (if BYO NSG)
az network nsg rule list -g <vnet-rg> --nsg-name <worker-nsg> --query "[?direction=='Outbound']"

# Check if NAT Gateway or Azure Firewall is blocking
# Review Azure Firewall logs or NAT Gateway metrics

# Check CoreDNS
oc get pods -n openshift-dns
oc logs -n openshift-dns <dns-pod>

# Test DNS from node
oc debug node/<node-name>
chroot /host
dig @8.8.8.8 google.com
```

---

### Performance Issues

#### Issue: High API Server Latency

**Symptoms:**
- `oc` commands slow
- Timeouts accessing API
- Applications experiencing slow Kubernetes API calls

**Resolution:**
```bash
# Check API server pods
oc get pods -n openshift-kube-apiserver

# Check API server logs for errors
oc logs -n openshift-kube-apiserver <kube-apiserver-pod> | grep -i error

# Check etcd health
oc get pods -n openshift-etcd
oc exec -n openshift-etcd <etcd-pod> -- etcdctl endpoint health

# Check control plane node load
oc adm top nodes | grep master

# Check for high number of objects
oc get all -A --no-headers | wc -l

# Check for resource contention on control plane
oc describe node <master-node>

# Review metrics in Prometheus
# Query: apiserver_request_duration_seconds_bucket
```

#### Issue: High Worker Node CPU/Memory

**Symptoms:**
- Nodes at high utilization
- Pods being evicted
- Performance degradation

**Resolution:**
```bash
# Check node resource usage
oc adm top nodes
oc adm top pods -A

# Check node allocatable resources
oc describe node <node-name> | grep -A 10 Allocatable

# Check for pods without resource limits
oc get pods -A -o json | jq '.items[] | select(.spec.containers[].resources.limits == null) | .metadata.name'

# Set resource limits/requests on pods
# Implement LimitRanges in namespaces

# Check for misbehaving pods
oc get pods -A --sort-by=.status.containerStatuses[0].restartCount

# Scale up worker nodes if needed
oc scale machineset <machineset> -n openshift-machine-api --replicas=<number>
```

---

### General Troubleshooting Commands

```bash
# Cluster health overview
oc get clusterversion
oc get clusteroperators
oc get nodes
oc get pods -A --field-selector status.phase!=Running

# Resource utilization
oc adm top nodes
oc adm top pods -A

# Events (last hour)
oc get events -A --sort-by='.lastTimestamp' | tail -50

# Degraded resources
oc get co | grep -v "False.*False.*False"

# Pending pods
oc get pods -A --field-selector status.phase=Pending

# Failed pods
oc get pods -A --field-selector status.phase=Failed

# Logs from failed pods
oc logs <pod-name> -n <namespace> --previous

# Node debugging
oc debug node/<node-name>

# Check cluster infrastructure
az aro show -n ${CLUSTER_NAME} -g ${RESOURCE_GROUP}

# Check managed identities
az identity list -g <rg> -o table

# Check NSG rules
az network nsg rule list -g <vnet-rg> --nsg-name <nsg-name> -o table
```

---

## Appendix D: Reference Information

### Azure Built-in Roles for ARO Managed Identities

| Role Name | Role ID | Purpose | Typical Scope |
|-----------|---------|---------|---------------|
| **Azure Red Hat OpenShift Federated Credential** | ef318e2a-8334-4a05-9e4a-295a196c6a6e | Manage federated credentials for platform identities | Cluster identities (all 8) |
| **Azure Red Hat OpenShift Cloud Controller Manager** | a1f96423-95ce-4224-ab27-4e3dc72facd4 | Manage load balancers, public IPs, and cloud resources | Subnets (master, worker) |
| **Azure Red Hat OpenShift Cluster Ingress Operator** | 0336e1d3-7a87-462b-b6db-342b63f7802c | Manage ingress resources and load balancers | Subnets (master, worker) |
| **Azure Red Hat OpenShift Disk Storage Operator** | (varies) | Manage disk storage resources | Managed resource group |
| **Azure Red Hat OpenShift File Storage Operator** | 0d7aedc0-15fd-4a67-a412-efad370c947e | Manage file storage resources | VNet, NSG (if BYO) |
| **Azure Red Hat OpenShift Image Registry Operator** | 8b32b316-c2f5-4ddf-b05b-83dacd2d08b5 | Manage image registry storage | VNet |
| **Azure Red Hat OpenShift Machine API Operator** | 0358943c-7e01-48ba-8889-02cc51d78637 | Create and manage virtual machines | Subnets (master, worker) |
| **Azure Red Hat OpenShift Network Operator** | be7a6435-15ae-4171-8f30-4a343eff9e8f | Manage networking resources | VNet |
| **Azure Red Hat OpenShift Service Operator** | 4436bae4-7702-4c84-919b-c4069ff25ee2 | Manage ARO service resources | Subnets (master, worker), NSG (if BYO) |

**Note:** These are ARO-specific built-in roles automatically assigned when using managed identities. They follow the principle of least privilege.

---

### Required Azure Endpoints and FQDNs

ARO clusters require outbound connectivity to the following endpoints:

#### Microsoft Azure Endpoints

| Endpoint | Port | Protocol | Purpose |
|----------|------|----------|---------|
| `*.blob.core.windows.net` | 443 | HTTPS | Azure Blob Storage |
| `*.table.core.windows.net` | 443 | HTTPS | Azure Table Storage |
| `*.servicebus.windows.net` | 443 | HTTPS | Azure Service Bus |
| `management.azure.com` | 443 | HTTPS | Azure Resource Manager |
| `login.microsoftonline.com` | 443 | HTTPS | Azure AD authentication |
| `*.azmk8s.io` | 443 | HTTPS | AKS/ARO management |

#### Red Hat Endpoints

| Endpoint | Port | Protocol | Purpose |
|----------|------|----------|---------|
| `quay.io` | 443 | HTTPS | Red Hat container registry |
| `*.quay.io` | 443 | HTTPS | Red Hat container registry (CDN) |
| `registry.redhat.io` | 443 | HTTPS | Red Hat container registry |
| `sso.redhat.com` | 443 | HTTPS | Red Hat SSO |
| `api.openshift.com` | 443 | HTTPS | OpenShift cluster manager |
| `console.redhat.com` | 443 | HTTPS | Red Hat Hybrid Cloud Console |

#### OpenShift/Kubernetes Endpoints

| Endpoint | Port | Protocol | Purpose |
|----------|------|----------|---------|
| `registry.access.redhat.com` | 443 | HTTPS | Container images |
| `*.registry.access.redhat.com` | 443 | HTTPS | Container images (CDN) |
| `docker.io` | 443 | HTTPS | Docker Hub (public images) |
| `gcr.io` | 443 | HTTPS | Google Container Registry |
| `ghcr.io` | 443 | HTTPS | GitHub Container Registry |

#### Azure Monitor / Telemetry (if using Azure Monitor)

| Endpoint | Port | Protocol | Purpose |
|----------|------|----------|---------|
| `*.ods.opinsights.azure.com` | 443 | HTTPS | Azure Monitor data ingestion |
| `*.oms.opinsights.azure.com` | 443 | HTTPS | Azure Monitor management |
| `*.monitoring.azure.com` | 443 | HTTPS | Azure Monitor |

**Note:** Use Azure Firewall application rules or NSG service tags where possible instead of allowing individual FQDNs.

---

### Supported Azure VM Sizes for ARO

#### Master Nodes (Control Plane)

| VM Size | vCPU | RAM | Temp Storage | Use Case |
|---------|------|-----|--------------|----------|
| **Standard_D8s_v5** | 8 | 32 GB | Remote | Minimum supported |
| **Standard_D16s_v5** | 16 | 64 GB | Remote | Recommended for production |
| **Standard_D32s_v5** | 32 | 128 GB | Remote | Large clusters (100+ nodes) |

**Requirements:**
- Minimum 8 vCPU, 32 GB RAM
- Premium SSD support required
- Always 3 master nodes (cannot be changed)

#### Worker Nodes (Compute)

**General Purpose:**
| VM Size | vCPU | RAM | Temp Storage | Use Case |
|---------|------|-----|--------------|----------|
| Standard_D2s_v3 | 2 | 8 GB | Remote | Development (not for production) |
| **Standard_D4s_v5** | 4 | 16 GB | Remote | General workloads (recommended minimum) |
| Standard_D8s_v5 | 8 | 32 GB | Remote | Standard production workloads |
| Standard_D16s_v5 | 16 | 64 GB | Remote | Larger workloads |
| Standard_D32s_v5 | 32 | 128 GB | Remote | Large workloads |

**Compute Optimized:**
| VM Size | vCPU | RAM | Use Case |
|---------|------|-----|----------|
| Standard_F4s_v2 | 4 | 8 GB | CPU-intensive workloads |
| Standard_F8s_v2 | 8 | 16 GB | Batch processing, analytics |
| Standard_F16s_v2 | 16 | 32 GB | High-performance compute |

**Memory Optimized:**
| VM Size | vCPU | RAM | Use Case |
|---------|------|-----|----------|
| Standard_E4s_v5 | 4 | 32 GB | Memory-intensive applications |
| Standard_E8s_v5 | 8 | 64 GB | In-memory databases, caches |
| Standard_E16s_v5 | 16 | 128 GB | Large in-memory workloads |

**GPU Workloads:**
| VM Size | GPU | vCPU | RAM | Use Case |
|---------|-----|------|-----|----------|
| Standard_NC6s_v3 | 1x V100 | 6 | 112 GB | ML training, inference |
| Standard_NC12s_v3 | 2x V100 | 12 | 224 GB | Multi-GPU ML workloads |
| Standard_NC24s_v3 | 4x V100 | 24 | 448 GB | Large-scale ML training |
| Standard_ND40rs_v2 | 8x V100 | 40 | 672 GB | Distributed ML training |

**See:** https://docs.microsoft.com/azure/openshift/support-policies-v4#supported-virtual-machine-sizes

---

### Supported OpenShift Versions

Check available versions for your region:
```bash
az aro get-versions --location <location>
```

**Version Support Policy:**
- ARO supports n and n-1 OpenShift versions
- Versions typically supported for 12-18 months after release
- Regular updates released monthly
- End-of-life versions deprecated with advance notice

**Check lifecycle:** https://access.redhat.com/support/policy/updates/openshift

---

### Common Azure Service Tags for NSG Rules

| Service Tag | Purpose |
|-------------|---------|
| **AzureLoadBalancer** | Azure Load Balancer health probes (REQUIRED) |
| **AzureCloud** | All Azure public IP addresses |
| **AzureCloud.<region>** | Azure IPs for specific region |
| **VirtualNetwork** | VNet address space and connected networks |
| **Internet** | Public internet |
| **Storage** | Azure Storage service |
| **Storage.<region>** | Azure Storage for specific region |
| **Sql** | Azure SQL Database |
| **AzureContainerRegistry** | Azure Container Registry |
| **AzureFrontDoor.Backend** | Azure Front Door backend IPs |
| **AzureKeyVault** | Azure Key Vault |
| **AzureMonitor** | Azure Monitor |

**Usage Example:**
```bash
az network nsg rule create \
  --source-address-prefixes AzureLoadBalancer \
  --destination-port-ranges '*' \
  --access Allow
```

---

### Default Network CIDRs

| Network | Default CIDR | Purpose | Configurable |
|---------|--------------|---------|--------------|
| **Pod Network** | 10.128.0.0/14 | Pod IP addresses | Yes (at cluster creation only) |
| **Service Network** | 172.30.0.0/16 | Service ClusterIPs | Yes (at cluster creation only) |
| **VNet** | (user-defined) | Azure VNet | Yes |
| **Master Subnet** | (user-defined, min /27) | Control plane nodes | Yes |
| **Worker Subnet** | (user-defined, min /27) | Worker nodes | Yes |

**Important:**
- Pod and Service CIDRs cannot be changed after cluster creation
- Ensure no overlap with VNet, peered VNets, or on-premises networks
- Minimum subnet sizes:
  - Master: /27 (32 IPs, 27 usable after Azure reservations)
  - Worker: /27 minimum, /24 recommended for scaling

---

### Useful Links

#### Official Documentation
- **ARO Documentation**: https://docs.microsoft.com/azure/openshift/
- **OpenShift Documentation**: https://docs.openshift.com/
- **ARO GitHub**: https://github.com/Azure/ARO-RP
- **Azure CLI Reference**: https://docs.microsoft.com/cli/azure/aro

#### Managed Identity Resources
- **ARO Managed Identity Guide**: https://learn.microsoft.com/en-us/azure/openshift/howto-understand-managed-identities
- **Create ARO with Managed Identity**: https://learn.microsoft.com/en-us/azure/openshift/howto-create-openshift-cluster
- **Azure Managed Identity Docs**: https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/

#### Support & Community
- **Red Hat Customer Portal**: https://access.redhat.com/
- **Red Hat Hybrid Cloud Console**: https://console.redhat.com/
- **ARO Support**: Azure Portal > Support + troubleshooting
- **OpenShift Community**: https://www.openshift.com/community

#### Training & Certification
- **Red Hat OpenShift Training**: https://www.redhat.com/en/services/training/all-courses-exams
- **Microsoft Learn - ARO**: https://learn.microsoft.com/training/browse/?products=azure-red-hat-openshift
- **OpenShift Interactive Learning**: https://learn.openshift.com/

---

**End of Azure Red Hat OpenShift Operations Guide v2.0**

*Last Updated: 2026-03-26*  
*Authors: Kevin Collins, Kumudu Herath*
