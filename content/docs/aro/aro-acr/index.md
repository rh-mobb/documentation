---
date: '2023-06-08T22:07:09.774151'
title: Using Azure Container Registry in Private ARO clusters
tags: ["ARO", "Azure"]
authors:
  - Roberto Carratalá
---

This guide describes how configure and deploy an Azure Container Registry, limiting the access to the registry and connecting privately from a Private ARO cluster, eliminating exposure from the public internet. 

You can limit access to the ACR by assigning virtual network private IP addresses to the registry endpoints and using [Azure Private Link](https://learn.microsoft.com/en-us/azure/private-link/private-link-overview). 

Network traffic between the Private ARO cluster and the registry's private endpoints traverses the virtual network and a private link on the Microsoft backbone network, eliminating exposure from the public internet.

>NOTE: If you are interested in deploy and integrate an ACR with a public endpoint and connect them into an ARO cluster follow the Use [ACR with ARO guide](https://learn.microsoft.com/en-us/azure/openshift/howto-use-acr-with-aro). 

## Prepare your ARO cluster

1. [Deploy a Private ARO cluster](/docs/private-cluster)

1. Set some environment variables

   ```bash
   export NAMESPACE=aro-acr
   export AZR_RESOURCE_LOCATION=eastus
   export AZR_RESOURCE_GROUP=aro-mobb-rg
   export ACR_NAME=acr$((RANDOM))
   export PRIVATEENDPOINTSUBNET_PREFIX="10.0.8.0/23"
   export PRIVATEENDPOINTSUBNET_NAME="PrivateEndpoint-subnet"
   export ARO_VNET_NAME="aro-rcarrata-vnet"
   ```

## Create ACR and restrict the access using Private Endpoint

You can limit access to the ACR instance by assigning virtual network private IP addresses to the registry endpoints and using Azure Private Link. 

Network traffic between the clients on the virtual network and the registry's private endpoints traverses the virtual network and a private link on the Microsoft backbone network, eliminating exposure from the public internet. Private Link also enables private registry access from on-premises through Azure ExpressRoute private peering or a VPN gateway.

Also, you can configure DNS settings for the registry's private endpoints, so that the settings resolve to the registry's allocated private IP address. With DNS configuration, clients and services in the network can continue to access the registry at the registry's fully qualified domain name, such as myaroacr.azurecr.io.

1. Register the resource provider for Azure Container Registry in that subscription:

  ```bash
  az provider register --namespace Microsoft.ContainerRegistry
  ```

1. Create PrivateEndpoint-subnet for allocate the ACR PrivateEndpoint resources (among others):

   ```bash
   az network vnet subnet create \
   --resource-group $AZR_RESOURCE_GROUP \
   --vnet-name $ARO_VNET_NAME \
   --name $PRIVATEENDPOINTSUBNET_NAME \
   --address-prefixes $PRIVATEENDPOINTSUBNET_PREFIX \
   --disable-private-endpoint-network-policies
   ```

>NOTE: Disable network policies such as network security groups in the subnet for the private endpoint it's needed for the integration with Private Endpoint in this scenario.

1. Create the Azure Container Registry disabling the public network access for the container registry:

   ```bash
   az acr create \
   --resource-group $AZR_RESOURCE_GROUP \
   --name $ACR_NAME \
   --sku Premium \
   --public-network-enabled false \
   --admin-enabled true
   ```

1. Create a private Azure DNS zone for the private Azure container registry domain:

  ```bash
  az network private-dns zone create \
    --resource-group $AZR_RESOURCE_GROUP \
    --name 'privatelink.azurecr.io'
  ```

>NOTE: To use a private zone to override the default DNS resolution for your Azure container registry, the zone must be named `privatelink.azurecr.io`.

1. Associate your private zone with the virtual network:

  ```bash
  az network private-dns link vnet create \
    --resource-group $AZR_RESOURCE_GROUP \
    --name 'AcrDNSLink' \
    --zone-name 'privatelink.azurecr.io' \
    --virtual-network $ARO_VNET_NAME \
    --registration-enabled false
  ```

1. Get the resource ID of your registry:

  ```
  REGISTRY_ID=$(az acr show -n $ACR_NAME --query 'id' -o tsv)
  ```

1. Create the registry's private endpoint in the virtual network: 

  ```bash
  az network private-endpoint create \
    --name 'acrPvtEndpoint' \
    --resource-group $AZR_RESOURCE_GROUP \
    --vnet-name $ARO_VNET_NAME \
    --subnet $PRIVATEENDPOINTSUBNET_NAME \
    --private-connection-resource-id $REGISTRY_ID \
    --group-id 'registry' \
    --connection-name 'acrConnection'
  ```

1. Create a DNS zone group for a private endpoint in Azure Container Registry (ACR):

  ```bash
  az network private-endpoint dns-zone-group create \
    --name 'ACR-ZoneGroup' \
    --resource-group $AZR_RESOURCE_GROUP \
    --endpoint-name 'acrPvtEndpoint' \
    --private-dns-zone 'privatelink.azurecr.io' \
    --zone-name 'ACR'
  ```

1. Query the Private Endpoint for the Network Interface ID:

  ```bash
  NETWORK_INTERFACE_ID=$(az network private-endpoint show \
    --name 'acrPvtEndpoint' \
    --resource-group $AZR_RESOURCE_GROUP \
    --query 'networkInterfaces[0].id' \
    --output tsv)
  ```

1. Get the FQDN of the ACR:

  ```bash
  REGISTRY_FQDN=$(az network nic show \
    --ids $NETWORK_INTERFACE_ID \
    --query "ipConfigurations[?privateLinkConnectionProperties.requiredMemberName=='registry'].privateLinkConnectionProperties.fqdns" \
    --output tsv)
  ```

1. Get the Private IP address of the ACR:

  ```bash
  REGISTRY_PRIVATE_IP=$(az network nic show \
    --ids $NETWORK_INTERFACE_ID \
    --query "ipConfigurations[?privateLinkConnectionProperties.requiredMemberName=='registry'].privateIPAddress" \
    -o tsv)
  ```