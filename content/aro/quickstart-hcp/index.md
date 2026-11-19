---
date: '2026-11-18'
title: ARO HCP Quickstart
weight: 1
authors:
  - Nicholas Morey
tags: ["ARO", "ARO HCP", "Quickstarts"]
---
A quickstart guide to deploying an Azure Red Hat OpenShift cluster with hosted control planes using Azure CLI (`az`).

{{% alert state="info" header="Prefer infrastructure as code" %}}
For production environments and repeatable deployments, we recommend infrastructure as code (IaC). Keeping infrastructure definitions in version control makes changes reviewable and helps keep environments consistent. Follow [Deploying ARO HCP with Terraform](/experts/aro/terraform-hcp/) for a Terraform deployment workflow covering cluster infrastructure, managed identities, networking, and Microsoft Entra integration.
{{% /alert %}}

The deployment steps follow the [Microsoft Azure CLI quickstart](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster?pivots=aro-az-cli).

## Prerequisites

### Azure CLI

Use Azure CLI **2.93.0 or later**, which includes the `az aro hcp` commands used in this guide. Check the installed version and confirm that HCP commands are available:

```bash
az --version
az aro hcp --help
```

**macOS**

{{% alert state="info" %}}See [Install Azure CLI on macOS](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-macos) for alternative install options.{{% /alert %}}

1. Install Azure CLI using Homebrew

    ```bash
    brew update && brew install azure-cli
    ```

**Linux (RHEL 8, 9, or 10, using `dnf`)**

{{% alert state="info" %}}For other distributions, follow [Install the Azure CLI on Linux](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux) for your operating system and package manager.{{% /alert %}}

1. Import the Microsoft signing key and add the repository for your RHEL major version

    Run only the commands for your release. See [Microsoft's RPM installation instructions](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux?pivots=dnf) for supported distributions.

    <details>
    <summary>RHEL 8</summary>

    ```bash
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo dnf install -y https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm
    ```

    </details>

    <details>
    <summary>RHEL 9</summary>

    ```bash
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo dnf install -y https://packages.microsoft.com/config/rhel/9.0/packages-microsoft-prod.rpm
    ```

    </details>

    <details>
    <summary>RHEL 10</summary>

    ```bash
    sudo rpm --import https://packages.microsoft.com/keys/microsoft-2025.asc
    sudo dnf install -y https://packages.microsoft.com/config/rhel/10/packages-microsoft-prod.rpm
    ```

    </details>

1. Install Azure CLI

    ```bash
    sudo dnf install -y azure-cli
    ```


### OpenShift CLI

Install the OpenShift CLI (`oc`) for your operating system from the [Red Hat downloads page](https://access.redhat.com/downloads/content/290), extract the archive, and place `oc` in a directory on your `PATH`. The deployment test environment used **client version 5.0.1**.

Check your installed client version:

```bash
oc version --client
```

The client version line from the test environment was:

```text
Client Version: 5.0.1
```

### Prepare your Azure account

1. Log into the Azure CLI by running the following and then authorizing through your Web Browser. If you have more than one subscription, list them and select the one where you will deploy the cluster.

    ```bash
    az login
    az account list -o table
    az account set --subscription "<id-or-name>"
    ```

1. Confirm your permissions at each required scope

    - **Subscription preparation:** **Contributor**, or **Owner**, at subscription scope permits resource provider registration and creation of a new resource group.
    - **Cluster deployment:** **Contributor and User Access Administrator**, or **Owner**, on the target resource group permits resource creation and role assignments. Roles inherited from the subscription also apply.

    If you only have resource group permissions, ask a subscription administrator to register the resource providers and create the resource group first. Then use that existing group and skip the registration and resource group creation commands in this guide. Resource group permissions do not grant subscription-level access. See [Azure role assignment scopes](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-cli#step-3-identify-the-needed-scope).

1. Check compute quota in your chosen [supported region](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration#choose-the-cluster-region). ARO HCP requires at least **20 cores**. This guide uses `eastus2`; change both the quota query and `AZR_RESOURCE_LOCATION` if needed.

    ```bash
    az vm list-usage --location eastus2 -o table
    ```

    Check quota for the worker VM family you plan to use. Request increases through [Azure quota management](https://learn.microsoft.com/en-us/azure/azure-portal/supportability/per-vm-quota-requests).

1. Register resource providers, unless a subscription administrator has already registered them

    ```bash
    az provider register -n Microsoft.RedHatOpenShift --wait
    az provider register -n Microsoft.Compute --wait
    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.Authorization --wait
    ```

## Deploy ARO with hosted control planes

### Define variables

Set the deployment location, resource group name, cluster name, and Key Vault name.

{{% alert state="info" %}}Change the values to suit your environment. Resource names must comply with [Azure naming rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules) and length limits. Run all following commands in the same shell so the exported variables apply.{{% /alert %}}

```bash
export AZR_RESOURCE_LOCATION=eastus2
export AZR_RESOURCE_GROUP=aro-rg
export AZR_CLUSTER=aro-cluster
# Key Vault: globally unique, 3-24 letters, digits, or hyphens.
# Start with a letter, end with a letter or digit, and avoid consecutive hyphens.
export AZR_KEYVAULT_NAME="<unique-vault-name>"
```

Print the exported values to confirm your settings:

```bash
printf 'AZR_RESOURCE_LOCATION=%s\n' "$AZR_RESOURCE_LOCATION"
printf 'AZR_RESOURCE_GROUP=%s\n' "$AZR_RESOURCE_GROUP"
printf 'AZR_CLUSTER=%s\n' "$AZR_CLUSTER"
printf 'AZR_KEYVAULT_NAME=%s\n' "$AZR_KEYVAULT_NAME"
```

Choose the Key Vault name independently of the cluster name so it fits the shorter [Key Vault naming limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules#microsoftkeyvault).

The Azure CLI requires explicit [cluster versions](https://learn.microsoft.com/en-us/cli/azure/aro/hcp/cluster#az-aro-hcp-cluster-create) and [node pool versions](https://learn.microsoft.com/en-us/cli/azure/aro/hcp/cluster/nodepool#az-aro-hcp-cluster-nodepool-create). Use [`az aro hcp get-versions`](https://learn.microsoft.com/en-us/cli/azure/aro/hcp#az-aro-hcp-get-versions) to list the available `stable` control plane versions in your selected region:

```bash
az aro hcp get-versions \
  --location "$AZR_RESOURCE_LOCATION" \
  --control-plane \
  --query "[?ChannelGroup=='stable']" \
  --output table
```

Choose a control plane minor version from the results. Replace `<major.minor>` with that version:

```bash
export AZR_CLUSTER_VERSION="<major.minor>"
```

Look up the highest available stable node pool patch version in the same minor stream. The numeric sort ensures that patch versions with multiple digits are ordered correctly:

```bash
export AZR_NODE_POOL_VERSION=$(
  az aro hcp get-versions \
    --location "$AZR_RESOURCE_LOCATION" \
    --node-pools \
    --query "[?starts_with(Name, '${AZR_CLUSTER_VERSION}.') && ChannelGroup=='stable'].Name" \
    --output tsv |
    sort -t. -k3,3n |
    tail -n 1
)
```

Print the selected versions:

```bash
printf 'AZR_CLUSTER_VERSION=%s\n' "$AZR_CLUSTER_VERSION"
printf 'AZR_NODE_POOL_VERSION=%s\n' "$AZR_NODE_POOL_VERSION"
```

Confirm that neither value is empty before continuing. If no node pool version is returned, check that the version query succeeded, then select an available control plane minor version and repeat the lookup.

### Create the resource group

An Azure resource group is a logical container for related Azure resources. This guide creates the cluster resource, VNet, NSG, managed identities, and Key Vault in `$AZR_RESOURCE_GROUP` so you can manage and clean up these resources together. ARO HCP creates a separate managed resource group for its managed infrastructure.

Create the resource group before continuing with the networking and identity steps. If a subscription administrator has already created it, set `AZR_RESOURCE_GROUP` to that group's name and skip this command.

```bash
az group create \
  --subscription "$(az account show --query id --output tsv)" \
  --name "$AZR_RESOURCE_GROUP" \
  --location "$AZR_RESOURCE_LOCATION" \
  --tags Environment=Lab Purpose=ARO-Quickstart
```

### Networking

Create a network security group, a virtual network, and subnets for the cluster.

1. Create a network security group

    ```bash
    az network nsg create \
      --name "$AZR_CLUSTER-aro-nsg-$AZR_RESOURCE_LOCATION" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --location "$AZR_RESOURCE_LOCATION"
    ```

1. Create the virtual network and worker subnet with the network security group

    ```bash
    az network vnet create \
      --name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --location "$AZR_RESOURCE_LOCATION" \
      --address-prefixes 10.0.0.0/16 \
      --subnet-name "$AZR_CLUSTER-aro-worker-subnet-$AZR_RESOURCE_LOCATION" \
      --subnet-prefixes 10.0.0.0/24 \
      --nsg "$AZR_CLUSTER-aro-nsg-$AZR_RESOURCE_LOCATION"
    ```

1. Create the VNet integration subnet with the required delegation

    ```bash
    az network vnet subnet create \
      --name "$AZR_CLUSTER-aro-integration-subnet-$AZR_RESOURCE_LOCATION" \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --address-prefixes 10.0.1.0/24 \
      --delegations Microsoft.RedHatOpenShift/hcpOpenShiftClusters
    ```

1. Get the resource IDs for the networking resources

    ```bash
    export NSG_ID=$(az network nsg show \
      --name "$AZR_CLUSTER-aro-nsg-$AZR_RESOURCE_LOCATION" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --query id --output tsv)

    export SUBNET_ID=$(az network vnet subnet show \
      --name "$AZR_CLUSTER-aro-worker-subnet-$AZR_RESOURCE_LOCATION" \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --query id --output tsv)

    export VNET_ID=$(az network vnet show \
      --name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --query id --output tsv)

    export VNET_INTEGRATION_SUBNET_ID=$(az network vnet subnet show \
      --name "$AZR_CLUSTER-aro-integration-subnet-$AZR_RESOURCE_LOCATION" \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --query id --output tsv)
    ```

1. Print the exported networking resource IDs and confirm that none are empty

    ```bash
    printf 'NSG_ID=%s\n' "$NSG_ID"
    printf 'SUBNET_ID=%s\n' "$SUBNET_ID"
    printf 'VNET_ID=%s\n' "$VNET_ID"
    printf 'VNET_INTEGRATION_SUBNET_ID=%s\n' "$VNET_INTEGRATION_SUBNET_ID"
    ```

### Managed identities

The cluster needs 13 user-assigned identities. See [Microsoft's identity reference](https://learn.microsoft.com/en-us/azure/openshift/concepts-managed-identities) for their responsibilities.

{{% alert state="info" %}}The commands in each block run one after another. Allow a moment for each block to finish before continuing to the next step.{{% /alert %}}

1. Create the operator and service identities

    ```bash
    # Control plane operator identities
    az identity create --name "${AZR_CLUSTER}-cp-cluster-api-azure" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-cp-control-plane" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-cp-cloud-controller-manager" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-cp-ingress" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-cp-disk-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-cp-file-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-cp-image-registry" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-cp-cloud-network-config" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-cp-kms" --resource-group "${AZR_RESOURCE_GROUP}"

    # Data plane operator identities
    az identity create --name "${AZR_CLUSTER}-dp-disk-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-dp-file-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}"
    az identity create --name "${AZR_CLUSTER}-dp-image-registry" --resource-group "${AZR_RESOURCE_GROUP}"

    # Service managed identity
    az identity create --name "${AZR_CLUSTER}-service-managed-identity" --resource-group "${AZR_RESOURCE_GROUP}"
    ```

1. Export the identity resource IDs and principal IDs

    ```bash
    # Control plane identity resource IDs and principal IDs
    export CLUSTER_API_AZURE_MI_ID=$(az identity show --name "${AZR_CLUSTER}-cp-cluster-api-azure" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export CLUSTER_API_AZURE_MI_PID=$(az identity show --name "${AZR_CLUSTER}-cp-cluster-api-azure" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    export CONTROL_PLANE_MI_ID=$(az identity show --name "${AZR_CLUSTER}-cp-control-plane" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export CONTROL_PLANE_MI_PID=$(az identity show --name "${AZR_CLUSTER}-cp-control-plane" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    export CLOUD_CONTROLLER_MANAGER_MI_ID=$(az identity show --name "${AZR_CLUSTER}-cp-cloud-controller-manager" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export CLOUD_CONTROLLER_MANAGER_MI_PID=$(az identity show --name "${AZR_CLUSTER}-cp-cloud-controller-manager" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    export INGRESS_MI_ID=$(az identity show --name "${AZR_CLUSTER}-cp-ingress" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export INGRESS_MI_PID=$(az identity show --name "${AZR_CLUSTER}-cp-ingress" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    export DISK_CSI_DRIVER_MI_ID=$(az identity show --name "${AZR_CLUSTER}-cp-disk-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)

    export FILE_CSI_DRIVER_MI_ID=$(az identity show --name "${AZR_CLUSTER}-cp-file-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export FILE_CSI_DRIVER_MI_PID=$(az identity show --name "${AZR_CLUSTER}-cp-file-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    export IMAGE_REGISTRY_MI_ID=$(az identity show --name "${AZR_CLUSTER}-cp-image-registry" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export IMAGE_REGISTRY_MI_PID=$(az identity show --name "${AZR_CLUSTER}-cp-image-registry" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    export CLOUD_NETWORK_CONFIG_MI_ID=$(az identity show --name "${AZR_CLUSTER}-cp-cloud-network-config" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export CLOUD_NETWORK_CONFIG_MI_PID=$(az identity show --name "${AZR_CLUSTER}-cp-cloud-network-config" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    export KMS_MI_ID=$(az identity show --name "${AZR_CLUSTER}-cp-kms" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export KMS_MI_PID=$(az identity show --name "${AZR_CLUSTER}-cp-kms" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    # Data plane identity resource IDs and principal IDs
    export DP_DISK_CSI_DRIVER_MI_ID=$(az identity show --name "${AZR_CLUSTER}-dp-disk-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)

    export DP_FILE_CSI_DRIVER_MI_ID=$(az identity show --name "${AZR_CLUSTER}-dp-file-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export DP_FILE_CSI_DRIVER_MI_PID=$(az identity show --name "${AZR_CLUSTER}-dp-file-csi-driver" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    export DP_IMAGE_REGISTRY_MI_ID=$(az identity show --name "${AZR_CLUSTER}-dp-image-registry" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export DP_IMAGE_REGISTRY_MI_PID=$(az identity show --name "${AZR_CLUSTER}-dp-image-registry" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)

    # Service managed identity resource ID and principal ID
    export SERVICE_MI_ID=$(az identity show --name "${AZR_CLUSTER}-service-managed-identity" --resource-group "${AZR_RESOURCE_GROUP}" --query id --output tsv)
    export SERVICE_MI_PID=$(az identity show --name "${AZR_CLUSTER}-service-managed-identity" --resource-group "${AZR_RESOURCE_GROUP}" --query principalId --output tsv)
    ```

1. Print the exported identity values and confirm that none are empty

    ```bash
    printf 'CLUSTER_API_AZURE_MI_ID=%s\n' "$CLUSTER_API_AZURE_MI_ID"
    printf 'CLUSTER_API_AZURE_MI_PID=%s\n' "$CLUSTER_API_AZURE_MI_PID"
    printf 'CONTROL_PLANE_MI_ID=%s\n' "$CONTROL_PLANE_MI_ID"
    printf 'CONTROL_PLANE_MI_PID=%s\n' "$CONTROL_PLANE_MI_PID"
    printf 'CLOUD_CONTROLLER_MANAGER_MI_ID=%s\n' "$CLOUD_CONTROLLER_MANAGER_MI_ID"
    printf 'CLOUD_CONTROLLER_MANAGER_MI_PID=%s\n' "$CLOUD_CONTROLLER_MANAGER_MI_PID"
    printf 'INGRESS_MI_ID=%s\n' "$INGRESS_MI_ID"
    printf 'INGRESS_MI_PID=%s\n' "$INGRESS_MI_PID"
    printf 'DISK_CSI_DRIVER_MI_ID=%s\n' "$DISK_CSI_DRIVER_MI_ID"
    printf 'FILE_CSI_DRIVER_MI_ID=%s\n' "$FILE_CSI_DRIVER_MI_ID"
    printf 'FILE_CSI_DRIVER_MI_PID=%s\n' "$FILE_CSI_DRIVER_MI_PID"
    printf 'IMAGE_REGISTRY_MI_ID=%s\n' "$IMAGE_REGISTRY_MI_ID"
    printf 'IMAGE_REGISTRY_MI_PID=%s\n' "$IMAGE_REGISTRY_MI_PID"
    printf 'CLOUD_NETWORK_CONFIG_MI_ID=%s\n' "$CLOUD_NETWORK_CONFIG_MI_ID"
    printf 'CLOUD_NETWORK_CONFIG_MI_PID=%s\n' "$CLOUD_NETWORK_CONFIG_MI_PID"
    printf 'KMS_MI_ID=%s\n' "$KMS_MI_ID"
    printf 'KMS_MI_PID=%s\n' "$KMS_MI_PID"
    printf 'DP_DISK_CSI_DRIVER_MI_ID=%s\n' "$DP_DISK_CSI_DRIVER_MI_ID"
    printf 'DP_FILE_CSI_DRIVER_MI_ID=%s\n' "$DP_FILE_CSI_DRIVER_MI_ID"
    printf 'DP_FILE_CSI_DRIVER_MI_PID=%s\n' "$DP_FILE_CSI_DRIVER_MI_PID"
    printf 'DP_IMAGE_REGISTRY_MI_ID=%s\n' "$DP_IMAGE_REGISTRY_MI_ID"
    printf 'DP_IMAGE_REGISTRY_MI_PID=%s\n' "$DP_IMAGE_REGISTRY_MI_PID"
    printf 'SERVICE_MI_ID=%s\n' "$SERVICE_MI_ID"
    printf 'SERVICE_MI_PID=%s\n' "$SERVICE_MI_PID"
    ```

### Role assignments

1. Export the Azure role definition IDs

    ```bash
    export READER_ROLE="acdd72a7-3385-48ef-bd42-f606fba81ae7"
    export HCP_CLUSTER_API_PROVIDER_ROLE="88366f10-ed47-4cc0-9fab-c8a06148393e"
    export HCP_CONTROL_PLANE_OPERATOR_ROLE="fc0c873f-45e9-4d0d-a7d1-585aab30c6ed"
    export CLOUD_CONTROLLER_MANAGER_ROLE="a1f96423-95ce-4224-ab27-4e3dc72facd4"
    export INGRESS_OPERATOR_ROLE="0336e1d3-7a87-462b-b6db-342b63f7802c"
    export FILE_STORAGE_OPERATOR_ROLE="0d7aedc0-15fd-4a67-a412-efad370c947e"
    export NETWORK_OPERATOR_ROLE="be7a6435-15ae-4171-8f30-4a343eff9e8f"
    export IMAGE_REGISTRY_OPERATOR_ROLE="8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
    export FEDERATED_CREDENTIAL_ROLE="ef318e2a-8334-4a05-9e4a-295a196c6a6e"
    export HCP_SERVICE_MI_ROLE="c0ff367d-66d8-445e-917c-583feb0ef0d4"
    ```

1. Print the exported role definition IDs

    ```bash
    printf 'READER_ROLE=%s\n' "$READER_ROLE"
    printf 'HCP_CLUSTER_API_PROVIDER_ROLE=%s\n' "$HCP_CLUSTER_API_PROVIDER_ROLE"
    printf 'HCP_CONTROL_PLANE_OPERATOR_ROLE=%s\n' "$HCP_CONTROL_PLANE_OPERATOR_ROLE"
    printf 'CLOUD_CONTROLLER_MANAGER_ROLE=%s\n' "$CLOUD_CONTROLLER_MANAGER_ROLE"
    printf 'INGRESS_OPERATOR_ROLE=%s\n' "$INGRESS_OPERATOR_ROLE"
    printf 'FILE_STORAGE_OPERATOR_ROLE=%s\n' "$FILE_STORAGE_OPERATOR_ROLE"
    printf 'NETWORK_OPERATOR_ROLE=%s\n' "$NETWORK_OPERATOR_ROLE"
    printf 'IMAGE_REGISTRY_OPERATOR_ROLE=%s\n' "$IMAGE_REGISTRY_OPERATOR_ROLE"
    printf 'FEDERATED_CREDENTIAL_ROLE=%s\n' "$FEDERATED_CREDENTIAL_ROLE"
    printf 'HCP_SERVICE_MI_ROLE=%s\n' "$HCP_SERVICE_MI_ROLE"
    ```

1. Assign roles to the control plane operator identities

    ```bash
    # Cluster API Azure: ARO HCP Cluster API Provider on the VNet
    az role assignment create --assignee-object-id "${CLUSTER_API_AZURE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${HCP_CLUSTER_API_PROVIDER_ROLE}" --scope "${VNET_ID}"

    # Control Plane: ARO HCP Control Plane Operator on VNet and NSG
    az role assignment create --assignee-object-id "${CONTROL_PLANE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${HCP_CONTROL_PLANE_OPERATOR_ROLE}" --scope "${VNET_ID}"
    az role assignment create --assignee-object-id "${CONTROL_PLANE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${HCP_CONTROL_PLANE_OPERATOR_ROLE}" --scope "${NSG_ID}"

    # Cloud Controller Manager: ARO Cloud Controller Manager on VNet and NSG
    az role assignment create --assignee-object-id "${CLOUD_CONTROLLER_MANAGER_MI_PID}" --assignee-principal-type ServicePrincipal --role "${CLOUD_CONTROLLER_MANAGER_ROLE}" --scope "${NSG_ID}"
    az role assignment create --assignee-object-id "${CLOUD_CONTROLLER_MANAGER_MI_PID}" --assignee-principal-type ServicePrincipal --role "${CLOUD_CONTROLLER_MANAGER_ROLE}" --scope "${VNET_ID}"

    # Ingress: ARO Cluster Ingress Operator on VNet
    az role assignment create --assignee-object-id "${INGRESS_MI_PID}" --assignee-principal-type ServicePrincipal --role "${INGRESS_OPERATOR_ROLE}" --scope "${VNET_ID}"

    # File CSI Driver: ARO File Storage Operator on VNet and NSG
    az role assignment create --assignee-object-id "${FILE_CSI_DRIVER_MI_PID}" --assignee-principal-type ServicePrincipal --role "${FILE_STORAGE_OPERATOR_ROLE}" --scope "${NSG_ID}"
    az role assignment create --assignee-object-id "${FILE_CSI_DRIVER_MI_PID}" --assignee-principal-type ServicePrincipal --role "${FILE_STORAGE_OPERATOR_ROLE}" --scope "${VNET_ID}"

    # Image Registry: ARO Image Registry Operator on VNet
    az role assignment create --assignee-object-id "${IMAGE_REGISTRY_MI_PID}" --assignee-principal-type ServicePrincipal --role "${IMAGE_REGISTRY_OPERATOR_ROLE}" --scope "${VNET_ID}"

    # Cloud Network Config: ARO Network Operator on VNet
    az role assignment create --assignee-object-id "${CLOUD_NETWORK_CONFIG_MI_PID}" --assignee-principal-type ServicePrincipal --role "${NETWORK_OPERATOR_ROLE}" --scope "${VNET_ID}"
    ```

1. Grant the service identity access to networking and control plane identities

    ```bash
    # Service MI: ARO HCP Service Managed Identity on VNet and NSG
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${HCP_SERVICE_MI_ROLE}" --scope "${VNET_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${HCP_SERVICE_MI_ROLE}" --scope "${NSG_ID}"

    # Service MI: Reader on each control plane identity
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${READER_ROLE}" --scope "${CLUSTER_API_AZURE_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${READER_ROLE}" --scope "${CONTROL_PLANE_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${READER_ROLE}" --scope "${CLOUD_CONTROLLER_MANAGER_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${READER_ROLE}" --scope "${INGRESS_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${READER_ROLE}" --scope "${DISK_CSI_DRIVER_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${READER_ROLE}" --scope "${FILE_CSI_DRIVER_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${READER_ROLE}" --scope "${IMAGE_REGISTRY_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${READER_ROLE}" --scope "${CLOUD_NETWORK_CONFIG_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${READER_ROLE}" --scope "${KMS_MI_ID}"
    ```

1. Assign the data plane and federated credential roles

    ```bash
    # Service MI: ARO Federated Credential on each data plane identity
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${FEDERATED_CREDENTIAL_ROLE}" --scope "${DP_DISK_CSI_DRIVER_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${FEDERATED_CREDENTIAL_ROLE}" --scope "${DP_FILE_CSI_DRIVER_MI_ID}"
    az role assignment create --assignee-object-id "${SERVICE_MI_PID}" --assignee-principal-type ServicePrincipal --role "${FEDERATED_CREDENTIAL_ROLE}" --scope "${DP_IMAGE_REGISTRY_MI_ID}"

    # Data Plane File CSI Driver: ARO File Storage Operator on VNet and NSG
    az role assignment create --assignee-object-id "${DP_FILE_CSI_DRIVER_MI_PID}" --assignee-principal-type ServicePrincipal --role "${FILE_STORAGE_OPERATOR_ROLE}" --scope "${NSG_ID}"
    az role assignment create --assignee-object-id "${DP_FILE_CSI_DRIVER_MI_PID}" --assignee-principal-type ServicePrincipal --role "${FILE_STORAGE_OPERATOR_ROLE}" --scope "${VNET_ID}"

    # Data Plane Image Registry: ARO Image Registry Operator on VNet
    az role assignment create --assignee-object-id "${DP_IMAGE_REGISTRY_MI_PID}" --assignee-principal-type ServicePrincipal --role "${IMAGE_REGISTRY_OPERATOR_ROLE}" --scope "${VNET_ID}"
    ```

### Key Vault and etcd encryption

{{% alert state="info" header="Key Vault naming" %}}
These commands use `AZR_KEYVAULT_NAME` from [Define variables](#define-variables). If the name is invalid or already taken, update that variable before retrying. All later vault references use the same variable; the cluster and resource group names can stay as they are.
{{% /alert %}}

1. Create a Key Vault using Azure RBAC

    ```bash
    az keyvault create \
      --name "${AZR_KEYVAULT_NAME}" \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --location "${AZR_RESOURCE_LOCATION}" \
      --enable-rbac-authorization true
    ```

1. Grant your signed-in account permission to create keys

    ```bash
    az role assignment create \
      --role "Key Vault Crypto Officer" \
      --assignee "$(az account show --query user.name -o tsv)" \
      --scope "$(az keyvault show --name "${AZR_KEYVAULT_NAME}" --resource-group "${AZR_RESOURCE_GROUP}" --query id -o tsv)"
    ```

1. Check Key Vault access while the new role assignment propagates

    Role assignments can take several minutes to become effective. Check access to the Key Vault data plane:

    ```bash
    az keyvault key list \
      --vault-name "${AZR_KEYVAULT_NAME}" \
      --output table
    ```

    An empty result is expected for a new vault. If the command returns `Forbidden` or `ForbiddenByRbac`, wait a few minutes and retry. A successful list confirms key-list access; the next command checks permission to create a key. See [Key Vault RBAC guidance](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide).

1. Create the RSA encryption key

    ```bash
    az keyvault key create \
      --vault-name "${AZR_KEYVAULT_NAME}" \
      --name "etcd-kms-key" \
      --kty RSA \
      --size 2048
    ```

    If key creation returns an RBAC authorization error, wait a few minutes and retry this command before continuing.

1. Export the key version

    ```bash
    export KMS_KEY_VERSION=$(az keyvault key show \
      --vault-name "${AZR_KEYVAULT_NAME}" \
      --name "etcd-kms-key" \
      --query "key.kid" --output tsv | rev | cut -d'/' -f1 | rev)
    ```

1. Print the exported key version and confirm that it is not empty

    ```bash
    printf 'KMS_KEY_VERSION=%s\n' "$KMS_KEY_VERSION"
    ```

1. Grant the KMS identity permission to use the key

    ```bash
    export KEY_VAULT_CRYPTO_USER_ROLE="12338af0-0e69-4776-bea7-57ae8d297424"
    export KEYVAULT_ID=$(az keyvault show --name "${AZR_KEYVAULT_NAME}" --query id --output tsv)

    # Confirm the exported values before assigning the role.
    printf 'KEY_VAULT_CRYPTO_USER_ROLE=%s\n' "$KEY_VAULT_CRYPTO_USER_ROLE"
    printf 'KEYVAULT_ID=%s\n' "$KEYVAULT_ID"

    az role assignment create \
      --assignee-object-id "${KMS_MI_PID}" \
      --assignee-principal-type ServicePrincipal \
      --role "${KEY_VAULT_CRYPTO_USER_ROLE}" \
      --scope "${KEYVAULT_ID}"
    ```

    Allow several minutes for this role assignment to propagate before creating the cluster.

### Create the hosted cluster

1. Create the cluster with the networking, identities, and encryption key

    ```bash
    az aro hcp cluster create \
      --name "${AZR_CLUSTER}" \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --location "${AZR_RESOURCE_LOCATION}" \
      --version "${AZR_CLUSTER_VERSION}" \
      --subnet-id "${SUBNET_ID}" \
      --vnet-integration-subnet-id "${VNET_INTEGRATION_SUBNET_ID}" \
      --nsg "${NSG_ID}" \
      --key-management-mode CustomerManaged \
      --kms-vault-name "${AZR_KEYVAULT_NAME}" \
      --vault-visibility Public \
      --kms-active-key "{name:etcd-kms-key,version:${KMS_KEY_VERSION}}" \
      --assign-service-managed-identity "${SERVICE_MI_ID}" \
      --assign-control-plane-operator-identity cluster-api-azure "${CLUSTER_API_AZURE_MI_ID}" \
      --assign-control-plane-operator-identity control-plane "${CONTROL_PLANE_MI_ID}" \
      --assign-control-plane-operator-identity cloud-controller-manager "${CLOUD_CONTROLLER_MANAGER_MI_ID}" \
      --assign-control-plane-operator-identity ingress "${INGRESS_MI_ID}" \
      --assign-control-plane-operator-identity disk-csi-driver "${DISK_CSI_DRIVER_MI_ID}" \
      --assign-control-plane-operator-identity file-csi-driver "${FILE_CSI_DRIVER_MI_ID}" \
      --assign-control-plane-operator-identity image-registry "${IMAGE_REGISTRY_MI_ID}" \
      --assign-control-plane-operator-identity cloud-network-config "${CLOUD_NETWORK_CONFIG_MI_ID}" \
      --assign-control-plane-operator-identity kms "${KMS_MI_ID}" \
      --assign-data-plane-operator-identity disk-csi-driver "${DP_DISK_CSI_DRIVER_MI_ID}" \
      --assign-data-plane-operator-identity file-csi-driver "${DP_FILE_CSI_DRIVER_MI_ID}" \
      --assign-data-plane-operator-identity image-registry "${DP_IMAGE_REGISTRY_MI_ID}"
    ```

    The `az aro hcp cluster create` command takes approximately 10 to 15 minutes to complete. Wait for it to finish before continuing.

1. Check cluster provisioning; wait for `Succeeded` before creating the node pool

    ```bash
    az aro hcp cluster show \
      --name "${AZR_CLUSTER}" \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --query "properties.provisioningState" \
      --output tsv
    ```

### Create the worker node pool

1. Create two `Standard_D8s_v6` worker nodes

    ```bash
    az aro hcp cluster nodepool create \
      --cluster-name "${AZR_CLUSTER}" \
      --name "default-workers" \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --replicas 2 \
      --vm-size Standard_D8s_v6 \
      --version "${AZR_NODE_POOL_VERSION}"
    ```

1. Check node pool provisioning; successful deployment reports `Succeeded`

    ```bash
    az aro hcp cluster nodepool show \
      --cluster-name "${AZR_CLUSTER}" \
      --name "default-workers" \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --query "properties.provisioningState" \
      --output tsv
    ```

## Set up CLI access

Use the same shell and exported cluster variables from the deployment steps, with the [OpenShift CLI](#openshift-cli) installed. If your cluster has a private API server, run CLI commands from a host with network connectivity to the cluster's virtual network.

1. Confirm the active subscription matches the one used for deployment

    Show the active subscription and tenant. If the subscription is incorrect, select the deployment subscription using `az account set --subscription "<id-or-name>"` before continuing.

    ```bash
    az account show \
      --query "{Subscription:name,SubscriptionID:id,TenantID:tenantId}" \
      --output table
    ```

1. Request an administrative credential and save it to a kubeconfig file

    ```bash
    az aro hcp cluster request-credential \
      --admin \
      --name "${AZR_CLUSTER}" \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --file kubeconfig
    ```

    Administrative credentials expire after 24 hours. Request a new credential when needed.

1. Set the kubeconfig file for CLI commands and print the configured path

    ```bash
    export KUBECONFIG=kubeconfig
    printf 'KUBECONFIG=%s\n' "$KUBECONFIG"
    ```

1. Verify access by listing the worker nodes

    ```bash
    oc get nodes
    ```

    Expected output (node names, ages, and versions will vary):

    ```text
    NAME                                  STATUS   ROLES    AGE   VERSION
    cluster-default-workers-nwxcr-6md49   Ready    worker   29m   v1.35.9
    cluster-default-workers-nwxcr-dlnmh   Ready    worker   29m   v1.35.9
    ```

    After node pool provisioning completes, the two worker nodes should report `Ready`.

## Configure OIDC authentication for console access

Unlike ARO Classic, ARO HCP does not include the built-in OpenShift OAuth server. There is no built-in `kubeadmin` user or support for an `htpasswd` identity provider. Console sign-in requires an external identity provider; the temporary administrative kubeconfig from the previous section provides initial CLI access. See the [ARO HCP authentication model](https://www.redhat.com/architect/portfolio/detail/134-openshift-external-auth/03-aro.html).

Integrating external OpenID Connect (OIDC) providers directly with ARO HCP supports machine-to-machine workflows, such as automated CLI access, and offers authentication capabilities unavailable through the built-in OAuth server. This guide configures Microsoft Entra ID for console and CLI sign-in, following [Configure an external authentication provider](https://learn.microsoft.com/en-us/azure/openshift/howto-configure-external-authentication).

Continue in the same shell, using `AZR_CLUSTER`, `AZR_RESOURCE_GROUP`, and the temporary administrative kubeconfig from [Set up CLI access](#set-up-cli-access). You also need permission to register applications in your Microsoft Entra tenant. If users cannot register applications, ask your tenant administrator for the **Application Developer** or **Application Administrator** role.

### Prepare authentication variables

Set the provider name and derive the application name and issuer URL from your existing cluster and Azure account:

```bash
export EXTERNAL_AUTH_DISPLAY_NAME="${AZR_CLUSTER}-auth"
export EXTERNAL_AUTH_NAME="entra"
export TENANT_ID=$(az account show --query tenantId --output tsv)
export ISSUER_URL="https://login.microsoftonline.com/${TENANT_ID}/v2.0"
```

Print the exported values:

```bash
printf 'EXTERNAL_AUTH_DISPLAY_NAME=%s\n' "$EXTERNAL_AUTH_DISPLAY_NAME"
printf 'EXTERNAL_AUTH_NAME=%s\n' "$EXTERNAL_AUTH_NAME"
printf 'TENANT_ID=%s\n' "$TENANT_ID"
printf 'ISSUER_URL=%s\n' "$ISSUER_URL"
```

### Register the Microsoft Entra application

1. Get the console URL and construct its authentication callback URL

    ```bash
    export CONSOLE_URL=$(az aro hcp cluster show \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --name "${AZR_CLUSTER}" \
      --query properties.console.url --output tsv)
    export CONSOLE_CALLBACK_URL="${CONSOLE_URL%/}/auth/callback"
    ```

1. Print the exported URLs and confirm that neither is empty

    ```bash
    printf 'CONSOLE_URL=%s\n' "$CONSOLE_URL"
    printf 'CONSOLE_CALLBACK_URL=%s\n' "$CONSOLE_CALLBACK_URL"
    ```

1. Register an application with redirects for the console and CLI

    The console uses its authentication callback URL. CLI sign-in uses `http://localhost:8000`.

    ```bash
    export CLIENT_ID=$(az ad app create \
      --display-name "${EXTERNAL_AUTH_DISPLAY_NAME}" \
      --web-redirect-uris "${CONSOLE_CALLBACK_URL}" http://localhost:8000 \
      --query appId --output tsv)
    ```

1. Print the application ID and confirm that it is not empty

    ```bash
    printf 'CLIENT_ID=%s\n' "$CLIENT_ID"
    ```

1. Create a client secret and retain it in the shell for the remaining steps

    ```bash
    CLIENT_SECRET=$(az ad app credential reset \
      --id "${CLIENT_ID}" \
      --query password --output tsv)
    ```

    The Azure CLI displays a notice that the output contains credentials. The assignment stores the secret without printing it.

### Create the external authentication provider

1. Configure the issuer, claim mappings, and console and CLI clients

    The username mapping uses `preferred_username` without a prefix. The group mapping uses the `groups` claim when present.

    ```bash
    az aro hcp cluster external-auth create \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --cluster-name "${AZR_CLUSTER}" \
      --name "${EXTERNAL_AUTH_NAME}" \
      --issuer-url "${ISSUER_URL}" \
      --issuer-audience "[${CLIENT_ID}]" \
      --claim groups \
      --username-claim preferred_username \
      --username-prefix-policy NoPrefix \
      --client client-id="${CLIENT_ID}" component-name=console auth-client-namespace=openshift-console extra-scopes="[profile]" type=Confidential \
      --client client-id="${CLIENT_ID}" component-name=cli auth-client-namespace=openshift-console extra-scopes="[profile]" type=Public
    ```

1. Verify the provider configuration

    ```bash
    az aro hcp cluster external-auth show \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --cluster-name "${AZR_CLUSTER}" \
      --name "${EXTERNAL_AUTH_NAME}"
    ```

### Configure the console secret and user permissions

Use the temporary administrative kubeconfig from the CLI access section for these commands. If that credential has expired, request it again before continuing.

1. Create the console client secret in OpenShift

    ```bash
    oc create secret generic "${EXTERNAL_AUTH_NAME}-console-openshift-console" \
      --namespace openshift-config \
      --from-literal=clientSecret="${CLIENT_SECRET}"
    ```

1. Look up the user principal name for the user who will administer the cluster

    Replace `<user-email>` with that user's Microsoft Entra email address.

    ```bash
    export USER_NAME=$(az ad user show \
      --id "<user-email>" \
      --query userPrincipalName --output tsv)
    ```

1. Print the user principal name and confirm that it identifies the intended user

    ```bash
    printf 'USER_NAME=%s\n' "$USER_NAME"
    ```

1. Grant the user the `cluster-admin` role

    Signing in establishes identity; RBAC determines permissions. This binding grants the selected user full administrative access to the cluster.

    ```bash
    oc apply -f - <<EOF
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: aro-admin
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: cluster-admin
    subjects:
      - apiGroup: rbac.authorization.k8s.io
        kind: User
        name: "${USER_NAME}"
    EOF
    ```

Optionally, [restrict the Entra application to selected users or groups](https://learn.microsoft.com/en-us/entra/identity-platform/howto-restrict-your-app-to-a-set-of-users). Application access and OpenShift RBAC permissions are configured separately.

### Validate console access

Print the console URL obtained earlier:

```bash
printf 'OpenShift console: %s\n' "$CONSOLE_URL"
```

Open that URL in your browser and sign in with the Microsoft Entra user granted access above.

### Validate OIDC access with the OpenShift CLI

Use the [OpenShift CLI](#openshift-cli) installed in the prerequisites. This workflow requires its built-in `oc-oidc` credential plugin.

1. Get the cluster API URL

    ```bash
    export API_URL=$(az aro hcp cluster show \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --name "${AZR_CLUSTER}" \
      --query properties.api.url --output tsv)
    ```

1. Print the API URL and confirm that it is not empty

    ```bash
    printf 'API_URL=%s\n' "$API_URL"
    ```

1. Sign in through Microsoft Entra ID

    ```bash
    oc login "${API_URL}" \
      --exec-plugin=oc-oidc \
      --client-id="${CLIENT_ID}" \
      --client-secret="${CLIENT_SECRET}" \
      --issuer-url="${ISSUER_URL}" \
      --extra-scopes=profile \
      --callback-port=8000
    ```

    Open the URL printed by the command and complete sign-in in your browser.

1. Verify the authenticated identity

    ```bash
    oc auth whoami
    ```

    Example output (the username and groups will vary):

    ```text
    ATTRIBUTE    VALUE
    Username     user@email.com
    Groups       [system:authenticated]
    ```

1. Clear the client secret from the shell after validating access

    ```bash
    unset CLIENT_SECRET
    ```

## Next steps

See [Connect to an ARO HCP cluster](https://learn.microsoft.com/en-us/azure/openshift/connect-hosted-control-planes-cluster) for more connection details.

### Optional: additional registry credentials

The [Microsoft HCP quickstart](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster?pivots=aro-az-cli) does not require a customer-provided Red Hat pull secret for cluster creation.

After connecting, add credentials if your workloads or Operators need authenticated access to `registry.redhat.io` or another private registry. Follow [Add pull secrets to access private registries](https://learn.microsoft.com/en-us/azure/openshift/how-to-add-pull-secrets), which uses a Secret named `additional-pull-secret` in the `kube-system` namespace.

### Clean up

Use the same shell and exported variables from this guide. If you opened a new shell, set `AZR_CLUSTER`, `AZR_RESOURCE_GROUP`, `AZR_KEYVAULT_NAME`, and `AZR_RESOURCE_LOCATION` to the values used during deployment.

If you completed the OIDC setup, also retain or restore `EXTERNAL_AUTH_NAME` (`entra` in this guide) and `CLIENT_ID` (the application ID returned by `az ad app create`). The Microsoft Entra application registration exists outside the Azure resource group and must be deleted separately.

1. Delete the external authentication provider, if configured

    Run this before deleting the cluster:

    ```bash
    az aro hcp cluster external-auth delete \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --cluster-name "${AZR_CLUSTER}" \
      --name "${EXTERNAL_AUTH_NAME}"
    ```

    Confirm the deletion when prompted and wait for the command to finish. Console and OIDC CLI sign-in will stop working; the remaining cleanup commands use Azure CLI authentication. See [`az aro hcp cluster external-auth delete`](https://learn.microsoft.com/en-us/cli/azure/aro/hcp/cluster/external-auth#az-aro-hcp-cluster-external-auth-delete).

1. Delete the cluster

    ```bash
    az aro hcp cluster delete \
      --name "${AZR_CLUSTER}" \
      --resource-group "${AZR_RESOURCE_GROUP}"
    ```

    Confirm the deletion when prompted. This also removes the node pools and managed resource group, but leaves the resources in your customer resource group. See [Delete an ARO HCP cluster](https://learn.microsoft.com/en-us/azure/openshift/delete-hosted-control-planes-cluster).

    The console client secret in `openshift-config` and the `aro-admin` ClusterRoleBinding are removed with the cluster.

1. Verify that cluster deletion has completed before deleting its encryption key

    ```bash
    az aro hcp cluster show \
      --name "${AZR_CLUSTER}" \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --query "properties.provisioningState" \
      --output tsv
    ```

    Continue only when the command reports that the cluster resource was not found. If it still reports a provisioning state, wait and check again. Resolve authentication or permission errors before proceeding.

1. Delete the Microsoft Entra application registration, if created

    Confirm that `CLIENT_ID` identifies the application created for this guide:

    ```bash
    az ad app show \
      --id "${CLIENT_ID}" \
      --query "{Name:displayName,ClientID:appId}" \
      --output table
    ```

    Delete that application registration and its client credentials:

    ```bash
    az ad app delete --id "${CLIENT_ID}"
    ```

    This requires permission to delete the application in Microsoft Entra ID. Deleting the cluster or resource group does not remove this registration. See [`az ad app delete`](https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-delete).

1. Delete the customer-managed KMS key

    Show the key ID and confirm that it contains the intended vault and key name:

    ```bash
    az keyvault key show \
      --vault-name "${AZR_KEYVAULT_NAME}" \
      --name "etcd-kms-key" \
      --query key.kid --output tsv
    ```

    Delete the confirmed key:

    ```bash
    az keyvault key delete \
      --vault-name "${AZR_KEYVAULT_NAME}" \
      --name "etcd-kms-key"
    ```

    This deletes all versions of the key. The **Key Vault Crypto Officer** role assigned earlier permits this operation. Keep the key until cluster deletion is complete. See [`az keyvault key delete`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key#az-keyvault-key-delete).

1. Delete the customer resource group and its remaining resources

    Review the resources before deleting the group:

    ```bash
    az resource list \
      --resource-group "${AZR_RESOURCE_GROUP}" \
      --output table
    ```

    Delete the group only if you no longer need any of its resources. This removes the virtual network, subnets, NSG, managed identities, and Key Vault created in this guide.

    ```bash
    az group delete --name "${AZR_RESOURCE_GROUP}"
    ```

    Confirm the deletion when prompted and wait for the command to finish. Verify that the group is gone:

    ```bash
    az group exists --name "${AZR_RESOURCE_GROUP}"
    ```

    The expected result is `false`.

1. Optional: permanently remove the deleted Key Vault

    [Key Vault soft delete](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview) retains the deleted vault and keys for the configured retention period (90 days by default). The vault name remains reserved during that period.

    If you need to reuse the vault name immediately, have permission to purge the vault, and no longer need to recover it or its keys, run:

    ```bash
    az keyvault purge \
      --name "${AZR_KEYVAULT_NAME}" \
      --location "${AZR_RESOURCE_LOCATION}"
    ```

    Purging is irreversible and requires subscription-level permission, such as **Key Vault Purge Operator**. If purge protection is enabled, you must wait until the retention period expires. See [`az keyvault purge`](https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-purge).
