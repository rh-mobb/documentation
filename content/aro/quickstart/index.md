---
date: '2021-06-21'
title: ARO Quickstart
weight: 1
aliases: [/experts/quickstart-aro.md]
authors: 
  - Paul Czarkowski
  - Nerav Doshi
tags: ["ARO", "Quickstarts"]
validated_version: "4.20"
---
A Quickstart guide to deploying an Azure Red Hat OpenShift cluster.

## Video Walkthrough

If you prefer a more visual medium, you can watch [Paul Czarkowski](https://twitter.com/pczarkowski) walk through this quickstart on [YouTube](https://youtu.be/VYfCltxoh40).

<iframe width="560" height="315" src="https://www.youtube.com/embed/VYfCltxoh40" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>


## Prerequisites

### Azure CLI

_Obviously you'll need to have an Azure account to configure the CLI against._

**macOS**

{{% alert state="info" %}}See [Install Azure CLI on macOS](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-macos) for alternative install options.{{% /alert %}}

1. Install Azure CLI using homebrew

    ```bash
    brew update && brew install azure-cli
    ```

**Linux (RHEL / Fedora / similar, using `dnf`)**

{{% alert state="info" %}}For Ubuntu, Debian, or other distributions, use the steps in [Install the Azure CLI on Linux](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux) for your package manager.{{% /alert %}}

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

1. Log into the Azure CLI by running the following and then authorizing through your Web Browser. If you have more than one subscription, list them and select the one where you will deploy the cluster.

    ```bash
    az login
    az account list -o table
    az account set --subscription "<id-or-name>"
    ```

1. Make sure you have enough quota in the **same Azure region** you plan to use for the cluster (below, `eastus` matches the default `AZR_RESOURCE_LOCATION` used later; change both if you use another region). Confirm current vCPU requirements in [Create an Azure Red Hat OpenShift cluster](https://learn.microsoft.com/en-us/azure/openshift/create-cluster) (prerequisites and sizing).

    ```bash
    az vm list-usage --location eastus -o table
    ```

    See [Addendum - Adding Quota to ARO account](#adding-quota-to-aro-account) if you do not have enough quota left for **Total Regional vCPUs** (Azure Red Hat OpenShift requires a minimum of 44 cores to create a cluster; verify against current Microsoft documents).

1. Register resource providers

    ```bash
    az provider register -n Microsoft.RedHatOpenShift --wait
    az provider register -n Microsoft.Compute --wait
    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.Authorization --wait
    ```

### Get Red Hat pull secret

{{% alert state="info" %}}This step is optional, but highly recommended. Without it, you can still install the cluster, but access to Red Hat container catalog images and many OperatorHub entries is limited.{{% /alert %}}

1. Log into <https://console.redhat.com>

1. Browse to <https://console.redhat.com/openshift/install/azure/aro-provisioned>

1. Click the **Download pull secret** button and save the file to a known path (for example the default `AZR_PULL_SECRET` path used below). Restrict access to the file and do not commit it to source control; for example on macOS or Linux: `chmod 600 ~/Downloads/pull-secret.txt`.

## Deploy Azure OpenShift

### Variables and Resource Group

Set some environment variables to use later, and create an Azure Resource Group.

1. Set the following environment variables

    {{% alert state="info" %}}Change the values to suit your environment, but these defaults should work. Resource names must comply with [Azure naming rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules) and length limits. Run all following commands in the same shell so the exported variables apply.{{% /alert %}}

    ```bash
    export AZR_RESOURCE_LOCATION=eastus
    export AZR_RESOURCE_GROUP=aro-rg
    export AZR_CLUSTER=aro-cluster
    export AZR_PULL_SECRET=~/Downloads/pull-secret.txt
    ```

1. Create an Azure resource group

    ```bash
    az group create \
      --name "$AZR_RESOURCE_GROUP" \
      --location "$AZR_RESOURCE_LOCATION" \
      --tags Environment=Lab Purpose=ARO-Quickstart
    ```


### Networking

Create a virtual network with two empty subnets

1. Create virtual network

    ```bash
    az network vnet create \
      --address-prefixes 10.0.0.0/22 \
      --name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --resource-group "$AZR_RESOURCE_GROUP"
    ```

1. Create control plane subnet

    ```bash
    az network vnet subnet create \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --address-prefixes 10.0.0.0/23
    ```

1. Create machine subnet

    ```bash
    az network vnet subnet create \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --name "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
      --address-prefixes 10.0.2.0/23
    ```

1. [Disable network policies for Private Link Service](https://learn.microsoft.com/en-us/azure/private-link/disable-private-link-service-network-policy?tabs=private-link-network-policy-cli) on the control plane subnet

    {{% alert state="info" %}}Optional. The ARO RP will disable this for you if you skip this step.{{% /alert %}}

    ```bash
    az network vnet subnet update \
      --name "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --vnet-name "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --private-link-service-network-policies Disabled
    ```

1. OpenShift version (optional)

    New clusters use a **supported default** OpenShift version for your region unless you choose one explicitly. List the exact versions you can install (they change over time as Microsoft and Red Hat add releases):

    ```bash
    az aro get-versions --location "$AZR_RESOURCE_LOCATION" -o table
    ```

    {{% alert state="info" %}}To **pin** a build, add `--version` with a full version string from that output (for example `4.18.12`) to the `az aro create` command below. Omit `--version` to let the platform pick the default for new clusters.{{% /alert %}}

1. Create the cluster

    {{% alert state="info" %}}This will take between 30 and 45 minutes.{{% /alert %}}

    ```bash
    az aro create \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --name "$AZR_CLUSTER" \
      --vnet "$AZR_CLUSTER-aro-vnet-$AZR_RESOURCE_LOCATION" \
      --master-subnet "$AZR_CLUSTER-aro-control-subnet-$AZR_RESOURCE_LOCATION" \
      --worker-subnet "$AZR_CLUSTER-aro-machine-subnet-$AZR_RESOURCE_LOCATION" \
      --pull-secret @"$AZR_PULL_SECRET"
    ```

    To create the cluster on a **specific OpenShift version** from `az aro get-versions`, append `--version X.Y.Z` to the same command (use the exact string from the table for your region).

1. Get OpenShift console URL

    ```bash
    az aro show \
      --name "$AZR_CLUSTER" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      -o tsv --query consoleProfile
    ```

1. Get OpenShift credentials

    ```bash
    az aro list-credentials \
      --name "$AZR_CLUSTER" \
      --resource-group "$AZR_RESOURCE_GROUP" \
      -o tsv
    ```

1. Use the URL and the credentials provided by the output of the last two commands to log into OpenShift via a web browser.

![ARO login page](./images/aro-login.png)


1. Deploy an application to OpenShift

    {{% alert state="info" %}}See the following video for a guide on easy application deployment on OpenShift.{{% /alert %}}

    <iframe width="560" height="315" src="https://www.youtube.com/embed/8uFUFJS9TA4?start=0:43" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>

### Delete Cluster

Once you're done it is a good idea to delete the cluster so you avoid unexpected charges.

1. Delete the cluster

    {{% alert state="info" %}}The `-y` flag skips confirmation prompts and is convenient for lab teardown; omit it if you want to be prompted before deletion.{{% /alert %}}

    ```bash
    az aro delete -y \
      --resource-group "$AZR_RESOURCE_GROUP" \
      --name "$AZR_CLUSTER"
    ```

1. Delete the Azure resource group

    {{% alert state="danger" %}}Only do this if there is nothing else in the resource group. `az group delete` removes all resources in that group.{{% /alert %}}

    ```bash
    az group delete -y \
      --name "$AZR_RESOURCE_GROUP"
    ```

## Addendum

### Adding Quota to ARO account

![aro quota support ticket request example](./images/aro-quota-request.png)

1. [Create an Azure Support Request](https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade/newsupportrequest)

1. Set **Issue Type** to "Service and subscription limits (quotas)"

1. Set **Quota Type** to "Compute-VM (cores-vCPUs) subscription limit increases"

1. Click **Next Solutions >>**

1. Click **Enter details**

1. Set **Deployment Model** to "Resource Manager"

1. Set **Locations** to "(US) East US"

1. Set **Types** to "Standard"

1. Under **Standard** check "DSv4" and "DSv5"

1. Set **New vCPU Limit** for each (example "60")

1. Click **Save and continue**

1. Click **Review + create >>**

1. Wait until quota is increased.
