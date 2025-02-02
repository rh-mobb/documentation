---
date: '2023-04-04'
title: Enabling the AWS EFS CSI Driver Operator on ROSA
tags: ["AWS", "ROSA"]
aliases:
- /experts/rosa/aws-efs/aws-efs-csi-operator-on-rosa/
- /experts/rosa/aws-efs/aws-efs-operator-on-rosa/
authors:
  - Paul Czarkowski
  - Andy Repton
  - Shaozhen Ding
---

The Amazon Web Services Elastic File System (AWS EFS) is a Network File System (NFS) that can be provisioned on Red Hat OpenShift Service on AWS clusters. With the release of OpenShift 4.10 the EFS CSI Driver is now GA and available.

This is a guide to quickly enable the EFS Operator on ROSA to a Red Hat OpenShift on AWS (ROSA) cluster with STS enabled.

> Note: The official supported installation instructions for the EFS CSI Driver on ROSA are available [here](https://access.redhat.com/articles/6966373).

## Dynamic vs Static provisioning

The CSI driver supports both Static and Dynamic provisioning. Dynamic provisioning should not be confused with the ability of the Operator to create EFS volumes.

### Dynamic provisioning

Dynamic provisioning provisions new PVs as subdirectories of a pre-existing EFS volume. The PVs are independent of each other. However, they all share the same EFS volume. When the volume is deleted, all PVs provisioned out of it are deleted too. The EFS CSI driver creates an AWS Access Point for each such subdirectory. Due to AWS AccessPoint limits, you can only dynamically provision 120 PVs from a single StorageClass/EFS volume.

### Static provisioning

Static provisioning mounts the entire volume to a pod.

## Prerequisites

* A Red Hat OpenShift on AWS (ROSA) 4.10 cluster
* The OC CLI
* The AWS CLI
* `jq` command
* `watch` command

## Set up environment

1. export some environment variables

   ```bash
   export CLUSTER_NAME="sts-cluster"
   export AWS_REGION="your_aws_region"
   export OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster -o json \
   | jq -r .spec.serviceAccountIssuer| sed -e "s/^https:\/\///")
   export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   export SCRATCH_DIR=/tmp/scratch
   export AWS_PAGER=""
   mkdir -p $SCRATCH_DIR
   ```

## Prepare AWS Account

In order to use the AWS EFS CSI Driver we need to create IAM roles and policies that can be attached to the Operator.

1. Create an IAM Policy

   ```bash
   cat << EOF > $SCRATCH_DIR/efs-policy.json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "elasticfilesystem:DescribeAccessPoints",
           "elasticfilesystem:DescribeFileSystems",
           "elasticfilesystem:DescribeMountTargets",
           "elasticfilesystem:TagResource",
           "ec2:DescribeAvailabilityZones"
         ],
         "Resource": "*"
       },
       {
         "Effect": "Allow",
         "Action": [
           "elasticfilesystem:CreateAccessPoint"
         ],
         "Resource": "*",
         "Condition": {
           "StringLike": {
             "aws:RequestTag/efs.csi.aws.com/cluster": "true"
           }
         }
       },
       {
         "Effect": "Allow",
         "Action": "elasticfilesystem:DeleteAccessPoint",
         "Resource": "*",
         "Condition": {
           "StringEquals": {
             "aws:ResourceTag/efs.csi.aws.com/cluster": "true"
           }
         }
       }
     ]
   }
   EOF
   ```


1. Create the Policy

   > This creates a named policy for the cluster, you could use a generic policy for multiple clusters to keep things simpler.

   ```bash
   POLICY=$(aws iam create-policy --policy-name "${CLUSTER_NAME}-rosa-efs-csi" \
      --policy-document file://$SCRATCH_DIR/efs-policy.json \
      --query 'Policy.Arn' --output text) || \
      POLICY=$(aws iam list-policies \
      --query 'Policies[?PolicyName==`rosa-efs-csi`].Arn' \
      --output text)
   echo $POLICY
   ```

1. Create a Trust Policy

   ```bash
   cat <<EOF > $SCRATCH_DIR/TrustPolicy.json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "${OIDC_PROVIDER}:sub": [
               "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-operator",
               "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-controller-sa"
             ]
           }
         }
       }
     ]
   }
   EOF
   ```

1. Create Role for the EFS CSI Driver Operator

   ```bash
   ROLE=$(aws iam create-role \
     --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
     --assume-role-policy-document file://$SCRATCH_DIR/TrustPolicy.json \
     --query "Role.Arn" --output text)
   echo $ROLE
   ```

1. Attach the Policies to the Role

   ```bash
   aws iam attach-role-policy \
      --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
      --policy-arn $POLICY
   ```

## Deploy and test the AWS EFS Operator

1. Create a Secret to tell the AWS EFS Operator which IAM role to request.

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
    name: aws-efs-cloud-credentials
    namespace: openshift-cluster-csi-drivers
   stringData:
     credentials: |-
       [default]
       role_arn = $ROLE
       web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
   EOF
   ```

1. Install the EFS Operator

   ```bash
   cat <<EOF | oc create -f -
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     generateName: openshift-cluster-csi-drivers-
     namespace: openshift-cluster-csi-drivers
   ---
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     labels:
       operators.coreos.com/aws-efs-csi-driver-operator.openshift-cluster-csi-drivers: ""
     name: aws-efs-csi-driver-operator
     namespace: openshift-cluster-csi-drivers
   spec:
     channel: stable
     installPlanApproval: Automatic
     name: aws-efs-csi-driver-operator
     source: redhat-operators
     sourceNamespace: openshift-marketplace
   EOF
   ```

1. Wait until the Operator is running

   ```bash
   watch oc get deployment aws-efs-csi-driver-operator -n openshift-cluster-csi-drivers
   ```

1. Install the AWS EFS CSI Driver

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: operator.openshift.io/v1
   kind: ClusterCSIDriver
   metadata:
       name: efs.csi.aws.com
   spec:
     managementState: Managed
   EOF
   ```

1. Wait until the CSI driver is running

   ```bash
   watch oc get daemonset aws-efs-csi-driver-node -n openshift-cluster-csi-drivers
   ```

## Prepare an AWS EFS Volume for dynamic provisioning

1. Run this set of commands to update the VPC to allow EFS access

   ```bash
   NODE=$(oc get nodes --selector=node-role.kubernetes.io/worker \
     -o jsonpath='{.items[0].metadata.name}')
   VPC=$(aws ec2 describe-instances \
     --filters "Name=private-dns-name,Values=$NODE" \
     --query 'Reservations[*].Instances[*].{VpcId:VpcId}' \
     --region $AWS_REGION \
     | jq -r '.[0][0].VpcId')
   CIDR=$(aws ec2 describe-vpcs \
     --filters "Name=vpc-id,Values=$VPC" \
     --query 'Vpcs[*].CidrBlock' \
     --region $AWS_REGION \
     | jq -r '.[0]')
   SG=$(aws ec2 describe-instances --filters \
     "Name=private-dns-name,Values=$NODE" \
     --query 'Reservations[*].Instances[*].{SecurityGroups:SecurityGroups}' \
     --region $AWS_REGION \
     | jq -r '.[0][0].SecurityGroups[0].GroupId')
   echo "CIDR - $CIDR,  SG - $SG"
   ```

1. Assuming the CIDR and SG are correct, update the security group

   ```bash
   aws ec2 authorize-security-group-ingress \
    --group-id $SG \
    --protocol tcp \
    --port 2049 \
    --cidr $CIDR | jq .
   ```

> At this point you can create either a single Zone EFS filesystem, or a Region wide EFS filesystem

### Creating a region-wide EFS

1. Create a region-wide EFS File System

   ```bash
   EFS=$(aws efs create-file-system --creation-token efs-token-1 \
      --region ${AWS_REGION} \
      --encrypted | jq -r '.FileSystemId')
   echo $EFS
   ```

1. Configure a region-wide Mount Target for EFS (this will create a mount point in each subnet of your VPC by default)

   ```bash
   for SUBNET in $(aws ec2 describe-subnets \
     --filters Name=vpc-id,Values=$VPC Name='tag:kubernetes.io/role/internal-elb',Values='*' \
     --query 'Subnets[*].{SubnetId:SubnetId}' \
     --region $AWS_REGION \
     | jq -r '.[].SubnetId'); do \
       MOUNT_TARGET=$(aws efs create-mount-target --file-system-id $EFS \
          --subnet-id $SUBNET --security-groups $SG \
          --region $AWS_REGION \
          | jq -r '.MountTargetId'); \
       echo $MOUNT_TARGET; \
    done
   ```

### Creating a single-zone EFS

> Note: If you followed the instructions above to create a region wide EFS mount, skip the following steps and proceed to "Create a Storage Class for the EFS volume"

1. Select the first subnet that you will make your EFS mount in (this will by default select the same Subnet your first node is in)

   ```bash
   SUBNET=$(aws ec2 describe-subnets \
     --filters Name=vpc-id,Values=$VPC Name='tag:kubernetes.io/role/internal-elb',Values='*' \
     --query 'Subnets[*].{SubnetId:SubnetId}' \
     --region $AWS_REGION \
     | jq -r '.[0].SubnetId')
   AWS_ZONE=$(aws ec2 describe-subnets --filters Name=subnet-id,Values=$SUBNET \
     --region $AWS_REGION | jq -r '.Subnets[0].AvailabilityZone')
   ```

1. Create your zonal EFS filesystem

   ```bash
   EFS=$(aws efs create-file-system --creation-token efs-token-1 \
      --availability-zone-name $AWS_ZONE \
      --region $AWS_REGION \
      --encrypted | jq -r '.FileSystemId')
   echo $EFS
   ```

1. Create your EFS mount point

   ```bash
   MOUNT_TARGET=$(aws efs create-mount-target --file-system-id $EFS \
     --subnet-id $SUBNET --security-groups $SG \
     --region $AWS_REGION \
     | jq -r '.MountTargetId')
   echo $MOUNT_TARGET
   ```

## Create a Storage Class for the EFS volume and verify a pod can access it.

1. Create a Storage Class for the EFS volume

   ```bash
   cat <<EOF | oc apply -f -
   kind: StorageClass
   apiVersion: storage.k8s.io/v1
   metadata:
     name: efs-sc
   provisioner: efs.csi.aws.com
   parameters:
     provisioningMode: efs-ap
     fileSystemId: $EFS
     directoryPerms: "700"
     gidRangeStart: "1000"
     gidRangeEnd: "2000"
     basePath: "/dynamic_provisioning"
   EOF
   ```

1. Create a namespace

   ```bash
   oc new-project efs-demo
   ```

1. Create a PVC

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-efs-volume
   spec:
     storageClassName: efs-sc
     accessModes:
       - ReadWriteMany
     resources:
       requests:
         storage: 5Gi
   EOF
   ```

1. Create a Pod to write to the EFS Volume

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
    name: test-efs
   spec:
    volumes:
      - name: efs-storage-vol
        persistentVolumeClaim:
          claimName: pvc-efs-volume
    containers:
      - name: test-efs
        image: centos:latest
        command: [ "/bin/bash", "-c", "--" ]
        args: [ "while true; do echo 'hello efs' | tee -a /mnt/efs-data/verify-efs && sleep 5; done;" ]
        volumeMounts:
          - mountPath: "/mnt/efs-data"
            name: efs-storage-vol
   EOF
   ```

   > It may take a few minutes for the pod to be ready.  If you see errors such as `Output: Failed to resolve "fs-XXXX.efs.us-east-2.amazonaws.com"` it likely means its still setting up the EFS volume, just wait longer.

1. Wait for the Pod to be ready

   ```bash
   watch oc get pod test-efs
   ```

1. Create a Pod to read from the EFS Volume

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
    name: test-efs-read
   spec:
    volumes:
      - name: efs-storage-vol
        persistentVolumeClaim:
          claimName: pvc-efs-volume
    containers:
      - name: test-efs-read
        image: centos:latest
        command: [ "/bin/bash", "-c", "--" ]
        args: [ "tail -f /mnt/efs-data/verify-efs" ]
        volumeMounts:
          - mountPath: "/mnt/efs-data"
            name: efs-storage-vol
   EOF
   ```

1. Verify the second POD can read the EFS Volume

   ```bash
   oc logs test-efs-read
   ```

    You should see a stream of "hello efs"

   ```
   hello efs
   hello efs
   hello efs
   hello efs
   hello efs
   hello efs
   hello efs
   hello efs
   hello efs
   hello efs
   ```

## Cleanup

1. Delete the Pods

   ```bash
   oc delete pod -n efs-demo test-efs test-efs-read
   ```

1. Delete the Volume

   ```bash
   oc delete -n efs-demo pvc pvc-efs-volume
   ```

1. Delete the Namespace

   ```bash
   oc delete project efs-demo
   ```

1. Delete the storage class

   ```bash
   oc delete storageclass efs-sc
   ```

1. Delete the EFS Shared Volume via AWS

   ```bash
   aws efs delete-mount-target --mount-target-id $MOUNT_TARGET --region $AWS_REGION
   aws efs delete-file-system --file-system-id $EFS --region $AWS_REGION
   ```

    > Note: if you receive the error `An error occurred (FileSystemInUse)` wait a few minutes and try again.

    > Note: if you created additional mount points for a regional EFS filesystem, remember to delete all of them before removing the file system

1. Detach the Policies to the Role

   ```bash
   aws iam detach-role-policy \
      --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
      --policy-arn $POLICY
   ```

1. Delete the Role

   ```bash
   aws iam delete-role --role-name \
      ${CLUSTER_NAME}-aws-efs-csi-operator
   ```

1. Delete the Policy

   ```bash
   aws iam delete-policy --policy-arn \
      $POLICY
   ```
