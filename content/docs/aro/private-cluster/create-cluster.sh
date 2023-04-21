#!/bin/bash

set -ex

export AZR_RESOURCE_LOCATION=eastus
export AZR_RESOURCE_GROUP=${USER}-openshift
export AZR_CLUSTER=${USER}-private
export AZR_PULL_SECRET=~/Downloads/pull-secret.txt
export NETWORK_SUBNET=10.0.0.0/20
export CONTROL_SUBNET=10.0.0.0/24
export MACHINE_SUBNET=10.0.1.0/24
export FIREWALL_SUBNET=10.0.2.0/24
export JUMPHOST_SUBNET=10.0.3.0/24

echo "==> Create Infrastructure"

echo "----> Create resource group"
az group create \
  --name $AZR_RESOURCE_GROUP \
  --location $AZR_RESOURCE_LOCATION

echo "----> Create virtual network"
az network vnet create \
  --address-prefixes $NETWORK_SUBNET \
  --name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
  --resource-group $AZR_RESOURCE_GROUP

echo "----> Create control plane subnet"
az network vnet subnet create \
   --resource-group $AZR_RESOURCE_GROUP \
   --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
   --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
   --address-prefixes $CONTROL_SUBNET \
   --service-endpoints Microsoft.ContainerRegistry

echo "----> Create machine subnet subnet"
az network vnet subnet create \
   --resource-group $AZR_RESOURCE_GROUP \
   --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
   --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
   --address-prefixes $MACHINE_SUBNET \
   --service-endpoints Microsoft.ContainerRegistry

echo "----> Update control plane subnet to disable private link service network policies"
   az network vnet subnet update \
   --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
   --resource-group $AZR_RESOURCE_GROUP \
   --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
   --disable-private-link-service-network-policies true

echo "==> Configure firewall"

echo "----> Create firewall subnet"
az network vnet subnet create \
 -g $AZR_RESOURCE_GROUP \
 --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
 -n "AzureFirewallSubnet" \
 --address-prefixes $FIREWALL_SUBNET
az network public-ip create -g $AZR_RESOURCE_GROUP -n fw-ip \
  --sku "Standard" --location $AZR_RESOURCE_LOCATION
az network firewall create -g $AZR_RESOURCE_GROUP \
  -n aro-private -l $AZR_RESOURCE_LOCATION

echo "----> create firewall"
az network firewall ip-config create -g $AZR_RESOURCE_GROUP \
  -f aro-private -n fw-config --public-ip-address fw-ip \
     --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"

FWPUBLIC_IP=$(az network public-ip show -g $AZR_RESOURCE_GROUP -n fw-ip --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $AZR_RESOURCE_GROUP -n aro-private --query "ipConfigurations[0].privateIpAddress" -o tsv)

echo "----> Create route table"
az network route-table create -g $AZR_RESOURCE_GROUP --name aro-udr
sleep 10


echo "----> Configure route tables"
az network route-table route create -g $AZR_RESOURCE_GROUP --name aro-udr \
--route-table-name aro-udr --address-prefix 0.0.0.0/0 \
--next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP

az network route-table route create -g $AZR_RESOURCE_GROUP --name aro-vnet \
--route-table-name aro-udr --address-prefix 10.0.0.0/16 --name local-route \
--next-hop-type VirtualNetworkGateway

az network firewall network-rule create -g $AZR_RESOURCE_GROUP -f aro-private \
      --collection-name 'allow-https' --name allow-all \
      --action allow --priority 100 \
      --source-addresses '*' --dest-addr '*' \
      --protocols 'Any' --destination-ports 1-65535

az network vnet subnet update -g $AZR_RESOURCE_GROUP \
  --vnet-name $AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION \
  --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
  --route-table aro-udr

az network vnet subnet update -g $AZR_RESOURCE_GROUP \
  --vnet-name $AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION \
  --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
  --route-table aro-udr

echo "==> Create jumphost"
az network vnet subnet create \
  --resource-group $AZR_RESOURCE_GROUP \
  --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
  --name JumpSubnet \
  --address-prefixes $JUMPHOST_SUBNET \
  --service-endpoints Microsoft.ContainerRegistry

az vm create --name jumphost \
    --resource-group $AZR_RESOURCE_GROUP \
    --ssh-key-values $HOME/.ssh/id_rsa.pub \
    --admin-username aro \
    --image "RedHat:RHEL:9_1:9.1.2022112113" \
    --subnet JumpSubnet \
    --public-ip-sku Standard \
    --public-ip-address jumphost-ip \
    --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"

JUMP_IP=$(az vm list-ip-addresses -g $AZR_RESOURCE_GROUP -n jumphost -o tsv \
  --query '[].virtualMachine.network.publicIpAddresses[0].ipAddress')

echo "==> Create cluster"
az aro create \
   --resource-group $AZR_RESOURCE_GROUP \
   --name $AZR_CLUSTER \
   --vnet "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
   --master-subnet "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
   --worker-subnet "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
   --apiserver-visibility Private \
   --ingress-visibility Private \
   --pull-secret @$AZR_PULL_SECRET

az aro show \
   --name $AZR_CLUSTER \
   --resource-group $AZR_RESOURCE_GROUP \
   -o tsv --query consoleProfile

az aro list-credentials \
   --name $AZR_CLUSTER \
   --resource-group $AZR_RESOURCE_GROUP \
   -o tsv

echo "==> Post Install Steps"


echo run the following to create a socks proxy for the cluster
echo    ssh -D 1337 -C -i $HOME/.ssh/id_rsa aro@$JUMP_IP

echo or run the following to create a sshuttle based vpn
echo    sshuttle --dns -NHr aro@$JUMP_IP $NETWORK_SUBNET
