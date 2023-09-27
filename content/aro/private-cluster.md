---
date: '2021-06-29'
title: Private ARO Cluster with access via JumpHost
tags: ["ARO", "Azure"]
---

A Quickstart guide to deploying a Private Azure Red Hat OpenShift cluster.

{{% alert state="info" %}}Once the cluster is running you will need a way to access the private network that ARO is deployed into.{{% /alert %}}

Authors: [Paul Czarkowski](https://twitter.com/pczarkowski), [Ricardo Macedo Martins](https://www.linkedin.com/in/ricmmartins)

## Prerequisites

### Azure CLI

_Obviously you'll need to have an Azure account to configure the CLI against._

**MacOS**

{{% alert state="info" %}}See [Azure Docs](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-macos) for alternative install options.{{% /alert %}}

1. Install Azure CLI using homebrew

    ```bash
    brew update && brew install azure-cli
    ```

2. Install sshuttle using homebrew

    ```bash
    brew install sshuttle
    ```

**Linux**

{{% alert state="info" %}}See [Azure Docs](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-linux?pivots=dnf) for alternative install options.{{% /alert %}}

1. Import the Microsoft Keys

    ```bash
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    ```

1. Add the Microsoft Yum Repository

    ```bash
    cat << EOF | sudo tee /etc/yum.repos.d/azure-cli.repo
    [azure-cli]
    name=Azure CLI
    baseurl=https://packages.microsoft.com/yumrepos/azure-cli
    enabled=1
    gpgcheck=1
    gpgkey=https://packages.microsoft.com/keys/microsoft.asc
    EOF
    ```

1. Install Azure CLI

    ```bash
    sudo dnf install -y azure-cli sshuttle
    ```

### Prepare Azure Account for Azure OpenShift

1. Log into the Azure CLI by running the following and then authorizing through your Web Browser

    ```bash
    az login
    ```

1. Make sure you have enough Quota (change the location if you're not using `East US`)

    ```bash
    az vm list-usage --location "East US" -o table
    ```

    see [Addendum - Adding Quota to ARO account](#adding-quota-to-aro-account) if you have less than `36` Quota left for `Total Regional vCPUs`.

1. Register resource providers

    ```bash
    az provider register -n Microsoft.RedHatOpenShift --wait
    az provider register -n Microsoft.Compute --wait
    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.Authorization --wait
    ```

### Get Red Hat pull secret

1. Log into cloud.redhat.com

1. Browse to <https://cloud.redhat.com/openshift/install/azure/aro-provisioned>

1. click the **Download pull secret** button and remember where you saved it, you'll reference it later.

## Deploy Azure OpenShift

### Variables and Resource Group

Set some environment variables to use later, and create an Azure Resource Group.

1. Set the following environment variables

    {{% alert state="info" %}}Change the values to suit your environment, but these defaults should work.{{% /alert %}}

    ```bash
    export AZR_RESOURCE_LOCATION=eastus
    export AZR_RESOURCE_GROUP=openshift-private
    export AZR_CLUSTER=private-cluster
    export AZR_PULL_SECRET=~/Downloads/pull-secret.txt
    export NETWORK_SUBNET=10.0.0.0/20
    export CONTROL_SUBNET=10.0.0.0/24
    export MACHINE_SUBNET=10.0.1.0/24
    export FIREWALL_SUBNET=10.0.2.0/24
    export JUMPHOST_SUBNET=10.0.3.0/24
    ```

1. Create an Azure resource group

    ```bash
    az group create                \
      --name $AZR_RESOURCE_GROUP   \
      --location $AZR_RESOURCE_LOCATION
    ```

1. Create an Azure Service Principal

    ```bash
    AZ_SUB_ID=$(az account show --query id -o tsv)
    AZ_SP_PASS=$(az ad sp create-for-rbac -n "${AZR_CLUSTER}-SP" --role contributor \
      --scopes "/subscriptions/${AZ_SUB_ID}/resourceGroups/${AZR_RESOURCE_GROUP}" \
      --query "password" -o tsv)
    AZ_SP_ID=$(az ad sp list --display-name "${AZR_CLUSTER}-SP" --query "[0].appId" -o tsv)
    ```

### Networking

Create a virtual network with two empty subnets

1. Create virtual network

    ```bash
    az network vnet create                                    \
      --address-prefixes $NETWORK_SUBNET                      \
      --name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"   \
      --resource-group $AZR_RESOURCE_GROUP
    ```

1. Create control plane subnet

    ```bash
    az network vnet subnet create                                     \
      --resource-group $AZR_RESOURCE_GROUP                            \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"      \
      --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --address-prefixes $CONTROL_SUBNET                              
    ```

1. Create machine subnet

    ```bash
    az network vnet subnet create                                       \
      --resource-group $AZR_RESOURCE_GROUP                              \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"        \
      --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION"   \
      --address-prefixes $MACHINE_SUBNET                                
    ```

1. [Disable network policies for Private Link Service](https://learn.microsoft.com/en-us/azure/private-link/disable-private-link-service-network-policy?tabs=private-link-network-policy-cli) on the control plane subnet

    {{% alert state="info" %}}Optional. The ARO RP will disable this for you if you skip this step.{{% /alert %}}

    ```bash
    az network vnet subnet update                                       \
      --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION"   \
      --resource-group $AZR_RESOURCE_GROUP                              \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"        \
      --disable-private-link-service-network-policies true
    ```

### Egress

You have the choice of running a NAT GW or Firewall service for your Internet Egress.

Run through the step of one of the two following options

#### Nat GW

This replaces the routes for the cluster to go through the Azure NAT GW service for egress vs the LoadBalancer which we can later remove. It does come with extra Azure costs of course.

1. Create a Public IP

    ```bash
    az network public-ip create -g $AZR_RESOURCE_GROUP \
      -n $AZR_CLUSTER-natgw-ip   \
      --sku "Standard" --location $AZR_RESOURCE_LOCATION
    ```

1. Create the NAT Gateway

    ```bash
    az network nat gateway create \
      --resource-group ${AZR_RESOURCE_GROUP} \
      --name "${AZR_CLUSTER}-natgw" \
      --location ${AZR_RESOURCE_LOCATION} \
      --public-ip-addresses "${AZR_CLUSTER}-natgw-ip"
    ```

1. Get the Public IP of the NAT Gateway

    ```bash
    GW_PUBLIC_IP=$(az network public-ip show -g ${AZR_RESOURCE_GROUP} \
      -n "${AZR_CLUSTER}-natgw-ip" --query "ipAddress" -o tsv)

    echo $GW_PUBLIC_IP
    ```

1. Reconfigure Subnets to use Nat GW

    ```bash
    az network vnet subnet update \
      --name "${AZR_CLUSTER}-aro-control-subnet-${AZR_RESOURCE_LOCATION}"   \
      --resource-group ${AZR_RESOURCE_GROUP}                              \
      --vnet-name "${AZR_CLUSTER}-aro-vnet-${AZR_RESOURCE_LOCATION}"        \
      --nat-gateway "${AZR_CLUSTER}-natgw"
    ```

    ```bash
    az network vnet subnet update \
      --name "${AZR_CLUSTER}-aro-machine-subnet-${AZR_RESOURCE_LOCATION}"   \
      --resource-group ${AZR_RESOURCE_GROUP}                              \
      --vnet-name "${AZR_CLUSTER}-aro-vnet-${AZR_RESOURCE_LOCATION}"        \
      --nat-gateway "${AZR_CLUSTER}-natgw"
    ```


#### Firewall + Internet Egress

This replaces the routes for the cluster to go through the Firewall for egress vs the LoadBalancer which we can later remove. It does come with extra Azure costs of course.

{{% alert state="info" %}}You can skip this step if you don't need to restrict egress.{{% /alert %}}

1. Make sure you have the AZ CLI firewall extensions

    ```bash
    az extension add -n azure-firewall
    az extension update -n azure-firewall
    ```

1. Create a firewall network, IP, and firewall

    ```bash
    az network vnet subnet create                                 \
      -g $AZR_RESOURCE_GROUP                                      \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"  \
      -n "AzureFirewallSubnet"                                    \
      --address-prefixes $FIREWALL_SUBNET

    az network public-ip create -g $AZR_RESOURCE_GROUP -n fw-ip   \
      --sku "Standard" --location $AZR_RESOURCE_LOCATION

    az network firewall create -g $AZR_RESOURCE_GROUP             \
      -n aro-private -l $AZR_RESOURCE_LOCATION
    ```

1. Configure the firewall and configure IP Config (this may take 15 minutes)

    ```bash
    az network firewall ip-config create -g $AZR_RESOURCE_GROUP    \
      -f aro-private -n fw-config --public-ip-address fw-ip        \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"

    FWPUBLIC_IP=$(az network public-ip show -g $AZR_RESOURCE_GROUP -n fw-ip --query "ipAddress" -o tsv)
    FWPRIVATE_IP=$(az network firewall show -g $AZR_RESOURCE_GROUP -n aro-private --query "ipConfigurations[0].privateIPAddress" -o tsv)

    echo $FWPUBLIC_IP
    echo $FWPRIVATE_IP
    ```

1. Create and configure a route table

    ```bash
    az network route-table create -g $AZR_RESOURCE_GROUP --name aro-udr

    sleep 10

    az network route-table route create -g $AZR_RESOURCE_GROUP --name aro-udr \
      --route-table-name aro-udr --address-prefix 0.0.0.0/0                   \
      --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP

    az network route-table route create -g $AZR_RESOURCE_GROUP --name aro-vnet   \
      --route-table-name aro-udr --address-prefix 10.0.0.0/16 --name local-route \
      --next-hop-type VirtualNetworkGateway
    ```

1. Create firewall rules for ARO resources

    {{% alert state="info" %}}Note: ARO clusters do not need access to the internet, however your own workloads running on them may. You can skip this step if you don't need any egress at all.{{% /alert %}}

    * Create a Network Rule to allow all http/https egress traffic (not recommended)

        ```bash
        az network firewall network-rule create -g $AZR_RESOURCE_GROUP -f aro-private \
            --collection-name 'allow-https' --name allow-all                          \
            --action allow --priority 100                                             \
            --source-addresses '*' --dest-addr '*'                                    \
            --protocols 'Any' --destination-ports 1-65535
        ```

    * Create Application Rules to allow to a restricted set of destinations

        {{% alert state="info" %}}replace the target-fqdns with your desired destinations{{% /alert %}}

        ```bash
        az network firewall application-rule create -g $AZR_RESOURCE_GROUP -f aro-private     \
            --collection-name 'Allow_Egress'                                                  \
            --action allow                                                                    \
            --priority 100                                                                    \
            -n 'required'                                                                     \
            --source-addresses '*'                                                            \
            --protocols 'http=80' 'https=443'                                                 \
            --target-fqdns '*.google.com' '*.bing.com'

        az network firewall application-rule create -g $AZR_RESOURCE_GROUP -f aro-private     \
            --collection-name 'Docker'                                                        \
            --action allow                                                                    \
            --priority 200                                                                    \
            -n 'docker'                                                                       \
            --source-addresses '*'                                                            \
            --protocols 'http=80' 'https=443'                                                 \
            --target-fqdns '*cloudflare.docker.com' '*registry-1.docker.io' 'apt.dockerproject.org' 'auth.docker.io'
        ```

1. Update the subnets to use the Firewall

    Once the cluster is deployed successfully you can update the subnets to use the firewall instead of the default outbound loadbalancer rule.

    ```bash
    az network vnet subnet update -g $AZR_RESOURCE_GROUP            \
    --vnet-name $AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION        \
    --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
    --route-table aro-udr

    az network vnet subnet update -g $AZR_RESOURCE_GROUP            \
    --vnet-name $AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION        \
    --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
    --route-table aro-udr
    ```

### Create the cluster

This will take between 30 and 45 minutes.

```bash
    az aro create                                                            \
    --resource-group $AZR_RESOURCE_GROUP                                     \
    --name $AZR_CLUSTER                                                      \
    --vnet "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"                    \
    --master-subnet "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
    --worker-subnet "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
    --apiserver-visibility Private                                           \
    --ingress-visibility Private                                             \
    --pull-secret @$AZR_PULL_SECRET                                          \
    --client-id "${AZ_SP_ID}"                                                \
    --client-secret "${AZ_SP_PASS}"
 ```


### Jump Host

With the cluster in a private network, we can create a Jump host in order to connect to it. You can do this while the cluster is being created.

1. Create jump subnet

    ```bash
    az network vnet subnet create                                \
      --resource-group $AZR_RESOURCE_GROUP                       \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name JumpSubnet                                          \
      --address-prefixes $JUMPHOST_SUBNET                        \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. Create a jump host

    ```bash
    az vm create --name jumphost                 \
        --resource-group $AZR_RESOURCE_GROUP     \
        --ssh-key-values $HOME/.ssh/id_rsa.pub   \
        --admin-username aro                     \
        --image "RedHat:RHEL:9_1:9.1.2022112113" \
        --subnet JumpSubnet                      \
        --public-ip-address jumphost-ip          \
        --public-ip-sku Standard                 \
        --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"
    ```

1. Save the jump host public IP address

    ```bash
    JUMP_IP=$(az vm list-ip-addresses -g $AZR_RESOURCE_GROUP -n jumphost -o tsv \
    --query '[].virtualMachine.network.publicIpAddresses[0].ipAddress')
    echo $JUMP_IP
    ```

1. Use sshuttle to create a ssh vpn via the jump host (use a separate terminal session)

    {{% alert state="info" %}}replace the IP with the IP of the jump box from the previous step.{{% /alert %}}

    ```bash
    sshuttle --dns -NHr "aro@${JUMP_IP}"  10.0.0.0/8
    ```

1. Get OpenShift console URL

    {{% alert state="info" %}}set these variables to match the ones you set at the start.{{% /alert %}}

    ```bash
    APISERVER=$(az aro show              \
    --name $AZR_CLUSTER                  \
    --resource-group $AZR_RESOURCE_GROUP \
    -o tsv --query apiserverProfile.url)
    echo $APISERVER
    ```

1. Get OpenShift credentials

    ```bash
    ADMINPW=$(az aro list-credentials    \
    --name $AZR_CLUSTER                  \
    --resource-group $AZR_RESOURCE_GROUP \
    --query kubeadminPassword            \
    -o tsv)
    ```

1. log into OpenShift

    ```bash
    oc login $APISERVER --username kubeadmin --password ${ADMINPW}
    ```



### Delete Cluster

Once you're done its a good idea to delete the cluster to ensure that you don't get a surprise bill.

1. Delete the cluster

    ```bash
    az aro delete -y                       \
      --resource-group $AZR_RESOURCE_GROUP \
      --name $AZR_CLUSTER
    ```

1. Delete the Azure resource group

    {{% alert state="danger" %}}Only do this if there's nothing else in the resource group.{{% /alert %}}

    ```bash
    az group delete -y \
      --name $AZR_RESOURCE_GROUP
    ```

## Addendum

### Adding Quota to ARO account

![aro quota support ticket request example](../../images/aro-quota.png)

1. [Create an Azure Support Request](https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade/newsupportrequest)

1. Set **Issue Type** to "Service and subscription limits (quotas)"

1. Set **Quota Type** to "Compute-VM (cores-vCPUs) subscription limit increases"

1. Click **Next Solutions >>**

1. Click **Enter details**

1. Set **Deployment Model** to "Resource Manager

1. Set **Locations** to "(US) East US"

1. Set **Types** to "Standard"

1. Under **Standard** check "DSv3" and "DSv4"

1. Set **New vCPU Limit** for each (example "60")

1. Click **Save and continue**

1. Click **Review + create >>**

1. Wait until quota is increased.
