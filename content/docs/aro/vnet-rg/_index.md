---
date: '2023-02-08'
title: ARO in Separate VNet Resource Group
tags: ["ARO", "Azure"]
---

In a default ARO installation, the virtual network (VNet) lives in the same resource group as ARO. You have the option to specify a separate VNet resource group during installation. This may be necessary if you need to deploy ARO in a network controlled by a different team.

This document will guide you through deploying ARO in a separate VNet resource group.

Author: [Chris Kang](https://github.com/theckang)

*Adopted from [ARO Quickstart](https://mobb.ninja/docs/quickstart-aro/)*

*Last modified 02/08/2023* 

## Prerequisites
* az cli
* jq
* [Minimum CPU Quota](https://mobb.ninja/docs/quickstart-aro/#adding-quota-to-aro-account)
* [Red Hat Pull Secret](https://mobb.ninja/docs/quickstart-aro/#get-red-hat-pull-secret)

## Deploy

### Setup Azure Environment

1. Login to Azure CLI

   ```bash
   az login
   ```

1. Register resource providers

   ```bash
   az provider register -n Microsoft.RedHatOpenShift --wait
   az provider register -n Microsoft.Compute --wait
   az provider register -n Microsoft.Storage --wait
   az provider register -n Microsoft.Authorization --wait
   ``` 

1. Set environment variables

   > ARO must be in the same region as the VNet region

   ```bash
   AZR_SUB_ID=$(az account show --query id -o tsv) 
   AZR_SP_NAME=aro-sp
   AZR_RESOURCE_LOCATION=eastus 
   AZR_CLUSTER=cluster
   AZR_PULL_SECRET=~/Downloads/pull-secret.txt
   AZR_ARO_RG=aro-rg
   AZR_VNET_RG=vnet-rg
   ```

### Resource Groups and Service Principal

1. Create ARO resource group

   ```bash
    az group create \
      --name $AZR_ARO_RG \
      --location $AZR_RESOURCE_LOCATION   
   ```

1. Create VNet resource group

   > Skip this if VNet already exists

    ```bash
    az group create \
      --name $AZR_VNET_RG \
      --location $AZR_RESOURCE_LOCATION
    ```

1. Create service principal with Contributor access to both resource groups

   ```bash
   AZR_SP=$(az ad sp create-for-rbac -n $AZR_SP_NAME --role contributor --output json \
     --scopes /subscriptions/${AZR_SUB_ID}/resourceGroups/${AZR_ARO_RG} \
              /subscriptions/${AZR_SUB_ID}/resourceGroups/${AZR_VNET_RG})
   ```

1. Set environment variables for service principal
   
   ```bash
   AZR_SP_APP_ID=$(echo $AZR_SP | jq -r '.appId')
   AZR_SP_PASSWORD=$(echo $AZR_SP | jq -r '.password')
   ```

### Networking

> Skip this if VNet subnets were already configured

1. Create virtual network

    ```bash
    az network vnet create \
      --address-prefixes 10.0.0.0/22 \
      --name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --resource-group $AZR_VNET_RG
    ```

1. Create control plane subnet

    ```bash
    az network vnet subnet create \
      --resource-group $AZR_VNET_RG \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --address-prefixes 10.0.0.0/23 \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. Create machine subnet

    ```bash
    az network vnet subnet create \
      --resource-group $AZR_VNET_RG \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
      --address-prefixes 10.0.2.0/23 \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. Disable network policies on the control plane subnet

    > This is required for the service to be able to connect to and manage the cluster.

    ```bash
    az network vnet subnet update \
      --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --resource-group $AZR_VNET_RG \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --disable-private-link-service-network-policies true
    ```

### Create Cluster

1. Create the cluster

    > This will take between 30 and 45 minutes.

    ```bash
    az aro create \
      --resource-group $AZR_ARO_RG \
      --vnet-resource-group $AZR_VNET_RG \
      --client-id $AZR_SP_APP_ID \
      --client-secret $AZR_SP_PASSWORD \
      --name $AZR_CLUSTER \
      --vnet "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --master-subnet "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --worker-subnet "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
      --pull-secret @$AZR_PULL_SECRET
    ```

1. Check cluster resource group
    
    ```bash
    az aro show \
      --name $AZR_CLUSTER \
      --resource-group $AZR_ARO_RG \
      --query "resourceGroup" -o tsv
    ```

    This should return the ARO resource group.

1. Check cluster's control plane subnet

   ```bash
    az aro show \
      --name $AZR_CLUSTER \
      --resource-group $AZR_ARO_RG \
      --query "masterProfile.subnetId" -o tsv   
   ```

   The subnet should belong to the VNet resource group.

### Delete Cluster

Once you're done its a good idea to delete the cluster to ensure that you don't get a surprise bill.

1. Delete the cluster

    ```bash
    az aro delete -y \
      --resource-group $AZR_ARO_RG \
      --name $AZR_CLUSTER
    ```

1. Delete the App Registration and Service Principal

   ```bash
   az ad app delete --id $AZR_SP_APP_ID
   ```

1. Delete the Azure resource group

    > Only do this if there's nothing else in the resource group.

    ```bash
    az group delete -y \
      --name $AZR_ARO_RG
    ```

1. Delete the VNet resource group

    > Only do this if there's nothing else in the resource group.

    ```bash
    az group delete -y \
      --name $AZR_VNET_RG
    ```
