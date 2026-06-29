#!/usr/bin/env bash
set -euo pipefail

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

ensure_group() {
  local group="$1"

  if [ "$(az group exists --name "$group")" = "true" ]; then
    echo "Resource group exists: $group"
    return
  fi

  az group create \
    --name "$group" \
    --location "$AZR_RESOURCE_LOCATION" \
    --only-show-errors
}

ensure_vnet() {
  if az network vnet show \
    --resource-group "$AZR_VNET_RESOURCE_GROUP" \
    --name "$AZR_VNET" \
    --only-show-errors >/dev/null 2>&1; then
    echo "VNet exists: $AZR_VNET"
    return
  fi

  az network vnet create \
    --resource-group "$AZR_VNET_RESOURCE_GROUP" \
    --name "$AZR_VNET" \
    --location "$AZR_RESOURCE_LOCATION" \
    --address-prefixes "$AZR_VNET_CIDR" \
    --only-show-errors
}

ensure_subnet() {
  local subnet_name="$1"
  local subnet_cidr="$2"

  if az network vnet subnet show \
    --resource-group "$AZR_VNET_RESOURCE_GROUP" \
    --vnet-name "$AZR_VNET" \
    --name "$subnet_name" \
    --only-show-errors >/dev/null 2>&1; then
    echo "Subnet exists: $subnet_name"
    return
  fi

  az network vnet subnet create \
    --resource-group "$AZR_VNET_RESOURCE_GROUP" \
    --vnet-name "$AZR_VNET" \
    --name "$subnet_name" \
    --address-prefixes "$subnet_cidr" \
    --only-show-errors
}

ensure_identity() {
  local identity_name="$1"

  if az identity show \
    --resource-group "$AZR_RESOURCE_GROUP" \
    --name "$identity_name" \
    --only-show-errors >/dev/null 2>&1; then
    echo "Identity exists: $identity_name"
    return
  fi

  az identity create \
    --resource-group "$AZR_RESOURCE_GROUP" \
    --name "$identity_name" \
    --location "$AZR_RESOURCE_LOCATION" \
    --only-show-errors >/dev/null
}

identity_id() {
  az identity show \
    --resource-group "$AZR_RESOURCE_GROUP" \
    --name "$1" \
    --query id \
    --output tsv
}

principal_id() {
  az identity show \
    --resource-group "$AZR_RESOURCE_GROUP" \
    --name "$1" \
    --query principalId \
    --output tsv
}

ensure_role_assignment() {
  local principal_id="$1"
  local role_id="$2"
  local scope="$3"

  local assignment_count
  assignment_count="$(az role assignment list \
    --assignee-object-id "$principal_id" \
    --role "$role_id" \
    --scope "$scope" \
    --query 'length(@)' \
    --output tsv)"

  if [ "$assignment_count" != "0" ]; then
    echo "Role assignment exists: $role_id on $scope"
    return
  fi

  az role assignment create \
    --assignee-object-id "$principal_id" \
    --assignee-principal-type ServicePrincipal \
    --role "$role_id" \
    --scope "$scope" \
    --only-show-errors >/dev/null
}

require_command az

: "${AZR_RESOURCE_LOCATION:=westus2}"
: "${AZR_RESOURCE_GROUP:=aro-mi-rg}"
: "${AZR_VNET_RESOURCE_GROUP:=aro-mi-network-rg}"
: "${AZR_CLUSTER:=aro-mi}"
: "${AZR_PULL_SECRET:=$HOME/Downloads/pull-secret.txt}"

: "${AZR_VNET:=${AZR_CLUSTER}-vnet-${AZR_RESOURCE_LOCATION}}"
: "${AZR_MASTER_SUBNET:=${AZR_CLUSTER}-control-subnet-${AZR_RESOURCE_LOCATION}}"
: "${AZR_WORKER_SUBNET:=${AZR_CLUSTER}-machine-subnet-${AZR_RESOURCE_LOCATION}}"
: "${AZR_VNET_CIDR:=10.0.0.0/22}"
: "${AZR_MASTER_SUBNET_CIDR:=10.0.0.0/23}"
: "${AZR_WORKER_SUBNET_CIDR:=10.0.2.0/23}"

: "${AZR_MASTER_VM_SIZE:=Standard_D8s_v5}"
: "${AZR_WORKER_VM_SIZE:=Standard_D4s_v5}"
: "${AZR_WORKER_COUNT:=3}"
: "${ARO_VERSION:=}"

: "${AZR_CLUSTER_IDENTITY:=${AZR_CLUSTER}-cluster}"
: "${AZR_CCM_IDENTITY:=${AZR_CLUSTER}-cloud-controller-manager}"
: "${AZR_INGRESS_IDENTITY:=${AZR_CLUSTER}-ingress}"
: "${AZR_MACHINE_API_IDENTITY:=${AZR_CLUSTER}-machine-api}"
: "${AZR_DISK_CSI_IDENTITY:=${AZR_CLUSTER}-disk-csi-driver}"
: "${AZR_NETWORK_IDENTITY:=${AZR_CLUSTER}-cloud-network-config}"
: "${AZR_IMAGE_REGISTRY_IDENTITY:=${AZR_CLUSTER}-image-registry}"
: "${AZR_FILE_CSI_IDENTITY:=${AZR_CLUSTER}-file-csi-driver}"
: "${AZR_OPERATOR_IDENTITY:=${AZR_CLUSTER}-aro-operator}"

test -f "$AZR_PULL_SECRET" || {
  echo "ERROR: pull secret not found: $AZR_PULL_SECRET" >&2
  exit 1
}

SUBSCRIPTION_ID="$(az account show --query id --output tsv)"

printf '%-30s %s\n' \
  "Location:" "$AZR_RESOURCE_LOCATION" \
  "Cluster resource group:" "$AZR_RESOURCE_GROUP" \
  "VNet resource group:" "$AZR_VNET_RESOURCE_GROUP" \
  "Cluster name:" "$AZR_CLUSTER" \
  "VNet name:" "$AZR_VNET" \
  "Control plane subnet:" "$AZR_MASTER_SUBNET" \
  "Worker subnet:" "$AZR_WORKER_SUBNET" \
  "Control plane VM size:" "$AZR_MASTER_VM_SIZE" \
  "Worker VM size:" "$AZR_WORKER_VM_SIZE" \
  "Worker count:" "$AZR_WORKER_COUNT" \
  "Pull secret:" "$AZR_PULL_SECRET"

echo "Registering Azure resource providers..."
for provider in \
  Microsoft.RedHatOpenShift \
  Microsoft.Compute \
  Microsoft.Storage \
  Microsoft.Network \
  Microsoft.Authorization
do
  az provider register \
    --namespace "$provider" \
    --wait \
    --only-show-errors
done

echo "Creating or verifying resource groups..."
ensure_group "$AZR_RESOURCE_GROUP"
ensure_group "$AZR_VNET_RESOURCE_GROUP"

echo "Creating or verifying network resources..."
ensure_vnet
ensure_subnet "$AZR_MASTER_SUBNET" "$AZR_MASTER_SUBNET_CIDR"
ensure_subnet "$AZR_WORKER_SUBNET" "$AZR_WORKER_SUBNET_CIDR"

echo "Creating or verifying managed identities..."
for identity in \
  "$AZR_CLUSTER_IDENTITY" \
  "$AZR_CCM_IDENTITY" \
  "$AZR_INGRESS_IDENTITY" \
  "$AZR_MACHINE_API_IDENTITY" \
  "$AZR_DISK_CSI_IDENTITY" \
  "$AZR_NETWORK_IDENTITY" \
  "$AZR_IMAGE_REGISTRY_IDENTITY" \
  "$AZR_FILE_CSI_IDENTITY" \
  "$AZR_OPERATOR_IDENTITY"
do
  ensure_identity "$identity"
done

VNET_ID="$(az network vnet show \
  --resource-group "$AZR_VNET_RESOURCE_GROUP" \
  --name "$AZR_VNET" \
  --query id --output tsv)"

MASTER_SUBNET_ID="$(az network vnet subnet show \
  --resource-group "$AZR_VNET_RESOURCE_GROUP" \
  --vnet-name "$AZR_VNET" \
  --name "$AZR_MASTER_SUBNET" \
  --query id --output tsv)"

WORKER_SUBNET_ID="$(az network vnet subnet show \
  --resource-group "$AZR_VNET_RESOURCE_GROUP" \
  --vnet-name "$AZR_VNET" \
  --name "$AZR_WORKER_SUBNET" \
  --query id --output tsv)"

AZR_CLUSTER_IDENTITY_ID="$(identity_id "$AZR_CLUSTER_IDENTITY")"
AZR_CCM_IDENTITY_ID="$(identity_id "$AZR_CCM_IDENTITY")"
AZR_INGRESS_IDENTITY_ID="$(identity_id "$AZR_INGRESS_IDENTITY")"
AZR_MACHINE_API_IDENTITY_ID="$(identity_id "$AZR_MACHINE_API_IDENTITY")"
AZR_DISK_CSI_IDENTITY_ID="$(identity_id "$AZR_DISK_CSI_IDENTITY")"
AZR_NETWORK_IDENTITY_ID="$(identity_id "$AZR_NETWORK_IDENTITY")"
AZR_IMAGE_REGISTRY_IDENTITY_ID="$(identity_id "$AZR_IMAGE_REGISTRY_IDENTITY")"
AZR_FILE_CSI_IDENTITY_ID="$(identity_id "$AZR_FILE_CSI_IDENTITY")"
AZR_OPERATOR_IDENTITY_ID="$(identity_id "$AZR_OPERATOR_IDENTITY")"

AZR_CLUSTER_PRINCIPAL_ID="$(principal_id "$AZR_CLUSTER_IDENTITY")"
AZR_CCM_PRINCIPAL_ID="$(principal_id "$AZR_CCM_IDENTITY")"
AZR_INGRESS_PRINCIPAL_ID="$(principal_id "$AZR_INGRESS_IDENTITY")"
AZR_MACHINE_API_PRINCIPAL_ID="$(principal_id "$AZR_MACHINE_API_IDENTITY")"
AZR_NETWORK_PRINCIPAL_ID="$(principal_id "$AZR_NETWORK_IDENTITY")"
AZR_IMAGE_REGISTRY_PRINCIPAL_ID="$(principal_id "$AZR_IMAGE_REGISTRY_IDENTITY")"
AZR_FILE_CSI_PRINCIPAL_ID="$(principal_id "$AZR_FILE_CSI_IDENTITY")"
AZR_OPERATOR_PRINCIPAL_ID="$(principal_id "$AZR_OPERATOR_IDENTITY")"

CLUSTER_IDENTITY_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e"
CCM_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/a1f96423-95ce-4224-ab27-4e3dc72facd4"
INGRESS_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0336e1d3-7a87-462b-b6db-342b63f7802c"
MACHINE_API_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0358943c-7e01-48ba-8889-02cc51d78637"
ARO_OPERATOR_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/4436bae4-7702-4c84-919b-c4069ff25ee2"
CLOUD_NETWORK_CONFIG_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/be7a6435-15ae-4171-8f30-4a343eff9e8f"
FILE_CSI_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0d7aedc0-15fd-4a67-a412-efad370c947e"
IMAGE_REGISTRY_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
ARO_RP_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/42f3c60f-e7b1-46d7-ba56-6de681664342"

echo "Creating or verifying role assignments..."
for platform_identity_id in \
  "$AZR_OPERATOR_IDENTITY_ID" \
  "$AZR_CCM_IDENTITY_ID" \
  "$AZR_INGRESS_IDENTITY_ID" \
  "$AZR_MACHINE_API_IDENTITY_ID" \
  "$AZR_DISK_CSI_IDENTITY_ID" \
  "$AZR_NETWORK_IDENTITY_ID" \
  "$AZR_IMAGE_REGISTRY_IDENTITY_ID" \
  "$AZR_FILE_CSI_IDENTITY_ID"
do
  ensure_role_assignment "$AZR_CLUSTER_PRINCIPAL_ID" "$CLUSTER_IDENTITY_ROLE_ID" "$platform_identity_id"
done

for scope in "$MASTER_SUBNET_ID" "$WORKER_SUBNET_ID"; do
  ensure_role_assignment "$AZR_CCM_PRINCIPAL_ID" "$CCM_ROLE_ID" "$scope"
  ensure_role_assignment "$AZR_INGRESS_PRINCIPAL_ID" "$INGRESS_ROLE_ID" "$scope"
  ensure_role_assignment "$AZR_MACHINE_API_PRINCIPAL_ID" "$MACHINE_API_ROLE_ID" "$scope"
  ensure_role_assignment "$AZR_OPERATOR_PRINCIPAL_ID" "$ARO_OPERATOR_ROLE_ID" "$scope"
done

ensure_role_assignment "$AZR_NETWORK_PRINCIPAL_ID" "$CLOUD_NETWORK_CONFIG_ROLE_ID" "$VNET_ID"
ensure_role_assignment "$AZR_FILE_CSI_PRINCIPAL_ID" "$FILE_CSI_ROLE_ID" "$VNET_ID"
ensure_role_assignment "$AZR_IMAGE_REGISTRY_PRINCIPAL_ID" "$IMAGE_REGISTRY_ROLE_ID" "$VNET_ID"

ARO_RP_SP_OBJECT_ID="$(az ad sp list \
  --display-name "Azure Red Hat OpenShift RP" \
  --query '[0].id' \
  --output tsv)"

test -n "$ARO_RP_SP_OBJECT_ID" || {
  echo "ERROR: Azure Red Hat OpenShift RP service principal was not found" >&2
  exit 1
}

ensure_role_assignment "$ARO_RP_SP_OBJECT_ID" "$ARO_RP_ROLE_ID" "$VNET_ID"

echo "Validating ARO configuration..."
az aro validate \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_CLUSTER" \
  --vnet-resource-group "$AZR_VNET_RESOURCE_GROUP" \
  --vnet "$AZR_VNET" \
  --master-subnet "$AZR_MASTER_SUBNET" \
  --worker-subnet "$AZR_WORKER_SUBNET" \
  --enable-managed-identity \
  --assign-cluster-identity "$AZR_CLUSTER_IDENTITY_ID" \
  --assign-platform-workload-identity file-csi-driver "$AZR_FILE_CSI_IDENTITY_ID" \
  --assign-platform-workload-identity cloud-controller-manager "$AZR_CCM_IDENTITY_ID" \
  --assign-platform-workload-identity ingress "$AZR_INGRESS_IDENTITY_ID" \
  --assign-platform-workload-identity image-registry "$AZR_IMAGE_REGISTRY_IDENTITY_ID" \
  --assign-platform-workload-identity machine-api "$AZR_MACHINE_API_IDENTITY_ID" \
  --assign-platform-workload-identity cloud-network-config "$AZR_NETWORK_IDENTITY_ID" \
  --assign-platform-workload-identity aro-operator "$AZR_OPERATOR_IDENTITY_ID" \
  --assign-platform-workload-identity disk-csi-driver "$AZR_DISK_CSI_IDENTITY_ID"

create_args=(
  --resource-group "$AZR_RESOURCE_GROUP"
  --name "$AZR_CLUSTER"
  --vnet-resource-group "$AZR_VNET_RESOURCE_GROUP"
  --vnet "$AZR_VNET"
  --master-subnet "$AZR_MASTER_SUBNET"
  --worker-subnet "$AZR_WORKER_SUBNET"
  --master-vm-size "$AZR_MASTER_VM_SIZE"
  --worker-vm-size "$AZR_WORKER_VM_SIZE"
  --worker-count "$AZR_WORKER_COUNT"
  --pull-secret "@$AZR_PULL_SECRET"
  --enable-managed-identity
  --assign-cluster-identity "$AZR_CLUSTER_IDENTITY_ID"
  --assign-platform-workload-identity file-csi-driver "$AZR_FILE_CSI_IDENTITY_ID"
  --assign-platform-workload-identity cloud-controller-manager "$AZR_CCM_IDENTITY_ID"
  --assign-platform-workload-identity ingress "$AZR_INGRESS_IDENTITY_ID"
  --assign-platform-workload-identity image-registry "$AZR_IMAGE_REGISTRY_IDENTITY_ID"
  --assign-platform-workload-identity machine-api "$AZR_MACHINE_API_IDENTITY_ID"
  --assign-platform-workload-identity cloud-network-config "$AZR_NETWORK_IDENTITY_ID"
  --assign-platform-workload-identity aro-operator "$AZR_OPERATOR_IDENTITY_ID"
  --assign-platform-workload-identity disk-csi-driver "$AZR_DISK_CSI_IDENTITY_ID"
  --no-wait
)

if [ -n "$ARO_VERSION" ]; then
  create_args+=(--version "$ARO_VERSION")
fi

echo "Submitting ARO cluster creation..."
az aro create "${create_args[@]}"

echo "Cluster creation was submitted. Check status with:"
echo "  az aro show --resource-group \"$AZR_RESOURCE_GROUP\" --name \"$AZR_CLUSTER\" --query provisioningState --output tsv"
echo "  az aro wait --resource-group \"$AZR_RESOURCE_GROUP\" --name \"$AZR_CLUSTER\" --created"

az aro show \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_CLUSTER" \
  --query '{
    provisioningState:provisioningState,
    powerState:powerState,
    version:clusterProfile.version,
    console:consoleProfile.url
  }' \
  --output yaml
