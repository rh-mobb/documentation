---
date: '2026-10-20'
title: 'Migrating an ARO Standard cluster to ARO HCP with the Migration Toolkit for Applications (MTA)'
tags: ["ARO", "ARO Classic", "ARO HCP"]
authors:
  - Kevin Collins
  - Diana Sari
  - Kumudu Herath
validated_version: "4.21"
---

Azure Red Hat OpenShift with hosted control planes (ARO HCP) runs the control plane in a Microsoft managed Azure subscription rather than your own. Because that is a different architecture, **there is no in-place upgrade path from ARO Standard to ARO HCP**. Moving to HCP means building a new cluster and migrating your workloads onto it.

The Migration Toolkit for Applications (MTA) provides `mta-ops`, a standalone CLI that migrates workload manifests and persistent volume data between OpenShift clusters.

This guide is a **walkthrough using five sample workloads**, not a template to run unchanged against production. It shows the sequence, the verification points, and the failure modes, using applications whose data you can predict and check.

Advanced topics such as workload identity, custom networking, and air-gapped or S3 mediated transfers are out of scope. For those, see the [MTA documentation](https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/8.3/html/migrating_workloads_by_using_the_mta-ops_cli).

## Prerequisites

* An **ARO Standard** cluster and an **ARO HCP** cluster
* `oc`, with cluster-admin on both clusters
* `git`, `python3`, and `curl`, used by commands in this guide
* The `mta-ops` CLI, downloaded from the [Red Hat Developer portal](https://developers.redhat.com/products/mta/download) (select the **Ops CLI** archive for your operating system, not the analyzer CLI)
* An Azure Disk and an Azure Files storage class on both clusters

### Registry Access
* Both clusters able to pull from `registry.redhat.io`, which is where `mta-ops` runs its transfer pods from.

  On ARO Standard this comes from the cluster-wide pull secret, added at creation or with [Add or update your Red Hat pull secret](https://learn.microsoft.com/en-us/azure/openshift/howto-add-update-pull-secret).

  On ARO HCP that secret is service managed, so add a cluster-wide [additional pull secret](https://learn.microsoft.com/en-us/azure/openshift/how-to-add-pull-secrets) instead.


## 1. Connect to both clusters

`mta-ops` talks to both clusters in one operation and identifies them by context name, so both must be in your kubeconfig at the same time.

Log in to the ARO Standard cluster, then record its context:

```bash
STANDARD=$(oc config current-context)
```

Log in to the ARO HCP cluster, then record its context:

```bash
HCP=$(oc config current-context)
```

Confirm the two variables point at **different** clusters, not the same one twice:

```bash
oc --context "$STANDARD" whoami --show-server
oc --context "$HCP" whoami --show-server
```

From here every command names its cluster explicitly with `--context`.

## 2. Deploy the sample applications on ARO Standard

Clone the repository and check out the tested commit:

```bash
git clone https://github.com/rh-mobb/aro-testing-apps.git
git -C ./aro-testing-apps checkout 419ed29
oc --context "$STANDARD" apply -k ./aro-testing-apps
```

Each application pairs an Azure Disk (ReadWriteOnce) volume with an Azure Files (ReadWriteMany) volume, so a migration has to handle both access modes:

| Application | Azure Disk (RWO) | Azure Files (RWX) | Migration case it proves |
|-------------|------------------|-------------------|--------------------------|
| Retail Orders | PostgreSQL database | Catalog images | A StatefulSet database beside a multi-replica frontend on a shared volume |
| Document Portal | MariaDB metadata | Document library | Three web replicas writing concurrently to one volume |
| Artifact Repository | Redis index cache | Artifact store | Separate writer and reader tiers sharing a volume |
| Analytics Reports | PostgreSQL warehouse | Report output | A CronJob writing a volume that a Deployment serves |
| Media Pipeline | Redis job queue | Media store | Three workers writing concurrently, the heaviest RWX case |

Three components write continuously once running: `transcode-worker` in `media-pipeline`, `artifact-uploader` in `build-artifacts`, and the `nightly-report` CronJob in `analytics-reports`. That is deliberate: it means the volumes hold real data to migrate, and it is why they are deployed last on the target.

### Verify the applications are running

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$STANDARD" get pods -n "$ns"
done

oc --context "$STANDARD" get pvc -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName'
```

Long running pods should be `Running` **and** ready.

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  for r in $(oc --context "$STANDARD" get deploy,statefulset -n "$ns" -o name); do
    oc --context "$STANDARD" rollout status "$r" -n "$ns" --timeout=300s
  done
done
```

You should see ten `Bound` claims, five on the Azure Disk class and five on Azure Files.

### Seed data you can verify later

The sample databases start with an empty schema, so a structural check would pass against an empty target. Seed a known dataset to compare afterwards:

```bash
oc --context "$STANDARD" exec -n analytics-reports analytics-db-0 -- \
  psql -U analytics -d warehouse -c "
    DROP TABLE IF EXISTS migration_check;
    CREATE TABLE migration_check(id serial primary key, payload text);
    INSERT INTO migration_check(payload) SELECT md5(g::text) FROM generate_series(1,1000) g;"
```

## 3. Export, transform, and render the manifests

**Retail Orders**

```bash
mta-ops export --context "$STANDARD" --namespace retail-orders --export-dir ./retail-orders/export
mta-ops transform --export-dir ./retail-orders/export --transform-dir ./retail-orders/transform
mta-ops apply --transform-dir ./retail-orders/transform --output-dir ./retail-orders/output --ordered
```

**Document Portal**

```bash
mta-ops export --context "$STANDARD" --namespace docs-portal --export-dir ./docs-portal/export
mta-ops transform --export-dir ./docs-portal/export --transform-dir ./docs-portal/transform
mta-ops apply --transform-dir ./docs-portal/transform --output-dir ./docs-portal/output --ordered
```

**Artifact Repository**

```bash
mta-ops export --context "$STANDARD" --namespace build-artifacts --export-dir ./build-artifacts/export
mta-ops transform --export-dir ./build-artifacts/export --transform-dir ./build-artifacts/transform
mta-ops apply --transform-dir ./build-artifacts/transform --output-dir ./build-artifacts/output --ordered
```

**Analytics Reports**

```bash
mta-ops export --context "$STANDARD" --namespace analytics-reports --export-dir ./analytics-reports/export
mta-ops transform --export-dir ./analytics-reports/export --transform-dir ./analytics-reports/transform
mta-ops apply --transform-dir ./analytics-reports/transform --output-dir ./analytics-reports/output --ordered
```

**Media Pipeline**

```bash
mta-ops export --context "$STANDARD" --namespace media-pipeline --export-dir ./media-pipeline/export
mta-ops transform --export-dir ./media-pipeline/export --transform-dir ./media-pipeline/transform
mta-ops apply --transform-dir ./media-pipeline/transform --output-dir ./media-pipeline/output --ordered
```


## 4. Prepare the clusters for migration

### Create the target namespaces in the ARO HCP Cluster

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$HCP" create namespace "$ns"
done
```

### Add a storage class for the Azure Files volumes

Azure Files is an SMB share and presents every file as a fixed owner rather than tracking POSIX ownership. The `mta-ops` transfer pod runs under the UID OpenShift assigns to its namespace, so if the share is mounted as a different owner the copy cannot set file metadata and fails.

This guide mounts each share as the UID of the namespace it serves. Because OpenShift allocates a different UID range per namespace, that means one storage class per namespace. The `0777` modes keep the share readable and writable by the application containers, which run under a different UID from the mount owner. This is the configuration used here, not a general requirement: Microsoft documents[other Azure File storage class options](https://learn.microsoft.com/en-us/azure/openshift/howto-configure-azure-file-storageclass) that may suit your environment better.

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  NS_UID=$(oc --context "$HCP" get namespace "$ns" \
    -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' | cut -d/ -f1)
  cat <<EOF | oc --context "$HCP" apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azurefile-$ns
provisioner: file.csi.azure.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
parameters:
  skuName: Standard_LRS
mountOptions:
  - mfsymlinks
  - cache=strict
  - nosharesock
  - actimeo=30
  - uid=$NS_UID
  - gid=$NS_UID
  - forceuid
  - forcegid
  - file_mode=0777
  - dir_mode=0777
EOF
done

oc --context "$HCP" get storageclass | grep azurefile-
```

## 5. Stage the Azure Files volumes

Staging copies the bulk of the data while the source keeps running, shortening the cutover window:

```bash
mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name catalog-images --pvc-namespace retail-orders:retail-orders \
  --dest-storage-class azurefile-retail-orders --endpoint route --verify

mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name docs-library --pvc-namespace docs-portal:docs-portal \
  --dest-storage-class azurefile-docs-portal --endpoint route --verify

mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name artifact-repo --pvc-namespace build-artifacts:build-artifacts \
  --dest-storage-class azurefile-build-artifacts --endpoint route --verify

mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name report-output --pvc-namespace analytics-reports:analytics-reports \
  --dest-storage-class azurefile-analytics-reports --endpoint route --verify

mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name media-store --pvc-namespace media-pipeline:media-pipeline \
  --dest-storage-class azurefile-media-pipeline --endpoint route --verify
```

The Azure Disk volumes are attached to running pods and cannot be copied yet. They are transferred during cutover.

{{< alert state="info" >}}
`--verify` performs a checksum comparison after the copy. The sample writers are still running during staging, so files can change mid-transfer and verification may report differences. Treat the staged copy as a head start, and the quiesced transfer in step 7 as the authoritative one.
{{< /alert >}}

## 6. Stop the source applications

`mta-ops` copies volumes file by file, so the source has to be stopped before the authoritative transfer. Scale the workloads down and suspend the CronJobs:

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$STANDARD" scale deploy --all -n "$ns" --replicas=0
  oc --context "$STANDARD" scale statefulset --all -n "$ns" --replicas=0
  for cj in $(oc --context "$STANDARD" get cronjob -n "$ns" -o name); do
    oc --context "$STANDARD" patch "$cj" -n "$ns" --type=merge -p '{"spec":{"suspend":true}}'
  done
done
```

A successful `scale` only records intent, so wait until the pods are actually gone:

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$STANDARD" wait --for=delete pod --all -n "$ns" --timeout=300s
done
```

{{< alert state="warning" >}}
Do not copy a database that is still running. A file-by-file copy is not an atomic snapshot: a live database can be copied in an internally inconsistent state that will not start, or will start while silently missing recently committed transactions. PostgreSQL requires the server to be stopped for an ordinary filesystem copy and documents [separate mechanisms](https://www.postgresql.org/docs/current/backup-file.html) for consistent online backups.
{{< /alert >}}

## 7. Transfer all volumes

Re-run the five Azure Files transfers from step 5. With the sourcestopped, this pass is the authoritative one.

Then transfer the five Azure Disk volumes:

```bash
mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name orders-db-data --pvc-namespace retail-orders:retail-orders \
  --dest-storage-class managed-csi --endpoint route --verify

mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name docs-db-data --pvc-namespace docs-portal:docs-portal \
  --dest-storage-class managed-csi --endpoint route --verify

mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name artifact-cache-data --pvc-namespace build-artifacts:build-artifacts \
  --dest-storage-class managed-csi --endpoint route --verify

mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name analytics-db-data --pvc-namespace analytics-reports:analytics-reports \
  --dest-storage-class managed-csi --endpoint route --verify

mta-ops transfer-pvc --source-context "$STANDARD" --destination-context "$HCP" \
  --pvc-name media-queue-data --pvc-namespace media-pipeline:media-pipeline \
  --dest-storage-class managed-csi --endpoint route --verify
```

List the claims on the **target** and check each one by namespace, class, and status:

```bash
oc --context "$HCP" get pvc -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName'
```

{{< alert state="warning" >}}
Transfer every volume before deploying workloads on the target. In testing, a claim already mounted by a running pod could not be written to, and the transfer failed with `destination PVC ... is in use by pod`.
{{< /alert >}}

## 8. Deploy the workloads on ARO HCP, writers last

The transfers already created the claims, so drop those manifests, hold the three writers back so they cannot modify the migrated data before you have checked it, and apply the rest:

```bash
for app in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  rm -f ./$app/output/resources/$app/*PersistentVolumeClaim*
done

mkdir -p deferred
mv ./media-pipeline/output/resources/media-pipeline/*transcode-worker*.yaml    deferred/
mv ./build-artifacts/output/resources/build-artifacts/*artifact-uploader*.yaml deferred/
mv ./analytics-reports/output/resources/analytics-reports/*CronJob*.yaml       deferred/

for app in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$HCP" apply -f ./$app/output/resources/$app/
done
```

## 9. Verify the migration

Wait for the workloads to roll out, then confirm all ten claims are `Bound` and on the storage class you intended:

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  for r in $(oc --context "$HCP" get deploy,statefulset -n "$ns" -o name); do
    oc --context "$HCP" rollout status "$r" -n "$ns" --timeout=300s
  done
done

oc --context "$HCP" get pvc -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName'
```

Pod status does not prove the data arrived. Check the rows you seeded in step 2, which must come back as `1000`, and the shared volume, which should hold the files the workers wrote before cutover:

```bash
oc --context "$HCP" exec -n analytics-reports analytics-db-0 -- \
  psql -U analytics -d warehouse -tAc "SELECT count(*) FROM migration_check"

oc --context "$HCP" exec -n media-pipeline deploy/media-web -- \
  sh -c 'ls -1 /var/www/html/media/rendered | wc -l'
```

Finally, every route should answer `200`:

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  for host in $(oc --context "$HCP" get route -n "$ns" -o jsonpath='{.items[*].spec.host}'); do
    printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' -L "https://$host")" "$host"
  done
done
```

## 10. Resume the writers

Once the comparisons pass, start the deferred components:

```bash
oc --context "$HCP" apply -f deferred/
```

Confirm they start and begin producing data:

```bash
oc --context "$HCP" get pods -n media-pipeline
oc --context "$HCP" get pods -n build-artifacts
oc --context "$HCP" get cronjob -n analytics-reports
```

From this point the applications generate new data on the target.

## 11. Accept the migration, then clean up

Keep the source cluster intact and its applications stopped until you have accepted the target. Leaving the source cluster running is not by itself a rollback plan.

{{< alert state="warning" >}}
Both sample storage classes use a `Delete` reclaim policy, so deleting the applications also deletes their Azure Disk and Azure Files volumes and the data on them. Do not run the cleanup until you no longer need the source data.
{{< /alert >}}

Once the applications have been accepted on HCP and your rollback window has passed:

```bash
oc --context "$STANDARD" delete -k ./aro-testing-apps
```

Rolling back after the target has accepted writes is not simply a matter of restarting the source. Anything written on HCP after cutover exists only there and would have to be reconciled by hand.