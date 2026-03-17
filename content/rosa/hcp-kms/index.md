---
title: "Creating a ROSA HCP cluster with custom KMS key"
date: 2026-03-16
tags: ["AWS", "ROSA", "HCP", "KMS", "Encryption"]
authors:
  - Nerav Doshi
---

This guide walks you through deploying a Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Planes (HCP) using a customer-managed AWS KMS key. The KMS key can be used to encrypt:

- Worker node root volumes
- etcd database (control plane encryption)
- PersistentVolumes (via custom StorageClass)

> **Tip:** For official documentation, see [Creating ROSA HCP clusters using a custom AWS KMS encryption key](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_clusters/rosa-hcp-creating-cluster-with-aws-kms-key).

> **Note:** This guide is specifically for **ROSA with Hosted Control Planes (HCP)**.

### Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) installed and configured
- [ROSA CLI](https://console.redhat.com/openshift/downloads) v1.2.0 or higher
- [OpenShift CLI](https://console.redhat.com/openshift/downloads) (`oc`)
- AWS account with ROSA enabled
- Red Hat account linked to AWS via the ROSA console

#### Verify Prerequisites

##### Verify ROSA CLI version (must be 1.2.0+)
```bash
rosa version
```

##### Verify AWS CLI is configured
```bash
aws sts get-caller-identity
```

##### Verify ROSA login
```bash
rosa whoami
```

##### Verify ROSA is enabled in your AWS account
```bash
rosa verify quota
rosa verify permissions
```
#### Set Environment Variables

Set the following environment variables to use throughout this guide:

```bash
# AWS Configuration
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Cluster Configuration
export CLUSTER_NAME=my-rosa-hcp
export MACHINE_CIDR=10.0.0.0/16

# Role Prefixes
export ACCOUNT_ROLES_PREFIX=ManagedOpenShift
export OPERATOR_ROLES_PREFIX=${CLUSTER_NAME}

# Verify
echo "AWS Account: ${AWS_ACCOUNT_ID}"
echo "Region: ${AWS_REGION}"
echo "Cluster Name: ${CLUSTER_NAME}"
```

### Step 1: Create a VPC

You need a VPC with at least one private subnet (and optionally public subnets for public clusters).

#### Option A: Using ROSA CLI (Recommended)

```bash
rosa create network --param Region=${AWS_REGION} \
  --param Name=${CLUSTER_NAME}-vpc \
  --param AvailabilityZoneCount=3 \
  --param VpcCidr=${MACHINE_CIDR}
```

After completion, capture the subnet IDs:

```bash
export PRIVATE_SUBNET_IDS=<comma-separated-private-subnet-ids>
export PUBLIC_SUBNET_IDS=<comma-separated-public-subnet-ids>
```

#### Option B: Using Terraform

```bash
git clone https://github.com/openshift-cs/terraform-vpc-example
cd terraform-vpc-example
terraform init
terraform plan -out rosa.tfplan -var region=${AWS_REGION}
terraform apply rosa.tfplan

export SUBNET_IDS=$(terraform output -raw cluster-subnets-string)
```

#### Tag Your Subnets

Ensure subnets are properly tagged:

```bash
# Public subnets
aws ec2 create-tags --resources <public-subnet-id> \
  --region ${AWS_REGION} \
  --tags Key=kubernetes.io/role/elb,Value=1

# Private subnets
aws ec2 create-tags --resources <private-subnet-id> \
  --region ${AWS_REGION} \
  --tags Key=kubernetes.io/role/internal-elb,Value=1
```

### Step 2: Create Account-Wide Roles

Create the account-wide IAM roles required for ROSA HCP:

```bash
rosa create account-roles --hosted-cp \
  --prefix ${ACCOUNT_ROLES_PREFIX} \
  --mode auto \
  --yes
```

### Step 3: Create OIDC Configuration

Create the OpenID Connect configuration:

```bash
rosa create oidc-config --mode auto --yes

# Save the OIDC config ID
export OIDC_ID=$(rosa list oidc-config -o json | jq -r '.[0].id')
echo "OIDC Config ID: ${OIDC_ID}"
```

### Step 4: Create Operator Roles

Create the operator IAM roles for ROSA HCP:

```bash
rosa create operator-roles --hosted-cp \
  --prefix ${OPERATOR_ROLES_PREFIX} \
  --oidc-config-id ${OIDC_ID} \
  --installer-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role \
  --mode auto \
  --yes
```

#### Verify Operator Roles

List the created operator roles to note their exact names (important for KMS policy):

```bash
rosa list operator-roles --prefix ${OPERATOR_ROLES_PREFIX}
```

You should see roles including:
- `<prefix>-openshift-cluster-csi-drivers-ebs-cloud-credentials`
- `<prefix>-kube-system-kube-controller-manager`
- `<prefix>-kube-system-kms-provider`
- `<prefix>-kube-system-capa-controller-manager`

> **Tip:** Role names may be truncated if the prefix is long. Use the above command to get exact names.

### Step 5: Create KMS Key

Create a customer-managed KMS key:

```bash
KMS_ARN=$(aws kms create-key \
  --region ${AWS_REGION} \
  --description "ROSA HCP Encryption Key for ${CLUSTER_NAME}" \
  --tags TagKey=red-hat,TagValue=true \
  --query KeyMetadata.Arn \
  --output text)

echo "KMS Key ARN: ${KMS_ARN}"
```

> **Important:** The tag `red-hat=true` is required for ROSA to use the KMS key.

#### Create KMS Alias (Optional)

```bash
aws kms create-alias \
  --alias-name alias/${CLUSTER_NAME}-key \
  --target-key-id ${KMS_ARN} \
  --region ${AWS_REGION}
```

### Step 6: Configure KMS Key Policy

Create a comprehensive KMS key policy that includes all required ROSA HCP roles:

```bash
cat <<EOF > rosa-hcp-kms-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnableIAMUserPermissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::\${AWS_ACCOUNT_ID}:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowROSAInstallerRole",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::\${AWS_ACCOUNT_ID}:role/\${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role"
      },
      "Action": [
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey",
        "kms:CreateGrant"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowROSASupportRole",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::\${AWS_ACCOUNT_ID}:role/\${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Support-Role"
      },
      "Action": "kms:DescribeKey",
      "Resource": "*"
    },
    {
      "Sid": "AllowKubeControllerManager",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::\${AWS_ACCOUNT_ID}:role/\${OPERATOR_ROLES_PREFIX}-kube-system-kube-controller-manager"
      },
      "Action": "kms:DescribeKey",
      "Resource": "*"
    },
    {
      "Sid": "AllowKMSProviderForEtcd",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::\${AWS_ACCOUNT_ID}:role/\${OPERATOR_ROLES_PREFIX}-kube-system-kms-provider"
      },
      "Action": [
        "kms:Encrypt",
        "kms:DescribeKey",
        "kms:Decrypt"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowCAPAControllerForNodes",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::\${AWS_ACCOUNT_ID}:role/\${OPERATOR_ROLES_PREFIX}-kube-system-capa-controller-manager"
      },
      "Action": [
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey",
        "kms:CreateGrant"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowEBSCSIDriverKMSOperations",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::\${AWS_ACCOUNT_ID}:role/\${OPERATOR_ROLES_PREFIX}-openshift-cluster-csi-drivers-ebs-cloud-credentials"
      },
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowEBSCSIDriverCreateGrant",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::\${AWS_ACCOUNT_ID}:role/\${OPERATOR_ROLES_PREFIX}-openshift-cluster-csi-drivers-ebs-cloud-credentials"
      },
      "Action": "kms:CreateGrant",
      "Resource": "*",
      "Condition": {
        "Bool": {
          "kms:GrantIsForAWSResource": "true"
        }
      }
    }
  ]
}
EOF
```

Apply the key policy:

```bash
aws kms put-key-policy \
  --key-id ${KMS_ARN} \
  --policy-name default \
  --policy file://rosa-hcp-kms-policy.json \
  --region ${AWS_REGION}
```

#### Verify Key Policy

```bash
aws kms get-key-policy \
  --key-id ${KMS_ARN} \
  --policy-name default \
  --region ${AWS_REGION} \
  --output text | jq .
```

### Step 7: Create the ROSA HCP Cluster

Create the cluster with KMS encryption enabled:

```bash
rosa create cluster \
  --cluster-name ${CLUSTER_NAME} \
  --sts \
  --hosted-cp \
  --region ${AWS_REGION} \
  --subnet-ids ${PRIVATE_SUBNET_IDS} \
  --machine-cidr ${MACHINE_CIDR} \
  --compute-machine-type m5.xlarge \
  --replicas 2 \
  --oidc-config-id ${OIDC_ID} \
  --operator-roles-prefix ${OPERATOR_ROLES_PREFIX} \
  --kms-key-arn ${KMS_ARN} \
  --etcd-encryption-kms-arn ${KMS_ARN} \
  --mode auto \
  --yes
```

**Parameters explained:**
- `--kms-key-arn`: Encrypts worker node root volumes
- `--etcd-encryption-kms-arn`: Encrypts the etcd database (optional, can use same or different key)

> **Note:** If your cluster name is longer than 15 characters, use `--domain-prefix` to customize the subdomain.

#### Monitor Cluster Installation

```bash
# Watch cluster status
rosa describe cluster --cluster ${CLUSTER_NAME}

# Watch installation logs
rosa logs install --cluster ${CLUSTER_NAME} --watch
```

Installation typically takes 10-15 minutes for ROSA HCP.

### Step 8: Configure Encrypted StorageClass for PersistentVolumes

> **Important:** ROSA does **not** automatically configure the default StorageClass to encrypt PersistentVolumes with your KMS key. You must create a custom StorageClass.

#### Create Encrypted StorageClass

```bash
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-csi-kms
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
  kmsKeyId: ${KMS_ARN}
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
```

#### Remove Default from Existing StorageClass

```bash
oc patch storageclass gp3-csi \
  -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
```

#### Verify StorageClasses

```bash
oc get storageclass
```

Expected output:
```
NAME                    PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
gp3-csi                 ebs.csi.aws.com         Delete          WaitForFirstConsumer   true                   10m
gp3-csi-kms (default)   ebs.csi.aws.com         Delete          WaitForFirstConsumer   true                   1m
```

### Step 9: Validate the Cluster

#### Create Admin User

```bash
rosa create admin --cluster ${CLUSTER_NAME}
```

Save the credentials and login:

```bash
oc login https://api.${CLUSTER_NAME}.<domain>:6443 \
  --username cluster-admin \
  --password <password>
```

#### Verify Node Root Volume Encryption

```bash
# Get worker node instance IDs
INSTANCE_IDS=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].spec.providerID}' | tr ' ' '\n' | cut -d'/' -f5)

# Check volume encryption for each instance
for INSTANCE_ID in ${INSTANCE_IDS}; do
  echo "Instance: ${INSTANCE_ID}"
  aws ec2 describe-volumes \
    --filters "Name=attachment.instance-id,Values=${INSTANCE_ID}" \
    --query "Volumes[*].{VolumeId:VolumeId,Encrypted:Encrypted,KmsKeyId:KmsKeyId}" \
    --region ${AWS_REGION} \
    --output table
done
```

#### Test PersistentVolume Encryption

```bash
# Create a test PVC
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-kms-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: gp3-csi-kms
EOF

# Create a pod to bind the PVC
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-kms-pod
  namespace: default
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-kms-pvc
EOF

# Wait for PVC to bind
oc get pvc test-kms-pvc -w

# Verify the volume is encrypted with your KMS key
PV_NAME=$(oc get pvc test-kms-pvc -o jsonpath='{.spec.volumeName}')
VOLUME_ID=$(oc get pv ${PV_NAME} -o jsonpath='{.spec.csi.volumeHandle}')

aws ec2 describe-volumes \
  --volume-ids ${VOLUME_ID} \
  --query "Volumes[0].{Encrypted:Encrypted,KmsKeyId:KmsKeyId}" \
  --region ${AWS_REGION}
```

Expected output should show `Encrypted: true` and your KMS key ARN.

#### Cleanup Test Resources

```bash
oc delete pod test-kms-pod
oc delete pvc test-kms-pvc
```

### Troubleshooting

#### PVC Stuck in Pending

If PVCs are stuck in `Pending` state:

```bash
# Check PVC events
oc describe pvc <pvc-name>

# Check CSI driver logs
oc logs -n openshift-cluster-csi-drivers \
  -l app=aws-ebs-csi-driver-controller \
  -c csi-provisioner --tail=50
```

### Cleanup

#### Delete Cluster

```bash
rosa delete cluster --cluster ${CLUSTER_NAME} --yes --watch
```

#### Delete Operator Roles

```bash
rosa delete operator-roles --prefix ${OPERATOR_ROLES_PREFIX} --mode auto --yes
```

#### Delete OIDC Provider

```bash
rosa delete oidc-provider --oidc-config-id ${OIDC_ID} --mode auto --yes
```

#### Delete OIDC Config

```bash
rosa delete oidc-config --oidc-config-id ${OIDC_ID} --mode auto --yes
```

#### Delete Account Roles (Optional)

Only delete if not shared with other clusters:

```bash
rosa delete account-roles --prefix ${ACCOUNT_ROLES_PREFIX} --hosted-cp --mode auto --yes
```

#### Delete KMS Key (Optional)

```bash
# Schedule key deletion (minimum 7 days)
aws kms schedule-key-deletion \
  --key-id ${KMS_ARN} \
  --pending-window-in-days 7 \
  --region ${AWS_REGION}
```

#### Delete VPC

If created with ROSA CLI:
```bash
rosa delete network --name ${CLUSTER_NAME}-vpc
```

If created with Terraform:
```bash
cd terraform-vpc-example
terraform destroy
```

### Additional Resources

- [Official ROSA HCP KMS Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_clusters/rosa-hcp-creating-cluster-with-aws-kms-key)
- [AWS KMS Documentation](https://docs.aws.amazon.com/kms/latest/developerguide/overview.html)
- [ROSA CLI Reference](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/rosa_cli/rosa-get-started-cli)
- [KBA 6992348: PV provisioning failed for AWS storageclass lacking KMS privileges](https://access.redhat.com/solutions/6992348)


**Key takeaways:**
- The KMS key policy must include **all** ROSA operator roles that need encryption access
- The EBS CSI driver role is often overlooked but required for PV encryption
- ROSA does **not** auto-configure the default StorageClass for KMS encryption
- Always verify role names as they may be truncated based on prefix length
