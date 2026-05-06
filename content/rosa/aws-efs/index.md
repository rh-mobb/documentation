---
date: '2023-04-04'
title: Enabling the AWS EFS CSI Driver Operator on ROSA
tags: ["ROSA", "ROSA Classic", "ROSA HCP"]
aliases:
- /experts/rosa/aws-efs/aws-efs-csi-operator-on-rosa/
- /experts/rosa/aws-efs/aws-efs-operator-on-rosa/
authors:
  - Paul Czarkowski
  - Andy Repton
  - Shaozhen Ding
  - Diana Sari
validated_version: "4.21"
---


Amazon Elastic File System (Amazon EFS) provides shared Network File System (NFS) storage that can be used by workloads running on Red Hat OpenShift Service on AWS (ROSA).

This guide shows how to enable the Red Hat-supported **AWS EFS CSI Driver Operator** on a ROSA cluster, create an EFS file system, dynamically provision a `ReadWriteMany` persistent volume claim (PVC), and validate shared access from multiple pods.

The flow in this guide covers:

* creating an IAM role and policy for the AWS EFS CSI Driver Operator
* installing the AWS EFS CSI Driver Operator from the OpenShift web console
* creating the `ClusterCSIDriver`
* creating an Amazon EFS file system and mount target
* creating an EFS-backed `StorageClass`
* dynamically provisioning a `ReadWriteMany` PVC
* validating shared access from two pods
* cleaning up the OpenShift, AWS EFS, security group, and IAM resources

{{% alert state="info" %}}
The official supported installation instructions for the AWS EFS CSI Driver Operator on ROSA are available in the Red Hat OpenShift Service on AWS storage documentation.
{{% /alert %}}

{{% alert state="warning" %}}
Use **AWS EFS CSI Driver Operator**, not **AWS EFS Operator**. The AWS EFS CSI Driver Operator is the Red Hat-supported Operator. The AWS EFS Operator is a community Operator and is not supported by Red Hat.
{{% /alert %}}

## Dynamic vs. static provisioning

The AWS EFS CSI driver supports both dynamic and static provisioning.

### Dynamic provisioning

Dynamic provisioning creates new persistent volumes as subdirectories of a pre-existing EFS file system. The PVs are independent Kubernetes resources, but they share the same EFS file system.

For dynamic provisioning, the EFS CSI driver creates an AWS EFS Access Point for each dynamically provisioned PV. Due to AWS EFS Access Point limits, you can dynamically provision up to 1000 PVs from a single `StorageClass` and EFS file system.

{{% alert state="warning" %}}
EFS does not enforce the requested PVC size. For example, a PVC that requests `5Gi` can store more than 5 GiB because the backing EFS file system is elastic. Monitor EFS usage and costs from AWS.
{{% /alert %}}

### Static provisioning

Static provisioning mounts an existing EFS file system or access point as a persistent volume. This guide focuses on dynamic provisioning.

## Prerequisites

You need:

* A ROSA cluster using STS
* The `rosa` CLI
* The `oc` CLI
* The AWS CLI
* `jq`
* AWS permissions to create IAM roles and policies
* AWS permissions to create EFS file systems, mount targets, and security groups

This guide was validated on:

```text
ROSA HCP
OpenShift 4.21.9
AWS region: us-west-2
Data plane: Single-AZ
```

The validation run for this update used ROSA HCP. The same EFS CSI Operator flow applies to ROSA Classic clusters that use STS, but subnet discovery, security group naming, and cluster metadata can differ.

## Set environment variables

Set the cluster name and AWS region:

```bash
export CLUSTER_NAME="<cluster-name>"
export AWS_REGION="<aws-region>"
export AWS_PAGER=""
```

Example:

```bash
export CLUSTER_NAME="ds-v0"
export AWS_REGION="us-west-2"
export AWS_PAGER=""
```

Confirm that you are logged in to the correct ROSA cluster:

```bash
rosa describe cluster -c "$CLUSTER_NAME"
oc get clusterversion
oc get nodes -o wide
```

Set the AWS account ID:

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "$AWS_ACCOUNT_ID"
```

Get the cluster OIDC endpoint:

```bash
export OIDC_ENDPOINT=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.aws.sts.oidc_endpoint_url')
echo "$OIDC_ENDPOINT"
```

Remove the `https://` prefix for IAM trust policy use:

```bash
export OIDC_PROVIDER=$(echo "$OIDC_ENDPOINT" | sed -e 's#^https://##')
echo "$OIDC_PROVIDER"
```

Expected format:

```text
oidc.op1.openshiftapps.com/<cluster-oidc-id>
```

Create a scratch directory for the generated policy files:

```bash
export SCRATCH_DIR=/tmp/rosa-efs
mkdir -p "$SCRATCH_DIR"
```

## Create the IAM policy and role

The AWS EFS CSI Driver Operator needs an IAM role that can be assumed by the Operator and controller service accounts.

Create the IAM permissions policy:

```bash
cat <<'EOF' > "$SCRATCH_DIR/efs-policy.json"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:CreateAccessPoint",
        "elasticfilesystem:DeleteAccessPoint",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    }
  ]
}
EOF
```

Create the IAM trust policy:

```bash
cat <<EOF > "$SCRATCH_DIR/efs-trust-policy.json"
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

Create the IAM role:

```bash
export EFS_ROLE_NAME="${CLUSTER_NAME}-aws-efs-csi-operator"
export EFS_POLICY_NAME="${CLUSTER_NAME}-rosa-efs-csi"

export ROLE_ARN=$(aws iam create-role \
  --role-name "$EFS_ROLE_NAME" \
  --assume-role-policy-document "file://$SCRATCH_DIR/efs-trust-policy.json" \
  --query "Role.Arn" \
  --output text)

echo "$ROLE_ARN"
```

Create and attach the IAM policy:

```bash
export POLICY_ARN=$(aws iam create-policy \
  --policy-name "$EFS_POLICY_NAME" \
  --policy-document "file://$SCRATCH_DIR/efs-policy.json" \
  --query 'Policy.Arn' \
  --output text)

echo "$POLICY_ARN"

aws iam attach-role-policy \
  --role-name "$EFS_ROLE_NAME" \
  --policy-arn "$POLICY_ARN"
```

Keep the role ARN available. The OpenShift web console prompts for this value when installing the Operator on STS clusters:

```bash
echo "$ROLE_ARN"
```

## Install the AWS EFS CSI Driver Operator

This guide uses the OpenShift web console installation path because it aligns with the supported ROSA documentation and avoids stale CLI installation YAML.

1. Log in to the OpenShift web console.

2. Go to **Ecosystem** > **Software Catalog** (this is formerly known as **OperatorHub**)

3. Search for **AWS EFS CSI**.

4. Select **AWS EFS CSI Driver Operator**.

   {{% alert state="warning" %}}
   Select **AWS EFS CSI Driver Operator**, not **AWS EFS Operator**.
   {{% /alert %}}

5. Click **Install**.

6. In the **role ARN** field at the top of the install page, paste the value of `ROLE_ARN`.

   Example:

   ```text
   arn:aws:iam::<aws-account-id>:role/<cluster-name>-aws-efs-csi-operator
   ```

7. Review or set the following installation options:

   * **Update channel**: `stable`
   * **Version**: the version that matches your OpenShift minor version
   * **Installation mode**: `All namespaces on the cluster`
   * **Installed namespace**: `openshift-cluster-csi-drivers`
   * **Update approval**: `Manual` or `Automatic`

   {{% alert state="info" %}}
   Manual approval is safer for STS clusters because future Operator versions might require updated IAM permissions before upgrade.
   {{% /alert %}}

8. Click **Install**.

Validate that the Operator installed successfully:

```bash
oc get subscription,csv,pods -n openshift-cluster-csi-drivers | grep -i efs
```

Expected output includes a succeeded CSV and a running Operator pod:

```text
subscription.operators.coreos.com/aws-efs-csi-driver-operator   aws-efs-csi-driver-operator   redhat-operators   stable
clusterserviceversion.operators.coreos.com/aws-efs-csi-driver-operator.v4.21.x   AWS EFS CSI Driver Operator   4.21.x   Succeeded
pod/aws-efs-csi-driver-operator-xxxxx   1/1   Running
```

The console installation creates the `aws-efs-cloud-credentials` secret in the `openshift-cluster-csi-drivers` namespace:

```bash
oc get secret -n openshift-cluster-csi-drivers | grep -i efs || true
```

## Create the ClusterCSIDriver

Create the `ClusterCSIDriver` resource:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: efs.csi.aws.com
spec:
  managementState: Managed
EOF
```

Verify that the EFS CSI driver controller and node pods are running:

```bash
oc get pods -n openshift-cluster-csi-drivers | grep -i efs
```

Expected output:

```text
aws-efs-csi-driver-controller-xxxxx   4/4   Running
aws-efs-csi-driver-node-xxxxx         3/3   Running
aws-efs-csi-driver-node-xxxxx         3/3   Running
aws-efs-csi-driver-operator-xxxxx     1/1   Running
```

Check the `ClusterCSIDriver` conditions:

```bash
oc get clustercsidriver efs.csi.aws.com -o json | jq -r '
  .status.conditions[]
  | select(.type == "AWSEFSDriverNodeServiceControllerAvailable" or .type == "AWSEFSDriverControllerServiceControllerAvailable")
  | [.type, .status, .reason, .message]
  | @tsv'
```

The driver is ready when the controller and node services are available:

```text
AWSEFSDriverNodeServiceControllerAvailable       True
AWSEFSDriverControllerServiceControllerAvailable True
```

## Create an EFS file system

Create an encrypted EFS file system:

```bash
export EFS_CREATION_TOKEN="${CLUSTER_NAME}-efs-$(date +%s)"

export EFS_ID=$(aws efs create-file-system \
  --region "$AWS_REGION" \
  --creation-token "$EFS_CREATION_TOKEN" \
  --encrypted \
  --tags Key=Name,Value="${CLUSTER_NAME}-efs-test" Key=Cluster,Value="$CLUSTER_NAME" \
  --query 'FileSystemId' \
  --output text)

echo "$EFS_ID"
```


Verify that the EFS file system is available:

```bash
aws efs describe-file-systems \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'FileSystems[*].{FileSystemId:FileSystemId,CreationToken:CreationToken,LifeCycleState:LifeCycleState,Name:Name}' \
  --output table
```

Expected output:

```text
--------------------------------------------------------------
|                     DescribeFileSystems                    |
+-------------------------+----------------------+------------------+--------------------+
|      CreationToken      |     FileSystemId     | LifeCycleState   |        Name        |
+-------------------------+----------------------+------------------+--------------------+
| <cluster>-efs-<timestamp>| fs-xxxxxxxxxxxxxxxxx | available        | <cluster>-efs-test |
+-------------------------+----------------------+------------------+--------------------+
```

{{% alert state="info" %}}
Some AWS CLI versions might not support `aws efs wait file-system-available`. This guide uses `describe-file-systems` to verify the EFS file system state.
{{% /alert %}}

## Find worker subnet, VPC, and security group

The EFS mount target must be reachable by the ROSA worker nodes over NFS port `2049`.

Get a worker node private IP:

```bash
oc get nodes -o wide
```

Set one worker private IP:

```bash
export WORKER_PRIVATE_IP="<worker-private-ip>"
```

Example:

```bash
export WORKER_PRIVATE_IP="10.10.11.49"
```

Find the EC2 instance ID for that worker:

```bash
export WORKER_INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --filters "Name=private-ip-address,Values=${WORKER_PRIVATE_IP}" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

echo "$WORKER_INSTANCE_ID"
```

Get the worker subnet, worker security group, and VPC:

```bash
export WORKER_SUBNET_ID=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$WORKER_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SubnetId' \
  --output text)

export WORKER_SG_ID=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$WORKER_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
  --output text)

export WORKER_VPC_ID=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$WORKER_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].VpcId' \
  --output text)

export WORKER_INSTANCE_PROFILE_ARN=$(aws ec2 describe-instances \
  --region "$AWS_REGION" \
  --instance-ids "$WORKER_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text)

export WORKER_INSTANCE_PROFILE_NAME="${WORKER_INSTANCE_PROFILE_ARN##*/}"

export WORKER_ROLE_NAME=$(aws iam get-instance-profile \
  --instance-profile-name "$WORKER_INSTANCE_PROFILE_NAME" \
  --query 'InstanceProfile.Roles[0].RoleName' \
  --output text)

echo "Worker subnet: $WORKER_SUBNET_ID"
echo "Worker SG:     $WORKER_SG_ID"
echo "Worker VPC:    $WORKER_VPC_ID"
echo "Worker role:   $WORKER_ROLE_NAME"
```

## Attach EFS permissions to the worker role

The worker nodes need EFS permissions to resolve and mount the EFS file system. Attach the AWS managed EFS CSI driver policy to the worker role:

```bash
export EFS_CSI_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"

aws iam attach-role-policy \
  --role-name "$WORKER_ROLE_NAME" \
  --policy-arn "$EFS_CSI_POLICY_ARN"

aws iam list-attached-role-policies \
  --role-name "$WORKER_ROLE_NAME" \
  --query "AttachedPolicies[?PolicyArn=='${EFS_CSI_POLICY_ARN}'].{PolicyName:PolicyName,PolicyArn:PolicyArn}" \
  --output table
```

## Create an EFS security group

Create a security group for the EFS mount target:

```bash
export EFS_SG_ID=$(aws ec2 create-security-group \
  --region "$AWS_REGION" \
  --group-name "${CLUSTER_NAME}-efs-sg" \
  --description "Allow ROSA workers to access EFS over NFS" \
  --vpc-id "$WORKER_VPC_ID" \
  --query 'GroupId' \
  --output text)

echo "$EFS_SG_ID"
```

Allow NFS traffic from the worker security group to the EFS security group:

```bash
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$EFS_SG_ID" \
  --protocol tcp \
  --port 2049 \
  --source-group "$WORKER_SG_ID"
```

## Create an EFS mount target

For a Single-AZ data plane, create one mount target in the worker subnet:

```bash
aws efs create-mount-target \
  --region "$AWS_REGION" \
  --file-system-id "$EFS_ID" \
  --subnet-id "$WORKER_SUBNET_ID" \
  --security-groups "$EFS_SG_ID"
```

Verify that the mount target becomes available:

```bash
aws efs describe-mount-targets \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'MountTargets[*].{MountTargetId:MountTargetId,SubnetId:SubnetId,State:LifeCycleState,IpAddress:IpAddress}' \
  --output table
```

Expected output:

```text
------------------------------------------------------------------------------------
|                               DescribeMountTargets                               |
+-------------+--------------------------+------------+----------------------------+
|  IpAddress  |      MountTargetId       |   State    |         SubnetId           |
+-------------+--------------------------+------------+----------------------------+
|  10.x.x.x   |  fsmt-xxxxxxxxxxxxxxxxx  |  available |  subnet-xxxxxxxxxxxxxxxxx  |
+-------------+--------------------------+------------+----------------------------+
```

{{% alert state="info" %}}
For a Multi-AZ data plane, create one EFS mount target in each Availability Zone where worker nodes run. Each Availability Zone can have only one mount target for a given EFS file system.
{{% /alert %}}

## Create the EFS StorageClass

Create a `StorageClass` that uses dynamic provisioning through EFS Access Points:

```bash
cat <<EOF | oc apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${EFS_ID}
  directoryPerms: "700"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/dynamic_provisioning"
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
```

Verify the `StorageClass`:

```bash
oc get sc efs-sc
```

Expected output:

```text
NAME     PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION
efs-sc   efs.csi.aws.com   Delete          Immediate           false
```

## Create a test project and PVC

Create a test project:

```bash
oc new-project efs-demo
```

Create a `ReadWriteMany` PVC:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-efs-volume
  namespace: efs-demo
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 5Gi
EOF
```

Verify that the PVC is bound:

```bash
oc get pvc -n efs-demo
oc get pv | grep efs || true
```

Expected output:

```text
NAME             STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
pvc-efs-volume   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   5Gi        RWX            efs-sc
```

Verify that the EFS CSI driver created an access point:

```bash
aws efs describe-access-points \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'AccessPoints[*].{AccessPointId:AccessPointId,State:LifeCycleState,RootDirectory:RootDirectory.Path}' \
  --output table
```

Expected output:

```text
-----------------------------------------------------------------------------------------------------------
|                                          DescribeAccessPoints                                           |
+------------------------+------------------------------------------------------------------+-------------+
|      AccessPointId     |                          RootDirectory                           |    State    |
+------------------------+------------------------------------------------------------------+-------------+
|  fsap-xxxxxxxxxxxxxxxxx|  /dynamic_provisioning/pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  |  available  |
+------------------------+------------------------------------------------------------------+-------------+
```

## Validate shared access from two pods

Create the first pod. This pod writes a file to the EFS-backed PVC.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-efs
  namespace: efs-demo
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test-efs
      image: registry.access.redhat.com/ubi9/ubi
      command: ["/bin/sh", "-c"]
      args:
        - |
          echo "hello from ROSA EFS test" > /mnt/efs/hello.txt
          sleep 3600
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: efs-storage
          mountPath: /mnt/efs
  volumes:
    - name: efs-storage
      persistentVolumeClaim:
        claimName: pvc-efs-volume
EOF
```

Verify that the pod is running and can read the file:

```bash
oc wait --for=condition=Ready pod/test-efs -n efs-demo --timeout=180s
oc get pod -n efs-demo test-efs
oc exec -n efs-demo test-efs -- cat /mnt/efs/hello.txt
```

Expected output:

```text
hello from ROSA EFS test
```

Create a second pod that mounts the same PVC, reads the file, and appends another line:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-efs-read
  namespace: efs-demo
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: test-efs-read
      image: registry.access.redhat.com/ubi9/ubi
      command: ["/bin/sh", "-c"]
      args:
        - |
          cat /mnt/efs/hello.txt
          echo "hello from second pod" >> /mnt/efs/hello.txt
          sleep 3600
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities:
          drop:
            - ALL
      volumeMounts:
        - name: efs-storage
          mountPath: /mnt/efs
  volumes:
    - name: efs-storage
      persistentVolumeClaim:
        claimName: pvc-efs-volume
EOF
```

Verify the second pod logs:

```bash
oc wait --for=condition=Ready pod/test-efs-read -n efs-demo --timeout=180s
oc logs -n efs-demo test-efs-read
```

Expected output:

```text
hello from ROSA EFS test
```

Verify that the first pod can see the second pod's write:

```bash
oc exec -n efs-demo test-efs -- cat /mnt/efs/hello.txt
```

Expected output:

```text
hello from ROSA EFS test
hello from second pod
```

## Final validation

Capture the final OpenShift state:

```bash
oc get pods,pvc -n efs-demo
oc get pv | grep efs
oc get sc efs-sc
oc get clustercsidriver efs.csi.aws.com
oc get pods -n openshift-cluster-csi-drivers | grep -i efs
```

Capture the final AWS EFS state:

```bash
aws efs describe-file-systems \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'FileSystems[*].{FileSystemId:FileSystemId,Name:Name,LifeCycleState:LifeCycleState}' \
  --output table

aws efs describe-mount-targets \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'MountTargets[*].{MountTargetId:MountTargetId,SubnetId:SubnetId,State:LifeCycleState,IpAddress:IpAddress}' \
  --output table

aws efs describe-access-points \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'AccessPoints[*].{AccessPointId:AccessPointId,State:LifeCycleState,RootDirectory:RootDirectory.Path}' \
  --output table
```

A successful validation shows:

```text
AWS EFS CSI Driver Operator: Running
AWS EFS CSI controller:     Running
AWS EFS CSI node pods:      Running
StorageClass:               efs-sc using efs.csi.aws.com
PVC:                        Bound with RWX
PV:                         Dynamically provisioned
EFS Access Point:            Created and available
Two pods:                    Mounted the same PVC successfully
```

## Clean up

This section removes the sample application, dynamically provisioned EFS resources, the EFS file system, the security group, the EFS CSI Driver Operator, and the IAM role and policy used for STS.

{{% alert state="warning" %}}
Before deleting the EFS file system, confirm that the file system ID belongs to this test. Do not delete a shared or pre-existing EFS file system.
{{% /alert %}}

### Remove the sample workload

Delete the test pods, PVC, project, and `StorageClass`:

```bash
export EFS_PV_NAME=$(oc get pv -o json | jq -r '.items[] | select(.spec.storageClassName == "efs-sc") | .metadata.name' | head -n 1)
echo "$EFS_PV_NAME"

oc delete pod -n efs-demo test-efs test-efs-read --ignore-not-found
oc delete pvc -n efs-demo pvc-efs-volume --ignore-not-found
oc delete project efs-demo --ignore-not-found
oc delete storageclass efs-sc --ignore-not-found
```

Confirm that no EFS PV remains. If the PV remains in `Released` state, remove the finalizer so Kubernetes can finish deleting the dynamically provisioned resource:

```bash
if [ -n "$EFS_PV_NAME" ] && oc get pv "$EFS_PV_NAME" >/dev/null 2>&1; then
  oc patch pv "$EFS_PV_NAME" \
    -p '{"metadata":{"finalizers":null}}' \
    --type=merge
fi

if [ -n "$EFS_PV_NAME" ]; then
  oc get pv "$EFS_PV_NAME" 2>/dev/null || true
fi
```

Confirm that the dynamically created EFS Access Point was removed. If an access point remains, delete it before deleting the file system:

```bash
for AP in $(aws efs describe-access-points \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'AccessPoints[*].AccessPointId' \
  --output text); do
  echo "Deleting access point: $AP"
  aws efs delete-access-point \
    --access-point-id "$AP" \
    --region "$AWS_REGION"
done

aws efs describe-access-points \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'AccessPoints[*].{AccessPointId:AccessPointId,State:LifeCycleState,RootDirectory:RootDirectory.Path}' \
  --output table
```

### Remove the EFS mount target and file system

List the mount targets:

```bash
aws efs describe-mount-targets \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'MountTargets[*].{MountTargetId:MountTargetId,SubnetId:SubnetId,State:LifeCycleState,IpAddress:IpAddress}' \
  --output table
```

Delete the mount targets:

```bash
for MT in $(aws efs describe-mount-targets \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'MountTargets[*].MountTargetId' \
  --output text); do
  echo "Deleting mount target: $MT"
  aws efs delete-mount-target \
    --mount-target-id "$MT" \
    --region "$AWS_REGION"
done
```

Wait until no mount targets are returned:

```bash
aws efs describe-mount-targets \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'MountTargets[*].{MountTargetId:MountTargetId,State:LifeCycleState}' \
  --output table
```

Delete the EFS file system:

```bash
aws efs delete-file-system \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION"
```

Verify that the file system is gone:

```bash
aws efs describe-file-systems \
  --file-system-id "$EFS_ID" \
  --region "$AWS_REGION" \
  --query 'FileSystems[*].{FileSystemId:FileSystemId,CreationToken:CreationToken,LifeCycleState:LifeCycleState,Name:Name}' \
  --output table 2>/dev/null || true
```

### Remove the EFS security group

Delete the EFS security group:

```bash
aws ec2 delete-security-group \
  --region "$AWS_REGION" \
  --group-id "$EFS_SG_ID"
```

If the command fails because the security group has a dependency, wait a few minutes after deleting the EFS mount target and try again.

Verify that the security group is gone:

```bash
aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --group-ids "$EFS_SG_ID" 2>/dev/null || true
```

### Remove the EFS CSI driver and Operator

Delete the `ClusterCSIDriver`:

```bash
oc delete clustercsidriver efs.csi.aws.com --ignore-not-found
```

Uninstall the **AWS EFS CSI Driver Operator** from the OpenShift web console:

1. Go to **Ecosystem** > **Installed Operators**.
2. Select the `openshift-cluster-csi-drivers` project.
3. Select **AWS EFS CSI Driver Operator**.
4. Click **Actions** > **Uninstall Operator**.

Alternatively, remove the Subscription and CSV by CLI:

```bash
oc delete subscription aws-efs-csi-driver-operator \
  -n openshift-cluster-csi-drivers \
  --ignore-not-found

EFS_CSV=$(oc get csv -n openshift-cluster-csi-drivers \
  -o name | grep aws-efs-csi-driver-operator || true)

if [ -n "$EFS_CSV" ]; then
  oc delete "$EFS_CSV" -n openshift-cluster-csi-drivers
fi
```

The Operator uninstall might not remove the credentials secret. Delete it explicitly if it remains:

```bash
oc delete secret aws-efs-cloud-credentials \
  -n openshift-cluster-csi-drivers \
  --ignore-not-found
```

### Remove the IAM roles and policies

If you attached the AWS managed EFS CSI driver policy to the worker role only for this guide, detach it after removing the test workload:

```bash
aws iam detach-role-policy \
  --role-name "$WORKER_ROLE_NAME" \
  --policy-arn "$EFS_CSI_POLICY_ARN" 2>/dev/null || true
```

Detach the IAM policy from the EFS CSI Operator role, then delete the role and policy:

```bash
export EFS_ROLE_NAME="${CLUSTER_NAME}-aws-efs-csi-operator"
export EFS_POLICY_NAME="${CLUSTER_NAME}-rosa-efs-csi"

for POLICY_ARN in $(aws iam list-attached-role-policies \
  --role-name "$EFS_ROLE_NAME" \
  --query 'AttachedPolicies[*].PolicyArn' \
  --output text 2>/dev/null); do
  echo "Detaching $POLICY_ARN"
  aws iam detach-role-policy \
    --role-name "$EFS_ROLE_NAME" \
    --policy-arn "$POLICY_ARN"
done

aws iam delete-role --role-name "$EFS_ROLE_NAME" 2>/dev/null || true

EFS_POLICY_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='${EFS_POLICY_NAME}'].Arn" \
  --output text)

if [ -n "$EFS_POLICY_ARN" ] && [ "$EFS_POLICY_ARN" != "None" ]; then
  aws iam delete-policy --policy-arn "$EFS_POLICY_ARN"
fi
```

### Remove local temporary files

Remove the IAM policy documents in the scratch directory:

```bash
rm -rf "$SCRATCH_DIR"
```

### Final cleanup validation

Run the following commands to confirm that no test resources remain:

```bash
oc get project efs-demo 2>/dev/null || true
oc get sc | grep -i efs || true
oc get pv | grep -i efs || true
oc get clustercsidriver efs.csi.aws.com 2>/dev/null || true
oc get subscription,csv,pods -n openshift-cluster-csi-drivers | grep -i efs || true
oc get secret -n openshift-cluster-csi-drivers aws-efs-cloud-credentials 2>/dev/null || true

aws efs describe-file-systems --file-system-id "$EFS_ID" --region "$AWS_REGION" --output table 2>/dev/null || true
aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$EFS_SG_ID" 2>/dev/null || true
aws iam get-role --role-name "${CLUSTER_NAME}-aws-efs-csi-operator" 2>/dev/null || true
```

Expected result:

* no `efs-demo` project
* no `efs-sc` StorageClass
* no EFS PV
* no `efs.csi.aws.com` `ClusterCSIDriver`
* no EFS Operator pods, Subscription, or CSV
* no `aws-efs-cloud-credentials` secret
* no test EFS file system
* no test EFS security group
* no test IAM role or policy
