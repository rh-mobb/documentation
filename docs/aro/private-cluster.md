# ARO Quickstart - Private Cluster

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
      --address-prefixes 10.0.0.0/23 \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. Create machine subnet

    ```bash
    az network vnet subnet create \
      --resource-group $AZR_RESOURCE_GROUP \
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
      --resource-group $AZR_RESOURCE_GROUP \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --disable-private-link-service-network-policies true
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

### Point to Site VPN

1. Create gateway subnet

    ```bash
    az network vnet subnet create \
      --resource-group $AZR_RESOURCE_GROUP \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name GatewaySubnet \
      --address-prefixes 10.0.4.0/24 \
      --service-endpoints Microsoft.ContainerRegistry
    ```

1. create a public ip

    ```bash
    az network public-ip create -g $AZR_RESOURCE_GROUP \
      -n $AZR_CLUSTER-vpn-ip --allocation-method Dynamic
    ```

1. Create a vpn gateway

> Note: this can take 45 minutes

    ```bash
    az network vnet-gateway create -g $AZR_RESOURCE_GROUP \
      -n $AZR_CLUSTER-vpn-gw --public-ip-address $AZR_CLUSTER-vpn-ip \
      --vnet $AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION \
      --gateway-type Vpn --sku VpnGw1 --vpn-type RouteBased \
      --location $AZR_RESOURCE_LOCATION
    ```

1. Update the gateway with address prefix and protocol settings

    ```bash
    az network vnet-gateway update -g $AZR_RESOURCE_GROUP \
      -n $AZR_CLUSTER-vpn-gw --address-prefixes 172.16.200.0/26 \
      --client-protocol SSTP
    ```

### VPN Client

>The following instructions should be performed in PowerShell

> ToDo - find a cleaner way to do this.

* [Alternative instructions For Linux](https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-certificates-point-to-site-linux)

1. Create a self-signed root certificate

    ```
    $cert = New-SelfSignedCertificate -Type Custom -KeySpec Signature `
      -Subject "CN=P2SRootCert" -KeyExportPolicy Exportable `
      -HashAlgorithm sha256 -KeyLength 2048 `
      -CertStoreLocation "Cert:\CurrentUser\My" `
      -KeyUsageProperty Sign -KeyUsage CertSign
    ```

1. Generate a client certificate

    ```
    New-SelfSignedCertificate -Type Custom -DnsName P2SChildCert -KeySpec Signature `
      -Subject "CN=P2SChildCert" -KeyExportPolicy Exportable `
      -HashAlgorithm sha256 -KeyLength 2048 `
      -CertStoreLocation "Cert:\CurrentUser\My" `
      -Signer $cert -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.2")
    ```

1. Export the root certificate public key (.cer)

To obtain a .cer file from the certificate, open Manage user certificates. Locate the self-signed root certificate, typically in 'Certificates - Current User\Personal\Certificates', and right-click. Click All Tasks, and then click Export. This opens the Certificate Export Wizard. If you can't find the certificate under Current User\Personal\Certificates, you may have accidentally opened "Certificates - Local Computer", rather than "Certificates - Current User"). If you want to open Certificate Manager in current user scope using PowerShell, you type certmgr in the console window

1. Generate files using the Azure portal

    In the Azure portal, navigate to the virtual network gateway for the virtual network that you want to connect to.

    On the virtual network gateway page, select Point-to-site configuration to open the Point-to-site configuration page.

    add the exported root certificate to the configuration

    At the top of the Point-to-site configuration page, select Download VPN client. This doesn't download VPN client software, it generates the configuration package used to configure VPN clients. It takes a few minutes for the client configuration package to generate.

    Download the VPN client configuration.

    Once the configuration package has been generated, your browser indicates that a client configuration zip file is available. It's named the same name as your gateway. Unzip the file to view the folders.

### Connect and test

1. From networking connect to the VPN connection that was configured in the previous step.

1. Get OpenShift console URL

    ```bash
    az aro show \
      --name $AZR_CLUSTER \
      --resource-group $AZR_RESOURCE_GROUP \
      -o tsv --query consoleProfile
    ```

1. Get OpenShift credentials

    ```bash
    az aro list-credentials \
      --name $AZR_CLUSTER \
      --resource-group $AZR_RESOURCE_GROUP \
      -o tsv
    ```

1. Use the URL and the credentials provided by the output of the last two commands to log into OpenShift via a web browser.

![ARO login page](../images/aro-login.png)


1. Deploy an application to OpenShift

    > See the following video for a guide on easy application deployment on OpenShift.

    <iframe width="560" height="315" src="https://www.youtube.com/embed/8uFUFJS9TA4?start=0:43" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>

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

