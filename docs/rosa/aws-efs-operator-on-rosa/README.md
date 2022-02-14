# Enabling the AWS EFS Operator on ROSA

The Amazon Web Services Elastic File System (AWS EFS) is a Network File System (NFS) that can be provisioned on Red Hat OpenShift Service on AWS clusters. AWS also provides and supports a CSI EFS Driver to be used with Kubernetes that allows Kubernetes workloads to leverage this shared file storage.

This is a guide to quickly enable the EFS Operator on ROSA to

See [here](https://docs.openshift.com/rosa/storage/persistent_storage/osd-persistent-storage-aws.html) for the official ROSA documentation.


## Prerequisites

* A Red Hat OpenShift on AWS (ROSA) cluster
* The OC CLI
* The AWS CLI
* JQ

## Prepare AWS Account

1. Get the Instance Name of one of your worker nodes

    ```bash
NODE=$(oc get nodes --selector=node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')
    ```

1. Get the VPC ID of your worker nodes

    ```bash
VPC=$(aws ec2 describe-instances \
  --filters "Name=private-dns-name,Values=$NODE" \
  --query 'Reservations[*].Instances[*].{VpcId:VpcId}' \
  | jq -r '.[0][0].VpcId')
    ```

1. Get subnets in your VPC

    ```bash
SUBNET=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC Name=tag:kubernetes.io/role/internal-elb,Values='' \
  --query 'Subnets[*].{SubnetId:SubnetId}' \
  | jq -r '.[0].SubnetId')
    ```

1. Get the CIDR block of your worker nodes

    ```bash
CIDR=$(aws ec2 describe-vpcs \
  --filters "Name=vpc-id,Values=$VPC" \
  --query 'Vpcs[*].CidrBlock' \
  | jq -r '.[0]')
    ```

1. Get the Security Group of your worker nodes

    ```bash
SG=$(aws ec2 describe-instances --filters \
  "Name=private-dns-name,Values=$NODE" \
  --query 'Reservations[*].Instances[*].{SecurityGroups:SecurityGroups}' \
  | jq -r '.[0][0].SecurityGroups[0].GroupId')
    ```

1. Add EFS to security group

    ```bash
aws ec2 authorize-security-group-ingress \
  --group-id $SG \
  --protocol tcp \
  --port 2049 \
  --cidr $CIDR | jq .
    ```

1. Create EFS File System

    > *Note: You may want to create separate/additional access-points for each application/shared vol.*


    ```bash
EFS=$(aws efs create-file-system --creation-token efs-token-1 \
  --encrypted | jq -r '.FileSystemId')
    ```

1. Configure Mount Target for EFS

    ```bash
MOUNT_TARGET=$(aws efs create-mount-target --file-system-id $EFS \
  --subnet-id $SUBNET --security-groups $SG \
  | jq -r '.MountTargetId')
    ```
1. Create Access Point for EFS

    ```bash
ACCESS_POINT=$(aws efs create-access-point --file-system-id $EFS \
  --client-token efs-token-1 \
  | jq -r '.AccessPointId')
    ```

## Deploy and test the AWS EFS Operator

1. Install the EFS Operator

    ```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/aws-efs-operator.openshift-operators: ""
  name: aws-efs-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: aws-efs-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
  startingCSV: aws-efs-operator.v0.0.8
EOF
    ```

1. Create a namespace

    ```bash
    oc new-project efs-demo
    ```

1. Create a EFS Shared Volume

    ```bash
cat <<EOF | oc apply -f -
apiVersion: aws-efs.managed.openshift.io/v1alpha1
kind: SharedVolume
metadata:
  name: efs-volume
  namespace: efs-demo
spec:
  accessPointID: ${ACCESS_POINT}
  fileSystemID: ${EFS}
EOF
    ```

1. Create a POD to write to the EFS Volume

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

1. Create a POD to read from the EFS Volume

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
    oc delete -n efs-demo SharedVolume efs-volume
    ```

1. Delete the Namespace

    ```bash
    oc delete project efs-demo
    ```


1. Delete the EFS Shared Volume via AWS

    ```bash
aws efs delete-mount-target --mount-target-id $MOUNT_TARGET | jq .
aws efs delete-access-point --access-point-id $ACCESS_POINT | jq .
aws efs delete-file-system --file-system-id $EFS | jq .
    ```
