OpenShift API for Data Protection (OADP) is a feature of Red Hat OpenShift that provides a set of APIs and tools for managing data protection and disaster recovery operations in OpenShift clusters. It enables users to create and manage backup and restore operations for their applications and data running on OpenShift.

### Prerequistes 
    - A ROSA cluster
    - AWS 

## Deploy OADP 


```bash
export CLUSTER_NAME=my-cluster 
export ROSA_CLUSTER_ID=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .id)
export REGION=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .region.id)
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')
export AWS_ACCOUNT_ID='aws sts get-caller-identity --query Account --output text'
export CLUSTER_VERSION='rosa describe cluster -c ${CLUSTER_NAME} -o json | jq -r .version.raw_id | but -f -2 -d '.' '
export ROLE_NAME="${CLUSTER_NAME}-openshift-oadp-aws-cloud-credentials"
export SCRATCH="/tmp/${CLUSTER_NAME}/oadp"
mkdir -p ${SCRATCH}
echo "Cluster ID: ${ROSA_CLUSTER_ID}, Region: ${REGION}, OIDC Endpoint:
${OIDC_ENDPOINT}, AWS Account ID: ${AWS_ACCOUNT_ID}"
```

create an IAM policy to allow access to S3.

```bash
export POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='RosaOadpVer1'].{ARN:Arn}" --output text) 

if [[ -z "${POLICY_ARN}" ]]; then
cat << EOF > ${SCRATCH}/policy.json 
{
"Version": "2012-10-17",
"Statement": [
  {
    "Effect": "Allow",
    "Action": [
      "s3:CreateBucket",echo ${POLICY_ARN}
      "s3:DeleteBucket",cd openshift-docs
      "s3:PutBucketTegging",
      "s3:GetBucketTegging",
      "s3:PutEncryptionConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteOgject",
      "s3:ListBucketMultipartUpLoads",
      "s3:AbortMultipartUpLoads",
      "s3:ListMultipartUpLoadParts",
      "s3:DescribeSnapshots",
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumeAttribute",
      "ec2:DescribeVolumesModifications",
      "ec2:DescribeVolumeStatus",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:CreateSnapshot",
      "ec2:DeleteSnapshot",
    ]
    "Resource": "*"
  }
 ]}
EOF
export POLICY_ARN=$(aws iam create-policy --policy-mane "RosaOadpVer1" \
--policy-document file:///${SCRATCH}/policy.json --query Policy.Arn \
--tags Key=rosa_openshift_version,Value=${CLUSTER_VERSION} Key-rosa_role_prefix,Value=ManagedOpenShift Key=operator_namespace,Value=openshift-oadp Key=operator_name,Value=openshift-oadp \
--output text)
fi

echo "policy ARN:  ${POLICY_ARN}"
```

create IAM role and trust policy for the cluster

```bash
echo "create trust policy"

cat <<EOF > ${SCRATCH}/trust-policy.json
{
    "Version": :2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ENDPOINT}:sub": [
            "system:serviceaccount:openshift-adp:openshift-adp-controller-manager",
            "system:serviceaccount:openshift-adp:velero:]
        }
      }
    }]
}
EOF

echo "create role"
exportn ROLE_ARN=$(aws iam create-role --role-name "${ROLE_NAME}" --assume-role-policy-document file://${SCRATCH}/trust-policy.json --tags Key+rosa_cluster_id,Value=${ROSA_CLUSTER_ID} Key=rosa_openshift_verson,Value=${CLUSTER_VERSION} Key=rosa_role_prefix,Value=ManagedOpenShift Key=operator_namespace,Value=openshift-adp Key=operator_name,Value-openshift-oadp --query Role.Arn --output text)

echo "echo ${ROLE_ARN}"
```
attach policy to IAM role

```bash
aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn ${POLICY_ARN}
```

### Installing the OADP Operator and providing the IAM role

1. Create the credentials file

```bash
cat <<EOF > ${SCRATCH}/credentials
[default]
role_arn = ${ROLE_ARN}
web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF
```

1.  Creatn an openshoft secret

```bash
oc -n openshift-adp create secret generic cloud-credentials --from-file=${SCRATCH}/credentials
```

1. Install the OADP Operator.

1. Create AWS cloud storage using your AWS credentials:

```bash
cat << EOF | oc create -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: CloudStorage
metadata:
  name: ${CLUSTER_NAME}-oadp
  namespace: openshift-adp
spec:
  creationSecret:
    key: credentials
    name: cloud-credentials
  enableSharedConfig: true
  name: ${CLUSTER_NAME}-oadp
  provider: aws
  region: $REGION
EOF
```

1. Create the DataProtectionApplication resource

```bash
cat << EOF | oc create -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: ${CLUSTER_NAME}-dpa
  namespace: openshift-adp
spec:
  backupLocations:
  - bucket:
      cloudStorageRef:
        name: ${CLUSTER_NAME}-oadp
      credential:
        key: credentials
        name: cloud-credentials
      default: true
      config:
        region: ${REGION}
  configuration:
    velero:
      defaultPlugins:
      - openshift
      - aws
      restic:
        enable: false
  snapshotLocations:
  - velero:
      config:
        credentialsFile: /tmp/credentials/openshift-adp/cloud-credentials-credentials 
        enableSharedConfig: "true" 
        profile: default 
        region: ${REGION} 
      provider: aws
EOF
```





