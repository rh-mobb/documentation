---
date: '2022-05-23'
title: Trident operator setup for Azure NetApp Files on ARO
tags: ["ARO"]
authors:
  - Byron Miller
  - Connor Wooley
  - Kevin Collins
  - Diana Sari
validated_version: "4.20"
---

{{< alert state="info" >}}
This guide is a simple "happy path" that shows a minimal friction way to use Azure NetApp Files with Azure Red Hat OpenShift. This may not be the best behavior for any system beyond demonstration purposes.
{{< /alert >}}

## Prerequisites

  * An Azure Red Hat OpenShift cluster installed with Service Principal role/credentials. 
  * [oc cli](https://docs.openshift.com/container-platform/4.10/cli_reference/openshift_cli/getting-started-cli.html)
  
Please review the current NetApp Trident documentation for Azure NetApp Files prerequisites and required permissions.

In this guide, you will need service principal and region details. Please have these handy.

* Azure subscriptionID
* Azure tenantID
* Azure clientID (Service Principal)
* Azure clientSecret (Service Principal Secret)
* Azure Region

If you do not want to reuse the existing ARO service principal, you can create a separate service principal and grant it the permissions required to manage the Azure NetApp Files resources used by Trident.

### Important Concepts

Persistent Volume Claims are [namespaced objects](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#a-note-on-namespaces).  Mounting RWX/ROX is only possible within the same namespace.

Azure NetApp Files must have a delegated subnet within your ARO VNet, and that subnet must be delegated to `Microsoft.NetApp/volumes`.

## Configure Azure

You must first register the `Microsoft.NetApp` provider and create an Azure NetApp Files account before you can use Azure NetApp Files.

### Register Azure NetApp files

[Azure Console](https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-register)


```bash
az provider register --namespace Microsoft.NetApp --wait
```

### Create Azure NetApp Files account

Again, for brevity I am using the same RESOURCE_GROUP and Service Principal that the cluster was created with.

[Azure Console](https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-create-netapp-account)

Or with the Azure CLI:

```bash
RESOURCE_GROUP="myresourcegroup"
LOCATION="southcentralus"
ANF_ACCOUNT_NAME="netappfiles"
```

```bash
az netappfiles account create \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --account-name $ANF_ACCOUNT_NAME
```

## Create capacity pool

Creating one pool for now. The common pattern is to expose all three levels with unique pool names respective of each service level.

[Azure Console](https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-set-up-capacity-pool)

Or with the Azure CLI:

```bash
POOL_NAME="Standard"
POOL_SIZE_TiB=4 # Size in Azure CLI needs to be in TiB unit (minimum 4 TiB)
SERVICE_LEVEL="Standard" # Valid values are Standard, Premium and Ultra
```

```bash
az netappfiles pool create \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --account-name $ANF_ACCOUNT_NAME \
    --pool-name $POOL_NAME \
    --size $POOL_SIZE_TiB \
    --service-level $SERVICE_LEVEL
```

### Delegate subnet to ARO

Login to the Azure console, find the VNet used by your ARO cluster, and add a delegated subnet for Azure NetApp Files. Make sure the backend configuration later in this guide references the exact subnet name/path you created.


## Install Trident Operator from OperatorHub/Software Catalog

Login to your ARO cluster and install **NetApp Trident** from **OperatorHub** (or **Software Catalog**) using the certified operator.

1. In the OpenShift console, go to **OperatorHub**.
2. Search for **NetApp Trident**.
3. Select the most recent available operator version.
4. Install the operator in the default recommended configuration.
5. Create a `TridentOrchestrator` instance.

Example:

```yaml
apiVersion: trident.netapp.io/v1
kind: TridentOrchestrator
metadata:
  name: trident
  namespace: openshift-operators
spec:
  namespace: trident
  IPv6: false
```

Apply and verify:

```bash
oc apply -f tridentorchestrator.yaml
oc get tridentorchestrator -n openshift-operators
oc get pods -n trident
```


## Create Trident backend

Create the backend using a Kubernetes Secret and a `TridentBackendConfig` custom resource.

Create the credentials secret first:

```bash
oc -n trident create secret generic anf-credentials \
  --from-literal=clientID="<app-id>" \
  --from-literal=clientSecret="<app-secret>"
```

{{< alert state="info" >}}
* Ensure the service principal has the required Azure permissions for Azure NetApp Files resources.
* If permissions are missing, you may see an error similar to: `capacity pool query returned no data; no capacity pools found for storage pool`.
{{< /alert >}}

Create the backend definition:

```bash
vi backend-anf.yaml
```

Add the following snippet:

```yaml
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: anf-backend
  namespace: trident
spec:
  version: 1
  backendName: anf-backend
  storageDriverName: azure-netapp-files
  credentials:
    name: anf-credentials
  subscriptionID: "12abc678-4774-fake-a1b2-a7abcde39312"
  tenantID: "a7abcde3-edc1-fake-b111-a7abcde356cf"
  location: "southcentralus"
  resourceGroups:
    - "my-resource-group"
  netappAccounts:
    - "my-resource-group/my-anf-account"
  capacityPools:
    - "my-resource-group/my-anf-account/my-capacity-pool"
  virtualNetwork: "my-resource-group/my-vnet"
  subnet: "my-resource-group/my-vnet/my-anf-subnet"
  nasType: "nfs"
```

Apply it:

```bash
oc apply -f backend-anf.yaml
oc get tridentbackendconfig -n trident
oc describe tridentbackendconfig anf-backend -n trident
```

Example successful output:

```bash
NAME          BACKEND NAME   BACKEND UUID                           PHASE   STATUS
anf-backend   anf-backend    bf13f361-91c6-4fc3-8fbe-697601b3f4eb   Bound   Success
```

If backend creation fails, review the Trident controller logs:

```bash
oc logs -n trident deploy/trident-controller --since=10m
```


## Create storage class

Example of StorageClass:

```bash
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: anf-sc
provisioner: csi.trident.netapp.io
parameters:
  backendType: "azure-netapp-files"
allowVolumeExpansion: true
mountOptions:
  - nfsvers=3
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
```

Output:

```bash
storageclass.storage.k8s.io/anf-sc created
```

### Troubleshooting notes

If the backend does not initialize successfully, PVC creation can later fail with errors such as `no available backends for storage class ...` or remain in `Pending`.

Common Azure resource discovery symptoms include:
- `Subnet query returned no data`
- `Resource group referenced in pool not found`
- `Virtual network referenced in pool not found`
- `Subnet referenced in pool not found`
- `no capacity pools found for storage pool <pool-name>`

These usually indicate one or more of the following:
- the resource group, virtual network, subnet, or capacity pool name does not exactly match the Azure resource
- the subnet is not delegated to `Microsoft.NetApp/volumes`
- the service principal role assignment scope is too narrow
- the service principal cannot read the VNet/subnet resources required for backend discovery

During ARO 4.20 validation, two additional Trident-specific issues were observed:
- inline backend credentials were rejected and had to be moved to a Kubernetes Secret referenced by `spec.credentials`
- using `backendName` as a StorageClass parameter was rejected; `backendType: "azure-netapp-files"` worked

Useful validation commands:

```bash
oc get tridentbackendconfig -n trident
oc get tridentbackendconfig -n trident -o yaml
oc logs -n trident deploy/trident-controller -c trident-main
oc describe pvc <pvc-name> -n <namespace>
```

## Provision volume

Create a new project and set up a persistent volume claim. PersistentVolumeClaims are namespaced objects, so create the claim in the namespace where it will be used. In this example, we use the project `netappdemo`.

```bash
oc new-project netappdemo
```

Now create the PVC:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: anf-pvc
  namespace: netappdemo
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: anf-sc
EOF
```

Output:

```bash
persistentvolumeclaim/anf-pvc created
```

Verify that the claim binds successfully:

```bash
oc get pvc -n netappdemo
oc get pv
```


## Verify

Verify that the StorageClass and PersistentVolumeClaim were created successfully.

### Verify with CLI

Check the StorageClass:

```bash
oc get sc
```

Example output:

```bash
NAME                         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
anf-sc                       csi.trident.netapp.io   Delete          Immediate              true                   1m
managed-csi (default)        disk.csi.azure.com      Delete          WaitForFirstConsumer   true                   12d
```

Check the PersistentVolumeClaim:

```bash
oc get pvc -n netappdemo
```

Example output:

```bash
NAME      STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
anf-pvc   Bound    pvc-b835e6c6-3f3e-4a6b-aeb3-3b2906df3bd5   100Gi      RWX            anf-sc         <unset>                 15s
```

Check the PersistentVolumes:

```bash
oc get pv
```

Example output:

```bash
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM              STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
pvc-b835e6c6-3f3e-4a6b-aeb3-3b2906df3bd5   100Gi      RWX            Delete           Bound    netappdemo/anf-pvc anf-sc         <unset>                          15s
```

### Verify in OpenShift Console

Login to the cluster as `cluster-admin` and confirm that:

* the `anf-sc` StorageClass is present
* the `anf-pvc` claim in the `netappdemo` project is `Bound`
* a dynamically provisioned PersistentVolume was created for the claim

## Create Pods to test Azure NetApp

Create two pods to validate the Azure NetApp file mount. One pod writes data to the shared volume, and the second pod reads the same data back to confirm `ReadWriteMany` access is working correctly.

{{< alert state="info" >}}
On current OpenShift clusters, these simple demo pods may emit Pod Security warnings unless restricted-compatible `securityContext` settings are added. The sample still works for basic validation.
{{< /alert >}}

### Writer Pod

This pod writes `hello netapp` to the shared mount backed by the `anf-pvc` claim.

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: writer
  namespace: netappdemo
spec:
  containers:
    - name: writer
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["/bin/sh", "-c"]
      args:
        - echo "hello netapp" > /data/hello.txt && sleep 3600
      volumeMounts:
        - name: shared
          mountPath: /data
  volumes:
    - name: shared
      persistentVolumeClaim:
        claimName: anf-pvc
EOF
```

Watch for the pod to become ready:

```bash
oc get pod writer -n netappdemo -w
```

Verify the file was written:

```bash
oc exec -n netappdemo writer -- cat /data/hello.txt
```

Expected output:

```bash
hello netapp
```

### Reader Pod

This pod reads the same file from the shared mount.

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: reader
  namespace: netappdemo
spec:
  containers:
    - name: reader
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["/bin/sh", "-c"]
      args:
        - cat /data/hello.txt && sleep 3600
      volumeMounts:
        - name: shared
          mountPath: /data
  volumes:
    - name: shared
      persistentVolumeClaim:
        claimName: anf-pvc
EOF
```

Wait for the pod to be ready:

```bash
oc get pod reader -n netappdemo -w
```

Verify the reader pod can access the shared file:

```bash
oc logs -n netappdemo reader
oc exec -n netappdemo reader -- cat /data/hello.txt
```

Expected output:

```bash
hello netapp
hello netapp
```

The first `hello netapp` is from the pod logs, and the second is from the `oc exec` command. This confirms that both pods successfully accessed the same Azure NetApp-backed `ReadWriteMany` volume.
