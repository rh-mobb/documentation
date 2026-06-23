---
date: '2026-04-06'
title: 'Deploy ARO with Managed Identities (Workload Identity Federation) via Azure CLI'
tags: ["ARO"]
authors:
  - Ken Moini
  - Kevin Collins
  - Diana Sari
validated_version: "4.20"
---


## Overview

This guide creates an Azure Red Hat OpenShift (ARO) cluster that uses:

- one user-assigned managed identity for the cluster;
- eight platform workload identities for ARO and OpenShift operators;
- Azure role assignments scoped to the required identities, virtual network, and subnets.

> **Important**
>
> - Use Azure CLI **2.84.0 or later**.
> - Existing service-principal-based ARO clusters cannot be converted to managed-identity clusters; create a new cluster instead.
> - The networking and role assignments below assume there is no pre-attached NSG, route table, or NAT gateway. Additional network resources require additional role assignments.
> - Run the commands from the same shell session, or save the variables in a local script that is excluded from source control.

{{% alert state="info" %}}
This guide was originally adapted from [Ken Moini's HackMD deployment guide](https://hackmd.io/@uEc--auZQr6p9NRV2558Hw/HkzS4XhiWl) and has since been updated and validated against the current Azure CLI managed identity workflow.
{{% /alert %}}

## Prerequisites

You need:

- an Azure subscription with sufficient ARO quota;
- permission to create resource groups, networks, managed identities, and role assignments;
- a Red Hat pull secret saved locally;
- Azure CLI 2.84.0 or later.

Check the CLI version:

```bash
az version --query '"azure-cli"' --output tsv
```

Confirm the managed-identity flags are available:

```bash
az aro create --help | grep -E \
  'enable-managed-identity|assign-cluster-identity|assign-platform'
```

Sign in and select the intended subscription:

```bash
az login
az account list --output table
az account set --subscription "<subscription-name-or-id>"
az account show --query '{name:name,id:id,tenantId:tenantId}' --output table
```

## 1. Set variables

Adjust these values for your environment:

```bash
#!/usr/bin/env bash
set -euo pipefail

AZR_RESOURCE_LOCATION="westus2"
AZR_RESOURCE_GROUP="aro-mi-rg"
AZR_CLUSTER="aro-mi"
AZR_PULL_SECRET="$HOME/Downloads/pull-secret.txt"

AZR_VNET="${AZR_CLUSTER}-vnet-${AZR_RESOURCE_LOCATION}"
AZR_MASTER_SUBNET="${AZR_CLUSTER}-control-subnet-${AZR_RESOURCE_LOCATION}"
AZR_WORKER_SUBNET="${AZR_CLUSTER}-machine-subnet-${AZR_RESOURCE_LOCATION}"

AZR_CLUSTER_IDENTITY="${AZR_CLUSTER}-cluster"
AZR_CCM_IDENTITY="${AZR_CLUSTER}-cloud-controller-manager"
AZR_INGRESS_IDENTITY="${AZR_CLUSTER}-ingress"
AZR_MACHINE_API_IDENTITY="${AZR_CLUSTER}-machine-api"
AZR_DISK_CSI_IDENTITY="${AZR_CLUSTER}-disk-csi-driver"
AZR_NETWORK_IDENTITY="${AZR_CLUSTER}-cloud-network-config"
AZR_IMAGE_REGISTRY_IDENTITY="${AZR_CLUSTER}-image-registry"
AZR_FILE_CSI_IDENTITY="${AZR_CLUSTER}-file-csi-driver"
AZR_OPERATOR_IDENTITY="${AZR_CLUSTER}-aro-operator"

test -f "$AZR_PULL_SECRET" || {
  echo "Pull secret not found: $AZR_PULL_SECRET"
  exit 1
}
```

## 2. Register required Azure resource providers

```bash
for provider in \
  Microsoft.RedHatOpenShift \
  Microsoft.Compute \
  Microsoft.Storage \
  Microsoft.Authorization
do
  az provider register \
    --namespace "$provider" \
    --wait
done
```

Verify registration:

```bash
az provider list \
  --query "[?namespace=='Microsoft.RedHatOpenShift' ||
             namespace=='Microsoft.Compute' ||
             namespace=='Microsoft.Storage' ||
             namespace=='Microsoft.Authorization'].{
               Provider:namespace,
               State:registrationState
             }" \
  --output table
```

All four providers should report `Registered`.

## 3. Create the resource group and network

This example creates one `/22` VNet with two empty `/23` subnets:

```bash
az group create \
  --name "$AZR_RESOURCE_GROUP" \
  --location "$AZR_RESOURCE_LOCATION"

az network vnet create \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_VNET" \
  --address-prefixes 10.0.0.0/22

az network vnet subnet create \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --vnet-name "$AZR_VNET" \
  --name "$AZR_MASTER_SUBNET" \
  --address-prefixes 10.0.0.0/23

az network vnet subnet create \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --vnet-name "$AZR_VNET" \
  --name "$AZR_WORKER_SUBNET" \
  --address-prefixes 10.0.2.0/23
```

## 4. Create the nine user-assigned managed identities

```bash
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
  az identity create \
    --resource-group "$AZR_RESOURCE_GROUP" \
    --name "$identity"
done
```

Verify the identities:

```bash
az identity list \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --query "[?starts_with(name, '$AZR_CLUSTER')].name" \
  --output table
```

The result should contain nine identities.

## 5. Capture resource IDs, scopes, and principal IDs

```bash
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"

VNET_ID="$(az network vnet show \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_VNET" \
  --query id --output tsv)"

MASTER_SUBNET_ID="$(az network vnet subnet show \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --vnet-name "$AZR_VNET" \
  --name "$AZR_MASTER_SUBNET" \
  --query id --output tsv)"

WORKER_SUBNET_ID="$(az network vnet subnet show \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --vnet-name "$AZR_VNET" \
  --name "$AZR_WORKER_SUBNET" \
  --query id --output tsv)"

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
```

Verify that the values are populated:

```bash
printf '%-25s %s\n' \
  "Subscription:" "$SUBSCRIPTION_ID" \
  "VNet:" "$VNET_ID" \
  "Master subnet:" "$MASTER_SUBNET_ID" \
  "Worker subnet:" "$WORKER_SUBNET_ID" \
  "Cluster identity:" "$AZR_CLUSTER_IDENTITY_ID" \
  "Cluster principal:" "$AZR_CLUSTER_PRINCIPAL_ID"
```

## 6. Create the required role assignments

The commands below use the built-in role definition IDs documented for ARO managed-identity clusters.

### 6.1 Allow the cluster identity to manage federated credentials

The cluster identity requires this assignment on each of the eight platform identities:

```bash
CLUSTER_IDENTITY_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e"

for PLATFORM_IDENTITY_ID in \
  "$AZR_OPERATOR_IDENTITY_ID" \
  "$AZR_CCM_IDENTITY_ID" \
  "$AZR_INGRESS_IDENTITY_ID" \
  "$AZR_MACHINE_API_IDENTITY_ID" \
  "$AZR_DISK_CSI_IDENTITY_ID" \
  "$AZR_NETWORK_IDENTITY_ID" \
  "$AZR_IMAGE_REGISTRY_IDENTITY_ID" \
  "$AZR_FILE_CSI_IDENTITY_ID"
do
  az role assignment create \
    --assignee-object-id "$AZR_CLUSTER_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$CLUSTER_IDENTITY_ROLE_ID" \
    --scope "$PLATFORM_IDENTITY_ID" \
    --only-show-errors
done
```

### 6.2 Assign subnet-scoped operator roles

Cloud Controller Manager:

```bash
CCM_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/a1f96423-95ce-4224-ab27-4e3dc72facd4"

for scope in "$MASTER_SUBNET_ID" "$WORKER_SUBNET_ID"; do
  az role assignment create \
    --assignee-object-id "$AZR_CCM_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$CCM_ROLE_ID" \
    --scope "$scope" \
    --only-show-errors
done
```

Ingress:

```bash
INGRESS_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0336e1d3-7a87-462b-b6db-342b63f7802c"

for scope in "$MASTER_SUBNET_ID" "$WORKER_SUBNET_ID"; do
  az role assignment create \
    --assignee-object-id "$AZR_INGRESS_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$INGRESS_ROLE_ID" \
    --scope "$scope" \
    --only-show-errors
done
```

Machine API:

```bash
MACHINE_API_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0358943c-7e01-48ba-8889-02cc51d78637"

for scope in "$MASTER_SUBNET_ID" "$WORKER_SUBNET_ID"; do
  az role assignment create \
    --assignee-object-id "$AZR_MACHINE_API_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$MACHINE_API_ROLE_ID" \
    --scope "$scope" \
    --only-show-errors
done
```

ARO Operator:

```bash
ARO_OPERATOR_ROLE_ID="/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/4436bae4-7702-4c84-919b-c4069ff25ee2"

for scope in "$MASTER_SUBNET_ID" "$WORKER_SUBNET_ID"; do
  az role assignment create \
    --assignee-object-id "$AZR_OPERATOR_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$ARO_OPERATOR_ROLE_ID" \
    --scope "$scope" \
    --only-show-errors
done
```

### 6.3 Assign VNet-scoped operator roles

Cloud Network Config:

```bash
az role assignment create \
  --assignee-object-id "$AZR_NETWORK_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/be7a6435-15ae-4171-8f30-4a343eff9e8f" \
  --scope "$VNET_ID" \
  --only-show-errors
```

File CSI Driver:

```bash
az role assignment create \
  --assignee-object-id "$AZR_FILE_CSI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0d7aedc0-15fd-4a67-a412-efad370c947e" \
  --scope "$VNET_ID" \
  --only-show-errors
```

Image Registry:

```bash
az role assignment create \
  --assignee-object-id "$AZR_IMAGE_REGISTRY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/8b32b316-c2f5-4ddf-b05b-83dacd2d08b5" \
  --scope "$VNET_ID" \
  --only-show-errors
```

### 6.4 Assign the Azure Red Hat OpenShift resource provider role

```bash
ARO_RP_SP_OBJECT_ID="$(az ad sp list \
  --display-name "Azure Red Hat OpenShift RP" \
  --query '[0].id' \
  --output tsv)"

test -n "$ARO_RP_SP_OBJECT_ID" || {
  echo "Azure Red Hat OpenShift RP service principal was not found"
  exit 1
}

az role assignment create \
  --assignee-object-id "$ARO_RP_SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "/subscriptions/${SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/42f3c60f-e7b1-46d7-ba56-6de681664342" \
  --scope "$VNET_ID" \
  --only-show-errors
```

## 7. Verify role-assignment counts

```bash
for IDENTITY_NAME in \
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
  PRINCIPAL_ID="$(principal_id "$IDENTITY_NAME")"

  COUNT="$(az role assignment list \
    --assignee-object-id "$PRINCIPAL_ID" \
    --all \
    --query 'length(@)' \
    --output tsv)"

  printf '%-45s %s assignments\n' "$IDENTITY_NAME" "$COUNT"
done
```

Expected minimums for this basic network layout:

```text
<cluster>-cluster                    8 assignments
<cluster>-cloud-controller-manager   2 assignments
<cluster>-ingress                    2 assignments
<cluster>-machine-api                2 assignments
<cluster>-disk-csi-driver            0 assignments
<cluster>-cloud-network-config       1 assignment
<cluster>-image-registry             1 assignment
<cluster>-file-csi-driver            1 assignment
<cluster>-aro-operator               2 assignments
```

The Disk CSI Driver identity having zero direct Azure RBAC assignments at this stage is expected. The cluster identity still has its assignment over the Disk CSI Driver identity so that the required federated credential can be created.

## 8. Check VM SKU availability and quota

List the intended VM sizes and restrictions:

```bash
az vm list-skus \
  --location "$AZR_RESOURCE_LOCATION" \
  --size Standard_D \
  --all \
  --query "[?name=='Standard_D8s_v5' || name=='Standard_D4s_v5'].{
    Size:name,
    Restrictions:restrictions
  }" \
  --output json
```

Check DSv5-family usage:

```bash
az vm list-usage \
  --location "$AZR_RESOURCE_LOCATION" \
  --query "[?contains(name.value, 'standardDSv5Family')].{
    Name:name.localizedValue,
    Current:currentValue,
    Limit:limit
  }" \
  --output table
```

ARO needs sufficient quota for the bootstrap, control-plane, and worker nodes during installation.

## 9. Optionally select an OpenShift version

List installable versions:

```bash
az aro get-versions \
  --location "$AZR_RESOURCE_LOCATION" \
  --output table
```

Set a version only when a specific release is required:

```bash
AZR_VERSION="<supported-version>"
```

Otherwise, omit `--version` and allow ARO to select its default supported version.

## 10. Validate the configuration

Run ARO validation before cluster creation:

```bash
az aro validate \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_CLUSTER" \
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
```

## 11. Create the cluster

Explicitly set VM sizes. This avoids an Azure CLI validation error where the worker VM size may be passed as an empty value:

```bash
az aro create \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_CLUSTER" \
  --vnet "$AZR_VNET" \
  --master-subnet "$AZR_MASTER_SUBNET" \
  --worker-subnet "$AZR_WORKER_SUBNET" \
  --master-vm-size "Standard_D8s_v5" \
  --worker-vm-size "Standard_D4s_v5" \
  --pull-secret "@$AZR_PULL_SECRET" \
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
```

To submit the operation and monitor it separately, add `--no-wait`.

## 12. Monitor deployment

```bash
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
```

List the cluster:

```bash
az aro list \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --output table
```

## 13. Retrieve credentials and log in

After deployment succeeds:

```bash
az aro list-credentials \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_CLUSTER"
```

Retrieve the API and console URLs:

```bash
az aro show \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_CLUSTER" \
  --query '{
    api:apiserverProfile.url,
    console:consoleProfile.url
  }' \
  --output yaml
```

## Troubleshooting

### Azure CLI emits a Python `SyntaxWarning`

A warning similar to the following is not an Azure deployment failure:

```text
SyntaxWarning: invalid escape sequence
```

Verify the command result and resource state rather than editing files under the Homebrew or Azure CLI installation directory.

### Worker VM size is empty

Symptom:

```text
The provided VM size '' is invalid for the 'worker' role.
```

Resolution: specify both VM sizes explicitly:

```bash
--master-vm-size "Standard_D8s_v5" \
--worker-vm-size "Standard_D4s_v5"
```

Confirm the SKUs are unrestricted in the target region before retrying.

### The shell closes or variables are lost

Opening a new terminal creates a new shell, so all unexported variables are lost. Rerun the variable block and recapture IDs before retrying.

Check whether the cluster was created before issuing another create command:

```bash
az aro show \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_CLUSTER" \
  --query provisioningState \
  --output tsv
```

- `Creating`: do not rerun creation; monitor the existing deployment.
- `Succeeded`: creation completed.
- `Failed`: inspect the returned error and deployment activity.
- `ResourceNotFound`: no cluster resource exists, so it is normally safe to retry after correcting the cause.

### Role assignment creation returns an authorization error

The account running these commands must be able to create role assignments at all required scopes. Having only resource creation permissions may not be sufficient.

### Existing NSG, route table, or NAT gateway

This guide assumes none is attached to the ARO subnets. When bringing those resources, add the operator role assignments required for each additional network resource before cluster creation.

## Cleanup

Delete the ARO cluster:

```bash
az aro delete \
  --resource-group "$AZR_RESOURCE_GROUP" \
  --name "$AZR_CLUSTER" \
  --yes
```

Cluster deletion does not remove the user-assigned managed identities or every role assignment created for them.

For a disposable lab where the resource group contains nothing else, deleting the resource group is the simplest complete cleanup:

```bash
az group delete \
  --name "$AZR_RESOURCE_GROUP" \
  --yes \
  --no-wait
```

Do not delete a shared resource group.

## References

- [Create an Azure Red Hat OpenShift cluster with managed identities](https://learn.microsoft.com/azure/openshift/howto-create-openshift-cluster)
- [Azure CLI `az aro` reference](https://learn.microsoft.com/cli/azure/aro)
- [Azure Red Hat OpenShift release notes](https://learn.microsoft.com/azure/openshift/azure-redhat-openshift-release-notes)
- [Understand managed identities in Azure Red Hat OpenShift](https://learn.microsoft.com/azure/openshift/howto-understand-managed-identities)
