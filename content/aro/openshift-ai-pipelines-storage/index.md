---
date: '2026-10-29'
title: Data science pipelines with Azure Blob storage on ARO
tags: ["ARO", "RHOAI"]
authors:
  - Kumudu Herath
  - Kevin Collins
---
<!-- TODO(validate): entire guide is untested; add validated_version after a clean run -->

OpenShift AI pipelines store their artifacts in S3-compatible object storage. Azure Blob storage doesn't speak the S3 API. This guide puts the OpenShift Data Foundation Multicloud Object Gateway (MCG) in front of a Blob container, so pipelines get an S3 endpoint while the data stays in your Azure storage account.

MCG runs in standalone mode, so you don't need the extra storage nodes that a full ODF deployment uses.

## Prerequisites

* OpenShift AI installed on ARO. See [Installing Red Hat OpenShift AI 3.x on ARO](/experts/aro/openshift-ai-3.x/).
* The `az` CLI, logged in to the subscription that contains the cluster.
* Set these variables:

    ```bash
    export AZR_RESOURCE_GROUP=<aro-resource-group>
    export AZR_LOCATION=<region>
    export AZR_STORAGE_ACCOUNT=rhoaipipelines$RANDOM
    export AZR_CONTAINER=pipelines
    export PROJECT=my-ds-project
    ```

## Create the Blob container

```bash
az storage account create -n $AZR_STORAGE_ACCOUNT -g $AZR_RESOURCE_GROUP -l $AZR_LOCATION \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false

export AZR_STORAGE_KEY=$(az storage account keys list -n $AZR_STORAGE_ACCOUNT -g $AZR_RESOURCE_GROUP --query '[0].value' -o tsv)

az storage container create -n $AZR_CONTAINER --account-name $AZR_STORAGE_ACCOUNT --account-key $AZR_STORAGE_KEY
```

## Deploy the Multicloud Object Gateway

1. Install the ODF Operator:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      name: openshift-storage
      labels:
        openshift.io/cluster-monitoring: "true"
    ---
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
      name: openshift-storage
      namespace: openshift-storage
    spec:
      targetNamespaces:
      - openshift-storage
    ---
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: odf-operator
      namespace: openshift-storage
    spec:
      channel: stable-4.20
      name: odf-operator
      source: redhat-operators
      sourceNamespace: openshift-marketplace
      installPlanApproval: Automatic
    EOF

    oc wait subscription/odf-operator -n openshift-storage \
      --for=jsonpath='{.status.state}'=AtLatestKnown --timeout=600s
    ```
    <!-- TODO(validate): channel must match the cluster's OpenShift minor version -->

1. Create a standalone MCG StorageCluster:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: ocs.openshift.io/v1
    kind: StorageCluster
    metadata:
      name: ocs-storagecluster
      namespace: openshift-storage
    spec:
      multiCloudGateway:
        reconcileStrategy: standalone
    EOF

    oc wait noobaa/noobaa -n openshift-storage --for=jsonpath='{.status.phase}'=Ready --timeout=900s
    ```

1. Create a backing store for the Blob container and a bucket class that uses it:

    ```bash
    oc create secret generic azure-blob-creds -n openshift-storage \
      --from-literal=AccountName=$AZR_STORAGE_ACCOUNT \
      --from-literal=AccountKey=$AZR_STORAGE_KEY

    cat <<EOF | oc apply -f -
    apiVersion: noobaa.io/v1alpha1
    kind: BackingStore
    metadata:
      name: azure-blob
      namespace: openshift-storage
    spec:
      type: azure-blob
      azureBlob:
        targetBlobContainer: $AZR_CONTAINER
        secret:
          name: azure-blob-creds
          namespace: openshift-storage
    ---
    apiVersion: noobaa.io/v1alpha1
    kind: BucketClass
    metadata:
      name: azure-blob
      namespace: openshift-storage
    spec:
      placementPolicy:
        tiers:
        - backingStores:
          - azure-blob
    EOF

    oc wait backingstore/azure-blob -n openshift-storage --for=jsonpath='{.status.phase}'=Ready --timeout=300s
    ```

## Create a bucket for a data science project

1. Create the project and make it visible in the dashboard:

    ```bash
    oc new-project $PROJECT
    oc label namespace $PROJECT opendatahub.io/dashboard=true
    ```

1. Request a bucket. MCG creates a ConfigMap and a Secret with the same name, holding the bucket details and the S3 credentials:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: objectbucket.io/v1alpha1
    kind: ObjectBucketClaim
    metadata:
      name: pipelines
      namespace: $PROJECT
    spec:
      generateBucketName: pipelines
      storageClassName: openshift-storage.noobaa.io
      additionalConfig:
        bucketclass: azure-blob
    EOF

    oc wait obc/pipelines -n $PROJECT --for=jsonpath='{.status.phase}'=Bound --timeout=300s
    export BUCKET=$(oc get configmap pipelines -n $PROJECT -o jsonpath='{.data.BUCKET_NAME}')
    ```

## Configure the pipeline server

Point the pipeline server at the MCG service. The cluster service CA signs the service certificate, and every namespace has that CA in the `openshift-service-ca.crt` ConfigMap.

```bash
cat <<EOF | oc apply -f -
apiVersion: datasciencepipelinesapplications.opendatahub.io/v1
kind: DataSciencePipelinesApplication
metadata:
  name: dspa
  namespace: $PROJECT
spec:
  dspVersion: v2
  apiServer:
    cABundle:
      configMapName: openshift-service-ca.crt
      configMapKey: service-ca.crt
  objectStorage:
    externalStorage:
      host: s3.openshift-storage.svc
      port: "443"
      scheme: https
      bucket: $BUCKET
      s3CredentialsSecret:
        secretName: pipelines
        accessKey: AWS_ACCESS_KEY_ID
        secretKey: AWS_SECRET_ACCESS_KEY
EOF
```
<!-- TODO(validate): confirm DSPA apiVersion/fields for RHOAI 3.x and that the dashboard picks up a CLI-created DSPA -->

Wait for the pipeline server to become ready:

```bash
oc wait dspa/dspa -n $PROJECT --for=condition=Ready --timeout=600s
```

## Validate

1. In the dashboard, open the project, go to **Pipelines**, and import a sample pipeline. Then create a run.
1. When the run finishes, check that MCG has written objects to the Azure container:

    ```bash
    az storage blob list -c $AZR_CONTAINER --account-name $AZR_STORAGE_ACCOUNT \
      --account-key $AZR_STORAGE_KEY --query 'length(@)'
    ```

    MCG stores data in its own chunked format, so the blob names won't match the pipeline artifact names.

## Clean up

```bash
oc delete project $PROJECT
oc delete bucketclass,backingstore azure-blob -n openshift-storage
oc delete storagecluster ocs-storagecluster -n openshift-storage
az storage account delete -n $AZR_STORAGE_ACCOUNT -g $AZR_RESOURCE_GROUP --yes
```
