---
date: '2026-06-24'
title: Cloning PersistentVolumeClaims Across Namespaces in Azure Red Hat OpenShift (ARO)

tags: ["ARO"]
authors:
  - Nerav Doshi
validated_version: "4.20"
---

Copy persistent volume data from one OpenShift namespace to another on Azure Red Hat OpenShift (ARO) using the default `managed-csi` storage class (Azure Disk CSI).

This guide walks through a self-contained lab you can run without deploying a full application stack. Use it when you need to duplicate data into a new namespace for testing, migration, or recovery. For cluster-wide backup and restore to Azure Blob Storage, see [Backup and Restore for ARO using OADP](/experts/aro/backup-restore/).

## Overview

### Cross-Namespace PVC Cloning Workflow

<style>
article .mermaid {
  max-width: 100%;
}
article .mermaid svg {
  width: 1200px;
  max-width: 100%;
  height: auto;
}
</style>

{{< mermaid >}}
%%{init: {"flowchart": {"useMaxWidth": false, "nodeSpacing": 50, "rankSpacing": 70, "padding": 20}, "themeVariables": {"fontSize": "22px"}}}%%
flowchart LR
    subgraph src ["SOURCE NS (e.g. my-app-source)"]
        direction TB
        pvc["PVC<br/>lab-data"]
        vs["VolumeSnapshot<br/>(namespaced)"]
        pvc -->|snapshot| vs
    end

    vsc["VolumeSnapshotContent<br/>(cluster-scoped)"]

    subgraph tgt ["TARGET NS (e.g. my-app-target)"]
        direction TB
        import["Pre-provisioned<br/>VolumeSnapshotContent<br/>(import)"]
        bridge["VolumeSnapshot<br/>(bridge)"]
        tgtpvc["PVC<br/>dataSource: VolumeSnapshot"]
        pod["Pod / workload"]
        import --> bridge
        bridge -->|restore| tgtpvc
        tgtpvc -->|mount| pod
    end

    vs -.->|bound to| vsc
    vsc -->|"(1) read snapshotHandle<br/>Azure snapshot ID"| import

    style src fill:#DAE8FC,stroke:#6C8EBF,stroke-width:2px,color:#1a1a1a
    style tgt fill:#D5E8D4,stroke:#82B366,stroke-width:2px,color:#1a1a1a
    style vsc fill:#FFF2CC,stroke:#D6B656,stroke-width:2px,color:#1a1a1a
    style pvc fill:#FFFFFF,stroke:#6C8EBF,stroke-width:2px
    style vs fill:#FFFFFF,stroke:#6C8EBF,stroke-width:2px
    style import fill:#FFFFFF,stroke:#82B366,stroke-width:2px
    style bridge fill:#FFFFFF,stroke:#82B366,stroke-width:2px
    style tgtpvc fill:#FFFFFF,stroke:#82B366,stroke-width:2px
    style pod fill:#FFFFFF,stroke:#82B366,stroke-width:2px

    linkStyle 2 stroke:#CC0000,stroke-width:3px
{{< /mermaid >}}


### What works on ARO

On managed ARO, block volumes use the `managed-csi` storage class (Azure Disk CSI). How you copy PVC data depends on whether the source and target namespaces are the same.

**Cross-namespace (this guide).** When the source PVC and the new PVC are in different namespaces, use volume snapshot import: snapshot the source PVC, copy the Azure `snapshotHandle` from the cluster-scoped `VolumeSnapshotContent`, pre-provision import content in the target namespace, restore a PVC from a namespaced `VolumeSnapshot`, then mount it from a pod or workload. The diagram above and the steps below follow this pattern.

**Same namespace.** If both PVCs stay in one namespace, you do not need snapshot import. Use the OpenShift console **Clone** action, or create a new PVC with `dataSource: PersistentVolumeClaim` pointing at the source claim.

**Other cross-namespace options.** For small volumes or one-off copies, file-level copy with `tar` and `oc exec` works without snapshots. The Kubernetes `CrossNamespaceVolumeDataSource` feature is alpha and is not enabled on managed ARO.

**Patterns to avoid.** Do not restore a cross-namespace clone by setting `dataSource: VolumeSnapshotContent` on the target PVC (Azure Disk CSI provisions an empty disk). Do not create a bridge `VolumeSnapshot` that references the source namespace's dynamic `VolumeSnapshotContent` (the driver expects pre-provisioned content).

### Azure Disk (`managed-csi`) requirements

- Storage class `managed-csi` uses **`WaitForFirstConsumer`**: PVC stays `Pending` until a pod mounts it.
- **Source volume must be attached to a running pod** when the snapshot is taken.
- Run **`sync`** on the source pod before snapshotting so data is flushed to disk.
- Restored PVC size must be **≥ snapshot restore size**.
- On Azure Disk CSI, restore PVC must use **`dataSource: VolumeSnapshot`** (namespaced), not `VolumeSnapshotContent` directly.

## Prerequisites

Before starting, ensure you have:

* `oc` logged in to an ARO cluster
* Cluster admin or sufficient RBAC to create snapshots and PVCs in both namespaces
* Azure Disk CSI snapshots enabled on the cluster
* For cloning an existing workload, a source PVC that is bound and mounted by a running pod

## Confirm prerequisites

Confirm the CLI can reach the cluster:

```bash
oc version
oc whoami
```

Confirm the default block storage class:

```bash
oc get storageclass managed-csi -o yaml | grep -E 'provisioner|volumeBindingMode'
```

Expected output (values may vary):

```text
provisioner: disk.csi.azure.com
volumeBindingMode: WaitForFirstConsumer
```

Confirm a `VolumeSnapshotClass` exists for Azure Disk:

```bash
oc get volumesnapshotclass
```

Expected output:

```text
NAME                                   DRIVER               DELETIONPOLICY   AGE
csi-azuredisk-vsc                      disk.csi.azure.com   Delete           ...
```

If no `VolumeSnapshotClass` exists, check your OpenShift version and the Azure Disk CSI operator in `openshift-cluster-csi-drivers`.

## Set environment variables

Customize these for your clone:

```bash
export SOURCE_NS="pvc-clone-lab-source"
export TARGET_NS="pvc-clone-lab-target"
export SOURCE_PVC="lab-data"
export TARGET_PVC="lab-data-clone"
export STORAGE_CLASS="managed-csi"
export PVC_SIZE="1Gi"
export SNAPSHOT_NAME="lab-snapshot-$(date +%Y%m%d)"
export IMPORT_SNAPSHOT_NAME="lab-snapshot-import"
export SNAPSHOT_CONTENT_NAME="snapcontent-lab-import"
```

## Step 1: Create namespaces

```bash
oc create namespace "${SOURCE_NS}" --dry-run=client -o yaml | oc apply -f -
oc create namespace "${TARGET_NS}" --dry-run=client -o yaml | oc apply -f -
```

Expected output:

```text
namespace/pvc-clone-lab-source created
namespace/pvc-clone-lab-target created
```

## Step 2: Create source PVC and write test data

Create the source PVC:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${SOURCE_PVC}
  namespace: ${SOURCE_NS}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF
```

Create a writer pod that mounts the PVC and writes a test file:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: lab-writer
  namespace: ${SOURCE_NS}
spec:
  containers:
    - name: writer
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["/bin/sh", "-c"]
      args:
        - |
          echo "clone-test-$(date -Iseconds)" > /data/testfile.txt
          echo "done" > /data/ready
          sleep 3600
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${SOURCE_PVC}
EOF
```

Wait for the pod to be ready and confirm the PVC is bound:

```bash
oc wait --for=condition=Ready pod/lab-writer -n "${SOURCE_NS}" --timeout=300s
oc get pvc -n "${SOURCE_NS}"
```

Expected output:

```text
NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
lab-data   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            managed-csi    <unset>                 1m
```

Read the test file and flush data to disk before snapshotting:

```bash
oc exec -n "${SOURCE_NS}" lab-writer -- cat /data/testfile.txt
oc exec -n "${SOURCE_NS}" lab-writer -- sync
```

Expected output:

```text
clone-test-2026-06-24T12:00:00+00:00
```

## Step 3: Take a VolumeSnapshot

```bash
export VSC_CLASS=$(oc get volumesnapshotclass -o jsonpath='{.items[?(@.driver=="disk.csi.azure.com")].metadata.name}')

cat <<EOF | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${SOURCE_NS}
spec:
  volumeSnapshotClassName: ${VSC_CLASS}
  source:
    persistentVolumeClaimName: ${SOURCE_PVC}
EOF
```

Wait until the snapshot is ready:

```bash
oc wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/${SNAPSHOT_NAME} -n "${SOURCE_NS}" --timeout=600s

oc get volumesnapshot -n "${SOURCE_NS}"
```

Expected output:

```text
NAME                    READYTOUSE   SOURCEPVC   SOURCESNAPSHOTCONTENT   RESTORESIZE   SNAPSHOTCLASS       SNAPSHOTCONTENT                                    CREATIONTIME   AGE
lab-snapshot-20260624   true         lab-data                            1Gi           csi-azuredisk-vsc   snapcontent-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   2m             2m
```

## Step 4: Get the Azure snapshot handle

```bash
export SNAPSHOT_CONTENT=$(oc get volumesnapshot "${SNAPSHOT_NAME}" -n "${SOURCE_NS}" \
  -o jsonpath='{.status.boundVolumeSnapshotContentName}')

export SNAPSHOT_HANDLE=$(oc get volumesnapshotcontent "${SNAPSHOT_CONTENT}" \
  -o jsonpath='{.status.snapshotHandle}')

echo "VolumeSnapshotContent: ${SNAPSHOT_CONTENT}"
echo "Azure snapshotHandle:    ${SNAPSHOT_HANDLE}"
```

Expected output:

```text
VolumeSnapshotContent: snapcontent-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Azure snapshotHandle:    /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/snapshots/<snapshot-name>
```

## Step 5: Import snapshot into the target namespace

**Do not** point a PVC directly at the source `VolumeSnapshotContent`. Azure Disk CSI ignores it and provisions an **empty** disk (only `lost+found`).

**Do not** create a bridge `VolumeSnapshot` that references the dynamically provisioned source content. That fails with:

```text
expects a pre-provisioned VolumeSnapshotContent but gets a dynamically provisioned one
```

Instead, create a **new pre-provisioned** `VolumeSnapshotContent` in the target namespace using the Azure `snapshotHandle`, then a bridge `VolumeSnapshot`, then restore the PVC from that local `VolumeSnapshot`.

Pre-provisioned import content:

```bash
cat <<EOF | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotContent
metadata:
  name: ${SNAPSHOT_CONTENT_NAME}
spec:
  deletionPolicy: Retain
  driver: disk.csi.azure.com
  source:
    snapshotHandle: ${SNAPSHOT_HANDLE}
  volumeSnapshotRef:
    name: ${IMPORT_SNAPSHOT_NAME}
    namespace: ${TARGET_NS}
  volumeSnapshotClassName: ${VSC_CLASS}
EOF
```

Bridge `VolumeSnapshot` in the target namespace:

```bash
cat <<EOF | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${IMPORT_SNAPSHOT_NAME}
  namespace: ${TARGET_NS}
spec:
  volumeSnapshotClassName: ${VSC_CLASS}
  source:
    volumeSnapshotContentName: ${SNAPSHOT_CONTENT_NAME}
EOF
```

Wait until the imported snapshot is ready:

```bash
oc wait --for=jsonpath='{.status.readyToUse}'=true \
  volumesnapshot/${IMPORT_SNAPSHOT_NAME} -n "${TARGET_NS}" --timeout=600s
```

Expected output:

```text
volumesnapshot.snapshot.storage.k8s.io/lab-snapshot-import condition met
```

## Step 6: Restore PVC from imported VolumeSnapshot

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TARGET_PVC}
  namespace: ${TARGET_NS}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${STORAGE_CLASS}
  resources:
    requests:
      storage: ${PVC_SIZE}
  dataSource:
    name: ${IMPORT_SNAPSHOT_NAME}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF
```

The PVC may show **Pending** until a pod mounts it (`WaitForFirstConsumer`):

```bash
oc get pvc "${TARGET_PVC}" -n "${TARGET_NS}"
```

Expected output before a pod mounts:

```text
NAME             STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
lab-data-clone   Pending                                      managed-csi    <unset>                 30s
```

## Step 7: Mount restored PVC and verify data

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: lab-reader
  namespace: ${TARGET_NS}
spec:
  containers:
    - name: reader
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["/bin/sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${TARGET_PVC}
EOF
```

```bash
oc wait --for=condition=Ready pod/lab-reader -n "${TARGET_NS}" --timeout=300s
oc get pvc -n "${TARGET_NS}"
oc exec -n "${TARGET_NS}" lab-reader -- cat /data/testfile.txt
oc exec -n "${TARGET_NS}" lab-reader -- ls -la /data
```

Expected output:

```text
NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
lab-data-clone   Bound    pvc-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy   1Gi        RWO            managed-csi    <unset>                 2m

clone-test-2026-06-24T12:00:00+00:00

total 12
drwxr-xr-x. 3 root root 4096 Jun 24 12:00 .
dr-xr-xr-x. 1 root root   28 Jun 24 12:05 ..
-rw-r--r--. 1 root root    5 Jun 24 12:00 ready
-rw-r--r--. 1 root root   38 Jun 24 12:00 testfile.txt
```

**Success:** the `testfile.txt` content matches what the source pod wrote. You should see `testfile.txt` and `ready`, not only `lost+found`.

## Step 8: Deploy your workload

Apply the restored PVC **before** deploying Helm or other installers. If the installer creates the PVC first (without `dataSource`), you get an **empty** disk that mounts correctly but has no data.

For Helm charts, use the chart-specific key for an existing claim (for example `volume.existingClaim` or `persistence.claimNameOverwrite`). Confirm the workload references `${TARGET_PVC}`, not a release-generated PVC name.

Verify the correct PVC is mounted and data is present inside the pod before declaring success:

```bash
oc get pod -n "${TARGET_NS}" -o jsonpath='{.items[0].spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}'
oc exec -n "${TARGET_NS}" <pod-name> -- ls -la /mount/path
```

## Step 9: Cleanup

Deleting only the lab namespaces is **not** enough before a second run. `VolumeSnapshotContent` is cluster-scoped and survives `oc delete namespace`.

```bash
oc delete pod lab-writer -n "${SOURCE_NS}" --ignore-not-found
oc delete pod lab-reader -n "${TARGET_NS}" --ignore-not-found
oc delete pvc "${SOURCE_PVC}" -n "${SOURCE_NS}" --ignore-not-found
oc delete pvc "${TARGET_PVC}" -n "${TARGET_NS}" --ignore-not-found
oc delete volumesnapshot "${SNAPSHOT_NAME}" -n "${SOURCE_NS}" --ignore-not-found
oc delete volumesnapshot "${IMPORT_SNAPSHOT_NAME}" -n "${TARGET_NS}" --ignore-not-found
oc delete volumesnapshotcontent "${SNAPSHOT_CONTENT_NAME}" --ignore-not-found
oc delete namespace "${SOURCE_NS}" "${TARGET_NS}" --ignore-not-found
```

### Second run fails: `snapshotHandle is immutable`

If a second lab run fails during import with:

```text
The VolumeSnapshotContent "snapcontent-lab-import" is invalid: spec.source.snapshotHandle: Invalid value: "string": snapshotHandle is immutable
```

**Cause:** Each run creates a new Azure disk snapshot with a new `snapshotHandle`. Reusing a fixed import object name leaves the old handle in place. A subsequent `oc apply` tries to update `spec.source.snapshotHandle`, which Kubernetes does not allow.

**Fix:** Delete the leftover import objects, then re-run from Step 3:

```bash
oc delete volumesnapshot "${IMPORT_SNAPSHOT_NAME}" -n "${TARGET_NS}" --ignore-not-found
oc delete volumesnapshotcontent "${SNAPSHOT_CONTENT_NAME}" --ignore-not-found
```

## Same-namespace clone (optional)

When source and target PVCs are in the **same** namespace, the OpenShift console **Clone** action or a PVC `dataSource` works:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc-clone
  namespace: my-app-source
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: managed-csi
  resources:
    requests:
      storage: 1Gi
  dataSource:
    name: lab-data
    kind: PersistentVolumeClaim
```

Deploy a pod that mounts `my-pvc-clone` to satisfy `WaitForFirstConsumer`.

## Alternative: file-level copy

For small volumes or when snapshot restore is problematic:

1. Scale down the source application.
2. Create an empty PVC in the target namespace (no `dataSource`).
3. Run a writer pod on the source PVC and a reader pod on the target PVC.
4. Stream data:

```bash
oc exec -n "${SOURCE_NS}" <src-pod> -- tar czf - -C /data . \
  | oc exec -i -n "${TARGET_NS}" <dst-pod> -- tar xzf - -C /data
```

## Related guides

- [Backup and Restore for ARO using OADP](/experts/aro/backup-restore/) (cluster wide backup to Azure Blob Storage and disaster recovery)
- [Azure Disk CSI clone example](https://github.com/kubernetes-sigs/azuredisk-csi-driver/blob/master/deploy/example/cloning/README.md)
