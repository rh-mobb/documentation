---
date: '2023-04-04'
title: Enabling cross account EFS mounting
tags: ["AWS", "ROSA"]
authors:
  - Andy Repton
---

The Amazon Web Services Elastic File System (AWS EFS) is a Network File System (NFS) that can be provisioned on Red Hat OpenShift Service on AWS clusters. With the release of OpenShift 4.10 the EFS CSI Driver is now GA and available.

This is a guide to enable cross-account EFS mounting on ROSA.

> Important: Cross Account EFS is considered an advanced topic, and this article makes various assumptions as to knowledge of AWS terms and techniques across VPCs, Networking, IAM permissions and more.

## Prerequisites

* One AWS Account containing a Red Hat OpenShift on AWS (ROSA) 4.16 or later cluster, in a VPC
* One AWS Account containing (or which will contain) the EFS filesystem, containing a VPC
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
   export AWS_ACCOUNT_A_ID="Account ID that holds your ROSA cluster"
   export AWS_ACCOUNT_B_ID="Account ID that will hold your EFS filesystem"
   export AWS_ACCOUNT_A_VPC_CIDR="CIDR of the VPC of your ROSA cluster"
   export AWS_ACCOUNT_B_VPC_CIDR="CIDR of the VPC of your EFS filesystem"
   export ACCOUNT_A_VPC_ID="Your VPC ID here"
   export ACCOUNT_B_VPC_ID="Your VPC ID here"
   export SCRATCH_DIR=/tmp/scratch
   export AWS_PAGER=""
   mkdir -p $SCRATCH_DIR
   ```

1. As we will be swapping back and forth between two AWS accounts, set up your AWS CLI profiles to avoid confusion now:

   ```bash
   aws configure --profile aws_account_a
   # Follow the instructions
   aws configure --profile aws_account_b
   # follow the instructions
   ```

## Prepare AWS Account A IAM Roles and Policies

> IMPORTANT: Run these commands in AWS ACCOUNT A

1. Swap to your Account A profile

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_a
   ```

1. Create an IAM Policy for the EFS CSI Driver (Note, this has additional permissions compared to a single account EFS CSI policy)

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
                   "elasticfilesystem:ClientMount",
                   "elasticfilesystem:ClientRootAccess",
                   "elasticfilesystem:ClientWrite",
                   "elasticfilesystem:DescribeMountTargets",
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
           },
           {
               "Effect": "Allow",
               "Action": "sts:AssumeRole",
               "Resource": "arn:aws:iam::${AWS_ACCOUNT_B_ID}:role/cross-account-efs-role"
           }
       ]
   }
   EOF
   ```

1. Create the Policy

   ```bash
   ACCOUNT_A_POLICY=$(aws iam create-policy --policy-name "${CLUSTER_NAME}-rosa-efs-csi" \
      --policy-document file://$SCRATCH_DIR/efs-policy.json \
      --query 'Policy.Arn' --output text) || \
   echo $ACCOUNT_A_POLICY
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
           "Federated": "arn:aws:iam::${AWS_ACCOUNT_A_ID}:oidc-provider/${OIDC_PROVIDER}"
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
   ACCOUNT_A_ROLE=$(aws iam create-role \
     --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
     --assume-role-policy-document file://$SCRATCH_DIR/TrustPolicy.json \
     --query "Role.Arn" --output text)
   echo $ACCOUNT_A_ROLE
   ```

1. Attach the Policies to the Role

   ```bash
   aws iam attach-role-policy \
      --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
      --policy-arn ${ACCOUNT_A_POLICY}
   ```

 1. At this stage, the Role that the EFS CSI Controller uses can now assume a role inside Account B, now we need to go to Account B and set up the correct permissions.


## Prepare AWS Account B IAM Roles and Policies

> IMPORTANT: Run these commands in AWS ACCOUNT B

In this account, we need to allow certain permissions to allow the EFS operator in AWS Account A to reach AWS Account B. 

1. Swap to your Account B profile

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_b
   ```

1. Create an IAM Policy

   ```bash
   cat << EOF > $SCRATCH_DIR/cross-account-efs-policy.json
   {
       "Version": "2012-10-17",
       "Statement": [
           {
               "Sid": "VisualEditor0",
               "Effect": "Allow",
               "Action": [
                   "ec2:DescribeNetworkInterfaces",
                   "ec2:DescribeSubnets"
               ],
               "Resource": "*"
           },
           {
               "Sid": "VisualEditor1",
               "Effect": "Allow",
               "Action": [
                   "elasticfilesystem:DescribeMountTargets",
                   "elasticfilesystem:DeleteAccessPoint",
                   "elasticfilesystem:ClientMount",
                   "elasticfilesystem:DescribeAccessPoints",
                   "elasticfilesystem:ClientWrite",
                   "elasticfilesystem:ClientRootAccess",
                   "elasticfilesystem:DescribeFileSystems",
                   "elasticfilesystem:CreateAccessPoint",
                   "elasticfilesystem:TagResource"
               ],
               "Resource": "*"
           }
       ]
   }
   EOF
   ```


1. Create the Policy

   ```bash
   ACCOUNT_B_POLICY=$(aws iam create-policy --policy-name "cross-account-rosa-efs-csi" \
      --policy-document file://$SCRATCH_DIR/efs-policy.json \
      --query 'Policy.Arn' --output text)
   echo $ACCOUNT_B_POLICY
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
                   "AWS": "arn:aws:iam::${AWS_ACCOUNT_A_ID}:root"
               },
               "Action": "sts:AssumeRole",
               "Condition": {}
           }
       ]
   }
   EOF
   ```

1. Create Role for the EFS CSI Driver Operator to assume

   ```bash
   ACCOUNT_B_ROLE=$(aws iam create-role \
     --role-name "cross-account-efs-role" \
     --assume-role-policy-document file://$SCRATCH_DIR/TrustPolicy.json \
     --query "Role.Arn" --output text)
   echo $ACCOUNT_B_ROLE
   ```

1. Attach the Policies to the Role

   ```bash
   aws iam attach-role-policy \
      --role-name "cross-account-efs-role" \
      --policy-arn $ACCOUNT_B_POLICY
   ```

## Set up VPC Peering

### Set up Account A

1. Swap to your Account A profile

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_a
   ```

1. Start a peering request to Account B from Account A

   ```bash
   PEER_REQUEST_ID=$(aws ec2 create-vpc-peering-connection --vpc-id "${ACCOUNT_A_VPC_ID}" --peer-vpc-id "${ACCOUNT_B_VPC_ID}" --peer-owner-id "${AWS_ACCOUNT_B_ID}" --query VpcPeeringConnection.VpcPeeringConnectionId --output text)
   ```

1. Accept the peering request from Account B

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_b
   aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id "${PEER_REQUEST_ID}"
   ```

1. Get the route table IDs for Account A and add route to Account B VPC

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_a
   for NODE in $(oc get nodes --selector=node-role.kubernetes.io/worker | tail -n +2 | awk '{print $1}')
   do 
     SUBNET=$(aws ec2 describe-instances --filters "Name=private-dns-name,Values=$NODE" --query 'Reservations[*].Instances[*].NetworkInterfaces[*].SubnetId' | jq -r '.[0][0][0]')
     echo SUBNET is ${SUBNET}
     ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${SUBNET}" --query 'RouteTables[*].RouteTableId' | jq -r '.[0]')
     echo Route table ID is $ROUTE_TABLE_ID
     aws ec2 create-route --route-table-id ${ROUTE_TABLE_ID} --destination-cidr-block ${AWS_ACCOUNT_B_VPC_CIDR} --vpc-peering-connection-id ${PEER_REQUEST_ID}
   done
   ```
   
1. Get the route table IDS for Account B and add route to Account A VPC

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_b
   export ROUTE_TABLE_ID="Put your Route table ID here"
   echo Route table ID is $ROUTE_TABLE_ID
   aws ec2 create-route --route-table-id ${ROUTE_TABLE_ID} --destination-cidr-block ${AWS_ACCOUNT_A_VPC_CIDR} --vpc-peering-connection-id ${PEER_REQUEST_ID}
   ```

1. Enable DNS resolution for Account A to read from Account B's VPC

   ```bash
   aws ec2 modify-vpc-peering-connection-options --vpc-peering-connection-id ${PEER_REQUEST_ID} --accepter-peering-connection-options AllowDnsResolutionFromRemoteVpc=true
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
       role_arn = $ACCOUNT_A_ROLE
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
   oc get deployment aws-efs-csi-driver-operator -n openshift-cluster-csi-drivers
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
   oc get daemonset aws-efs-csi-driver-node -n openshift-cluster-csi-drivers
   ```

1. Create a new secret that will tell the CSI Driver the role name in Account B to assume

   ```bash
   oc create secret generic cross-account-arn -n openshift-cluster-csi-drivers --from-literal=awsRoleArn="arn:aws:iam::${AWS_ACCOUNT_B_ID}:role/cross-account-efs-role"
   ```

1. Allow the EFS CSI Controller to read this secret

   ```bash
   oc -n openshift-cluster-csi-drivers create role access-secrets --verb=get,list,watch --resource=secrets
   oc -n openshift-cluster-csi-drivers create rolebinding --role=access-secrets default-to-secrets --serviceaccount=openshift-cluster-csi-drivers:aws-efs-csi-driver-controller-sa
   ```

## Prepare the security groups on Account A to allow NFS traffic to EFS

> IMPORTANT: Run these commands on Account A

1. Swap to your Account A profile

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_a
   ```

1. Run this set of commands to update the VPC to allow EFS access

   ```bash
   NODE=$(oc get nodes --selector=node-role.kubernetes.io/worker \
     -o jsonpath='{.items[0].metadata.name}')
   VPC=$(aws ec2 describe-instances \
     --filters "Name=private-dns-name,Values=$NODE" \
     --query 'Reservations[*].Instances[*].{VpcId:VpcId}' \
     --region $AWS_REGION \
     | jq -r '.[0][0].VpcId')
   SG=$(aws ec2 describe-instances --filters \
     "Name=private-dns-name,Values=$NODE" \
     --query 'Reservations[*].Instances[*].{SecurityGroups:SecurityGroups}' \
     --region $AWS_REGION \
     | jq -r '.[0][0].SecurityGroups[0].GroupId')
   echo "SG - $SG"
   ```

1. Update the Security Groups in Account A to allow NFS traffic to your nodes from EFS

   ```bash
   aws ec2 authorize-security-group-ingress \
    --group-id $SG \
    --protocol tcp \
    --port 2049 \
    --cidr $AWS_ACCOUNT_B_VPC_CIDR | jq .
   ```

> At this point you can create either a single Zone EFS filesystem, or a Region wide EFS filesystem. To simplify this document, we're going to give only an example of a Region wide EFS filesystem.

### Creating a region-wide EFS filesystem in Account B

1. Swap to your Account B profile

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_b
   ```

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
     --query 'Subnets[*].{SubnetId:SubnetId}' \
     --region $AWS_REGION \
     | jq -r '.[].SubnetId'); do \
       MOUNT_TARGET=$(aws efs create-mount-target --file-system-id $EFS \
          --subnet-id $SUBNET \
          --region $AWS_REGION \
          | jq -r '.MountTargetId'); \
       echo $MOUNT_TARGET; \
    done
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
     csi.storage.k8s.io/provisioner-secret-name: cross-account-arn
     csi.storage.k8s.io/provisioner-secret-namespace: openshift-cluster-csi-drivers
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
   export AWS_DEFAULT_PROFILE=aws_account_b
   for TARGET in $(aws efs describe-mount-targets --file-system-id $EFS --query 'MountTargets[*].MountTargetId' --output text)
   do
     aws efs delete-mount-target --mount-target-id ${TARGET} --region $AWS_REGION
   done
   aws efs delete-file-system --file-system-id $EFS --region $AWS_REGION
   ```

    > Note: if you receive the error `An error occurred (FileSystemInUse)` wait a few minutes and try again.

    > Note: if you created additional mount points for a regional EFS filesystem, remember to delete all of them before removing the file system

1. Detach the Policies to the Role

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_a
   aws iam detach-role-policy \
      --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" \
      --policy-arn ${ACCOUNT_A_POLICY}
   ```

1. Delete the Role

   ```bash
   aws iam delete-role --role-name \
      ${CLUSTER_NAME}-aws-efs-csi-operator
   ```

1. Delete the Policy

   ```bash
   aws iam delete-policy --policy-arn \
      $ACCOUNT_A_POLICY
   ```

1. Detach the policies from the cross-account role

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_b
   aws iam detach-role-policy \
      --role-name "cross-account-efs-role" \
      --policy-arn ${ACCOUNT_B_POLICY}
   ```

1. Delete the Role

   ```bash
   aws iam delete-role --role-name \
      cross-account-efs-role
   ```

1. Delete the Policy

   ```bash
   aws iam delete-policy --policy-arn \
      $ACCOUNT_B_POLICY
   ```

1. Remove peering connection from account B

   ```bash
   aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "${PEER_REQUEST_ID}"
   ```

1. Remove peering connection from account A

   ```bash
   export AWS_DEFAULT_PROFILE=aws_account_a
   aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "${PEER_REQUEST_ID}"
   ```
