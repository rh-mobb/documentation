---
date: '2024-07-25'
title: Migrating EC2 Instances to OpenShift Virtualization
tags: ["AWS", "ROSA", "EC2", "OpenShift", "Virtualization", "Migration"]
authors:
  - Florian Jacquin
---

Red Hat OpenShift Service on AWS (ROSA) provides a managed OpenShift environment that can run virtualized workloads using OpenShift Virtualization. This guide will walk you through migrating an existing EC2 instance to OpenShift Virtualization by exporting it to S3, syncing to EFS, and importing as a VM.

## Prerequisites

* A Red Hat OpenShift on AWS (ROSA) 4.19+ cluster
* AWS CLI configured with appropriate permissions
* SSH public key at `~/.ssh/id_rsa.pub` (**REQUIRED** - for key-based authentication)
* Terraform installed
* OC CLI (Admin access to cluster)
* virtctl CLI tool

## Clone the Repository

First, clone the repository and navigate to the project directory:

```bash
git clone https://github.com/rh-mobb/ec2-export.git
cd ec2-export
```

## Set Environment Variables

Set up your environment with the required variables:

```bash
export CLUSTER_NAME="your-rosa-cluster-name"
export AWS_REGION="eu-west-1"  # Replace with your AWS region
export EC2_OS="rhel10"  # Options: rhel10, ubuntu
```

## Set up Bare Metal Worker Node

OpenShift Virtualization requires bare metal nodes to run VMs:

```bash
rosa create machine-pool -c $CLUSTER_NAME --name bm --replicas=1 --instance-type c5n.metal
```

This creates a machine pool with one bare metal instance for running your VMs.

## Deploy Required Operators

Deploy the virtualization and migration operators using kustomize:

```bash
oc apply -k yaml/operators/
```

## Wait for CRDs

Ensure the Custom Resource Definitions are available:

```bash
oc get crd hyperconvergeds.hco.kubevirt.io
oc get crd forkliftcontrollers.forklift.konveyor.io
```

## Deploy Custom Resources

Deploy the operator instances:

```bash
oc apply -k yaml/custom-resources/
```

## Deploy AWS Infrastructure

Deploy the EC2 instance and required AWS infrastructure:

```bash
terraform apply -var="aws_region=$AWS_REGION" -var="cluster_name=$CLUSTER_NAME" -var="ec2_os=$EC2_OS"
```

This creates:
- EC2 instance with web server
- S3 bucket for VM export storage
- EFS file system for OpenShift access
- DataSync task for S3-to-EFS transfer
- IAM roles and security groups

## Test EC2 Instance

Verify your EC2 instance is running correctly:

```bash
$(terraform output -raw curl_test_command)
```

You should see a response like "Hello from RHEL 10 on EC2" or "Hello from Ubuntu 24.04 on EC2".

## Export EC2 to OVA

Export your EC2 instance to OVA format and store in S3:

```bash
$(terraform output -raw ec2_export_command)
```

Monitor the export progress:

```bash
aws ec2 describe-export-tasks --region $AWS_REGION | jq .ExportTasks[0].State
```

Wait for completion (typically 15-20 minutes):

```bash
aws ec2 wait export-task-completed --region $AWS_REGION
```

## Sync OVA to EFS

Once the export is complete, sync the OVA file to EFS:

```bash
$(terraform output -raw datasync_execution_command)
```

## Create OVA Provider

In the OpenShift Console:

1. Navigate to **Migration → Providers for virtualization**
2. Click **Create Provider**
3. Select **Open Virtual Appliance (OVA)**
4. Enter provider name: `ec2-provider`
5. Enter EFS NFS URL: 
   ```bash
   echo $(terraform output -raw efs_dns_name):/ova
   ```
6. Click **Create**

## Create Migration Plan

1. Create destination namespace:
   ```bash
   oc new-project ec2-vm
   ```

2. In OpenShift Console:
   - Navigate to **Migration → Plans for virtualization**
   - Click **Create Plan**
   - Select your OVA provider as source
   - Select VMs to migrate
   - Create network and storage mappings
   - Select `ec2-vm` as target namespace
   - Click **Create migration plan**

## Start Migration

1. Click **Start** on your migration plan
2. Wait for migration to complete
3. Navigate to **Virtualization → Virtual Machines**
4. Select `ec2-vm` namespace
5. Your migrated VM will appear - click to start it

## Expose VM via Route

Create a service and route to access your migrated VM:

```bash
VM_NAME=$(oc get vm -n ec2-vm -o jsonpath='{.items[0].metadata.name}')
oc create service clusterip vm-service --tcp=80:80 -n ec2-vm
oc patch service vm-service -n ec2-vm -p '{"spec":{"selector":{"app":"'$VM_NAME'"}}}'
oc create route edge vm-route --service=vm-service -n ec2-vm
```

## Test Migrated VM

Test your migrated VM via the OpenShift route:

```bash
ROUTE_URL=$(oc get route vm-route -n ec2-vm -o jsonpath='{.spec.host}')
curl -s https://$ROUTE_URL
```

## Verify Migration Success

SSH into your migrated VM and modify the web content to prove migration:

```bash
# SSH user depends on OS: ec2-user (RHEL) or ubuntu (Ubuntu)
virtctl ssh ec2-user@$VM_NAME -n ec2-vm

# Modify the web page content
sudo sed -i "s/EC2/OpenShift Virt/g" /var/www/html/index.html
exit

# Test the change
curl -s https://$ROUTE_URL
```

You should now see "Hello from RHEL 10 on OpenShift Virt" - Migration complete! 🎉

## Multiple VMs

To migrate multiple EC2 instances, simply repeat the export and sync process for each instances.
Make sure to check [limitations](https://docs.aws.amazon.com/vm-import/latest/userguide/vmexport-limits.html).

## Cleanup

When you're done testing, clean up the AWS resources:

```bash
# Get bucket name and empty it
BUCKET_NAME=$(terraform output -raw s3_bucket_name)
aws s3 rm s3://$BUCKET_NAME --recursive --region $AWS_REGION

# Destroy Terraform infrastructure
terraform destroy -var="aws_region=$AWS_REGION" -var="cluster_name=$CLUSTER_NAME" -var="ec2_os=$EC2_OS"

# Remove bare metal machine pool
rosa delete machine-pool bm -c $CLUSTER_NAME --yes
```

## Conclusion

- You now have successfully migrated an EC2 instance to OpenShift Virtualization running on ROSA.
- This approach provides a reliable path for migrating existing AWS workloads to a containerized platform while maintaining VM compatibility.
- The combination of AWS services (S3, EFS, DataSync) with OpenShift Virtualization provides a robust migration path for legacy applications.
- Your migrated VMs benefit from OpenShift's enterprise features like monitoring, logging, security policies, and automated operations while maintaining their original runtime environment.
- **ROSA can optimize your resource consumption** through efficient hardware overprovisioning ratios, potentially delivering 30-60% annual cost savings compared to running VMs directly on EC2, while including unlimited RHEL licensing.
