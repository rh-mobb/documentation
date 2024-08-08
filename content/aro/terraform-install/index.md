---
date: '2023-2-10'
title: Deploying ARO using azurerm Terraform Provider
tags: ["azure", "ARO", "Terraform"]
authors:
  - James Land
  - Fola Oso
  - Paul Czarkowski
---

## Overview

Infrastructure as Code has become one of the most prevalent ways in which to deploy and install code for good reason, especially on the cloud. This lab will use the popular tool Terraform in order to create a clear repeatable process in which to install an Azure Managed Openshift(ARO) cluster and all the required components.

### Terraform

Terraform is an open-source IaC tool developed by HashiCorp. It provides a consistent and unified language to describe infrastructure across various cloud providers such as AWS, Azure, Google Cloud, and many others. With Terraform, you can define your infrastructure in code and store it inside of `git`. This makes it easy to version, share, and reproduce.

This article will go over using the Terraform's official [azurerm provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs) in order to deploy an ARO Cluster into our Azure environment.

### Azure's Terraform Provider

[Azurerm](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs) is one of Azure's official Terraform provider, which contains the [Azurerm Red Hat Openshift Cluster Module](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/redhat_openshift_cluster) that is used for the deployment of Azure Managed Red Hat Openshift(ARO).

{{% alert state="info" %}}This lab will also be using resources from the [azuread module](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs).{{% /alert %}}

## Prerequisites

* [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
* [Terraform](https://developer.hashicorp.com/terraform/install)
* [ARO Pull Secret](https://console.redhat.com/openshift/install/azure/aro-provisioned) *(Optional, but highly recommended)*

## Create an ARO Cluster

1. Clone down the example Terraform repository

    ```bash
    git clone https://github.com/rh-mobb/terraform-aro.git
    cd terraform-aro
    ```

1. Set some environment variables

    Cluster configuration options can be found in the `variables.tf` file, and you can see some more automated setting of these variables for different scenarios in the `Makefile`. However to get a basic public cluster we only need to set the following

    > Note: Update the variables to match your environment.  Example set the pull secret to the file that you downloaded in the prerequisites.

    ```bash
    export TF_VAR_pull_secret_path="~/Downloads/pull-secret.txt"
    export TF_VAR_subscription_id="$(az account show --query id --output tsv)"
    export TF_VAR_cluster_name="$(whoami)-aro"
    export TF_VAR_aro_version="$(az aro get-versions -l eastus --query '[-1]' | sed 's/"//g')"
    ```

1. Run Terraform to deploy the cluster

    > **Note:** Expect this to take up to 45 minutes to complete.

    ```bash
    terraform init && \
      terraform plan -out tf.plan && \
      terraform apply tf.plan
    ```

    Eventually you'll see the following

    ```bash
    Apply complete! Resources: 12 added, 0 changed, 0 destroyed.
    Outputs:
    api_server_ip = "172.191.191.23"
    console_url = "https://console-openshift-console.apps.dheaiuio.eastus.aroapp.io/"
    ingress_ip = "172.191.191.48"
    ```


1. Fetch the credentials for the cluster

    ```bash
    ARO_PASS=$(az aro list-credentials --name ${TF_VAR_cluster_name} \
      --resource-group ${TF_VAR_cluster_name}-rg  -o tsv --query kubeadminPassword)
    ```

1. Log into the cluster

    ```bash
    oc login $(terraform output -raw api_url) \
        --username kubeadmin --password "${ARO_PASS}"
    ```

## Cleanup

1. Terraform makes it very easy to clean up the resources when you're finished with them.

    ```
    terraform destroy
    ```

1. When prompted type in `yes`

    ```
    Do you really want to destroy all resources?
    Terraform will destroy all your managed infrastructure, as shown above.
    There is no undo. Only 'yes' will be accepted to confirm.

    Enter a value: yes
    ```


## Conclusion

This article demonstrates the deployment of OpenShift clusters in a consistent manner using Terraform and the azurerm provider. The provided configuration is highly adaptable, allowing for more intricate and customizable deployments. For instance, it could easily be modified for the use of a custom domain zone with your cluster.
