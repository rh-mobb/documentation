---
date: '2023-08-23'
title: Use Azure Blob storage Container Storage Interface (CSI) driver on an ARO cluster
tags: ["ARO"]
authors:
  - Daniel Penagos
  - Paul Czarkowski
  - Diana Sari
validated_version: "4.20"
---


The Azure Blob Storage Container Storage Interface (CSI) is a CSI-compliant driver that can be installed on an Azure Red Hat OpenShift (ARO) cluster to provision and mount Azure Blob storage for Kubernetes workloads.

When you use this CSI driver to mount Azure Blob storage into a pod, it allows you to use blob storage to work with massive amounts of data.

You can also refer to the driver's documentation [here](https://github.com/kubernetes-sigs/blob-csi-driver/blob/master/charts/README.md).

The Azure Blob CSI driver supports two common dynamic provisioning models:

- **Driver-managed path**: the driver can select or create a suitable storage account when one is not explicitly specified in the StorageClass.
- **Bring your own (BYO) storage account path**: the StorageClass is tied to an existing storage account that you create and manage.


## Scope of validation

* The steps below were validated on ARO using a dynamic provisioning path with BlobFuse2 and a manually specified storage account.
* The driver-managed storage account creation path was outside the scope of this update.
* During validation, additional ARO-specific controller credential wiring was required:
  - `azure-cred-file` ConfigMap in `kube-system`
  - `azure-cloud-provider` secret in `kube-system`
  - explicit BlobFuse2 working directory in the StorageClass mount options
* Static provisioning with Azure Blob CSI was also validated separately in lab testing, but it is outside the scope of this walkthrough.


## Prerequisites

* ARO cluster up and running.
* [Helm - command line utility](https://helm.sh/docs/intro/install/)
* oc - command line utility. 
* jq - command line utility.
* Azure CLI logged into the correct subscription.
* Permissions to create or access an Azure Storage Account for the test workflow.
* Permissions to create a service principal and assign Azure RBAC roles.


1. Set the environment variables related to your cluster environment:

    > Update the `LOCATION`, `CLUSTER_NAME`, `RG_NAME`, and `VNET_NAME` variables in the snippet below to match your cluster details:

    ```bash
    export LOCATION=eastus
    export CLUSTER_NAME=my-cluster
    export RG_NAME=myresourcegroup
    export VNET_NAME=my-vnet
    export TENANT_ID=$(az account show --query tenantId -o tsv)
    export SUB_ID=$(az account show --query id -o tsv)
    export MANAGED_RG=$(az aro show -n $CLUSTER_NAME -g $RG_NAME --query 'clusterProfile.resourceGroupId' -o tsv)
    export MANAGED_RG_NAME=$(echo -e $MANAGED_RG | cut -d "/" -f5)
    ```

1. Set environment variables related to the project and secret names used to install the driver, and the testing project where a pod will use the configured storage:

    ```bash
    export CSI_BLOB_PROJECT=csi-azure-blob
    export CSI_BLOB_SECRET=csi-azure-blob-secret
    export CSI_TESTING_PROJECT=testing-project
    ```

1. Set additional environment variables for the storage resources used by the test workflow, including the storage account and blob container names:

    ```bash
    export APP_NAME=myapp
    export STORAGE_ACCOUNT_NAME=aroblobsa
    export BLOB_CONTAINER_NAME=aroblob
    ```


## Create an identity for the CSI Driver to access the Blob Storage

The Azure Blob CSI driver needs Azure credentials so it can access the blob storage resources used by this walkthrough.

For the validated ARO path used here, this includes:

- a service principal with the required Azure permissions
- a Kubernetes secret for the driver
- additional ARO-specific controller cloud configuration in `kube-system`


1. Create a service principal for the Blob CSI driver:

    ```bash
    az ad sp create-for-rbac --name http://$CSI_BLOB_SECRET --skip-assignment
    ```

    Example output:

    ```json
    {
      "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "displayName": "csi-azure-blob-secret",
      "password": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "tenant": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    }
    ```

1. Export the values from the command output:

    ```bash
    export AZURE_CLIENT_ID=<appId>
    export AZURE_CLIENT_SECRET=<password>
    export AZURE_TENANT_ID=<tenant>
    ```

1. Assign the required roles to the service principal.

    For the validated ARO path in this article, the service principal required:
    - `Contributor` on the relevant resource group
    - `Storage Account Contributor` on the target storage account after that account is created


    Assign `Contributor` on the resource group:

    ```bash
    az role assignment create \
      --assignee $AZURE_CLIENT_ID \
      --role Contributor \
      --scope /subscriptions/$SUB_ID/resourceGroups/$RG_NAME
    ```


1. Create the `azure-cred-file` ConfigMap in `kube-system` so the controller can locate the host cloud configuration:

    ```bash
    cat <<'EOF' | oc apply -f -
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: azure-cred-file
      namespace: kube-system
    data:
      path: /etc/kubernetes/cloud.conf
      path-windows: C:\\k\\cloud.conf
    EOF
    ```

1. Create the `azure-cloud-provider` secret in `kube-system` with the Azure cloud configuration used by the controller:

    ```bash
    cat <<EOF > azure-cloud-provider.json
    {
      "cloud": "AzurePublicCloud",
      "tenantId": "$AZURE_TENANT_ID",
      "subscriptionId": "$SUB_ID",
      "aadClientId": "$AZURE_CLIENT_ID",
      "aadClientSecret": "$AZURE_CLIENT_SECRET",
      "resourceGroup": "$RG_NAME",
      "vnetName": "$VNET_NAME",
      "vnetResourceGroup": "$RG_NAME"
    }
    EOF

    oc -n kube-system create secret generic azure-cloud-provider \
      --from-file=cloud-config=azure-cloud-provider.json \
      --dry-run=client -o yaml | oc apply -f -
    ```


## Driver installation

After creating the identity and required Azure configuration, install the Azure Blob CSI driver on the cluster.

1. Add the Blob CSI driver Helm repository:

    ```bash
    helm repo add blob-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/charts
    helm repo update
    ```

1. Install the Blob CSI driver chart:

    ```bash
    helm install blob-csi-driver blob-csi-driver/blob-csi-driver \
      --namespace kube-system
    ```

1. Verify that the Blob CSI driver pods are running:

    ```bash
    oc get pods -n kube-system | grep blob
    ```

    Expected output should include the Blob CSI controller and node pods in a `Running` state.

1. If you created or updated the ARO-specific controller configuration in the previous section, restart the controller so it picks up the latest configuration:

    ```bash
    oc rollout restart deploy/csi-blob-controller -n kube-system
    oc rollout status deploy/csi-blob-controller -n kube-system
    ```

1. Confirm that the controller is healthy before continuing:

    ```bash
    oc get pods -n kube-system -l app=csi-blob-controller -o wide
    oc logs -n kube-system deploy/csi-blob-controller -c blob --tail=100 | cat
    ```

    At this point, the Blob CSI controller should be running without missing cloud configuration errors and ready for the StorageClass and PVC workflow used in the next section.


## Test the CSI driver is working

To test the Blob CSI driver, create the required storage resources, then create a StorageClass, PersistentVolumeClaim, and a pod that mounts the provisioned storage.

1. Create the storage account:

    ```bash
    az storage account create \
      --name $STORAGE_ACCOUNT_NAME \
      --resource-group $RG_NAME \
      --location $LOCATION \
      --sku Standard_LRS \
      --kind StorageV2
    ```

    Assign `Storage Account Contributor` on the storage account:

    ```bash
    export STORAGE_ACCOUNT_ID=$(az storage account show \
      --name $STORAGE_ACCOUNT_NAME \
      --resource-group $RG_NAME \
      --query id -o tsv)

    test -n "$STORAGE_ACCOUNT_ID"

    az role assignment create \
      --assignee $AZURE_CLIENT_ID \
      --role "Storage Account Contributor" \
      --scope $STORAGE_ACCOUNT_ID
    ```

1. Create the blob container:

    ```bash
    az storage container create \
      --name $BLOB_CONTAINER_NAME \
      --account-name $STORAGE_ACCOUNT_NAME
    ```

1. Create the test project:

    ```bash
    oc new-project $CSI_TESTING_PROJECT
    ```

1. Create a secret in the test project containing the storage account credentials:

    ```bash
    oc create secret generic azure-secret \
      --from-literal azurestorageaccountname=$STORAGE_ACCOUNT_NAME \
      --from-literal azurestorageaccountkey="$(az storage account keys list \
        --account-name $STORAGE_ACCOUNT_NAME \
        --resource-group $RG_NAME \
        --query '[0].value' -o tsv)" \
      -n $CSI_TESTING_PROJECT
    ```

1. Create the StorageClass:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: azureblob-fuse2
    provisioner: blob.csi.azure.com
    parameters:
      protocol: fuse2
      skuName: Standard_LRS
      containerName: $BLOB_CONTAINER_NAME
      secretName: azure-secret
      secretNamespace: $CSI_TESTING_PROJECT
      storageAccount: $STORAGE_ACCOUNT_NAME
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
    mountOptions:
      - --file-cache-timeout-in-seconds=120
      - --use-attr-cache=true
      - --cancel-list-on-mount-seconds=10
      - -o allow_other
      - --default-working-dir=/tmp/blobfuse2
    EOF
    ```

    > Note:
    > When using BlobFuse2 on ARO, adding `--default-working-dir=/tmp/blobfuse2` avoids mount failures caused by the default `/.blobfuse2` path being read-only.

1. Create the PersistentVolumeClaim:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: azureblob-pvc
      namespace: $CSI_TESTING_PROJECT
    spec:
      accessModes:
        - ReadWriteMany
      storageClassName: azureblob-fuse2
      resources:
        requests:
          storage: 5Gi
    EOF
    ```

1. Create a test pod that mounts the claim:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: Pod
    metadata:
      name: blobfuse2-test-pod
      namespace: $CSI_TESTING_PROJECT
    spec:
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["/bin/sh", "-c", "sleep infinity"]
        volumeMounts:
        - name: azureblob
          mountPath: /mnt/blob
      volumes:
      - name: azureblob
        persistentVolumeClaim:
          claimName: azureblob-pvc
    EOF
    ```

1. Verify that the pod is running:

    ```bash
    oc get pod -n $CSI_TESTING_PROJECT
    ```

1. Verify that the volume is mounted successfully:

    ```bash
    oc exec -it -n $CSI_TESTING_PROJECT blobfuse2-test-pod -- sh -c 'df -h /mnt/blob && ls -la /mnt/blob'
    ```

    Expected result:
    - the pod is in `Running` state
    - the mount is present at `/mnt/blob`
    - the filesystem shows `blobfuse2`


## Troubleshooting

### Blob CSI controller is not healthy after installation

If the controller pods are not running, check their status and logs:

```bash
oc get pods -n kube-system | grep blob
oc logs -n kube-system deploy/csi-blob-controller -c blob --tail=100 | cat
```

During validation on ARO, dynamic provisioning required additional controller-side Azure configuration in `kube-system`:

* `azure-cred-file` ConfigMap
* `azure-cloud-provider` secret

If those resources are missing or incomplete, the controller may fail to initialize correctly.

You can recreate them and then restart the controller:

```bash
oc rollout restart deploy/csi-blob-controller -n kube-system
oc rollout status deploy/csi-blob-controller -n kube-system
```

### PVC stays in Pending state

If the PersistentVolumeClaim does not bind, describe the PVC and review the related events:

```bash
oc describe pvc azureblob-pvc -n $CSI_TESTING_PROJECT
```

Also verify:

* the `StorageClass` name matches the PVC
* the storage account name and key are correct in the secret
* the blob container exists
* the controller has the required Azure permissions

### Pod is stuck in ContainerCreating

If the pod does not start, describe the pod and review the events:

```bash
oc describe pod blobfuse2-test-pod -n $CSI_TESTING_PROJECT
```

During validation with BlobFuse2 on ARO, one observed failure was a read-only filesystem error for the default BlobFuse2 working directory.

To avoid this, include the following mount option in the `StorageClass`:

```text
--default-working-dir=/tmp/blobfuse2
```

### Verify the mount inside the pod

To confirm the mount is working:

```bash
oc exec -it -n $CSI_TESTING_PROJECT blobfuse2-test-pod -- sh -c 'df -h /mnt/blob && ls -la /mnt/blob'
```

Expected result:

* the pod is in `Running` state
* the mount is present at `/mnt/blob`
* the filesystem shows `blobfuse2`


## Clean up

After testing is complete, remove the test resources created for the Blob CSI validation.

1. Delete the test pod, PersistentVolumeClaim, and StorageClass:

    ```bash
    oc delete pod blobfuse2-test-pod -n $CSI_TESTING_PROJECT
    oc delete pvc azureblob-pvc -n $CSI_TESTING_PROJECT
    oc delete storageclass azureblob-fuse2
    ```

1. Delete the secret from the test project:

    ```bash
    oc delete secret azure-secret -n $CSI_TESTING_PROJECT
    ```

1. Delete the test project:

    ```bash
    oc delete project $CSI_TESTING_PROJECT
    ```

1. If no longer needed, delete the Blob CSI driver resources project:

    ```bash
    oc delete project $CSI_BLOB_PROJECT
    ```

1. If you created the ARO-specific controller configuration for this validation and no longer need it, remove it from `kube-system`:

    ```bash
    oc delete configmap azure-cred-file -n kube-system
    oc delete secret azure-cloud-provider -n kube-system
    ```

1. If no longer needed, delete the service principal created for the Blob CSI driver:

    ```bash
    az ad sp delete --id $AZURE_CLIENT_ID
    ```

1. If you created a temporary storage account and blob container specifically for this test, delete them:

    ```bash
    az storage container delete \
      --name $BLOB_CONTAINER_NAME \
      --account-name $STORAGE_ACCOUNT_NAME

    az storage account delete \
      --name $STORAGE_ACCOUNT_NAME \
      --resource-group $RG_NAME \
      --yes
    ```