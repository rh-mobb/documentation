#!/bin/bash

AZR_RESOURCE_LOCATION=eastus
AZR_RESOURCE_GROUP=${USER}-openshift
AZR_CLUSTER=${USER}-cluster
AZR_PULL_SECRET=~/Downloads/pull-secret.txt

echo "==> Create Infrastructure"

echo "----> Create resource group"
az group create \
  --name $AZR_RESOURCE_GROUP \
  --location $AZR_RESOURCE_LOCATION

echo "----> Create virtual network"
az network vnet create \
  --address-prefixes 10.0.0.0/22 \
  --name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
  --resource-group $AZR_RESOURCE_GROUP

echo "----> Create control plane subnet"
az network vnet subnet create \
   --resource-group $AZR_RESOURCE_GROUP \
   --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
   --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
   --address-prefixes 10.0.0.0/23 \
   --service-endpoints Microsoft.ContainerRegistry

echo "----> Create machine subnet subnet"
az network vnet subnet create \
   --resource-group $AZR_RESOURCE_GROUP \
   --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
   --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
   --address-prefixes 10.0.2.0/23 \
   --service-endpoints Microsoft.ContainerRegistry

echo "----> Update control plane subnet to disable private link service network policies"
   az network vnet subnet update \
   --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
   --resource-group $AZR_RESOURCE_GROUP \
   --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
   --disable-private-link-service-network-policies true

az aro create \
   --resource-group $AZR_RESOURCE_GROUP \
   --name $AZR_CLUSTER \
   --vnet "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
   --master-subnet "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
   --worker-subnet "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
   --pull-secret @$AZR_PULL_SECRET #--sdn-type "OVNKubernetes"

az aro show \
   --name $AZR_CLUSTER \
   --resource-group $AZR_RESOURCE_GROUP \
   -o tsv --query consoleProfile

az aro list-credentials \
   --name $AZR_CLUSTER \
   --resource-group $AZR_RESOURCE_GROUP \
   -o tsv
