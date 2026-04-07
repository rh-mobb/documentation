---
date: '2026-04-06'
title: Deploy ARO with Managed Identities and Workload Identity
tags: ["ARO"]
authors:
  - Ken Moini
  - Kevin Collins
validated_version: "4.20"
---

A guide to deploying Azure Red Hat OpenShift with Managed Identities and Workload Identity (MIWI) for enhanced security and streamlined Azure resource access.

{{% alert state="info" %}}
This guide is adapted from [Ken Moini's HackMD deployment guide](https://hackmd.io/@uEc--auZQr6p9NRV2558Hw/HkzS4XhiWl).
{{% /alert %}}

## Overview

This guide walks through deploying an ARO cluster using Azure Managed Identities instead of service principals, enabling Workload Identity for platform operators. This provides:

- **Enhanced Security**: No service principal secrets to manage
- **Streamlined Operations**: Automatic credential rotation via Azure Managed Identity
- **Workload Identity**: Platform operators use federated credentials with Azure

## Prerequisites

### Azure CLI

Ensure you have Azure CLI version 2.84 or later:

```bash
az version
```

{{% alert state="info" %}}If you need to install or upgrade Azure CLI, see the [ARO Quickstart](/aro/quickstart/) for installation instructions.{{% /alert %}}

### Red Hat Pull Secret

{{% alert state="info" %}}This step is optional, but highly recommended{{% /alert %}}

1. Log into <https://console.redhat.com>

1. Browse to <https://console.redhat.com/openshift/install/azure/aro-provisioned>

1. Click the **Download pull secret** button and save it as `rh-pull-secret.json`

### Azure Account Preparation

1. Log into Azure CLI

    ```bash
    az login
    ```

1. Set your subscription ID

    ```bash
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    ```

1. Register required resource providers

    ```bash
    az provider register -n Microsoft.RedHatOpenShift --wait
    az provider register -n Microsoft.Compute --wait
    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.Network --wait
    az provider register -n Microsoft.Authorization --wait
    az provider register -n Microsoft.ContainerRegistry --wait
    ```

## Configuration

### Set Environment Variables

Configure the deployment parameters:

```bash
# Azure Configuration
AZURE_LOCATION="eastus"
ARO_CLUSTER_NAME="miwi-aro"

# Resource Groups
CREATE_RESOURCE_GROUPS="true"
RESOURCE_GROUP="${ARO_CLUSTER_NAME}-rg"
VNET_RESOURCE_GROUP="vnet-${RESOURCE_GROUP}"
INFRASTRUCTURE_RESOURCE_GROUP="infra-${RESOURCE_GROUP}"

# Networking Configuration
CREATE_VNET="true"
VNET_NAME="aro-vnet"
VNET_CIDR="10.42.0.0/16"
VNET_CONTROL_PLANE_SUBNET_CIDR="10.42.0.0/23"
VNET_APP_NODE_SUBNET_CIDR="10.42.2.0/23"

# OpenShift Network Configuration
POD_CIDR_SUBNET="100.80.0.0/14"
SERVICE_CIDR_SUBNET="100.84.0.0/16"

# Cluster Configuration
CLUSTER_EXPOSURE="Private"  # or "Public"
WORKER_VM_SIZE="Standard_D4s_v5"
CREATE_MANAGED_IDENTITIES="true"

# Pull Secret (optional but recommended)
PULL_SECRET_PATH="rh-pull-secret.json"  # Set to empty string if not using: PULL_SECRET_PATH=""
```

{{% alert state="warning" %}}
Avoid using the following CIDR ranges for pod and service networks as they conflict with OVN-K:
- `100.64.0.0/16`
- `100.88.0.0/16`
{{% /alert %}}

## Deployment Options

You can deploy ARO with managed identities using either approach:

- **Option 1:** [One-Shot Deployment](#one-shot-deployment) - Single script that creates everything
- **Option 2:** [Step-by-Step Deployment](#step-by-step-deployment) - Individual commands for each component

## One-Shot Deployment

Deploy the entire ARO cluster with managed identities in a single script:

```bash
# Create resource groups
if [ "$CREATE_RESOURCE_GROUPS" = "true" ]; then
  echo "Creating resource groups..."
  az group create --name $RESOURCE_GROUP --location $AZURE_LOCATION
  az group create --name $VNET_RESOURCE_GROUP --location $AZURE_LOCATION
fi

# Create virtual network
if [ "$CREATE_VNET" = "true" ]; then
  echo "Creating virtual network..."
  az network vnet create \
    --resource-group $VNET_RESOURCE_GROUP \
    --name $VNET_NAME \
    --address-prefixes $VNET_CIDR

  az network vnet subnet create \
    --resource-group $VNET_RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --name control-plane-subnet \
    --address-prefixes $VNET_CONTROL_PLANE_SUBNET_CIDR

  az network vnet subnet create \
    --resource-group $VNET_RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --name worker-subnet \
    --address-prefixes $VNET_APP_NODE_SUBNET_CIDR

  az network vnet subnet update \
    --name control-plane-subnet \
    --resource-group $VNET_RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --disable-private-link-service-network-policies true
fi

# Create managed identities
if [ "$CREATE_MANAGED_IDENTITIES" = "true" ]; then
  echo "Creating managed identities..."
  az identity create --name "${ARO_CLUSTER_NAME}-aro-cluster" --resource-group $RESOURCE_GROUP
  
  for IDENTITY in cloud-controller-manager ingress machine-api \
                  disk-csi-driver cloud-network-config \
                  image-registry file-csi-driver aro-operator; do
    az identity create --name "${ARO_CLUSTER_NAME}-${IDENTITY}" --resource-group $RESOURCE_GROUP
  done
  
  # Wait for identities to be created
  sleep 10
fi

# Assign role permissions
echo "Assigning role permissions..."
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

CLUSTER_IDENTITY_ID=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-aro-cluster" \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

az role assignment create \
  --assignee $CLUSTER_IDENTITY_ID \
  --role Contributor \
  --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP

CCM_IDENTITY_ID=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-cloud-controller-manager" \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

az role assignment create \
  --assignee $CCM_IDENTITY_ID \
  --role "Network Contributor" \
  --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP

# Get managed identity resource IDs
CLUSTER_IDENTITY=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-aro-cluster" \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

# Get VNet subnet IDs
VNET_ID=$(az network vnet show \
  --resource-group $VNET_RESOURCE_GROUP \
  --name $VNET_NAME \
  --query id -o tsv)

CONTROL_PLANE_SUBNET_ID="${VNET_ID}/subnets/control-plane-subnet"
WORKER_SUBNET_ID="${VNET_ID}/subnets/worker-subnet"

# Deploy ARO cluster
echo "Creating ARO cluster (this will take 30-45 minutes)..."

# Build pull secret argument if provided
PULL_SECRET_ARG=""
if [ -n "$PULL_SECRET_PATH" ] && [ -f "$PULL_SECRET_PATH" ]; then
  PULL_SECRET_ARG="--pull-secret @$PULL_SECRET_PATH"
fi

az aro create \
  --resource-group $RESOURCE_GROUP \
  --name $ARO_CLUSTER_NAME \
  --location $AZURE_LOCATION \
  --vnet-resource-group $VNET_RESOURCE_GROUP \
  --master-subnet $CONTROL_PLANE_SUBNET_ID \
  --worker-subnet $WORKER_SUBNET_ID \
  --pod-cidr $POD_CIDR_SUBNET \
  --service-cidr $SERVICE_CIDR_SUBNET \
  --worker-vm-size $WORKER_VM_SIZE \
  $PULL_SECRET_ARG \
  --cluster-resource-group $INFRASTRUCTURE_RESOURCE_GROUP \
  --apiserver-visibility $CLUSTER_EXPOSURE \
  --ingress-visibility $CLUSTER_EXPOSURE \
  --enable-managed-identity \
  --assign-identity $CLUSTER_IDENTITY \
  --assign-kubelet-identity $CLUSTER_IDENTITY

echo "ARO cluster deployment complete!"

# Get cluster details
echo ""
echo "=== Cluster Console URL ==="
az aro show \
  --name $ARO_CLUSTER_NAME \
  --resource-group $RESOURCE_GROUP \
  --query consoleProfile.url -o tsv

echo ""
echo "=== Cluster Credentials ==="
az aro list-credentials \
  --name $ARO_CLUSTER_NAME \
  --resource-group $RESOURCE_GROUP
```

{{% alert state="info" %}}
The script automatically includes the pull secret if the file exists. If you don't have a pull secret, set `PULL_SECRET_PATH=""` in the environment variables.
{{% /alert %}}

After the one-shot deployment completes, proceed to [Configure Workload Identity](#6-configure-workload-identity) or skip to [Access the Cluster](#access-the-cluster) to start using your cluster.

## Step-by-Step Deployment

Alternatively, deploy each component individually for better control and understanding.

### 1. Create Resource Groups

```bash
if [ "$CREATE_RESOURCE_GROUPS" = "true" ]; then
  az group create \
    --name $RESOURCE_GROUP \
    --location $AZURE_LOCATION

  az group create \
    --name $VNET_RESOURCE_GROUP \
    --location $AZURE_LOCATION
fi
```

### 2. Create Virtual Network

```bash
if [ "$CREATE_VNET" = "true" ]; then
  # Create VNet
  az network vnet create \
    --resource-group $VNET_RESOURCE_GROUP \
    --name $VNET_NAME \
    --address-prefixes $VNET_CIDR

  # Create control plane subnet
  az network vnet subnet create \
    --resource-group $VNET_RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --name control-plane-subnet \
    --address-prefixes $VNET_CONTROL_PLANE_SUBNET_CIDR

  # Create worker subnet
  az network vnet subnet create \
    --resource-group $VNET_RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --name worker-subnet \
    --address-prefixes $VNET_APP_NODE_SUBNET_CIDR

  # Disable private link service network policies on control plane subnet
  az network vnet subnet update \
    --name control-plane-subnet \
    --resource-group $VNET_RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --disable-private-link-service-network-policies true
fi
```

### 3. Create Managed Identities

Create managed identities for ARO platform operators:

```bash
if [ "$CREATE_MANAGED_IDENTITIES" = "true" ]; then
  # Core cluster identity
  az identity create \
    --name "${ARO_CLUSTER_NAME}-aro-cluster" \
    --resource-group $RESOURCE_GROUP

  # Platform operator identities
  for IDENTITY in cloud-controller-manager ingress machine-api \
                  disk-csi-driver cloud-network-config \
                  image-registry file-csi-driver aro-operator; do
    az identity create \
      --name "${ARO_CLUSTER_NAME}-${IDENTITY}" \
      --resource-group $RESOURCE_GROUP
  done
fi
```

### 4. Assign Role Permissions

Grant necessary permissions to managed identities:

```bash
# Get subscription ID if not set
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Cluster identity - Contributor on resource group
CLUSTER_IDENTITY_ID=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-aro-cluster" \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

az role assignment create \
  --assignee $CLUSTER_IDENTITY_ID \
  --role Contributor \
  --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP

# Network permissions for cloud-controller-manager
CCM_IDENTITY_ID=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-cloud-controller-manager" \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

az role assignment create \
  --assignee $CCM_IDENTITY_ID \
  --role "Network Contributor" \
  --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP

# Storage permissions for image-registry
REGISTRY_IDENTITY_ID=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-image-registry" \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

az role assignment create \
  --assignee $REGISTRY_IDENTITY_ID \
  --role "Storage Account Contributor" \
  --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$INFRASTRUCTURE_RESOURCE_GROUP
```

{{% alert state="info" %}}
Additional role assignments may be required based on your specific requirements. Consult the [ARO documentation](https://learn.microsoft.com/en-us/azure/openshift/howto-create-workload-identity) for complete permissions.
{{% /alert %}}

### 5. Deploy ARO Cluster

Create the ARO cluster with managed identity configuration:

```bash
# Get managed identity resource IDs
CLUSTER_IDENTITY=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-aro-cluster" \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

CCM_IDENTITY=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-cloud-controller-manager" \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

INGRESS_IDENTITY=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-ingress" \
  --resource-group $RESOURCE_GROUP \
  --query id -o tsv)

# Get VNet IDs
VNET_ID=$(az network vnet show \
  --resource-group $VNET_RESOURCE_GROUP \
  --name $VNET_NAME \
  --query id -o tsv)

CONTROL_PLANE_SUBNET_ID="${VNET_ID}/subnets/control-plane-subnet"
WORKER_SUBNET_ID="${VNET_ID}/subnets/worker-subnet"

# Build pull secret argument if provided
PULL_SECRET_ARG=""
if [ -n "$PULL_SECRET_PATH" ] && [ -f "$PULL_SECRET_PATH" ]; then
  PULL_SECRET_ARG="--pull-secret @$PULL_SECRET_PATH"
fi

# Create cluster
az aro create \
  --resource-group $RESOURCE_GROUP \
  --name $ARO_CLUSTER_NAME \
  --location $AZURE_LOCATION \
  --vnet-resource-group $VNET_RESOURCE_GROUP \
  --master-subnet $CONTROL_PLANE_SUBNET_ID \
  --worker-subnet $WORKER_SUBNET_ID \
  --pod-cidr $POD_CIDR_SUBNET \
  --service-cidr $SERVICE_CIDR_SUBNET \
  --worker-vm-size $WORKER_VM_SIZE \
  $PULL_SECRET_ARG \
  --cluster-resource-group $INFRASTRUCTURE_RESOURCE_GROUP \
  --apiserver-visibility $CLUSTER_EXPOSURE \
  --ingress-visibility $CLUSTER_EXPOSURE \
  --enable-managed-identity \
  --assign-identity $CLUSTER_IDENTITY \
  --assign-kubelet-identity $CLUSTER_IDENTITY
```

{{% alert state="info" %}}
Cluster creation takes approximately 30-45 minutes. The script automatically includes the pull secret if the file exists.
{{% /alert %}}

### 6. Configure Workload Identity for Custom Workloads (Optional)

{{% alert state="info" %}}
Platform operators (cloud-controller-manager, ingress, machine-api, etc.) are **automatically configured** with workload identity when you deploy with `--enable-managed-identity`. This step is only needed for optional operators or custom applications that need Azure authentication.
{{% /alert %}}

For custom applications or optional operators that need to authenticate to Azure, create federated credentials:

```bash
# Get cluster credentials
az aro get-admin-kubeconfig \
  --resource-group $RESOURCE_GROUP \
  --name $ARO_CLUSTER_NAME \
  --file kubeconfig

export KUBECONFIG=kubeconfig

# Get OIDC issuer URL
OIDC_ISSUER=$(az aro show \
  --resource-group $RESOURCE_GROUP \
  --name $ARO_CLUSTER_NAME \
  --query "clusterProfile.oidcIssuerProfile.issuerUrl" -o tsv)

# Example: Create federated credential for a custom application
# Replace with your application's namespace, service account, and managed identity name
az identity federated-credential create \
  --name my-app-federated-credential \
  --identity-name "${ARO_CLUSTER_NAME}-my-custom-identity" \
  --resource-group $RESOURCE_GROUP \
  --issuer $OIDC_ISSUER \
  --subject system:serviceaccount:my-namespace:my-service-account \
  --audience openshift
```

{{% alert state="info" %}}
You must create a separate managed identity and federated credential for each custom application or optional operator that needs Azure access.
{{% /alert %}}

## Access the Cluster

### Get Cluster Console URL

```bash
az aro show \
  --name $ARO_CLUSTER_NAME \
  --resource-group $RESOURCE_GROUP \
  --query consoleProfile.url -o tsv
```

### Get Admin Credentials

```bash
az aro list-credentials \
  --name $ARO_CLUSTER_NAME \
  --resource-group $RESOURCE_GROUP
```

## Verify Workload Identity Configuration

Verify that platform operators are using managed identities:

```bash
# Check cloud-controller-manager pod logs
oc logs -n openshift-cloud-controller-manager \
  -l app=cloud-controller-manager \
  --tail=50 | grep -i "identity"

# Verify no service principal secrets exist
oc get secrets -n openshift-cloud-controller-manager | grep azure-cloud-credentials

# Should return empty - credentials are provided via workload identity
```

## Cleanup

To delete the cluster and all resources:

```bash
# Delete ARO cluster
az aro delete \
  --resource-group $RESOURCE_GROUP \
  --name $ARO_CLUSTER_NAME \
  --yes

# Delete managed identities
for IDENTITY in aro-cluster cloud-controller-manager ingress machine-api \
                disk-csi-driver cloud-network-config \
                image-registry file-csi-driver aro-operator; do
  az identity delete \
    --name "${ARO_CLUSTER_NAME}-${IDENTITY}" \
    --resource-group $RESOURCE_GROUP
done

# Delete resource groups
az group delete --name $RESOURCE_GROUP --yes
az group delete --name $VNET_RESOURCE_GROUP --yes
```

{{% alert state="danger" %}}
Ensure you want to delete all resources before running cleanup commands. This action cannot be undone.
{{% /alert %}}

## Benefits of Managed Identity with Workload Identity

**Security:**
- No service principal secrets stored in the cluster
- Automatic credential rotation via Azure
- Reduced attack surface for credential theft

**Operational:**
- Simplified secret management
- No manual secret rotation required
- Better audit trails via Azure Activity Log

**Compliance:**
- Meets security requirements for secret-free authentication
- Aligns with Azure security best practices
- Easier to demonstrate compliance posture

## Troubleshooting

### Managed Identity Not Working

Check role assignments:

```bash
az role assignment list \
  --assignee $CLUSTER_IDENTITY_ID \
  --output table
```

### Workload Identity Federation Issues

Verify federated credentials:

```bash
az identity federated-credential list \
  --identity-name "${ARO_CLUSTER_NAME}-cloud-controller-manager" \
  --resource-group $RESOURCE_GROUP \
  --output table
```

Confirm OIDC issuer matches:

```bash
echo $OIDC_ISSUER
```

### Permission Errors

Review Azure Activity Log for detailed error messages:

```bash
az monitor activity-log list \
  --resource-group $RESOURCE_GROUP \
  --max-events 50 \
  --output table
```

## Additional Resources

- [ARO Workload Identity Documentation](https://learn.microsoft.com/en-us/azure/openshift/howto-create-workload-identity)
- [Azure Managed Identity Overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview)
- [OpenShift on Azure](https://docs.openshift.com/container-platform/latest/installing/installing_azure/installing-azure-customizations.html)
