#!/bin/bash

set -eox

export NAME=${NAME:-"aro-demo"}

export AZR_RESOURCE_LOCATION=eastus
export AZR_RESOURCE_GROUP="${NAME}-rg"
export AZR_CLUSTER="${NAME}"
export NETWORK_SUBNET=10.0.0.0/20
export CONTROL_SUBNET=10.0.0.0/24
export MACHINE_SUBNET=10.0.1.0/24

az group create                \
  --name $AZR_RESOURCE_GROUP   \
  --location $AZR_RESOURCE_LOCATION

az network public-ip create -g $AZR_RESOURCE_GROUP \
  -n $AZR_CLUSTER-natgw-ip   \
  --sku "Standard" --location $AZR_RESOURCE_LOCATION

az network nat gateway create \
  --resource-group ${AZR_RESOURCE_GROUP} \
  --name "${AZR_CLUSTER}-natgw" \
  --location ${AZR_RESOURCE_LOCATION} \
  --public-ip-addresses "${AZR_CLUSTER}-natgw-ip"

az network vnet create                                    \
  --address-prefixes $NETWORK_SUBNET                      \
  --name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"   \
  --resource-group $AZR_RESOURCE_GROUP

az network vnet subnet create                                     \
  --resource-group $AZR_RESOURCE_GROUP                            \
  --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"      \
  --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
  --address-prefixes $CONTROL_SUBNET                              \
  --service-endpoints Microsoft.ContainerRegistry

az network vnet subnet create                                       \
  --resource-group $AZR_RESOURCE_GROUP                              \
  --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"        \
  --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION"   \
  --address-prefixes $MACHINE_SUBNET                                \
  --service-endpoints Microsoft.ContainerRegistry

az network vnet subnet update                                       \
  --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION"   \
  --resource-group $AZR_RESOURCE_GROUP                              \
  --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"        \
  --disable-private-link-service-network-policies true              \
  --nat-gateway "${AZR_CLUSTER}-natgw"

az network vnet subnet update                                           \
  --name "${AZR_CLUSTER}-aro-machine-subnet-${AZR_RESOURCE_LOCATION}"   \
  --resource-group ${AZR_RESOURCE_GROUP}                                \
  --vnet-name "${AZR_CLUSTER}-aro-vnet-${AZR_RESOURCE_LOCATION}"        \
  --nat-gateway "${AZR_CLUSTER}-natgw"

az aro create                                                            \
--resource-group $AZR_RESOURCE_GROUP                                     \
--name $AZR_CLUSTER                                                      \
--vnet "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"                    \
--master-subnet "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
--worker-subnet "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
--apiserver-visibility Private                                           \
--ingress-visibility Private


az group delete                \
  --name $AZR_RESOURCE_GROUP
