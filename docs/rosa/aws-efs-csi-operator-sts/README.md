# Enabling the AWS EFS CSI Driver Operator on ROSA

**Author: Paul Czarkowski**
*Modified: 03/16/2022*

The Amazon Web Services Elastic File System (AWS EFS) is a Network File System (NFS) that can be provisioned on Red Hat OpenShift Service on AWS clusters. With the release of OpenShift 4.10 the EFS CSI Driver is now GA and available.

This is a guide to quickly enable the EFS Operator on ROSA to a Red Hat OpenShift on AWS (ROSA) cluster with STS enabled.

See [here](https://docs.openshift.com/container-platform/4.10/storage/container_storage_interface/persistent-storage-csi-aws-efs.html#persistent-storage-csi-aws-efs) for the official ROSA documentation.


## Prerequisites

* A Red Hat OpenShift on AWS (ROSA) 4.10 cluster
* The OC CLI
* The AWS CLI
* JQ

## Set up environment

1. export some environment variables

    ```bash
    export SCRATCH_DIR=/tmp/scratch
    export AWS_PAGER=""
    mkdir -p $SCRATCH_DIR
    ```

## Prepare AWS Account

1. Download the IAM Policy

    ```bash
cat << EOF > $SCRATCH_DIR/efs-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems"
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


1. Apply the Policy

    ```bash
    POLICY=$(aws iam create-policy --policy-name rosa-efs-csi \
      --policy-document file://$SCRATCH_DIR/efs-policy.json \
      --query 'Policy.Arn' --output text)
    echo $POLICY
    ```

1. Create service account

    ```bash
    aws iam create-user --user-name rosa-efs-csi  \
      --query User.Arn --output text
    ```

1. Attach policy to user

    ```bash
    aws iam attach-user-policy --user-name rosa-efs-csi \
      --policy-arn ${POLICY}
    ```

1. Create Access Keys

    ```bash
read -r ACCESS_KEY_ID ACCESS_KEY < <(aws iam create-access-key \
  --user-name rosa-efs-csi \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
    ```

## Deploy and test the AWS EFS Operator

1. Create a Secret to store the Access Keys

    ```bash
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
 name: aws-efs-cloud-credentials
 namespace: openshift-cluster-csi-drivers
stringData:
  aws_access_key_id: $ACCESS_KEY_ID
  aws_secret_access_key: $ACCESS_KEY
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
  startingCSV: aws-efs-csi-driver-operator.4.10.0-202202221641
EOF
    ```

1. Wait until the Operator is running

    ```bash
watch oc get deployment aws-efs-csi-driver-controller
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
watch oc get daemonset aws-efs-csi-driver-node
    ```


1. Create a storage class

    ```bash
cat <<EOF | oc apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-csi
parameters:
provisioner: efs.csi.aws.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
    ```

## Prepare an AWS EFS Volume


1. Run this set of commands to update the VPC to allow EFS access

    ```bash
NODE=$(oc get nodes --selector=node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')
VPC=$(aws ec2 describe-instances \
  --filters "Name=private-dns-name,Values=$NODE" \
  --query 'Reservations[*].Instances[*].{VpcId:VpcId}' \
  | jq -r '.[0][0].VpcId')
SUBNET=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC Name=tag:Name,Values='*-private' \
  --query 'Subnets[*].{SubnetId:SubnetId}' \
  | jq -r '.[0].SubnetId')
CIDR=$(aws ec2 describe-vpcs \
  --filters "Name=vpc-id,Values=$VPC" \
  --query 'Vpcs[*].CidrBlock' \
  | jq -r '.[0]')
SG=$(aws ec2 describe-instances --filters \
  "Name=private-dns-name,Values=$NODE" \
  --query 'Reservations[*].Instances[*].{SecurityGroups:SecurityGroups}' \
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

1. Create EFS File System

    ```bash
EFS=$(aws efs create-file-system --creation-token efs-token-1 \
  --encrypted | jq -r '.FileSystemId')
echo $EFS
    ```

1. Configure Mount Target for EFS

    ```bash
MOUNT_TARGET=$(aws efs create-mount-target --file-system-id $EFS \
  --subnet-id $SUBNET --security-groups $SG \
  | jq -r '.MountTargetId')
    ```

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


## Test


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
aws efs delete-mount-target --mount-target-id $MOUNT_TARGET
aws efs delete-file-system --file-system-id $EFS
    ```

    > Note if you receive the error `An error occurred (FileSystemInUse)` wait a few minutes and try again.
