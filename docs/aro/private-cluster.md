# ARO Quickstart - Private Cluster with JumpHost

A Quickstart guide to deploying a Private Azure RedHat OpenShift cluster.

> Once the cluster is running you will need a way to access the private network that ARO is deployed into.

Author: [Paul Czarkowski](https://twitter.com/pczarkowski)

## Prerequisites

### Azure CLI

_Obviously you'll need to have an Azure account to configure the CLI against._

**MacOS**

> See [Azure Docs](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-macos) for alternative install options.

1. Install Azure CLI using homebrew

    ```bash
    brew update && brew install azure-cli
    ```

**Linux**

> See [Azure Docs](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-linux?pivots=dnf) for alternative install options.

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
    sudo dnf install -y azure-cli
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

    see [Addendum - Adding Quota to ARO account](#Adding-Quota-to-ARO-account) if you have less than `36` Quota left for `Total Regional vCPUs`.

1. Register resource providers

    ```bash
    az provider register -n Microsoft.RedHatOpenShift --wait
    az provider register -n Microsoft.Compute --wait
    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.Authorization --wait
    ```

### Get Red Hat pull secret

1. Log into cloud.redhat.com

1. Browse to https://cloud.redhat.com/openshift/install/azure/aro-provisioned

1. click the **Download pull secret** button and remember where you saved it, you'll reference it later.

## Deploy Azure OpenShift

### Variables and Resource Group

Set some environment variables to use later, and create an Azure Resource Group.

1. Set the following environment variables

    > Change the values to suit your environment, but these defaults should work.

    ```bash
    AZR_RESOURCE_LOCATION=eastus
    AZR_RESOURCE_GROUP=openshift-private
    AZR_CLUSTER=private-cluster
    AZR_PULL_SECRET=~/Downloads/pull-secret.txt
    ```

1. Create an Azure resource group

    ```bash
    az group create \
      --name $AZR_RESOURCE_GROUP \
      --location $AZR_RESOURCE_LOCATION
    ```


### Networking

Create a virtual network with two empty subnets

1. Create virtual network

    ```bash
    az network vnet create \
      --address-prefixes 10.0.0.0/20 \
      --name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --resource-group $AZR_RESOURCE_GROUP
    ```

1. Create control plane subnet

    ```bash
    az network vnet subnet create \
      --resource-group $AZR_RESOURCE_GROUP \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --address-prefixes 10.0.0.0/24 \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. Create machine subnet

    ```bash
    az network vnet subnet create \
      --resource-group $AZR_RESOURCE_GROUP \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
      --address-prefixes 10.0.1.0/24 \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. Disable network policies on the control plane subnet

    > This is required for the service to be able to connect to and manage the cluster.

    ```bash
    az network vnet subnet update \
      --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --resource-group $AZR_RESOURCE_GROUP \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --disable-private-link-service-network-policies true
    ```

### Firewall + Internet Egress

This replaces the routes for the cluster to go through the Firewall for egress vs the Loadbalancer which we can later remove. It does come with extra Azure costs of course.

> You can skip this step if you don't need to restrict egress.

1. Make sure you have the AZ CLI firewall extensions

    ```bash
    az extension add -n azure-firewall
    az extension update -n azure-firewall
    ```

1. Create a firewall network, IP, and firewall

    ```bash
    az network vnet subnet create \
        -g $AZR_RESOURCE_GROUP \
        --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
        -n "AzureFirewallSubnet" \
        --address-prefixes 10.0.4.0/24

    az network public-ip create -g $AZR_RESOURCE_GROUP -n fw-ip \
      --sku "Standard" --location $AZR_RESOURCE_LOCATION

    az network firewall create -g $AZR_RESOURCE_GROUP \
      -n aro-private -l $AZR_RESOURCE_LOCATION
    ```

1. Configure the firewall

> this may take 15 minutes

    ```bash
    az network firewall ip-config create -g $AZR_RESOURCE_GROUP \
      -f aro-private -n fw-config --public-ip-address fw-ip \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"

    FWPUBLIC_IP=$(az network public-ip show -g $AZR_RESOURCE_GROUP -n fw-ip --query "ipAddress" -o tsv)
    FWPRIVATE_IP=$(az network firewall show -g $AZR_RESOURCE_GROUP -n aro-private --query "ipConfigurations[0].privateIpAddress" -o tsv)

    echo $FWPUBLIC_IP
    echo $FWPRIVATE_IP
    ```

1. Create and configure a route table

    ```bash
    az network route-table create -g $AZR_RESOURCE_GROUP --name aro-udr

    az network route-table route create -g $AZR_RESOURCE_GROUP --name aro-udr --route-table-name aro-udr --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP
    ```

1. Create application rules for ARO resources

    ```bash
    az network firewall application-rule create -g $AZR_RESOURCE_GROUP -f aro-private \
      --collection-name 'ARO' \
      --action allow \
      --priority 100 \
      -n 'required' \
      --source-addresses '*' \
      --protocols 'http=80' 'https=443' \
      --target-fqdns 'registry.redhat.io' '*.quay.io' 'sso.redhat.com' 'management.azure.com' 'mirror.openshift.com' 'api.openshift.com' 'quay.io' '*.blob.core.windows.net' 'gcs.prod.monitoring.core.windows.net' 'registry.access.redhat.com' 'login.microsoftonline.com' '*.servicebus.windows.net' '*.table.core.windows.net' 'grafana.com'
    ```

1. Create application rules for dockerhub

    ```bash
    az network firewall application-rule create -g $AZR_RESOURCE_GROUP -f aro-private \
    --collection-name 'Docker' \
    --action allow \
    --priority 200 \
    -n 'docker' \
    --source-addresses '*' \
    --protocols 'http=80' 'https=443' \
    --target-fqdns '*cloudflare.docker.com' '*registry-1.docker.io' 'apt.dockerproject.org' 'auth.docker.io'
    ```

1. Update the subnets to use the Firewall

    ```bash
    az network vnet subnet update -g $AZR_RESOURCE_GROUP \
      --vnet-name $AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION \
      --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --route-table aro-udr

    az network vnet subnet update -g $AZR_RESOURCE_GROUP \
      --vnet-name $AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION \
      --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
      --route-table aro-udr
    ```

### The cluster itself

1. Create the cluster

    > This will take between 30 and 45 minutes.

    ```bash
    az aro create \
      --resource-group $AZR_RESOURCE_GROUP \
      --name $AZR_CLUSTER \
      --vnet "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --master-subnet "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --worker-subnet "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
      --apiserver-visibility Private \
      --ingress-visibility Private \
      --pull-secret @$AZR_PULL_SECRET
      ```

### Jump Host

With the cluster in a private network, we can create a Jump host in order to connect to it. You can do this while the cluster is being created.

1. Create jump subnet

    ```bash
    az network vnet subnet create \
      --resource-group $AZR_RESOURCE_GROUP \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name JumpSubnet \
      --address-prefixes 10.0.5.0/24 \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. Create a jump host

    ```
    az vm create --name jumphost \
        --resource-group $AZR_RESOURCE_GROUP \
        --ssh-key-values $HOME/.ssh/id_rsa.pub \
        --admin-username aro \
        --image "RedHat:RHEL:8.2:8.2.2021040911" \
        --subnet JumpSubnet \
        --public-ip-address jumphost-ip \
        --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION"
    ```

1. ssh to jump host forwarding port 1337 as a socks proxy.

    > replace the IP with the IP of the jump box from the previous step.

    ```
    ssh -D 1337 -C -i $HOME/.ssh/id_rsa aro@52.152.221.4
    ```

1. test the socks proxy

    ```bash
    curl --socks5-hostname localhost:1337 http://www.google.com/
    ```

1. Install tools

    ```bash
    sudo yum install -y gcc libffi-devel python3-devel openssl-devel jq

    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    echo -e "[azure-cli]
    name=Azure CLI
    baseurl=https://packages.microsoft.com/yumrepos/azure-cli
    enabled=1
    gpgcheck=1
    gpgkey=https://packages.microsoft.com/keys/microsoft.asc" | sudo tee /etc/yum.repos.d/azure-cli.repo
    sudo dnf install -y microsoft-azure-cli

    wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz

    mkdir openshift
    tar -zxvf openshift-client-linux.tar.gz -C openshift
    echo 'export PATH=$PATH:~/openshift' >> ~/.bashrc && source ~/.bashrc
    ```

1. Wait until the ARO cluster is fully provisioned.

1. Login to Azure

    ```
    az login
    ```

1. Get OpenShift console URL

    > set these variables to match the ones you set at the start.

    ```bash
    AZR_RESOURCE_GROUP=openshift-private
    AZR_CLUSTER=private-cluster

    APISERVER=$(az aro show \
      --name $AZR_CLUSTER \
      --resource-group $AZR_RESOURCE_GROUP \
      -o tsv --query apiserverProfile.url)
    echo $APISERVER
    ```

1. Get OpenShift credentials

    ```bash
    ADMINPW=$(az aro list-credentials \
      --name $AZR_CLUSTER \
      --resource-group $AZR_RESOURCE_GROUP \
      --query kubeadminPassword \
      -o tsv)
    ```

#### Delete the ARO egress LB

> Note: you should only do this if enabled the firewall egress above and you plan to use the [egress-ipam-operator](./egress-ipam-operator) doing this may render your ARO cluster **UNSUPPORTED** by Red Hat / Azure, so speak to your support
 team before doing this.

1. Get and Login as Service Principal

    ```bash
    oc login $APISERVER -u kubeadmin -p $ADMINPW

    SPAPPID="$(oc get secret azure-credentials -n kube-system -o json | jq -r .data.azure_client_id | base64 --decode)"
    SPSECRET="$(oc get secret azure-credentials -n kube-system -o json | jq -r .data.azure_client_secret | base64 --decode)"
    SPTENANT="$(oc get secret azure-credentials -n kube-system -o json | jq -r .data.azure_tenant_id | base64 --decode)"
    CLUSTERRG="$(oc get secret azure-credentials -n kube-system -o json | jq -r .data.azure_resourcegroup |base64 --decode)"

    az login --service-principal -u $SPAPPID -p $SPSECRET -t $SPTENANT

    ```

1. get the name of the LB

    ```
    LB_NAME=$(az network lb list -g $CLUSTERRG --query [].name -o tsv | grep -v 'internal')
    echo $LB_NAME
    ```

1. delete the outbound rule

    ```
    az network lb outbound-rule delete -n outbound-rule-v4 \
      --lb-name $LB_NAME -g $CLUSTERRG
    ```

1. *optional* delete the LB and IP

    ```
    az network lb delete -n $LB_NAME -g $CLUSTERRG

    az network public-ip delete -n $LB_NAME-pip-v4 \
      -g $CLUSTERRG
```

1. Test Access to the cluster via the socks proxy

> Unfortunately you can't [easily] use the socks proxy with the `oc` command, but at least you can access the console via the socks proxy.

```bash
    CONSOLE=$(az aro show \
      --name $AZR_CLUSTER \
      --resource-group $AZR_RESOURCE_GROUP \
      -o tsv --query consoleProfile)

    echo $CONSOLE

    curl --socks5-hostname localhost:1337 $CONSOLE
```

1. Set localhost:1337 as a socks proxy in your browser and verify you can access the cluster by browsing to the `$CONSOLE` url.

### Delete Cluster

Once you're done its a good idea to delete the cluster to ensure that you don't get a surprise bill.

1. Delete the cluster

    ```bash
    az aro delete -y \
      --resource-group $AZR_RESOURCE_GROUP \
      --name $AZR_CLUSTER
    ```

1. Delete the Azure resource group

    > Only do this if there's nothing else in the resource group.

    ```bash
    az group delete -y \
      --name $AZR_RESOURCE_GROUP
    ```

## Adendum

### Adding Quota to ARO account

![aro quota support ticket request example](./images/aro-quota.png)

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

