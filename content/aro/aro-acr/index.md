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

>NOTE: If you are interested in deploy and integrate an ACR with a public endpoint and connect them into an ARO cluster follow the [How-to Use ACR with ARO guide](https://learn.microsoft.com/en-us/azure/openshift/howto-use-acr-with-aro). 

## Prepare your ARO cluster

1. [Deploy a Private ARO cluster](/experts/private-cluster)

1. Set some environment variables

   ```bash
   export NAMESPACE=aro-acr
   export AZR_CLUSTER=aro-mobb
   export AZR_RESOURCE_LOCATION=eastus
   export AZR_RESOURCE_GROUP=aro-mobb-rg
   export ACR_NAME=acr$((RANDOM))
   export PRIVATEENDPOINTSUBNET_PREFIX="10.0.8.0/23"
   export PRIVATEENDPOINTSUBNET_NAME="PrivateEndpoint-subnet"
   export ARO_VNET_NAME="aro-mobb-vnet"
   ```

## Create ACR and restrict the access using Private Endpoint

You can limit access to the ACR instance by assigning virtual network private IP addresses to the registry endpoints and using Azure Private Link. 

Network traffic between the clients on the virtual network and the registry's private endpoints traverses the virtual network and a private link on the Microsoft backbone network, eliminating exposure from the public internet. Private Link also enables private registry access from on-premises through Azure ExpressRoute private peering or a VPN gateway.

1. Register the resource provider for Azure Container Registry in your subscription:

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

  ```bash
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

1. You can nslookup the FQDN to check that the record it's propagated properly, and answers with the privatelink one:

  ```bash
  nslookup $REGISTRY_FQDN
  ```

1. Get the Username and Password for login to the ACR instance:

  ```bash
  ACR_USER=$(az acr credential show -n  $ACR_NAME --query "username" -o tsv)
  ACR_PASS=$(az acr credential show -n $ACR_NAME --query "passwords[0].value" -o tsv)
  ```

1. Try to login with `podman` or `docker` to the registry outside of the vNET:

  ```bash
  podman login --username $ACR_USER $REGISTRY_FQDN
  ```

>NOTE: you will receive an error, that it's what we're expecting, because the access to the ACR it's restricted outside of the vNET (peering or VPN/ER needs to be used). 

1. Get (and save) the ARO_URL and the KUBEADMIN password:

  ```bash
  ARO_KUBEPASS=$(az aro list-credentials --name $AZR_CLUSTER --resource-group $AZR_RESOURCE_GROUP -o tsv --query kubeadminPassword)
   ARO_URL=$(az aro show -g $AZR_RESOURCE_GROUP -n $AZR_CLUSTER --query apiserverProfile.url -o tsv)
  ```

## Automation with Terraform (Optional)

If you want to deploy everything on this blog post automated, clone the rh-mobb terraform-aro repo and deploy it:

  ```bash
  git clone https://github.com/rh-mobb/terraform-aro.git
  cd terraform-aro
  terraform init
  terraform plan -out aro.plan 		                       \
    -var "cluster_name=aro-$(shell whoami)"              \
    -var "restrict_egress_traffic=true"		               \
    -var "api_server_profile=Private"                    \
    -var "ingress_profile=Private"                       \
    -var "acr_private=true"

  terraform apply aro.plan
  ```

## Testing the Azure Container Registry from the Private ARO cluster

Once we have deployed the ACR, we need to test the ACR instance deployed, and limited the access only from within the vNET (or using peering, VPN or ExpressRoute connectivity).

1. SSH to the JUMPHOST to be able to test and push a example image:

  ```bash
  export JUMPHOST="xxx"
  ssh -l aro $JUMPHOST
  ```

1. Inside of the JUMPHOST (within the vNET) install oc and docker/podman:

  ```bash
  sudo dnf update -y --disablerepo=* --enablerepo='*microsoft*' rhui-azure-rhel8-eus
  sudo dnf install telnet wget bash-completion podman -y
  wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
  tar -xvf openshift-client-linux.tar.gz
  sudo mv oc kubectl /usr/bin/
  oc completion bash > oc_bash_completion
  sudo cp oc_bash_completion /etc/bash_completion.d/
  ```

1. Login to the registry (this time should work):

  ```bash
  export REGISTRY_FQDN="xxx"
  export ACR_USER="xxx"
  export ARO_URL="xxx"
  podman login --username $ACR_USER $REGISTRY_FQDN 
  ```

1. Push an example image to the ACR:

  ```bash
  podman pull quay.io/centos7/httpd-24-centos7
  podman tag quay.io/centos7/httpd-24-centos7 $REGISTRY_FQDN/centos7/httpd-24-centos7
  podman push $REGISTRY_FQDN/centos7/httpd-24-centos7
  ```

1. Login to the Private ARO cluster and create a test namespace: 

  ```bash
  oc login --username kubeadmin --server=$ARO_URL
  oc new-project test-acr
  ```

1. Create the Kubernetes secret for storing the credentials to access the ACR inside of the ARO cluster:

  ```bash
  oc create -n test-acr secret docker-registry \
      --docker-server=$REGISTRY_FQDN \
      --docker-username=$ACR_USER \
      --docker-password=******** \
      --docker-email=unused \
      acr-secret
  ```

1. Link the secret to the service account:

  ```bash
  oc secrets link default acr-secret --for=pull
  ```

1. Deploy an example app using the ACR container image pushed in the previous step:

```bash
oc create -n test-acr deployment httpd --image=$REGISTRY_FQDN/centos7/httpd-24-centos7
```

1. After a couple of minutes, check the status of the pod:

```bash
oc get pod -n test-acr
```

It should work, deploying the container image in the Private ARO cluster.