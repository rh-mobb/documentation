---
date: '2026-08-21'
title: Disaster Recovery with OADP on ROSA HCP
tags: ["ROSA HCP", "OADP", "EFS", "S3"]
authors:
  - Kevin Collins
  - Diana Sari
  - Kumudu Herath
validated_version: "4.22"
---

This guide shows a disaster recovery pattern for applications running on two existing ROSA HCP clusters. It uses OADP to back up and restore Kubernetes resources, S3 Cross-Region Replication for object data, and EFS replication for persistent file data.

The workflow supports both hot-to-warm and hot-to-cold recovery. Both models use the same recovery procedure. In a hot-to-cold model, bring the DR cluster compute online first, then run the same recovery steps.

This article keeps the recovery decisions visible. Helper scripts are used only for repetitive setup tasks such as IAM, S3, EFS, OADP installation, and recording EFS PVC mappings.

ACM and GitOps based recovery are intentionally out of scope for this article and are covered separately.

## 0. Architecture

The reference environment has:

- A primary ROSA HCP cluster in one AWS Region
- A DR ROSA HCP cluster in another AWS Region
- An application S3 bucket in the primary Region, replicated to a DR bucket
- An OADP backup S3 bucket in the primary Region, replicated to a DR bucket
- A primary EFS file system, replicated to an EFS file system in the DR Region
- EFS CSI Driver installed on both clusters
- OADP installed on both clusters
- An example workload that writes object data to S3 and file data to EFS

During recovery, OADP restores the Kubernetes objects. EFS file data is not restored dynamically by OADP. Instead, the DR cluster uses static PersistentVolumes that point at the original replicated EFS paths recorded before the disaster.

DNS or traffic cutover is external to this guide. After recovery is validated, update DNS, load balancer, or application routing according to your environment.

## 1. Requirements

You need:

- Two existing ROSA HCP clusters
- AWS CLI
- `rosa` CLI
- `oc` CLI
- `jq`
- AWS permissions for IAM, EC2, S3, and EFS
- Cluster admin access to both clusters

The examples use these names:

```bash
export PRIMARY_CLUSTER_NAME=ds-uswest2
export DR_CLUSTER_NAME=ds-useast1
export PRIMARY_REGION=us-west-2
export DR_REGION=us-east-1
export DR_ENV=./dr.env
export EFS_MAPPING_FILE=./efs-pvc-map.csv
```

Identify the worker/node security groups that should be allowed to mount EFS. Also identify the subnet IDs where EFS mount targets should be created. If your ROSA HCP machine pools expose subnets through the `rosa` CLI, the EFS helper can discover the subnets. Security groups must be provided explicitly because EC2 name-tag discovery is not reliable across cluster layouts:

```bash
export PRIMARY_WORKER_SECURITY_GROUP_ID=<primary-worker-or-node-sg>
export DR_WORKER_SECURITY_GROUP_ID=<dr-worker-or-node-sg>

# Optional if the helper cannot discover subnets from ROSA.
export PRIMARY_SUBNET_IDS=<subnet-a,subnet-b>
export DR_SUBNET_IDS=<subnet-c,subnet-d>
```

Create the initial environment file:

```bash
cat > "$DR_ENV" <<EOF
export PRIMARY_CLUSTER_NAME=$PRIMARY_CLUSTER_NAME
export DR_CLUSTER_NAME=$DR_CLUSTER_NAME
export PRIMARY_REGION=$PRIMARY_REGION
export DR_REGION=$DR_REGION
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export DR_ENV=$DR_ENV
export EFS_MAPPING_FILE=$EFS_MAPPING_FILE
export PRIMARY_WORKER_SECURITY_GROUP_ID=$PRIMARY_WORKER_SECURITY_GROUP_ID
export DR_WORKER_SECURITY_GROUP_ID=$DR_WORKER_SECURITY_GROUP_ID
export PRIMARY_SUBNET_IDS=${PRIMARY_SUBNET_IDS:-}
export DR_SUBNET_IDS=${DR_SUBNET_IDS:-}
EOF
```

Load this file before each step:

```bash
source "$DR_ENV"
```

The helper scripts write generated values to `dr.env` so later steps do not require manually copying IDs and ARNs. Each helper updates existing keys instead of appending duplicate entries.

## 2. Prepare the DR Foundation

Run the setup steps before deploying or protecting the workload.

### 2.1 Install the EFS CSI Driver

Install the EFS CSI Driver on each cluster:

```bash
oc login <primary-api-url>
./scripts/install-efs-csi.sh --cluster "$PRIMARY_CLUSTER_NAME" --region "$PRIMARY_REGION" --env-file "$DR_ENV"

oc login <dr-api-url>
./scripts/install-efs-csi.sh --cluster "$DR_CLUSTER_NAME" --region "$DR_REGION" --env-file "$DR_ENV"
```

The helper creates a customer-managed EFS CSI controller IAM policy. This is intentional. The AWS-managed EFS CSI policy includes tag conditions that can conflict with tags injected by ROSA or OpenShift during access point creation. A custom policy avoids those tag-condition failures while keeping the EFS CSI permissions explicit.

Verify the driver on each cluster:

```bash
oc get pods -n openshift-cluster-csi-drivers | grep efs
oc get clustercsidriver efs.csi.aws.com
```

### 2.2 Configure S3 Replication

Create S3 buckets for application data and OADP backups, then configure one-way replication from primary to DR:

```bash
source "$DR_ENV"
./scripts/configure-s3-replication.sh --env-file "$DR_ENV"
source "$DR_ENV"
./scripts/validate-s3-replication.sh --env-file "$DR_ENV"
```

The script writes these values to `dr.env`:

- `APP_BUCKET_PRIMARY`
- `APP_BUCKET_DR`
- `OADP_BUCKET_PRIMARY`
- `OADP_BUCKET_DR`
- `S3_REPLICATION_ROLE_ARN`
- `APP_S3_ROLE_ARN_PRIMARY`
- `APP_S3_ROLE_ARN_DR`

S3 Cross-Region Replication in this guide is one-way: primary to DR. Objects written to the DR bucket during failover are not automatically copied back to the primary bucket.

### 2.3 Configure EFS Replication

Create the primary EFS file system, mount targets, and the DR replica:

```bash
source "$DR_ENV"
./scripts/configure-efs-replication.sh \
  --env-file "$DR_ENV" \
  --primary-worker-sg "$PRIMARY_WORKER_SECURITY_GROUP_ID" \
  --dr-worker-sg "$DR_WORKER_SECURITY_GROUP_ID"
source "$DR_ENV"
./scripts/validate-efs-replication.sh --env-file "$DR_ENV"
```

The script:

- Discovers each cluster VPC from the EFS subnet list
- Creates or reuses named EFS security groups
- Uses the worker security groups recorded in `dr.env`
- Creates a primary EFS file system
- Waits for the primary file system to become available
- Creates mount targets in every machine pool subnet
- Creates EFS replication to the DR Region
- Waits for the DR replica file system to become available
- Creates DR mount targets
- Waits for all mount targets to become available

Waiting for file system and mount target readiness is required. Pods can fail to mount EFS if a file system or a mount target is not ready, or if a pod lands in an Availability Zone without a matching mount target.

The script writes these values to `dr.env`:

- `PRIMARY_EFS`
- `DR_EFS`
- `EFS_SG_PRIMARY`
- `EFS_SG_DR`
- `VPC_PRIMARY`
- `VPC_DR`

After EFS is created, create the EFS StorageClass on both clusters and verify dynamic provisioning on the primary cluster:

```bash
source "$DR_ENV"
./scripts/validate-efs-csi.sh --env-file "$DR_ENV"
```

The StorageClass uses dynamic EFS access point provisioning and `directoryPerms: "755"`. The validation helper creates a small throwaway PVC on the primary cluster, waits for it to bind, and removes the smoke-test namespace before continuing.

### 2.4 Configure OADP

Install OADP on both clusters and create the DataProtectionApplication objects:

```bash
source "$DR_ENV"

oc login <primary-api-url>
./scripts/configure-oadp.sh \
  --cluster "$PRIMARY_CLUSTER_NAME" \
  --region "$PRIMARY_REGION" \
  --bucket "$OADP_BUCKET_PRIMARY" \
  --role-suffix primary \
  --env-file "$DR_ENV"

oc login <dr-api-url>
./scripts/configure-oadp.sh \
  --cluster "$DR_CLUSTER_NAME" \
  --region "$DR_REGION" \
  --bucket "$OADP_BUCKET_DR" \
  --role-suffix dr \
  --env-file "$DR_ENV"

source "$DR_ENV"
```

Verify the BackupStorageLocation on each cluster:

```bash
oc get backupstoragelocation -n openshift-adp
```

The phase must be `Available`.

## 3. Deploy the Example Workload

Phoenix Mission Control is used only as a lightweight example because it exercises the recovery cases this guide cares about:

- S3 object writes
- Shared EFS file data
- StatefulSet replicas with ordinal PVCs

Deploy the workload on the primary cluster:

```bash
source "$DR_ENV"
oc login <primary-api-url>

./scripts/deploy-phoenix.sh --env-file "$DR_ENV"
```

For your own application, use an equivalent workload that has both S3 and EFS data and at least one StatefulSet.

Verify the workload:

```bash
oc get pods,pvc,sts -n dr-demo
```

Create visible test data:

```bash
export VALIDATION_ID=dr-$(date +%Y%m%d%H%M%S)

oc exec -n dr-demo deploy/mission-control -- \
  sh -c "echo efs-$VALIDATION_ID > /shared/validation-$VALIDATION_ID.txt"

printf '%s\n' "s3-$VALIDATION_ID" | aws s3 cp - \
  "s3://$APP_BUCKET_PRIMARY/validation/$VALIDATION_ID.txt" \
  --region "$PRIMARY_REGION"
```

Adjust the in-pod EFS path if your example workload mounts EFS somewhere else.

## 4. Record EFS PVC Mappings Before Failure

Record the EFS mapping while the primary cluster API is available:

```bash
source "$DR_ENV"
oc login <primary-api-url>

./scripts/record-efs-mapping.sh \
  --namespace dr-demo \
  --region "$PRIMARY_REGION" \
  --output "$EFS_MAPPING_FILE"
```

The mapping file records:

- PVC name
- PV name
- Source EFS access point ID
- EFS root path
- Access point POSIX UID and GID
- Root directory owner UID, owner GID, and permissions
- StatefulSet ordinal, if the PVC name ends in an ordinal
- Requested storage
- Access modes

Example:

```csv
namespace,pvc,pv,source_access_point_id,efs_path,posix_uid,posix_gid,root_owner_uid,root_owner_gid,root_permissions,statefulset_ordinal,requested_storage,access_modes
dr-demo,shared-flight-data,pvc-d7b69237,fsap-abc123,/dynamic_provisioning/pvc-d7b69237,1000,1000,1000,1000,750,,5Gi,ReadWriteMany
dr-demo,flight-data-flight-recorder-0,pvc-483625aa,fsap-def456,/dynamic_provisioning/pvc-483625aa,1001,1001,1001,1001,750,0,5Gi,ReadWriteMany
dr-demo,flight-data-flight-recorder-1,pvc-16a379dd,fsap-ghi789,/dynamic_provisioning/pvc-16a379dd,1002,1002,1002,1002,750,1,5Gi,ReadWriteMany
```

This mapping is critical for EFS recovery.

When the EFS CSI driver dynamically provisions a restored PVC, it creates a new access point with a new root path. The replicated data remains under the original primary root path. If the DR restore creates new dynamic access points, the application can mount empty directories even though the data exists on the DR EFS file system.

The DR static PV must also use an access point, not only a direct file-system path mount. A direct path mount such as `${DR_EFS}:${EFS_PATH}` can read replicated files, but it bypasses the original access point POSIX identity and can fail on new writes with `Permission denied`. The mapping therefore records enough source access point metadata to recreate a DR-side access point for each original PVC path.

StatefulSets require extra attention. A StatefulSet volume claim template creates separate PVCs for each ordinal, such as:

- `flight-data-flight-recorder-0`
- `flight-data-flight-recorder-1`

Each ordinal PVC can have a different original EFS path. Record every PVC separately and update the mapping whenever PVCs are recreated.

Store the mapping file with your DR runbook. Do not assume the primary cluster API will be available during a disaster.

## 5. Create an OADP Backup

Create a backup on the primary cluster and verify the exact backup appears on the DR cluster:

```bash
source "$DR_ENV"
./scripts/create-dr-backup.sh --env-file "$DR_ENV"
source "$DR_ENV"
```

The backup intentionally excludes PVs and PVCs. EFS data is protected by EFS replication, and the DR cluster recreates the EFS claims from the mapping file recorded before the disaster.

The helper creates the Velero `Backup`, waits for phase `Completed`, records `BACKUP_NAME` in `dr.env`, and verifies that the same backup name is visible from the DR cluster. For validation it also copies the exact Velero backup prefix from the primary OADP bucket to the DR OADP bucket so the test does not depend on S3 replication timing.

## 6. Recover to the DR Cluster

Use this same recovery procedure for hot-to-warm and hot-to-cold.

For hot-to-warm, the DR worker nodes are already running.

Hot-to-cold is pending validation on a Multi-AZ lab. The recovery workflow is the same as hot-to-warm; the only additional step is bringing DR application compute online before running the shared recovery procedure. Do not assume the machine pool is named `workers`, and do not assume Multi-AZ automatically permits scaling a hosted machine pool to zero. Inspect the DR machine-pool topology first.

For a topology that supports cold DR application compute, bring the selected DR compute online first, then continue here:

```bash
rosa list machinepools -c "$DR_CLUSTER_NAME"
rosa edit machinepool <dr-machinepool-name> --cluster "$DR_CLUSTER_NAME" --replicas <replica-count>
oc wait nodes --for=condition=Ready --all --timeout=600s
oc wait deployment/velero -n openshift-adp --for=condition=Available --timeout=300s
```

Scale only the DR machine pool or pools that host the recovered workload. Use the name shown by `rosa list machinepools`.

### 6.1 Confirm EFS Replication Freshness

Before promoting EFS, verify that replication is healthy and recent enough for your recovery point objective:

```bash
source "$DR_ENV"

aws efs describe-replication-configurations \
  --region "$PRIMARY_REGION" \
  --file-system-id "$PRIMARY_EFS" \
  --query 'Replications[0].Destinations[0].{Status:Status,LastReplicatedTimestamp:LastReplicatedTimestamp}' \
  --output table
```

Continue only if:

- `Status` is `ENABLED`
- `LastReplicatedTimestamp` is acceptable for your workload

Any data written after the last replicated timestamp might not exist on the DR file system.

### 6.2 Promote the DR EFS Replica

EFS replicas are read-only while replication is active. Promote the DR EFS file system by deleting the replication configuration:

```bash
aws efs delete-replication-configuration \
  --source-file-system-id "$PRIMARY_EFS" \
  --region "$PRIMARY_REGION"
```

Wait until the DR file system is available:

```bash
until [ "$(aws efs describe-file-systems \
  --file-system-id "$DR_EFS" \
  --region "$DR_REGION" \
  --query 'FileSystems[0].LifeCycleState' \
  --output text)" = "available" ]; do
  echo "Waiting for DR EFS to become available..."
  sleep 10
done
```

Verify DR mount targets are available:

```bash
aws efs describe-mount-targets \
  --file-system-id "$DR_EFS" \
  --region "$DR_REGION" \
  --query 'MountTargets[].{MountTargetId:MountTargetId,SubnetId:SubnetId,LifeCycleState:LifeCycleState}' \
  --output table
```

All mount targets used by DR worker subnets must be `available`.

### 6.3 Recreate Static EFS Persistent Volumes and Claims

Use the mapping file recorded before the disaster. Create one DR EFS access point, one static PV, and one matching PVC for every EFS-backed claim in the mapping file. This avoids relying on OADP to rewrite restored PVC binding fields and preserves the access point POSIX identity needed for writes.

On the DR cluster:

```bash
source "$DR_ENV"
./scripts/recover-efs-volumes.sh --env-file "$DR_ENV"
```

The important fields are:

- `claimRef.namespace` and `claimRef.name`, which pre-bind the PV to the expected PVC
- `volumeName` on the PVC, which binds the claim to the static DR PV
- `volumeHandle: "${DR_EFS}::${DR_ACCESS_POINT_ID}"`, which mounts the original replicated EFS path through a DR access point
- the DR access point POSIX UID/GID, which preserves the write behavior of the original dynamically provisioned access point
- one PV per EFS-backed PVC, including every StatefulSet ordinal PVC

The helper waits until every recreated claim is `Bound` before returning.

### 6.4 Restore Kubernetes Resources with OADP

Restore the application namespace. Exclude PVs and PVCs because you already recreated the EFS-backed storage objects from the recorded mapping file. Workloads are restored only after the claims are present and bound.

```bash
source "$DR_ENV"
./scripts/restore-dr-workload.sh --env-file "$DR_ENV"
```

The helper creates the Velero `Restore`, waits for phase `Completed`, records `RESTORE_NAME` in `dr.env`, and applies the DR-specific S3 bucket, Region, and IAM role values for Phoenix.

### 6.5 Apply DR-Specific Configuration

The restored workload can contain primary-region values. For Phoenix Mission Control, the restore helper applies:

```bash
APP_S3_ROLE_ARN_DR
APP_BUCKET_DR
DR_REGION
DR_CLUSTER_NAME
```

For other applications, update any region-specific bucket names, IAM role annotations, external endpoints, or configuration values before sending traffic to DR.

### 6.6 Validate Recovery

Run the recovery validator:

```bash
source "$DR_ENV"
./scripts/validate-dr-recovery.sh --env-file "$DR_ENV"
```

The validator checks StatefulSet readiness, PVC binding, each PV handle, each DR access point root path, the pre-failover EFS and S3 markers, a new DR EFS write, a new DR S3 write, and the application route.

After these checks pass, perform your external DNS or traffic cutover.

## 7. Failback Considerations

Failback is not a single generic command. Treat it as an application data reconciliation event.

During failover, the DR EFS file system and DR S3 bucket become writable data stores. Writes made in the DR Region are not automatically copied back to the primary Region.

Before returning traffic to primary:

- Reconcile DR EFS writes back to primary EFS, or intentionally discard them
- Reconcile DR S3 writes back to the primary bucket, or intentionally discard them
- Validate the primary application with reconciled data
- Only then move traffic back to the primary cluster

Be careful when re-establishing EFS replication from primary to DR. AWS enables overwrite protection after promotion. Disabling overwrite protection and recreating primary-to-DR replication can overwrite the DR EFS file system with primary data.

S3 CRR in this guide is one-way. To preserve DR-side S3 writes, configure reverse replication or manually synchronize objects before returning traffic to primary.

## 8. Cleanup

Cleanup was validated for the current single-AZ validation run. The helper scripts record generated resource names in `dr.env`; use that file as the cleanup source of truth.

Run cleanup in this order and stop if any subsystem fails:

```bash
source "$DR_ENV"

oc login <primary-api-url>
./scripts/cleanup-openshift.sh --env-file "$DR_ENV" || return 1

oc login <dr-api-url>
./scripts/cleanup-openshift.sh --env-file "$DR_ENV" || return 1

./scripts/cleanup-s3.sh --env-file "$DR_ENV" || return 1
./scripts/cleanup-efs.sh --env-file "$DR_ENV" || return 1
./scripts/cleanup-iam.sh --env-file "$DR_ENV"
```

The cleanup scripts remove only resources recorded in `dr.env` or fixed validation resources created by this guide. The S3 cleanup purges all object versions and delete markers before deleting buckets. The EFS cleanup handles replication already being absent, deletes access points, deletes mount targets, waits until mount targets are gone, then deletes file systems and helper-created EFS security groups. The IAM cleanup detaches policies before deleting helper-created roles and customer-managed policies, including EFS CSI resources.

Validate cleanup:

```bash
./scripts/validate-cleanup.sh --env-file "$DR_ENV"
```

The validator prints `PASS deleted` for absent resources and returns nonzero if any guide-created S3 bucket, EFS file system, EFS security group, IAM role, IAM policy, or OpenShift validation resource remains.
