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

Ensure you have Azure CLI version 2.84 or later (version 2.70+ recommended for latest managed identity features):

```bash
az version
```

For the latest syntax with `--assign-identity` and `--assign-kubelet-identity`, upgrade to Azure CLI 2.70.0 or later:
```bash
brew upgrade azure-cli  # macOS
```
{{% /alert %}}

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

Deploy the entire ARO cluster with managed identities in a single script:

```bash
# Create resource groups
if [ $CREATE_RESOURCE_GROUPS = "true" ]; then
  echo "Creating Resource Groups..."

  ## Create the ARO Resource Group
  if [ $(az group exists -n $RESOURCE_GROUP) = "false" ]; then
    az group create --name $RESOURCE_GROUP --location $AZURE_LOCATION
  fi

  ## Create the VNet Resource Group
  if [ $(az group exists -n $VNET_RESOURCE_GROUP) = "false" ]; then
    az group create --name $VNET_RESOURCE_GROUP --location $AZURE_LOCATION
  fi
  
  # Validation Check
  # The Infrastructure Resource Group is Automatically Created, an RG name is optional and will be randomly generated otherwise
  if [ $(az group exists -n $INFRASTRUCTURE_RESOURCE_GROUP) = "false" ]; then
    echo " - PASS: ARO Infrastructure Resource Group $INFRASTRUCTURE_RESOURCE_GROUP does not exist!"
  else
    echo " - FAIL: ARO Infrastructure Resource Group $INFRASTRUCTURE_RESOURCE_GROUP already exists!"
    exit 1
  fi

else
  echo "Skipping Resource Group Creation..."
  echo "Using:"
  echo " - ARO Resource Group: $RESOURCE_GROUP"
  echo " - ARO VNet Resource Group: $VNET_RESOURCE_GROUP"
  echo " - ARO Infrastructure Resource Group: $INFRASTRUCTURE_RESOURCE_GROUP"
  echo ""
  echo "Checking for required Resource Groups..."
  if [ $(az group exists -n $RESOURCE_GROUP) = "false" ]; then
    echo " - FAIL: ARO Resource Group $RESOURCE_GROUP does not exist!"
    exit 1
  else
    echo " - PASS: ARO Resource Group exists"
  fi
  if [ $(az group exists -n $VNET_RESOURCE_GROUP) = "false" ]; then
    echo " - FAIL: ARO Resource Group $VNET_RESOURCE_GROUP does not exist!"
    exit 1
  else
    echo " - PASS: ARO VNet Resource Group exists"
  fi
  if [ $(az group exists -n $INFRASTRUCTURE_RESOURCE_GROUP) = "false" ]; then
    echo " - PASS: ARO Infrastructure Resource Group $INFRASTRUCTURE_RESOURCE_GROUP does not exist!"
  else
    echo " - FAIL: ARO Infrastructure Resource Group $INFRASTRUCTURE_RESOURCE_GROUP already exists!"
    exit 1
  fi
fi

# Create virtual network
if [ $CREATE_VNET = "true" ]; then

  echo "Creating VNet and Subnets..."

  ## Create the VNet
  if [ $(az network vnet list --resource-group $VNET_RESOURCE_GROUP --query "[?contains(name, '"$VNET_NAME"')]" | jq -r 'length') = "0" ]; then
    az network vnet create \
      --resource-group $VNET_RESOURCE_GROUP \
      --name $VNET_NAME \
      --address-prefixes "${VNET_CIDR}"
  else
    echo "$VNET_NAME already exists!"
  fi

  ## Create the Control Plane Subnet
  if [ $(az network vnet subnet list -g $VNET_RESOURCE_GROUP --vnet-name $VNET_NAME --query "[?contains(name, '"$VNET_CONTROL_PLANE_SUBNET_NAME"')]" | jq -r 'length') = "0" ]; then
    az network vnet subnet create \
      --resource-group $VNET_RESOURCE_GROUP \
      --vnet-name $VNET_NAME \
      --name $VNET_CONTROL_PLANE_SUBNET_NAME \
      --address-prefixes "${VNET_CONTROL_PLANE_SUBNET_CIDR}" \
      --service-endpoints Microsoft.ContainerRegistry
  else
    echo "Subnet $VNET_CONTROL_PLANE_SUBNET_NAME in $VNET_NAME already exists!"
  fi

  ## Create the Application Node Subnet
  if [ $(az network vnet subnet list -g $VNET_RESOURCE_GROUP --vnet-name $VNET_NAME --query "[?contains(name, '"$VNET_APP_NODE_SUBNET_NAME"')]" | jq -r 'length') = "0" ]; then
    az network vnet subnet create \
      --resource-group $VNET_RESOURCE_GROUP \
      --vnet-name $VNET_NAME \
      --name $VNET_APP_NODE_SUBNET_NAME \
      --address-prefixes "${VNET_APP_NODE_SUBNET_CIDR}" \
      --service-endpoints Microsoft.ContainerRegistry
  else
    echo "Subnet $VNET_APP_NODE_SUBNET_NAME in $VNET_NAME already exists!"
  fi

  ## Disable subnet private endpoints
  az network vnet subnet update \
    --name $VNET_CONTROL_PLANE_SUBNET_NAME \
    --resource-group $VNET_RESOURCE_GROUP \
    --vnet-name $VNET_NAME \
    --private-link-service-network-policies Disabled
fi


if [ $CREATE_MANAGED_IDENTITIES = "true" ]; then
  az identity create --resource-group $RESOURCE_GROUP --name aro-cluster
  az identity create --resource-group $RESOURCE_GROUP --name cloud-controller-manager
  az identity create --resource-group $RESOURCE_GROUP --name ingress
  az identity create --resource-group $RESOURCE_GROUP --name machine-api
  az identity create --resource-group $RESOURCE_GROUP --name disk-csi-driver
  az identity create --resource-group $RESOURCE_GROUP --name cloud-network-config
  az identity create --resource-group $RESOURCE_GROUP --name image-registry
  az identity create --resource-group $RESOURCE_GROUP --name file-csi-driver
  az identity create --resource-group $RESOURCE_GROUP --name aro-operator
fi

########################
## Associate the Managed Identities to Roles

# assign cluster identity permissions over identities previously created

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aro-operator"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cloud-controller-manager"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ingress"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/machine-api"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/disk-csi-driver"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cloud-network-config"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/image-registry"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-cluster --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e" --scope "/subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/file-csi-driver"

########################
# VNet Role Assignment
# assign vnet-level permissions for operators that require it, and subnets-level permission for operators that require it

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name cloud-controller-manager --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/a1f96423-95ce-4224-ab27-4e3dc72facd4" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$VNET_CONTROL_PLANE_SUBNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name cloud-controller-manager --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/a1f96423-95ce-4224-ab27-4e3dc72facd4" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$VNET_APP_NODE_SUBNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name ingress --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/0336e1d3-7a87-462b-b6db-342b63f7802c" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$VNET_CONTROL_PLANE_SUBNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name ingress --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/0336e1d3-7a87-462b-b6db-342b63f7802c" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$VNET_APP_NODE_SUBNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name machine-api --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/0358943c-7e01-48ba-8889-02cc51d78637" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$VNET_CONTROL_PLANE_SUBNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name machine-api --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/0358943c-7e01-48ba-8889-02cc51d78637" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$VNET_APP_NODE_SUBNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name cloud-network-config --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/be7a6435-15ae-4171-8f30-4a343eff9e8f" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name file-csi-driver --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/0d7aedc0-15fd-4a67-a412-efad370c947e" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name image-registry --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/8b32b316-c2f5-4ddf-b05b-83dacd2d08b5" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-operator --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/4436bae4-7702-4c84-919b-c4069ff25ee2" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$VNET_CONTROL_PLANE_SUBNET_NAME"

az role assignment create --assignee-object-id "$(az identity show --resource-group $RESOURCE_GROUP --name aro-operator --query principalId -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/4436bae4-7702-4c84-919b-c4069ff25ee2" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$VNET_APP_NODE_SUBNET_NAME"

az role assignment create --assignee-object-id "$(az ad sp list --display-name "Azure Red Hat OpenShift RP" --query '[0].id' -o tsv)" --assignee-principal-type ServicePrincipal --role "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Authorization/roleDefinitions/42f3c60f-e7b1-46d7-ba56-6de681664342" --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"

# Wait for identities to be created
sleep 10

# Deploy ARO cluster
echo "Creating ARO cluster (this will take 30-45 minutes)..."

az aro create \
  --name $ARO_CLUSTER_NAME \
  --resource-group $RESOURCE_GROUP \
  --cluster-resource-group $INFRASTRUCTURE_RESOURCE_GROUP \
  --vnet-resource-group $VNET_RESOURCE_GROUP \
  --vnet $VNET_NAME \
  --master-subnet $VNET_CONTROL_PLANE_SUBNET_NAME \
  --worker-subnet $VNET_APP_NODE_SUBNET_NAME \
  --worker-vm-size $WORKER_VM_SIZE \
  --apiserver-visibility $CLUSTER_EXPOSURE \
  --ingress-visibility $CLUSTER_EXPOSURE \
  --version $(az aro get-versions --location $AZURE_LOCATION | jq -r '.[-1]') \
  --pull-secret "@{PULL_SECRET_PATH}" \
  --enable-managed-identity \
  --assign-cluster-identity /subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aro-cluster \
  --assign-platform-workload-identity file-csi-driver /subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/file-csi-driver \
  --assign-platform-workload-identity cloud-controller-manager /subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cloud-controller-manager \
  --assign-platform-workload-identity ingress /subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ingress \
  --assign-platform-workload-identity image-registry /subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/image-registry \
  --assign-platform-workload-identity machine-api /subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/machine-api \
  --assign-platform-workload-identity cloud-network-config /subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cloud-network-config \
  --assign-platform-workload-identity aro-operator /subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aro-operator \
  --assign-platform-workload-identity disk-csi-driver /subscriptions/$SUBSCRIPTION_ID/resourcegroups/$RESOURCE_GROUP/providers/Microsoft.ManagedIdentity/userAssignedIdentities/disk-csi-driver \
  --pod-cidr $POD_CIDR_SUBNET \
  --service-cidr $SERVICE_CIDR_SUBNET \
  --debug

echo "ARO cluster deployment complete!"

# Get cluster details
echo ""
echo "=== Cluster Console URL ==="
az aro show \
  --name ${ARO_CLUSTER_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --query consoleProfile.url -o tsv

echo ""
echo "=== Cluster Credentials ==="
az aro list-credentials \
  --name ${ARO_CLUSTER_NAME} \
  --resource-group ${RESOURCE_GROUP}
```

{{% alert state="info" %}}
The script automatically includes the pull secret if the file exists. If you don't have a pull secret, set `PULL_SECRET_PATH=""` in the environment variables.
{{% /alert %}}

After the one-shot deployment completes, proceed to [Configure Workload Identity](#6-configure-workload-identity) or skip to [Access the Cluster](#access-the-cluster) to start using your cluster.

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
    --address-prefixes ${VNET_CIDR}

  # Create control plane subnet
  az network vnet subnet create \
    --resource-group ${VNET_RESOURCE_GROUP} \
    --vnet-name ${VNET_NAME} \
    --name control-plane-subnet \
    --address-prefixes ${VNET_CONTROL_PLANE_SUBNET_CIDR}

  # Create worker subnet
  az network vnet subnet create \
    --resource-group ${VNET_RESOURCE_GROUP} \
    --vnet-name ${VNET_NAME} \
    --name worker-subnet \
    --address-prefixes ${VNET_APP_NODE_SUBNET_CIDR}

  # Disable private link service network policies on control plane subnet
  az network vnet subnet update \
    --name control-plane-subnet \
    --resource-group ${VNET_RESOURCE_GROUP} \
    --vnet-name ${VNET_NAME} \
    --disable-private-link-service-network-policies true
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
  for IDENTITY in cloud-controller-manager ingress machine-api \
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
# Get subscription ID if not set
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Cluster identity - Contributor on resource group
CLUSTER_IDENTITY_ID=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-aro-cluster" \
  --resource-group ${RESOURCE_GROUP} \
  --query principalId -o tsv)

az role assignment create \
  --assignee ${CLUSTER_IDENTITY_ID} \
  --role Contributor \
  --scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}

# Network permissions for cloud-controller-manager
CCM_IDENTITY_ID=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-cloud-controller-manager" \
  --resource-group ${RESOURCE_GROUP} \
  --query principalId -o tsv)

az role assignment create \
  --assignee ${CCM_IDENTITY_ID} \
  --role "Network Contributor" \
  --scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VNET_RESOURCE_GROUP}

# Storage permissions for image-registry
REGISTRY_IDENTITY_ID=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-image-registry" \
  --resource-group ${RESOURCE_GROUP} \
  --query principalId -o tsv)

az role assignment create \
  --assignee ${REGISTRY_IDENTITY_ID} \
  --role "Storage Account Contributor" \
  --scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${INFRASTRUCTURE_RESOURCE_GROUP}
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
  --resource-group ${RESOURCE_GROUP} \
  --query id -o tsv)

CCM_IDENTITY=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-cloud-controller-manager" \
  --resource-group ${RESOURCE_GROUP} \
  --query id -o tsv)

INGRESS_IDENTITY=$(az identity show \
  --name "${ARO_CLUSTER_NAME}-ingress" \
  --resource-group ${RESOURCE_GROUP} \
  --query id -o tsv)

# Get VNet IDs
VNET_ID=$(az network vnet show \
  --resource-group ${VNET_RESOURCE_GROUP} \
  --name ${VNET_NAME} \
  --query id -o tsv)

CONTROL_PLANE_SUBNET_ID="${VNET_ID}/subnets/control-plane-subnet"
WORKER_SUBNET_ID="${VNET_ID}/subnets/worker-subnet"

# Build pull secret argument if provided
PULL_SECRET_ARG=""
if [ -n "${PULL_SECRET_PATH}" ] && [ -f "${PULL_SECRET_PATH}" ]; then
  PULL_SECRET_ARG="--pull-secret @${PULL_SECRET_PATH}"
fi

# Create cluster
az aro create \
  --resource-group ${RESOURCE_GROUP} \
  --name ${ARO_CLUSTER_NAME} \
  --location ${AZURE_LOCATION} \
  --vnet-resource-group ${VNET_RESOURCE_GROUP} \
  --master-subnet ${CONTROL_PLANE_SUBNET_ID} \
  --worker-subnet ${WORKER_SUBNET_ID} \
  --pod-cidr ${POD_CIDR_SUBNET} \
  --service-cidr ${SERVICE_CIDR_SUBNET} \
  --worker-vm-size ${WORKER_VM_SIZE} \
  ${PULL_SECRET_ARG} \
  --cluster-resource-group ${INFRASTRUCTURE_RESOURCE_GROUP} \
  --apiserver-visibility ${CLUSTER_EXPOSURE} \
  --ingress-visibility ${CLUSTER_EXPOSURE} \
  --enable-managed-identity \
  --assign-identity ${CLUSTER_IDENTITY} \
  --assign-kubelet-identity ${CLUSTER_IDENTITY}
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
  --resource-group ${RESOURCE_GROUP} \
  --name ${ARO_CLUSTER_NAME} \
  --file kubeconfig

export KUBECONFIG=kubeconfig

# Get OIDC issuer URL
OIDC_ISSUER=$(az aro show \
  --resource-group ${RESOURCE_GROUP} \
  --name ${ARO_CLUSTER_NAME} \
  --query "clusterProfile.oidcIssuerProfile.issuerUrl" -o tsv)

# Example: Create federated credential for a custom application
# Replace with your application's namespace, service account, and managed identity name
az identity federated-credential create \
  --name my-app-federated-credential \
  --identity-name "${ARO_CLUSTER_NAME}-my-custom-identity" \
  --resource-group ${RESOURCE_GROUP} \
  --issuer ${OIDC_ISSUER} \
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

### Workload Identity Federation Issues

Verify federated credentials:

```bash
az identity federated-credential list \
  --identity-name "${ARO_CLUSTER_NAME}-cloud-controller-manager" \
  --resource-group ${RESOURCE_GROUP} \
  --output table
```

Confirm OIDC issuer matches:

```bash
echo ${OIDC_ISSUER}
```

### Permission Errors

Review Azure Activity Log for detailed error messages:

```bash
az monitor activity-log list \
  --resource-group ${RESOURCE_GROUP} \
  --max-events 50 \
  --output table
```

## Additional Resources

- [ARO Workload Identity Documentation](https://learn.microsoft.com/en-us/azure/openshift/howto-create-workload-identity)
- [Azure Managed Identity Overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview)
- [OpenShift on Azure](https://docs.openshift.com/container-platform/latest/installing/installing_azure/installing-azure-customizations.html)
