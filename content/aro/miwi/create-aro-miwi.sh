#!/bin/bash
set -e

# Clean up SUBSCRIPTION_ID in case it has extra content
if [ -n "${SUBSCRIPTION_ID}" ]; then
  # Extract only the UUID part (subscription ID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
  SUBSCRIPTION_ID=$(echo "${SUBSCRIPTION_ID}" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
fi

# Validate required environment variables
if [ -z "${SUBSCRIPTION_ID}" ]; then
  echo "ERROR: SUBSCRIPTION_ID environment variable is not set or invalid"
  echo "Please set required environment variables before running this script."
  echo ""
  echo "Recommended: source the set-env-vars.sh file:"
  echo "  source ./set-env-vars.sh"
  echo ""
  echo "Or manually set variables:"
  echo "  export SUBSCRIPTION_ID=\$(az account show --query id -o tsv)"
  echo "  export AZURE_LOCATION=\"eastus\""
  echo "  export ARO_CLUSTER_NAME=\"miwi-aro\""
  echo "  # ... see documentation for full list"
  exit 1
fi


# Validate other critical variables
for var in AZURE_LOCATION ARO_CLUSTER_NAME RESOURCE_GROUP VNET_RESOURCE_GROUP INFRASTRUCTURE_RESOURCE_GROUP; do
  if [ -z "${!var}" ]; then
    echo "ERROR: ${var} environment variable is not set"
    exit 1
  fi
done

# Create resource groups
if [ "${CREATE_RESOURCE_GROUPS}" = "true" ]; then
  echo "Creating Resource Groups..."

  ## Create the ARO Resource Group
  if [ "$(az group exists -n ${RESOURCE_GROUP})" = "false" ]; then
    az group create --name ${RESOURCE_GROUP} --location ${AZURE_LOCATION}
  fi

  ## Create the VNet Resource Group
  if [ "$(az group exists -n ${VNET_RESOURCE_GROUP})" = "false" ]; then
    az group create --name ${VNET_RESOURCE_GROUP} --location ${AZURE_LOCATION}
  fi

  # Validation Check
  # The Infrastructure Resource Group is Automatically Created, an RG name is optional and will be randomly generated otherwise
  if [ "$(az group exists -n ${INFRASTRUCTURE_RESOURCE_GROUP})" = "false" ]; then
    echo " - PASS: ARO Infrastructure Resource Group ${INFRASTRUCTURE_RESOURCE_GROUP} does not exist!"
  else
    echo " - FAIL: ARO Infrastructure Resource Group ${INFRASTRUCTURE_RESOURCE_GROUP} already exists!"
    exit 1
  fi

else
  echo "Skipping Resource Group Creation..."
  echo "Using:"
  echo " - ARO Resource Group: ${RESOURCE_GROUP}"
  echo " - ARO VNet Resource Group: ${VNET_RESOURCE_GROUP}"
  echo " - ARO Infrastructure Resource Group: ${INFRASTRUCTURE_RESOURCE_GROUP}"
  echo ""
  echo "Checking for required Resource Groups..."
  if [ "$(az group exists -n ${RESOURCE_GROUP})" = "false" ]; then
    echo " - FAIL: ARO Resource Group ${RESOURCE_GROUP} does not exist!"
    exit 1
  else
    echo " - PASS: ARO Resource Group exists"
  fi
  if [ "$(az group exists -n ${VNET_RESOURCE_GROUP})" = "false" ]; then
    echo " - FAIL: ARO VNet Resource Group ${VNET_RESOURCE_GROUP} does not exist!"
    exit 1
  else
    echo " - PASS: ARO VNet Resource Group exists"
  fi
  if [ "$(az group exists -n ${INFRASTRUCTURE_RESOURCE_GROUP})" = "false" ]; then
    echo " - PASS: ARO Infrastructure Resource Group ${INFRASTRUCTURE_RESOURCE_GROUP} does not exist!"
  else
    echo " - FAIL: ARO Infrastructure Resource Group ${INFRASTRUCTURE_RESOURCE_GROUP} already exists!"
    exit 1
  fi
fi

# Create virtual network
if [ "${CREATE_VNET}" = "true" ]; then

  echo "Creating VNet and Subnets..."

  ## Create the VNet
  if ! az network vnet show --resource-group ${VNET_RESOURCE_GROUP} --name ${VNET_NAME} &>/dev/null; then
    az network vnet create \
      --resource-group ${VNET_RESOURCE_GROUP} \
      --name ${VNET_NAME} \
      --location ${AZURE_LOCATION} \
      --address-prefixes "${VNET_CIDR}"
  else
    echo "${VNET_NAME} already exists!"
  fi

  ## Create the Control Plane Subnet
  if ! az network vnet subnet show -g ${VNET_RESOURCE_GROUP} --vnet-name ${VNET_NAME} --name ${VNET_CONTROL_PLANE_SUBNET_NAME} &>/dev/null; then
    az network vnet subnet create \
      --resource-group ${VNET_RESOURCE_GROUP} \
      --vnet-name ${VNET_NAME} \
      --name ${VNET_CONTROL_PLANE_SUBNET_NAME} \
      --address-prefixes "${VNET_CONTROL_PLANE_SUBNET_CIDR}" \
      --service-endpoints Microsoft.ContainerRegistry
  else
    echo "Subnet ${VNET_CONTROL_PLANE_SUBNET_NAME} in ${VNET_NAME} already exists!"
  fi

  ## Create the Application Node Subnet
  if ! az network vnet subnet show -g ${VNET_RESOURCE_GROUP} --vnet-name ${VNET_NAME} --name ${VNET_APP_NODE_SUBNET_NAME} &>/dev/null; then
    az network vnet subnet create \
      --resource-group ${VNET_RESOURCE_GROUP} \
      --vnet-name ${VNET_NAME} \
      --name ${VNET_APP_NODE_SUBNET_NAME} \
      --address-prefixes "${VNET_APP_NODE_SUBNET_CIDR}" \
      --service-endpoints Microsoft.ContainerRegistry
  else
    echo "Subnet ${VNET_APP_NODE_SUBNET_NAME} in ${VNET_NAME} already exists!"
  fi

  ## Disable subnet private endpoints
  az network vnet subnet update \
    --name ${VNET_CONTROL_PLANE_SUBNET_NAME} \
    --resource-group ${VNET_RESOURCE_GROUP} \
    --vnet-name ${VNET_NAME} \
    --private-link-service-network-policies Disabled
fi


if [ "${CREATE_MANAGED_IDENTITIES}" = "true" ]; then
  echo "Creating managed identities..."
  az identity create --resource-group ${RESOURCE_GROUP} --location ${AZURE_LOCATION} --name "${ARO_CLUSTER_NAME}-aro-cluster"
  az identity create --resource-group ${RESOURCE_GROUP} --location ${AZURE_LOCATION} --name "${ARO_CLUSTER_NAME}-cloud-controller-manager"
  az identity create --resource-group ${RESOURCE_GROUP} --location ${AZURE_LOCATION} --name "${ARO_CLUSTER_NAME}-ingress"
  az identity create --resource-group ${RESOURCE_GROUP} --location ${AZURE_LOCATION} --name "${ARO_CLUSTER_NAME}-machine-api"
  az identity create --resource-group ${RESOURCE_GROUP} --location ${AZURE_LOCATION} --name "${ARO_CLUSTER_NAME}-disk-csi-driver"
  az identity create --resource-group ${RESOURCE_GROUP} --location ${AZURE_LOCATION} --name "${ARO_CLUSTER_NAME}-cloud-network-config"
  az identity create --resource-group ${RESOURCE_GROUP} --location ${AZURE_LOCATION} --name "${ARO_CLUSTER_NAME}-image-registry"
  az identity create --resource-group ${RESOURCE_GROUP} --location ${AZURE_LOCATION} --name "${ARO_CLUSTER_NAME}-file-csi-driver"
  az identity create --resource-group ${RESOURCE_GROUP} --location ${AZURE_LOCATION} --name "${ARO_CLUSTER_NAME}-aro-operator"
fi

########################
## Associate the Managed Identities to Roles
echo "Assigning role permissions..."

# assign cluster identity permissions over identities previously created

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

# Deploy ARO cluster
echo "Creating ARO cluster (this will take 30-45 minutes)..."

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
  --enable-managed-identity \
  --location ${AZURE_LOCATION} \
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
