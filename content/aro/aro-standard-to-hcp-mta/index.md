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

Azure Red Hat OpenShift with hosted control planes (ARO HCP) runs the control plane in a
Microsoft managed Azure subscription rather than your own. Because that is a different
architecture, **there is no in-place upgrade path from ARO Standard to ARO HCP**. Moving
to HCP means building a new cluster and migrating your workloads onto it.

The Migration Toolkit for Applications (MTA) provides `mta-ops`, a standalone CLI that
migrates workload manifests and persistent volume data between OpenShift clusters.

This guide is a **walkthrough using five sample workloads**, not a template to run
unchanged against production. It shows the sequence, the verification points, and the
failure modes, using applications whose data you can predict and check.

Advanced topics such as workload identity, custom networking, and air-gapped or
S3 mediated transfers are out of scope. For those, see the
[MTA documentation](https://docs.redhat.com/en/documentation/migration_toolkit_for_applications/8.3/html/migrating_workloads_by_using_the_mta-ops_cli).

## Tested configuration

| Component | Version |
|-----------|---------|
| Source, ARO Standard | OpenShift 4.21.22, service principal identity |
| Target, ARO HCP | OpenShift 4.21.36, node pool 4.21.37 |
| `mta-ops` | 8.3.1 |
| Sample applications | [rh-mobb/aro-testing-apps](https://github.com/rh-mobb/aro-testing-apps) at commit `419ed29` |

Both clusters were in the same Azure region. That is the tested scope rather than a
documented requirement. The actual requirement is network reachability: **the transfer
pod on the source cluster must be able to reach the transfer endpoint published on the
target cluster**, which this guide exposes as an OpenShift route.

## Prerequisites

* An **ARO Standard** cluster and an **ARO HCP** cluster, both deployed
* `oc`, with cluster-admin on both clusters
* `az` with the `aro` extension, used to request ARO HCP credentials
* `git`, `python3`, and `curl`, used by commands in this guide
* The `mta-ops` CLI, downloaded from the
  [Red Hat Developer portal](https://developers.redhat.com/products/mta/download)
  (select the **Ops CLI** archive for your operating system, not the analyzer CLI)
* An Azure Disk and an Azure Files storage class on both clusters

### Confirm your storage classes

Run this on each cluster:

```bash
oc get storageclass
```

ARO HCP provides `managed-csi` and `azurefile-csi` by default. On ARO Standard the
Azure Files class depends on how the cluster was built: Microsoft documents that the
default Azure Files storage class is disabled on clusters using managed identity, and
describes
[configuring an Azure File storage class](https://learn.microsoft.com/en-us/azure/openshift/howto-configure-azure-file-storageclass)
in that case.

Check which identity model your source cluster uses:

```bash
az aro show -g <resource-group> -n <cluster-name> \
  --query "servicePrincipalProfile.clientId != null && 'service principal' || 'managed identity'" -o tsv
```

If your Azure Files class is named something other than `azurefile-csi`, substitute that
name in the sample application manifests before deploying them.

## 1. Connect to both clusters

`mta-ops` talks to both clusters in one operation and identifies them by context name,
so both must be in your kubeconfig at the same time.

Log in to the ARO Standard cluster, then record its context:

```bash
STANDARD=$(oc config current-context)
```

ARO HCP does not expose the built-in OAuth login, so `oc login` with a username and
password does not work there. Request an administrator credential, which adds a context
to your kubeconfig and makes it current:

```bash
az aro hcp cluster request-credential -g <resource-group> -n <cluster-name> --admin
HCP=$(oc config current-context)
```

Confirm the two variables point at **different** clusters, not the same one twice:

```bash
oc --context "$STANDARD" whoami --show-server
oc --context "$HCP" whoami --show-server
```

Those must print two distinct API server URLs. Then confirm both respond:

```bash
oc --context "$STANDARD" get nodes
oc --context "$HCP" get nodes
```

{{< alert state="info" >}}
The administrator credential is time limited. If commands against `$HCP` start failing
with authentication errors part way through, request a new credential and re-record
`HCP`.
{{< /alert >}}

From here every command names its cluster explicitly with `--context`.

## 2. Deploy the sample applications on ARO Standard

Clone the repository and check out the tested commit:

```bash
git clone https://github.com/rh-mobb/aro-testing-apps.git
git -C ./aro-testing-apps checkout 419ed29
oc --context "$STANDARD" apply -k ./aro-testing-apps
```

Each application pairs an Azure Disk (ReadWriteOnce) volume with an Azure Files
(ReadWriteMany) volume, so a migration has to handle both access modes:

| Application | Azure Disk (RWO) | Azure Files (RWX) | Migration case it proves |
|-------------|------------------|-------------------|--------------------------|
| Retail Orders | PostgreSQL database | Catalog images | A StatefulSet database beside a multi-replica frontend on a shared volume |
| Document Portal | MariaDB metadata | Document library | Three web replicas writing concurrently to one volume |
| Artifact Repository | Redis index cache | Artifact store | Separate writer and reader tiers sharing a volume |
| Analytics Reports | PostgreSQL warehouse | Report output | A CronJob writing a volume that a Deployment serves |
| Media Pipeline | Redis job queue | Media store | Three workers writing concurrently, the heaviest RWX case |

Three components write continuously once running: `transcode-worker` in
`media-pipeline`, `artifact-uploader` in `build-artifacts`, and the `nightly-report`
CronJob in `analytics-reports`. That is deliberate, and those are the three you stop
before capturing a baseline.

### Verify the applications are running

A repeated `-n` flag does not select multiple namespaces, the last one wins, so loop:

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$STANDARD" get pods -n "$ns"
done

oc --context "$STANDARD" get pvc -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName'
```

Long running pods should be `Running` **and** ready. Check rollout status rather than
waiting on pods by label: CronJob pods in these samples carry the same
`app.kubernetes.io/part-of` label, and a `Completed` pod never reports `Ready`, so a
label based `wait` times out on them.

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  for r in $(oc --context "$STANDARD" get deploy,statefulset -n "$ns" -o name); do
    oc --context "$STANDARD" rollout status "$r" -n "$ns" --timeout=300s
  done
done
```

You should see ten `Bound` claims, five on the Azure Disk class and five on Azure Files.

### Seed data you can verify later

The sample databases start with an empty schema, so a structural check would pass
against an empty target. Seed a known dataset to compare afterwards:

```bash
oc --context "$STANDARD" exec -n analytics-reports analytics-db-0 -- \
  psql -U analytics -d warehouse -c "
    DROP TABLE IF EXISTS migration_check;
    CREATE TABLE migration_check(id serial primary key, payload text);
    INSERT INTO migration_check(payload) SELECT md5(g::text) FROM generate_series(1,1000) g;"
```

## 3. Export, transform, and render the manifests

`export` captures the live resources, `transform` produces kustomize overlays that strip
cluster-injected fields, and `apply` renders the final manifests.

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

### Review the rendered output

```bash
ls ./retail-orders/output/resources/retail-orders/
```

In the tested configuration, `transform` removes `spec.host` from Route objects, so the
target generates its own hostname on the target domain. Confirm that for yourself before
the outage, because a retained source hostname would not be rewritten on apply:

```bash
grep -l 'host:' ./*/output/resources/*/*Route*.yaml
```

That should return nothing. If any Route still carries a `host:`, remove it so OpenShift
assigns a hostname on the target.

Also read through the rendered manifests for security contexts and service accounts that
reference source-cluster UIDs, and check that PVC references match the volumes you are
about to transfer.

## 4. Prepare the clusters for migration

### Create the target namespaces

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$HCP" create namespace "$ns"
done
```

### Add a storage class for the Azure Files volumes

Azure Files is an SMB share and presents every file as a fixed owner rather than
tracking POSIX ownership. The `mta-ops` transfer pod runs under the UID OpenShift
assigns to its namespace, so if the share is mounted as a different owner the copy
cannot set file metadata and fails.

This guide mounts each share as the UID of the namespace it serves. Because OpenShift
allocates a different UID range per namespace, that means one storage class per
namespace. The `0777` modes keep the share readable and writable by the application
containers, which run under a different UID from the mount owner. This is the
configuration used here, not a general requirement: Microsoft documents
[other Azure File storage class options](https://learn.microsoft.com/en-us/azure/openshift/howto-configure-azure-file-storageclass)
that may suit your environment better.

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

### Allow pulls from registry.redhat.io

`mta-ops` runs its transfer pods from `registry.redhat.io`, so both clusters need
credentials for that registry.

**On ARO Standard**, the cluster-wide pull secret covers this, but only if the cluster
was created with the optional Red Hat pull secret. A cluster created without one gets a
partially populated secret with no `registry.redhat.io` entry. Check without printing
the secret:

```bash
oc --context "$STANDARD" get secret pull-secret -n openshift-config \
  -o go-template='{{index .data ".dockerconfigjson" | base64decode}}' \
  | python3 -c "import sys,json; print('registry.redhat.io' in json.load(sys.stdin)['auths'])"
```

If that prints `False`, add it by following
[Add or update your Red Hat pull secret](https://learn.microsoft.com/en-us/azure/openshift/howto-add-update-pull-secret).

**On ARO HCP** the cluster-wide pull secret is managed by the service and cannot be
edited, so the credential has to be attached per workload. Microsoft describes one
approach in
[Add pull secrets to access private registries](https://learn.microsoft.com/en-us/azure/openshift/how-to-add-pull-secrets),
using a secret in `kube-system`. This guide uses a different approach that suits the
transfer pods specifically: a secret in each migration namespace, linked to the
`default` service account that those pods run as.

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$HCP" create secret docker-registry rh-reg \
    --docker-server=registry.redhat.io \
    --docker-username='<service-account-username>' \
    --docker-password='<service-account-token>' \
    -n "$ns"
  oc --context "$HCP" secrets link default rh-reg -n "$ns" --for=pull
done
```

Confirm the link took effect, since the transfer pods depend on it:

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$HCP" get serviceaccount default -n "$ns" \
    -o jsonpath="$ns"'{" "}{.imagePullSecrets[*].name}{"\n"}'
done
```

Each line should include `rh-reg`.

### Run the preflight check

```bash
for app in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  mta-ops validate --context "$HCP" \
    --input-dir ./$app/output --validate-dir ./$app/validate --overwrite
done
```

Each run reports compatible and incompatible resource counts and writes
`./<app>/validate/report.json`. Exit code 0 means every resource passed.

{{< alert state="info" >}}
`validate` checks API compatibility only. It does not confirm that applications will
start, that storage will bind, or that data is intact.
{{< /alert >}}

## 5. Stage the Azure Files volumes

Staging copies the bulk of the data while the source keeps running, shortening the
cutover window:

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

The Azure Disk volumes are attached to running pods and cannot be copied yet. They are
transferred during cutover.

{{< alert state="info" >}}
`--verify` performs a checksum comparison after the copy. The sample writers are still
running during staging, so files can change mid-transfer and verification may report
differences. Treat the staged copy as a head start, and the quiesced transfer in step 7
as the authoritative one.
{{< /alert >}}

## 6. Capture a baseline, then stop the source

You cannot compare the target against the source once the source is shut down, so record
the data first.

### Stop only the writers

Stop the three components that generate data, leaving the readers and databases up so
you can still query them:

```bash
oc --context "$STANDARD" -n media-pipeline scale deployment/transcode-worker --replicas=0
oc --context "$STANDARD" -n build-artifacts scale deployment/artifact-uploader --replicas=0

for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  for cj in $(oc --context "$STANDARD" get cronjob -n "$ns" -o name); do
    oc --context "$STANDARD" patch "$cj" -n "$ns" --type=merge -p '{"spec":{"suspend":true}}'
  done
  oc --context "$STANDARD" delete job --all -n "$ns" --ignore-not-found
done
```

Suspending a CronJob only stops future runs, which is why the Jobs it already created
are deleted as well. Wait for the writer pods to disappear before capturing anything:

```bash
oc --context "$STANDARD" -n media-pipeline wait --for=delete pod -l app=transcode-worker --timeout=300s
oc --context "$STANDARD" -n build-artifacts wait --for=delete pod -l app=artifact-uploader --timeout=300s
```

### Capture the baseline

A capture that fails partway through still writes a file. Worse, in a pipeline the exit
status comes from the last command, so `oc exec ... | sort > file` reports success even
when `oc exec` failed after emitting some output. That produces a short but non-empty
baseline that every later comparison will accept.

Guard against it: enable `pipefail`, capture to a temporary file, and only promote it to
the baseline once the command succeeded.

```bash
set -o pipefail
mkdir -p baseline

capture() {          # capture <name> <command...>
  name=$1; shift
  if "$@" > "/tmp/$name.part"; then
    mv "/tmp/$name.part" "baseline/$name"
    echo "captured $name ($(wc -l < "baseline/$name" | tr -d ' ') lines)"
  else
    echo "FAILED to capture $name"; rm -f "/tmp/$name.part"; return 1
  fi
}

capture analytics-rows.txt \
  oc --context "$STANDARD" exec -n analytics-reports analytics-db-0 -- \
  psql -U analytics -d warehouse -tAc \
  "SELECT count(*)||' '||md5(string_agg(payload,',' ORDER BY id)) FROM migration_check"

capture docs-databases.txt \
  oc --context "$STANDARD" exec -n docs-portal docs-db-0 -- \
  sh -c 'MYSQL_PWD=$MYSQL_PASSWORD mysql -u $MYSQL_USER -N -e "SHOW DATABASES" | LC_ALL=C sort'

capture media-store.txt \
  oc --context "$STANDARD" exec -n media-pipeline deploy/media-web -- \
  sh -c 'cd /var/www/html/media && find . -type f -exec md5sum {} + | LC_ALL=C sort'

capture artifact-repo.txt \
  oc --context "$STANDARD" exec -n build-artifacts deploy/artifact-web -- \
  sh -c 'cd /var/www/html/repo && find . -type f -exec md5sum {} + | LC_ALL=C sort'
```

Sorting happens inside the remote shell so the local pipeline cannot mask a remote
failure. Now assert the baseline is what you expect before going any further:

```bash
grep -qE '^1000 [0-9a-f]{32}$' baseline/analytics-rows.txt \
  && echo "seeded rows OK" || echo "FAIL: analytics baseline wrong"

for f in docs-databases.txt media-store.txt artifact-repo.txt; do
  [ -s "baseline/$f" ] && echo "$f OK ($(wc -l < baseline/$f | tr -d ' ') lines)" \
                       || echo "FAIL: baseline/$f is empty"
done
```

Every line must report `OK`. Do not continue otherwise.

### Shut the source down cleanly

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$STANDARD" scale deploy --all -n "$ns" --replicas=0
  oc --context "$STANDARD" scale statefulset --all -n "$ns" --replicas=0
done
```

A successful `scale` only records intent. Wait until the pods are actually gone, per
namespace:

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$STANDARD" wait --for=delete pod --all -n "$ns" --timeout=300s
  oc --context "$STANDARD" get pods -n "$ns"
done
```

Each namespace should report no resources.

{{< alert state="warning" >}}
Do not copy a database that is still running. `mta-ops` performs a file-by-file copy,
not an atomic snapshot: a live database can be copied in an internally inconsistent
state that will not start, or will start while silently missing recently committed
transactions. PostgreSQL requires the server to be stopped for an ordinary filesystem
copy and documents
[separate mechanisms](https://www.postgresql.org/docs/current/backup-file.html) for
consistent online backups. Confirm the database pods have fully terminated before
continuing.
{{< /alert >}}

## 7. Transfer all volumes

Re-run the five Azure Files transfers from step 5 exactly as written. With the source
stopped, this pass is the authoritative one.

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
Transfer every volume before deploying workloads on the target. In testing, a claim
already mounted by a running pod could not be written to, and the transfer failed with
`destination PVC ... is in use by pod`.
{{< /alert >}}

## 8. Deploy the workloads on ARO HCP, writers last

Deploy everything except the three writers, so the migrated data is not modified before
you have verified it.

The transfers already created the claims, so remove the exported
`PersistentVolumeClaim` manifests, and set the writer manifests aside:

```bash
for app in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  rm -f ./$app/output/resources/$app/*PersistentVolumeClaim*
done

mkdir -p deferred
mv ./media-pipeline/output/resources/media-pipeline/*transcode-worker*.yaml   deferred/
mv ./build-artifacts/output/resources/build-artifacts/*artifact-uploader*.yaml deferred/
mv ./analytics-reports/output/resources/analytics-reports/*CronJob*.yaml       deferred/
```

Then apply the rest:

```bash
for app in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  oc --context "$HCP" apply -f ./$app/output/resources/$app/
done
```

## 9. Verify the migration

With the writers still stopped, the target data is static, so these comparisons are
deterministic.

### Workloads and storage

```bash
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  for r in $(oc --context "$HCP" get deploy,statefulset -n "$ns" -o name); do
    oc --context "$HCP" rollout status "$r" -n "$ns" --timeout=300s
  done
done

oc --context "$HCP" get pvc -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName'
```

Confirm all ten expected claims are present, `Bound`, and on the intended class.

### Database contents

```bash
oc --context "$HCP" exec -n analytics-reports analytics-db-0 -- \
  psql -U analytics -d warehouse -tAc \
  "SELECT count(*)||' '||md5(string_agg(payload,',' ORDER BY id)) FROM migration_check" \
  > target-analytics-rows.txt

diff baseline/analytics-rows.txt target-analytics-rows.txt && echo "analytics rows match"

oc --context "$HCP" exec -n docs-portal docs-db-0 -- \
  sh -c 'MYSQL_PWD=$MYSQL_PASSWORD mysql -u $MYSQL_USER -N -e "SHOW DATABASES" | LC_ALL=C sort' \
  > target-docs-databases.txt

diff baseline/docs-databases.txt target-docs-databases.txt && echo "docs databases match"
```

Both `diff` commands must report no differences, but they prove different things.

`SHOW DATABASES` is a **structural** check: it confirms the MariaDB volume restored and
the expected databases exist, and says nothing about their contents. The PostgreSQL
comparison is the substantive one, covering an exact row count and a checksum over the
data, so a database that restored its schema but lost its rows fails there.

Apply the same pattern to your own workloads: compare records you can predict, not just
the objects that hold them.

### Shared volume contents

Collect the target listings the same way, then compare whole sorted lines. `comm`
requires both inputs sorted the same way, and these records begin with a checksum, so
both sides must be sorted on the full line:

```bash
oc --context "$HCP" exec -n media-pipeline deploy/media-web -- \
  sh -c 'cd /var/www/html/media && find . -type f -exec md5sum {} + | LC_ALL=C sort' \
  > target-media-store.txt

oc --context "$HCP" exec -n build-artifacts deploy/artifact-web -- \
  sh -c 'cd /var/www/html/repo && find . -type f -exec md5sum {} + | LC_ALL=C sort' \
  > target-artifact-repo.txt

LC_ALL=C comm -23 baseline/media-store.txt   target-media-store.txt
LC_ALL=C comm -23 baseline/artifact-repo.txt target-artifact-repo.txt
```

Each command should print nothing, meaning every baseline file is present on the target
with an identical checksum. Any line printed is a file that is missing or whose contents
changed.

{{< alert state="warning" >}}
Sorting these records by filename, for example with `sort -k2`, breaks the comparison.
In testing, that produced 25 reported missing files when only 3 were missing. Sort on
the full line with `LC_ALL=C sort`, and confirm the baseline files are non-empty before
trusting an empty result.
{{< /alert >}}

### Endpoints

Check all five applications and fail on anything unexpected:

Printing failures is not enough, because a loop that prints `FAIL` still exits `0` and
would not stop you resuming the writers. Count the failures and exit on them:

```bash
failures=0
for ns in retail-orders docs-portal build-artifacts analytics-reports media-pipeline; do
  hosts=$(oc --context "$HCP" get route -n "$ns" -o jsonpath='{.items[*].spec.host}')
  if [ -z "$hosts" ]; then
    echo "FAIL $ns: no route"; failures=$((failures+1)); continue
  fi
  for host in $hosts; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -L "https://$host")
    if [ "$code" = "200" ]; then
      echo "ok   $ns $host"
    else
      echo "FAIL $ns $host -> $code"; failures=$((failures+1))
    fi
  done
done
echo "endpoint failures: $failures"
[ "$failures" -eq 0 ] || echo "DO NOT PROCEED: fix the failures above before step 10"
```

Every line must start with `ok` and the failure count must be `0`. A `200` shows the
endpoint answers; exercise whatever function matters for your own workloads as well.

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

From this point the target diverges from the baseline by design.

## 11. Accept the migration, then clean up

Keep the source cluster intact and its applications stopped until you have accepted the
target. Leaving the source cluster running is not by itself a rollback plan.

{{< alert state="warning" >}}
Both sample storage classes use a `Delete` reclaim policy, so deleting the applications
also deletes their Azure Disk and Azure Files volumes and the data on them. Do not run
the cleanup until you no longer need the source data.
{{< /alert >}}

Once the applications have been accepted on HCP and your rollback window has passed:

```bash
oc --context "$STANDARD" delete -k ./aro-testing-apps
```

Rolling back after the target has accepted writes is not simply a matter of restarting
the source. Anything written on HCP after cutover exists only there and would have to be
reconciled by hand.
