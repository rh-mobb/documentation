---
date: '2023-08-23'
title: Use Azure Blob storage Container Storage Interface (CSI) driver on an ARO cluster
tags: ["ARO", "ARO Classic"]
authors:
  - Daniel Penagos
  - Paul Czarkowski
  - Diana Sari
  - Kevin Collins
validated_version: "4.21"
---

The Azure Blob Storage Container Storage Interface (CSI) is a CSI-compliant driver that can be installed on an Azure Red Hat OpenShift (ARO) cluster to provision and mount Azure Blob storage for Kubernetes workloads.

The driver mounts Azure Blob storage for use by pods.

You can also refer to the driver's documentation [here](https://github.com/kubernetes-sigs/blob-csi-driver/blob/master/charts/README.md).

The Azure Blob CSI driver supports two common dynamic provisioning models:

- **Driver-managed path**: the driver can select or create a suitable storage account when one is not explicitly specified in the StorageClass.
- **Bring your own (BYO) storage account path**: the StorageClass is tied to an existing storage account that you create and manage.


## Scope of validation

* The steps below were validated on ARO using a dynamic provisioning path with BlobFuse2 and a manually specified storage account.
* The driver-managed storage account creation path was outside the scope of this update.
* During validation, the ARO-specific configuration included:
  - a dedicated cloud configuration secret in `kube-system`
  - the chart's RHCOS path handling with read-ahead configuration disabled
  - an explicit BlobFuse2 working directory in the dynamic StorageClass mount options
* A statically provisioned volume using service principal authentication and an Azure RBAC data role was also validated, and is described in [Mounting without a storage account key](#mounting-without-a-storage-account-key).


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
    export CSI_BLOB_SECRET=csi-azure-blob-secret
    export CSI_TESTING_PROJECT=testing-project
    ```

1. Set additional environment variables for the storage resources used by the test workflow, including the storage account and blob container names:

    ```bash
    export APP_NAME=myapp
    export STORAGE_ACCOUNT_NAME=aroblobsa
    export BLOB_CONTAINER_NAME=aroblob
    ```

The storage account name must be globally unique in Azure. Update `STORAGE_ACCOUNT_NAME` if the sample name is already in use.

## Create an identity for the CSI Driver to access the Blob Storage

The Azure Blob CSI driver needs Azure credentials so it can access the blob storage resources used by this walkthrough.

This guide uses:

- a service principal with the required Azure permissions
- a Kubernetes secret for the driver
- additional ARO-specific controller cloud configuration in `kube-system`


1. Create a service principal for the Blob CSI driver:

    ```bash
    umask 077
    az ad sp create-for-rbac \
      --name http://$CSI_BLOB_SECRET \
      --skip-assignment > blob-csi-driver-credentials.json
    ```

    Note that the service principal name based on `http://$CSI_BLOB_SECRET` must be unique enough to avoid colliding with an existing Azure AD app.

1. Export the values from the protected credentials file:

    ```bash
    export AZURE_CLIENT_ID=$(jq -r .appId blob-csi-driver-credentials.json)
    export AZURE_CLIENT_SECRET=$(jq -r .password blob-csi-driver-credentials.json)
    export AZURE_TENANT_ID=$(jq -r .tenant blob-csi-driver-credentials.json)
    ```

    Delete `blob-csi-driver-credentials.json` after creating the cloud configuration secret.

1. Assign the required roles to the service principal.

    The lab used these permissions:

    - `Contributor` on the relevant resource group
    - `Storage Account Contributor` on the target storage account after that account is created

    These permissions supported the tested lab. They are not presented as the minimum permissions for every BYO storage account deployment. Required permissions depend on which resources the driver must discover, create, or manage.


    Assign `Contributor` on the resource group:

    ```bash
    export CSI_RG_ROLE_ASSIGNMENT_ID=$(az role assignment create \
      --assignee $AZURE_CLIENT_ID \
      --role Contributor \
      --scope /subscriptions/$SUB_ID/resourceGroups/$RG_NAME \
      --query id -o tsv)
    ```


1. Create a dedicated cloud configuration secret in `kube-system` for the Blob CSI driver:

    ```bash
    cat <<EOF > blob-csi-cloud-provider.json
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

    oc -n kube-system create secret generic blob-csi-cloud-provider \
      --from-file=cloud-config=blob-csi-cloud-provider.json
    ```

    {{< alert state="warning" >}}
    If `oc create` returns `AlreadyExists`, stop and resolve the name or ownership conflict before continuing. Do not overwrite or delete the existing resource. This guide uses `blob-csi-cloud-provider` instead of the chart default, `azure-cloud-provider`. Never modify or delete `azure-cloud-provider` as part of this guide.
    {{< /alert >}}

    After `oc create` succeeds, label the new secret and remove the temporary files:

    ```bash
    oc -n kube-system label secret blob-csi-cloud-provider \
      app.kubernetes.io/part-of=blob-csi-guide

    rm -f blob-csi-cloud-provider.json blob-csi-driver-credentials.json
    ```

    Keep the data key as `cloud-config`. The driver reads the secret through the Kubernetes API at runtime, so it does not appear as a mounted volume in the pod specification.


## Driver installation

After creating the identity and required Azure configuration, install the Azure Blob CSI driver on the cluster.

On ARO, use the chart's RHCOS path handling and disable its read-ahead initialization. In chart `1.27.11`, `linux.distro: rhcos` changes the init container's `/usr/local` host mount to `/var/usrlocal`. Setting `node.blobfuseProxy.setReadAheadSize: false` prevents the init script from writing a host udev rule and running `udevadm control --reload`, which fails on RHCOS. The init container remains in place and completes normally, so no manual DaemonSet patch is required.

1. Add the Blob CSI driver Helm repository:

    ```bash
    helm repo add blob-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/charts
    helm repo update
    ```

1. Install the Blob CSI driver chart with the ARO-specific settings:

    ```bash
    cat <<EOF > blob-csi-aro-values.yaml
    linux:
      distro: rhcos

    controller:
      cloudConfigSecretName: blob-csi-cloud-provider
      cloudConfigSecretNamespace: kube-system

    node:
      cloudConfigSecretName: blob-csi-cloud-provider
      cloudConfigSecretNamespace: kube-system
      enableBlobfuseProxy: false
      enableAznfsMount: false
      blobfuseProxy:
        setReadAheadSize: false
    EOF

    helm install blob-csi-driver blob-csi-driver/blob-csi-driver \
      --namespace kube-system \
      --version 1.27.11 \
      -f blob-csi-aro-values.yaml
    ```

    The `cloudConfigSecretName` overrides point the controller and node components at the dedicated secret created in the previous section, instead of the chart default `azure-cloud-provider`.

1. Confirm the controller and node workloads reference the dedicated secret:

    ```bash
    oc get deploy csi-blob-controller -n kube-system \
      -o jsonpath='{.spec.template.spec.containers[*].args}' \
      | tr ' ' '\n' | grep cloud-config-secret
    ```

    Repeat the check for the node DaemonSet:

    ```bash
    oc get daemonset csi-blob-node -n kube-system \
      -o jsonpath='{.spec.template.spec.containers[*].args}' \
      | tr ' ' '\n' | grep cloud-config-secret
    ```

    Both commands should name `blob-csi-cloud-provider` and `kube-system`.

1. Confirm the RHCOS init settings rendered as expected:

    ```bash
    oc get daemonset csi-blob-node -n kube-system -o yaml | grep -A1 -E \
      'SET_READ_AHEAD_SIZE|host-usr-local|mountPath: /host/var/usrlocal|path: /var/usrlocal'
    ```

    Verify that `SET_READ_AHEAD_SIZE` is `false`, the init container mount path is `/host/var/usrlocal`, and the host path is `/var/usrlocal`.

1. Verify that the Blob CSI driver pods are running:

    ```bash
    oc get pods -n kube-system | grep blob
    ```

    Expected output should include two Blob CSI controller pods and one node pod per cluster node in a `Running` state. Do not continue while any node pod is in an init error state.

1. Confirm that the controller and node processes actually read the dedicated secret:

    ```bash
    oc get pods -n kube-system -l app=csi-blob-controller -o wide
    oc logs -n kube-system deploy/csi-blob-controller -c blob --tail=100 | cat

    oc get pods -n kube-system -l app=csi-blob-node -o wide
    oc logs -n kube-system daemonset/csi-blob-node -c blob --tail=100 | cat
    ```

    In both logs, look for `reading cloud config from secret kube-system/blob-csi-cloud-provider`. Checking only the container arguments proves that the configuration rendered; the startup log proves that the process read the named secret.


## Test the CSI driver is working

To test the Blob CSI driver, create the required storage resources, then create a StorageClass, PersistentVolumeClaim, and a pod that mounts the provisioned storage.

1. Create the storage account:

    ```bash
    az storage account create \
      --name $STORAGE_ACCOUNT_NAME \
      --resource-group $RG_NAME \
      --location $LOCATION \
      --sku Standard_LRS \
      --kind StorageV2 \
      --allow-shared-key-access true \
      --min-tls-version TLS1_2
    ```

    Assign `Storage Account Contributor` on the storage account:

    ```bash
    export STORAGE_ACCOUNT_ID=$(az storage account show \
      --name $STORAGE_ACCOUNT_NAME \
      --resource-group $RG_NAME \
      --query id -o tsv)

    test -n "$STORAGE_ACCOUNT_ID"

    export CSI_STORAGE_ROLE_ASSIGNMENT_ID=$(az role assignment create \
      --assignee $AZURE_CLIENT_ID \
      --role "Storage Account Contributor" \
      --scope $STORAGE_ACCOUNT_ID \
      --query id -o tsv)
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
    umask 077
    az storage account keys list \
      --account-name $STORAGE_ACCOUNT_NAME \
      --resource-group $RG_NAME \
      --query '[0].value' -o tsv > azurestorageaccountkey

    oc create secret generic azure-secret \
      --from-literal azurestorageaccountname=$STORAGE_ACCOUNT_NAME \
      --from-file=azurestorageaccountkey=azurestorageaccountkey \
      -n $CSI_TESTING_PROJECT

    rm -f azurestorageaccountkey
    ```

    {{< alert state="info" >}}
    This uses a storage account key. If your organization does not permit shared key access, see [Mounting without a storage account key](#mounting-without-a-storage-account-key) below for a service principal and Azure RBAC alternative.
    {{< /alert >}}

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

    {{< alert state="info" >}}
    When using BlobFuse2 on ARO, adding `--default-working-dir=/tmp/blobfuse2` avoids mount failures caused by the default `/.blobfuse2` path being read-only.
    {{< /alert >}}

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
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["/bin/sh", "-c", "sleep infinity"]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
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

1. Verify create, read, modify, and delete operations through the mount:

    ```bash
    oc exec -n $CSI_TESTING_PROJECT blobfuse2-test-pod -- sh -ceu '
      probe=/mnt/blob/.dynamic-probe
      printf "first\n" > "$probe"
      test "$(cat "$probe")" = first
      printf "second\n" >> "$probe"
      cat "$probe"
      rm "$probe"
      test ! -e "$probe"
    '
    ```

    If the Blob CSI node DaemonSet is restarted later, existing BlobFuse2 mounts can report `Transport endpoint is not connected` even though their workload pods still show `Running`. Recreate only the affected workload pods after the node rollout so Kubernetes establishes fresh mounts.


## Mounting without a storage account key

The test workflow above authenticates with a storage account key. Where shared key access is not permitted, a service principal with an Azure RBAC data role can be used instead, through a statically provisioned volume.

This removes storage account keys from the mount. It is not secretless: the service principal still has a client secret. If client secrets are also prohibited, this approach does not meet that requirement either.

1. If you are starting with this section, create a dedicated test project or select one that you created for this walkthrough:

    ```bash
    oc get project $CSI_TESTING_PROJECT
    ```

    If it does not exist, create it:

    ```bash
    oc new-project $CSI_TESTING_PROJECT
    ```

    If it already exists and is dedicated to this walkthrough, select it:

    ```bash
    oc project $CSI_TESTING_PROJECT
    ```

    Do not use a shared project because the cleanup section removes the test project.

1. Set unique names for a second, dedicated storage account and application:

    ```bash
    export SPN_STORAGE_ACCOUNT_NAME=<globally-unique-storage-account-name>
    export SPN_BLOB_CONTAINER_NAME=blob-spn
    export BLOB_APP_NAME=<unique-application-name>
    ```

1. Create the storage account with Shared Key access disabled, then create the container through the Azure Resource Manager API:

    ```bash
    az storage account create \
      --name $SPN_STORAGE_ACCOUNT_NAME \
      --resource-group $RG_NAME \
      --location $LOCATION \
      --sku Standard_LRS \
      --kind StorageV2 \
      --allow-shared-key-access false \
      --https-only true \
      --min-tls-version TLS1_2

    export SPN_STORAGE_ACCOUNT_ID=$(az storage account show \
      --resource-group $RG_NAME \
      --name $SPN_STORAGE_ACCOUNT_NAME \
      --query id -o tsv)

    az storage container-rm create \
      --storage-account $SPN_STORAGE_ACCOUNT_ID \
      --name $SPN_BLOB_CONTAINER_NAME \
      --public-access off \
      --fail-on-exist

    az storage account show \
      --resource-group $RG_NAME \
      --name $SPN_STORAGE_ACCOUNT_NAME \
      --query allowSharedKeyAccess -o tsv
    ```

    Using `az storage container-rm` avoids relying on a storage account key to create the container. The final command must return `false`.

1. Create a dedicated application identity and save its generated credentials in a protected temporary file:

    ```bash
    umask 077
    az ad sp create-for-rbac \
      --name $BLOB_APP_NAME \
      --skip-assignment > blob-spn-credentials.json

    export BLOB_CLIENT_ID=$(jq -r .appId blob-spn-credentials.json)
    export BLOB_TENANT_ID=$(jq -r .tenant blob-spn-credentials.json)
    export BLOB_SP_OBJECT_ID=$(az ad sp show --id $BLOB_CLIENT_ID --query id -o tsv)
    export IS_HNS_ENABLED=$(az storage account show \
      --resource-group $RG_NAME --name $SPN_STORAGE_ACCOUNT_NAME \
      --query 'isHnsEnabled || `false`' -o tsv)
    ```

    The credentials file contains a client secret. Keep it out of source control and delete it after creating the Kubernetes Secret. `az ad sp show` returns the service principal object ID, which is different from the application client ID. Role assignments need the object ID.

1. Grant the application a data plane role scoped to the container:

    ```bash
    export BLOB_ROLE_ASSIGNMENT_ID=$(az role assignment create \
      --assignee-object-id $BLOB_SP_OBJECT_ID \
      --assignee-principal-type ServicePrincipal \
      --role "Storage Blob Data Contributor" \
      --scope "$SPN_STORAGE_ACCOUNT_ID/blobServices/default/containers/$SPN_BLOB_CONTAINER_NAME" \
      --query id -o tsv)
    ```

    Role assignments can take several minutes to take effect.

1. If you need independent proof of the authenticating identity, enable Blob service diagnostics before mounting the volume:

    ```bash
    export LOG_WORKSPACE=<unique-log-analytics-workspace-name>

    az monitor log-analytics workspace create \
      --resource-group $RG_NAME \
      --workspace-name $LOG_WORKSPACE \
      --location $LOCATION

    export LOG_WORKSPACE_ID=$(az monitor log-analytics workspace show \
      --resource-group $RG_NAME \
      --workspace-name $LOG_WORKSPACE \
      --query id -o tsv)

    az monitor diagnostic-settings create \
      --name blob-csi-oauth \
      --resource "$SPN_STORAGE_ACCOUNT_ID/blobServices/default" \
      --workspace $LOG_WORKSPACE_ID \
      --logs '[{"category":"StorageRead","enabled":true},{"category":"StorageWrite","enabled":true},{"category":"StorageDelete","enabled":true}]'
    ```

    Log ingestion is not immediate. The mount and I/O tests do not need this diagnostic setting, but identity verification does.

1. Create a secret holding only the client secret. Read it from a protected file rather than passing it on the command line:

    ```bash
    jq -r .password blob-spn-credentials.json > blob-spn-client-secret

    oc -n $CSI_TESTING_PROJECT create secret generic blob-spn \
      --from-file=azurestoragespnclientsecret=blob-spn-client-secret

    rm -f blob-spn-client-secret blob-spn-credentials.json
    ```

    This secret contains no `azurestorageaccountkey`, and is separate from both `azure-secret` and the driver's `blob-csi-cloud-provider` secret.

1. Create a statically provisioned volume that selects service principal authentication:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: pv-blob-spn
    spec:
      capacity:
        storage: 1Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      storageClassName: ""
      claimRef:
        namespace: $CSI_TESTING_PROJECT
        name: blob-spn-pvc
      mountOptions:
        - -o allow_other
      csi:
        driver: blob.csi.azure.com
        volumeHandle: "$RG_NAME#$SPN_STORAGE_ACCOUNT_NAME#$SPN_BLOB_CONTAINER_NAME#spn"
        volumeAttributes:
          protocol: fuse2
          subscriptionID: "$SUB_ID"
          resourceGroup: "$RG_NAME"
          storageAccount: "$SPN_STORAGE_ACCOUNT_NAME"
          containerName: "$SPN_BLOB_CONTAINER_NAME"
          isHnsEnabled: "$IS_HNS_ENABLED"
          AzureStorageAuthType: "SPN"
          AzureStorageSPNClientID: "$BLOB_CLIENT_ID"
          AzureStorageSPNTenantID: "$BLOB_TENANT_ID"
        nodeStageSecretRef:
          name: blob-spn
          namespace: $CSI_TESTING_PROJECT
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: blob-spn-pvc
      namespace: $CSI_TESTING_PROJECT
    spec:
      accessModes:
        - ReadWriteMany
      storageClassName: ""
      volumeName: pv-blob-spn
      resources:
        requests:
          storage: 1Gi
    EOF
    ```

    An empty `storageClassName` keeps this volume out of the dynamic, key based StorageClass created earlier. The `volumeHandle` must be unique within the cluster, and the capacity is a binding value rather than a quota on the container.

1. Create a test pod that mounts the static claim:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: Pod
    metadata:
      name: blob-spn-test-pod
      namespace: $CSI_TESTING_PROJECT
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["/bin/sh", "-c", "sleep infinity"]
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: azureblob
          mountPath: /mnt/blob
      volumes:
      - name: azureblob
        persistentVolumeClaim:
          claimName: blob-spn-pvc
    EOF
    ```

1. Confirm the claim binds and the pod becomes ready:

    ```bash
    oc get pvc blob-spn-pvc -n $CSI_TESTING_PROJECT
    oc wait pod/blob-spn-test-pod -n $CSI_TESTING_PROJECT \
      --for=condition=Ready --timeout=5m
    ```

1. Verify the data path from inside the pod:

    ```bash
    oc exec blob-spn-test-pod -n $CSI_TESTING_PROJECT -- sh -ceu '
      probe="/mnt/blob/.spn-probe-$(date +%s)"
      printf "first\n" > "$probe"
      printf "second\n" >> "$probe"
      cat "$probe"
      rm "$probe"
    '
    ```

    The output should be `first` and `second` on separate lines.

1. If you enabled diagnostics, query the ingested storage requests:

    ```bash
    export LOG_WORKSPACE_CUSTOMER_ID=$(az monitor log-analytics workspace show \
      --resource-group $RG_NAME \
      --workspace-name $LOG_WORKSPACE \
      --query customerId -o tsv)

    az monitor log-analytics query \
      --workspace $LOG_WORKSPACE_CUSTOMER_ID \
      --timespan PT1H \
      --analytics-query "StorageBlobLogs
        | where TimeGenerated > ago(1h)
        | where AccountName == '$SPN_STORAGE_ACCOUNT_NAME'
        | project TimeGenerated, OperationName, AuthenticationType, RequesterAppId, StatusCode, StatusText
        | order by TimeGenerated desc"
    ```

    Allow several minutes for ingestion. Successful `PutBlob`, `ListBlobs`, and `DeleteBlob` rows should have `AuthenticationType` set to `OAuth` and `RequesterAppId` set to `$BLOB_CLIENT_ID`.

    {{< alert state="info" >}}
    A bound claim and a successful mount prove that the data path works while Shared Key is disabled, but do not by themselves identify the caller. The diagnostic log fields provide that separate identity proof.
    {{< /alert >}}

## Troubleshooting

### Blob CSI controller is not healthy after installation

If the controller pods are not running, check their status and logs:

```bash
oc get pods -n kube-system | grep blob
oc logs -n kube-system deploy/csi-blob-controller -c blob --tail=100 | cat
```

During validation on ARO, dynamic provisioning required additional controller-side Azure configuration in `kube-system`:

* the dedicated cloud configuration secret

If the secret is missing or incomplete, the controller may fail to initialize correctly.

You can recreate the secret and then restart the controller:

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

Delete only resources that you created while following this guide. If a name existed before you started, do not overwrite or delete that resource. Never modify or delete the existing `azure-cloud-provider` secret.

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

1. If you followed [Mounting without a storage account key](#mounting-without-a-storage-account-key), remove those resources as well:

    ```bash
    oc delete pod blob-spn-test-pod -n $CSI_TESTING_PROJECT
    oc delete pvc blob-spn-pvc -n $CSI_TESTING_PROJECT
    oc delete pv pv-blob-spn
    oc delete secret blob-spn -n $CSI_TESTING_PROJECT

    az role assignment delete --ids $BLOB_ROLE_ASSIGNMENT_ID
    az ad app delete --id $BLOB_CLIENT_ID
    az storage account delete \
      --name $SPN_STORAGE_ACCOUNT_NAME \
      --resource-group $RG_NAME \
      --yes

    if test -n "$LOG_WORKSPACE"; then
      az monitor log-analytics workspace delete \
        --resource-group $RG_NAME \
        --workspace-name $LOG_WORKSPACE \
        --yes
    fi
    ```

    Skip the Log Analytics command if you did not enable diagnostics. Deleting the dedicated storage account also removes its diagnostic setting.

1. Delete the test project:

    ```bash
    oc delete project $CSI_TESTING_PROJECT
    ```

    Run this command only if you created the project for this walkthrough and it contains no unrelated resources.

1. Uninstall the Blob CSI driver Helm chart:

    ```bash
    helm uninstall blob-csi-driver -n kube-system
    ```

1. Remove the dedicated driver secret only if it still carries the label added by this walkthrough:

    ```bash
    oc delete secret blob-csi-cloud-provider -n kube-system \
      --selector app.kubernetes.io/part-of=blob-csi-guide
    ```

    The selector is an additional safeguard, not proof of ownership. Run this command only for the secret that you successfully created and labeled during this walkthrough. Do not delete `azure-cloud-provider`.

1. If no longer needed, delete the service principal created for the Blob CSI driver:

    ```bash
    az role assignment delete --ids \
      $CSI_RG_ROLE_ASSIGNMENT_ID \
      $CSI_STORAGE_ROLE_ASSIGNMENT_ID

    az ad app delete --id $AZURE_CLIENT_ID
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
