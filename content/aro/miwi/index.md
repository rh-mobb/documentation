---
date: '2026-04-06'
title: 'Deploy ARO with Managed Identities and Workload Identity'
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

Ensure you have Azure CLI version 2.84 or later (version 2.70+ recommended for latest managed identity features):

```bash
az version
```

For the latest syntax with `--assign-identity` and `--assign-kubelet-identity`, upgrade to Azure CLI 2.70.0 or later:
```bash
brew upgrade azure-cli  # macOS
```

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
    export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
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
export AZURE_LOCATION="eastus"
export ARO_CLUSTER_NAME="miwi-aro"

# Resource Groups
export CREATE_RESOURCE_GROUPS="true"
export RESOURCE_GROUP="${ARO_CLUSTER_NAME}-rg"
export VNET_RESOURCE_GROUP="vnet-${RESOURCE_GROUP}"
export INFRASTRUCTURE_RESOURCE_GROUP="infra-${RESOURCE_GROUP}"

# Networking Configuration
export CREATE_VNET="true"
export VNET_NAME="aro-vnet"
export VNET_CIDR="10.42.0.0/16"
export VNET_CONTROL_PLANE_SUBNET_CIDR="10.42.0.0/23"
export VNET_APP_NODE_SUBNET_CIDR="10.42.2.0/23"

export VNET_CONTROL_PLANE_SUBNET_NAME="${ARO_CLUSTER_NAME}-cp-sn"
export VNET_APP_NODE_SUBNET_NAME="${ARO_CLUSTER_NAME}-app-sn"

# OpenShift Network Configuration
export POD_CIDR_SUBNET="100.80.0.0/14"
export SERVICE_CIDR_SUBNET="100.84.0.0/16"

# Cluster Configuration
export CLUSTER_EXPOSURE="Private"  # or "Public"
export WORKER_VM_SIZE="Standard_D4s_v5"
export CREATE_MANAGED_IDENTITIES="true"

# Pull Secret (optional but recommended)
export PULL_SECRET_PATH="rh-pull-secret.json"  # Set to empty string if not using: PULL_SECRET_PATH=""
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

Download and execute the automated deployment script:

```bash
# Download the deployment script
curl -O https://raw.githubusercontent.com/rh-mobb/documentation/main/content/aro/miwi/create-aro-miwi.sh
chmod +x create-aro-miwi.sh

# Run the deployment
./create-aro-miwi.sh
```

After the one-shot deployment completes, proceed to [Access the Cluster](#access-the-cluster) to start using your cluster.

## Step-by-Step Deployment

Alternatively, deploy each component individually for better control and understanding.

### 1. Create Resource Groups

```bash
if [ "${CREATE_RESOURCE_GROUPS}" = "true" ]; then
  az group create \
    --name ${RESOURCE_GROUP} \
    --location ${AZURE_LOCATION}

  az group create \
    --name ${VNET_RESOURCE_GROUP} \
    --location ${AZURE_LOCATION}
fi
```

### 2. Create Virtual Network

```bash
if [ "${CREATE_VNET}" = "true" ]; then
  # Create VNet
  az network vnet create \
    --resource-group ${VNET_RESOURCE_GROUP} \
    --name ${VNET_NAME} \
    --location ${AZURE_LOCATION} \
    --address-prefixes ${VNET_CIDR}

  # Create control plane subnet
  az network vnet subnet create \
    --resource-group ${VNET_RESOURCE_GROUP} \
    --vnet-name ${VNET_NAME} \
    --name ${VNET_CONTROL_PLANE_SUBNET_NAME} \
    --address-prefixes ${VNET_CONTROL_PLANE_SUBNET_CIDR}

  # Create worker subnet
  az network vnet subnet create \
    --resource-group ${VNET_RESOURCE_GROUP} \
    --vnet-name ${VNET_NAME} \
    --name ${VNET_APP_NODE_SUBNET_NAME} \
    --address-prefixes ${VNET_APP_NODE_SUBNET_CIDR}

  # Disable private link service network policies on control plane subnet
  az network vnet subnet update \
    --name ${VNET_CONTROL_PLANE_SUBNET_NAME} \
    --resource-group ${VNET_RESOURCE_GROUP} \
    --vnet-name ${VNET_NAME} \
    --private-link-service-network-policies Disabled
fi
```

### 3. Create Managed Identities

Create managed identities for ARO platform operators:

```bash
if [ "${CREATE_MANAGED_IDENTITIES}" = "true" ]; then
  # Core cluster identity
  az identity create \
    --name "${ARO_CLUSTER_NAME}-aro-cluster" \
    --resource-group ${RESOURCE_GROUP}

  # Platform operator identities
  for IDENTITY in aro-cluster cloud-controller-manager ingress machine-api \
                  disk-csi-driver cloud-network-config \
                  image-registry file-csi-driver aro-operator; do
    az identity create \
      --name "${ARO_CLUSTER_NAME}-${IDENTITY}" \
      --resource-group ${RESOURCE_GROUP}
  done
fi
```

### 4. Assign Role Permissions

Grant necessary permissions to managed identities:

```bash
az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-aro-operator"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-cloud-controller-manager"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-ingress"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-machine-api"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-disk-csi-driver"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-cloud-network-config"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-image-registry"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-file-csi-driver"

########################
# VNet Role Assignment
# assign vnet-level permissions for operators that require it, and subnets-level permission for operators that require it

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-cloud-controller-manager --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/a1f96423-95ce-4224-ab27-4e3dc72facd4" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${VNET_CONTROL_PLANE_SUBNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-cloud-controller-manager --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/a1f96423-95ce-4224-ab27-4e3dc72facd4" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${VNET_APP_NODE_SUBNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-ingress --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0336e1d3-7a87-462b-b6db-342b63f7802c" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${VNET_CONTROL_PLANE_SUBNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-ingress --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0336e1d3-7a87-462b-b6db-342b63f7802c" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${VNET_APP_NODE_SUBNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-machine-api --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0358943c-7e01-48ba-8889-02cc51d78637" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${VNET_CONTROL_PLANE_SUBNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-machine-api --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0358943c-7e01-48ba-8889-02cc51d78637" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${VNET_APP_NODE_SUBNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-cloud-network-config --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/be7a6435-15ae-4171-8f30-4a343eff9e8f" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-file-csi-driver --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0d7aedc0-15fd-4a67-a412-efad370c947e" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-image-registry --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/8b32b316-c2f5-4ddf-b05b-83dacd2d08b5" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-operator --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/4436bae4-7702-4c84-919b-c4069ff25ee2" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${VNET_CONTROL_PLANE_SUBNET_NAME}"

az role assignment create --assignee-object-id "$(az identity show --resource-group ${RESOURCE_GROUP} --name ${ARO_CLUSTER_NAME}-aro-operator --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/4436bae4-7702-4c84-919b-c4069ff25ee2" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${VNET_APP_NODE_SUBNET_NAME}"

az role assignment create --assignee-object-id "$(az ad sp list --display-name "Azure Red Hat OpenShift RP" --query '[0].id' -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/42f3c60f-e7b1-46d7-ba56-6de681664342" --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"

# Wait for identities to be created
sleep 10

```

### 5. Deploy ARO Cluster

Create the ARO cluster with managed identity configuration:

```bash
az aro create \
  --name ${ARO_CLUSTER_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --cluster-resource-group ${INFRASTRUCTURE_RESOURCE_GROUP} \
  --vnet-resource-group ${VNET_RESOURCE_GROUP} \
  --vnet ${VNET_NAME} \
  --master-subnet ${VNET_CONTROL_PLANE_SUBNET_NAME} \
  --worker-subnet ${VNET_APP_NODE_SUBNET_NAME} \
  --worker-vm-size ${WORKER_VM_SIZE} \
  --apiserver-visibility ${CLUSTER_EXPOSURE} \
  --ingress-visibility ${CLUSTER_EXPOSURE} \
  --version $(az aro get-versions --location ${AZURE_LOCATION} | jq -r '.[-1]') \
  --pull-secret @$PULL_SECRET_PATH \
  --location ${AZURE_LOCATION} \
  --enable-managed-identity \
  --assign-cluster-identity /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-aro-cluster \
  --assign-platform-workload-identity file-csi-driver /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-file-csi-driver \
  --assign-platform-workload-identity cloud-controller-manager /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-cloud-controller-manager \
  --assign-platform-workload-identity ingress /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-ingress \
  --assign-platform-workload-identity image-registry /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-image-registry \
  --assign-platform-workload-identity machine-api /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-machine-api \
  --assign-platform-workload-identity cloud-network-config /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-cloud-network-config \
  --assign-platform-workload-identity aro-operator /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-aro-operator \
  --assign-platform-workload-identity disk-csi-driver /subscriptions/${SUBSCRIPTION_ID}/resourcegroups/${RESOURCE_GROUP}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${ARO_CLUSTER_NAME}-disk-csi-driver \
  --pod-cidr ${POD_CIDR_SUBNET} \
  --service-cidr ${SERVICE_CIDR_SUBNET} \
  --debug
```

{{% alert state="info" %}}
Cluster creation takes approximately 30-45 minutes. The script automatically includes the pull secret if the file exists.
{{% /alert %}}

## Access the Cluster

### Get Cluster Console URL

```bash
az aro show \
  --name ${ARO_CLUSTER_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --query consoleProfile.url -o tsv
```

### Get Admin Credentials

```bash
az aro list-credentials \
  --name ${ARO_CLUSTER_NAME} \
  --resource-group ${RESOURCE_GROUP}
```

## Cleanup

To delete the cluster and all resources:

```bash
# Delete ARO cluster
az aro delete \
  --resource-group ${RESOURCE_GROUP} \
  --name ${ARO_CLUSTER_NAME} \
  --yes

# Delete managed identities
for IDENTITY in aro-cluster cloud-controller-manager ingress machine-api \
                disk-csi-driver cloud-network-config \
                image-registry file-csi-driver aro-operator; do
  az identity delete \
    --name "${ARO_CLUSTER_NAME}-${IDENTITY}" \
    --resource-group ${RESOURCE_GROUP}
done

# Delete resource groups
az group delete --name ${RESOURCE_GROUP} --yes
az group delete --name ${VNET_RESOURCE_GROUP} --yes
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
  --assignee ${CLUSTER_IDENTITY_ID} \
  --output table
```

### Permission Errors

Review Azure Activity Log for detailed error messages:

```bash
az monitor activity-log list \
  --resource-group ${RESOURCE_GROUP} \
  --max-events 50 \
  --output table
```
