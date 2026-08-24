---
date: '2026-08-24'
title: Create ROSA HCP Disaster Recovery Infrastructure
tags: ["ROSA HCP"]
authors:
  - Kevin Collins
  - Diana Sari
  - Kumudu Herath
validated_version: "4.22"
---

This guide builds the shared infrastructure for disaster recovery between two ROSA HCP clusters in different AWS Regions. It configures the EFS CSI Driver, S3 Cross-Region Replication, and EFS replication, giving you a foundation that multiple DR recovery patterns can build on.

Once this infrastructure is in place, choose a recovery pattern:

- **[Disaster Recovery with OADP](/experts/rosa/oadp-efs-s3/)** uses OADP (OpenShift API for Data Protection) to back up and restore Kubernetes resources. This is a traditional backup-and-restore approach where Velero captures application state on the primary cluster and replays it on the DR cluster during failover.
- **[Disaster Recovery with ACM and OpenShift GitOps](/experts/rosa/rosa-acm-dr/)** uses Red Hat Advanced Cluster Management for automatic failover detection and ArgoCD for application deployment. This is a GitOps-driven approach where ACM monitors cluster health and ArgoCD continuously reconciles the application to whichever cluster ACM selects, removing the need for manual backup and restore operations.

Both patterns use the same shared infrastructure configured in this guide.

## Architecture

The reference environment has:

- A primary ROSA HCP cluster in one AWS Region
- A DR ROSA HCP cluster in another AWS Region
- An application S3 bucket in the primary Region, replicated to a DR bucket
- A DR-pattern-specific S3 bucket in the primary Region, replicated to a DR bucket (for example, an OADP backup bucket)
- A primary EFS file system, replicated to an EFS file system in the DR Region
- EFS CSI Driver installed on both clusters

DNS or traffic cutover is external to this guide. After recovery is validated, update DNS, load balancer, or application routing according to your environment.

## 0. Prerequisites

You need:

- Two existing ROSA HCP clusters in different AWS Regions
- AWS CLI
- `rosa` CLI
- `oc` CLI
- `jq`
- AWS permissions for IAM, EC2, S3, and EFS
- Cluster admin access to both clusters

Clone the helper scripts repository:

```bash
git clone https://github.com/rh-mobb/rosa-dr-scripts.git
cd rosa-dr-scripts
```

## Environment Variables

Set your cluster names:

```bash
export PRIMARY_CLUSTER_NAME=<primary-cluster-name>
export DR_CLUSTER_NAME=<dr-cluster-name>
export AWS_PAGER=""
```

The helper scripts detect regions, VPCs, subnets, and worker security groups from the cluster names. No additional environment setup is needed before continuing.

## 1. Install the EFS CSI Driver

**Log in to the primary cluster**, then install the EFS CSI Driver:

```bash
eval "$(./scripts/install-efs-csi.sh --cluster "$PRIMARY_CLUSTER_NAME")"

PRIMARY_VAR=$(echo "$PRIMARY_CLUSTER_NAME" | tr '-' '_')
echo "${PRIMARY_VAR}_EFS_CSI_ROLE_ARN: $(eval echo \$${PRIMARY_VAR}_EFS_CSI_ROLE_ARN)"
echo "${PRIMARY_VAR}_EFS_CSI_POLICY_ARN: $(eval echo \$${PRIMARY_VAR}_EFS_CSI_POLICY_ARN)"
```

**Log in to the DR cluster**, then install the EFS CSI Driver:

```bash
eval "$(./scripts/install-efs-csi.sh --cluster "$DR_CLUSTER_NAME")"

DR_VAR=$(echo "$DR_CLUSTER_NAME" | tr '-' '_')
echo "${DR_VAR}_EFS_CSI_ROLE_ARN: $(eval echo \$${DR_VAR}_EFS_CSI_ROLE_ARN)"
echo "${DR_VAR}_EFS_CSI_POLICY_ARN: $(eval echo \$${DR_VAR}_EFS_CSI_POLICY_ARN)"
```

The helper creates a customer-managed EFS CSI controller IAM policy. This is intentional. The AWS-managed EFS CSI policy includes tag conditions that can conflict with tags injected by ROSA or OpenShift during access point creation. A custom policy avoids those tag-condition failures while keeping the EFS CSI permissions explicit.

Verify the driver on each cluster:

```bash
oc get pods -n openshift-cluster-csi-drivers | grep efs
oc get clustercsidriver efs.csi.aws.com
```

## 2. Configure S3 Replication

Create S3 buckets for application data and DR-pattern backups, then configure one-way replication from primary to DR:

```bash
eval "$(./scripts/configure-s3-replication.sh)"
./scripts/validate-s3-replication.sh

echo "PRIMARY_REGION:        $PRIMARY_REGION"
echo "DR_REGION:             $DR_REGION"
echo "AWS_ACCOUNT_ID:        $AWS_ACCOUNT_ID"
echo "APP_BUCKET_PRIMARY:    $APP_BUCKET_PRIMARY"
echo "APP_BUCKET_DR:         $APP_BUCKET_DR"
echo "OADP_BUCKET_PRIMARY:   $OADP_BUCKET_PRIMARY"
echo "OADP_BUCKET_DR:        $OADP_BUCKET_DR"
echo "S3_REPLICATION_ROLE_ARN: $S3_REPLICATION_ROLE_ARN"
echo "APP_S3_ROLE_ARN_PRIMARY: $APP_S3_ROLE_ARN_PRIMARY"
echo "APP_S3_ROLE_ARN_DR:    $APP_S3_ROLE_ARN_DR"
```

For the purposes of this guide, S3 Cross-Region Replication is configured as one-way (primary to DR). However, in a real-world production environment, you should configure bi-directional replication to ensure any objects written to the DR bucket during a failover automatically sync back to the primary bucket.

## 3. Configure EFS Replication

Create the primary EFS file system, mount targets, and the DR replica:

```bash
eval "$(./scripts/configure-efs-replication.sh)"
./scripts/validate-efs-replication.sh

echo "PRIMARY_EFS:  $PRIMARY_EFS"
echo "DR_EFS:       $DR_EFS"
echo "EFS_SG_PRIMARY: $EFS_SG_PRIMARY"
echo "EFS_SG_DR:    $EFS_SG_DR"
echo "VPC_PRIMARY:  $VPC_PRIMARY"
echo "VPC_DR:       $VPC_DR"
```

The script:

- Detects regions, subnets, and worker security groups from the cluster names
- Discovers each cluster VPC from the subnet list
- Creates or reuses named EFS security groups
- Uses the worker security groups to allow NFS (port 2049) access
- Creates a primary EFS file system
- Waits for the primary file system to become available
- Creates mount targets in every machine pool subnet
- Creates EFS replication to the DR Region
- Waits for the DR replica file system to become available
- Creates DR mount targets
- Waits for all mount targets to become available


After EFS is created, create the EFS StorageClass on both clusters.

**Log in to the primary cluster**, then apply the StorageClass and run a smoke test:

```bash
./scripts/validate-efs-csi.sh --efs-id "$PRIMARY_EFS" --smoke-test
```

**Log in to the DR cluster**, then apply the StorageClass:

```bash
./scripts/validate-efs-csi.sh --efs-id "$DR_EFS"
```

The StorageClass uses dynamic EFS access point provisioning and `directoryPerms: "775"`. The `--smoke-test` flag creates a small throwaway PVC on the primary cluster, waits for it to bind, and removes the smoke-test namespace before continuing.

## Next Steps

With the EFS CSI Driver, S3 replication, and EFS replication in place, continue with a DR recovery pattern:

- **[Disaster Recovery with OADP](/experts/rosa/oadp-efs-s3/)** -- backup-and-restore approach using OADP/Velero for Kubernetes resource recovery, with EFS PVC mapping and full failover/failback workflow.
- **[Disaster Recovery with ACM and OpenShift GitOps](/experts/rosa/rosa-acm-dr/)** -- GitOps-driven approach using ACM for automatic failover detection and ArgoCD for continuous application reconciliation.
