---
date: '2026-03-25'
title: OpenShift Dedicated Quickstart
weight: 1
authors:
  - Kevin Collins
  - Kumudu Herath
tags: ["OSD", "Quickstarts"]
---
{{% alert state="info" %}}This guide has been validated on **OpenShift 4.20**. Operator CRD names, API versions, and console paths may differ on other versions.{{% /alert %}}

A Quickstart guide to deploying an OpenShift Dedicated cluster on Google Cloud Platform.

## Prerequisites

### Google Cloud Account

{{% alert state="info" %}}You should already have the Google Cloud CLI installed and be authenticated with `gcloud auth application-default login` before proceeding. Review the [Google Cloud prerequisites and requirements for OSD](https://docs.openshift.com/dedicated/latest/osd_install_access_delete_cluster/gcp-ccs.html) for detailed information on permissions and quota requirements.{{% /alert %}}


### Install OCM CLI

The OCM (OpenShift Cluster Manager) CLI is used to create and manage OpenShift Dedicated clusters.

1. Download the OCM CLI

    **MacOS**

    ```bash
    curl -Lo ocm https://developers.redhat.com/content-gateway/rest/browse/pub/cgw/ocm/latest/ocm_darwin_amd64.zip
    chmod +x ocm
    sudo mv ocm /usr/local/bin/
    ```

    **Linux**

    ```bash
    curl -Lo ocm https://developers.redhat.com/content-gateway/rest/browse/pub/cgw/ocm/latest/ocm_linux_amd64.zip
    chmod +x ocm
    sudo mv ocm /usr/local/bin/
    ```

1. Verify installation

    ```bash
    ocm version
    ```

### Authenticate OCM CLI

1. Log in to OCM using your API token

    ```bash
    ocm login --use-auth-code
    ```

## Deploy OpenShift Dedicated on GCP

### Configure Workload Identity Federation

{{% alert state="info" %}}Workload Identity Federation is the recommended approach as it eliminates the need to create and manage long-lived service account keys, reducing security risks.{{% /alert %}}

1. Set environment variables

    {{% alert state="info" %}}Change the values to suit your environment.{{% /alert %}}

    ```bash
    export PROJECT_ID=$(gcloud config get-value project)
    export WIF_CONFIG_NAME=osd-wif-config
    ```

1. Create Workload Identity Federation configuration

    ```bash
    ocm gcp create wif-config \
      --name ${WIF_CONFIG_NAME} \
      --project ${PROJECT_ID} \
      --federated-project ${PROJECT_ID}
    ```

### Create the Cluster

1. Set cluster variables

    ```bash
    export CLUSTER_NAME=my-osd-cluster
    export REGION=us-east1
    export COMPUTE_NODES=2
    export COMPUTE_MACHINE_TYPE=n2-standard-8
    ```

1. Create the cluster using OCM CLI with Workload Identity Federation

    {{% alert state="info" %}}This will take between 30 and 40 minutes.{{% /alert %}}

    ```bash
    ocm create cluster \
      --ccs \
      --provider gcp \
      --region ${REGION} \
      --compute-nodes ${COMPUTE_NODES} \
      --compute-machine-type ${COMPUTE_MACHINE_TYPE} \
      --wif-config ${WIF_CONFIG_NAME} \
      --subscription-type=marketplace-gcp \
      --marketplace-gcp-terms=true \
      ${CLUSTER_NAME} 
    ```

1. Monitor cluster installation

    ```bash
    ocm describe cluster ${CLUSTER_NAME}
    ```

    Or watch the installation status:

    ```bash
    watch -n 30 "ocm describe cluster ${CLUSTER_NAME} | grep State"
    ```

1. Once the cluster is ready, get the console URL

    ```bash
    ocm describe cluster ${CLUSTER_NAME} | grep "Console URL"
    ```

1. Get cluster credentials

    ```bash
    ocm describe cluster ${CLUSTER_NAME} | grep -A 2 "Admin"
    ```

    Alternatively, create a cluster-admin user:

    ```bash
    ocm create idp \
      --cluster=${CLUSTER_NAME} \
      --type=htpasswd \
      --name=admin-idp \
      --username=cluster-admin \
      --password=YourSecurePassword123!

    ocm create user ${CLUSTER_NAME} \
      --cluster=${CLUSTER_NAME} \
      --group=cluster-admins
    ```

1. Use the console URL and credentials to log into OpenShift via a web browser.

### Delete Cluster

Once you're done, delete the cluster to avoid ongoing charges.

1. Delete the cluster

    ```bash
    ocm delete cluster ${CLUSTER_NAME}
    ```

1. Monitor deletion progress

    ```bash
    watch -n 30 "ocm list clusters | grep ${CLUSTER_NAME}"
    ```

## Additional Resources

- [OpenShift Dedicated Documentation](https://docs.openshift.com/dedicated/latest/)
- [OCM CLI Documentation](https://github.com/openshift-online/ocm-cli)
- [Google Cloud Prerequisites for OSD](https://docs.openshift.com/dedicated/latest/osd_install_access_delete_cluster/creating-a-gcp-cluster.html)
