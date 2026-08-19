---
date: '2026-08-19'
title: Disaster Recovery with OADP on ROSA HCP
tags: ["ROSA HCP", "OADP"]
authors:
  - Kevin Collins, Diana Sari, Kumudu Herath
validated_version: "4.22"
---

This guide demonstrates a complete disaster recovery (DR) solution for ROSA HCP using OADP (OpenShift API for Data Protection), S3 Cross-Region Replication, EFS replication, and Route 53 DNS failover. You will deploy a demo application, configure backup and restore infrastructure, and walk through two DR scenarios: hot-to-hot failover and cold DR failover.

## Architecture Overview

- **Primary cluster** in us-east-1, **DR cluster** in us-east-2
- **S3 with Cross-Region Replication** for application data and OADP backups
- **EFS with cross-region replication** for persistent volume data
- **Route 53 failover routing** with health checks for automatic DNS failover

## Prerequisites

- Two ROSA HCP clusters (one per region), referred to as `PRIMARY_CLUSTER` and `DR_CLUSTER`
- AWS CLI, `oc` CLI, `rosa` CLI, Helm CLI
- A Route 53 hosted zone (optional, for custom domain failover)
- The AWS EFS CSI Driver Operator installed on both clusters. Follow [Enabling the AWS EFS CSI Driver Operator on ROSA](/experts/rosa/aws-efs/) to set up EFS CSI on each cluster.

## Environment Variables

Set these variables for your environment. You will need values from both clusters.

```bash
export PRIMARY_CLUSTER_NAME=my-primary
export DR_CLUSTER_NAME=my-dr
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PRIMARY_REGION=$(rosa describe cluster -c $PRIMARY_CLUSTER_NAME -o json \
  | jq -r '.region.id')
export DR_REGION=$(rosa describe cluster -c $DR_CLUSTER_NAME -o json \
  | jq -r '.region.id')
export AWS_PAGER=""

echo "AWS_ACCOUNT_ID:  $AWS_ACCOUNT_ID"
echo "PRIMARY_REGION:  $PRIMARY_REGION"
echo "DR_REGION:       $DR_REGION"
```

Get the OIDC endpoints for both clusters:

```bash
export OIDC_PRIMARY=$(rosa describe cluster -c $PRIMARY_CLUSTER_NAME -o json \
  | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')
export OIDC_DR=$(rosa describe cluster -c $DR_CLUSTER_NAME -o json \
  | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')

echo "OIDC_PRIMARY: $OIDC_PRIMARY"
echo "OIDC_DR:      $OIDC_DR"
```

Get the VPC and subnet info from the machine pools (the worker node subnets are in your account):

```bash
export SUBNET_PRIMARY=$(rosa list machinepools -c $PRIMARY_CLUSTER_NAME -o json \
  | jq -r '.[0].subnet')

export VPC_PRIMARY=$(aws ec2 describe-subnets --subnet-ids $SUBNET_PRIMARY \
  --region $PRIMARY_REGION \
  --query 'Subnets[0].VpcId' --output text)

export SUBNET_DR=$(rosa list machinepools -c $DR_CLUSTER_NAME -o json \
  | jq -r '.[0].subnet')

export VPC_DR=$(aws ec2 describe-subnets --subnet-ids $SUBNET_DR \
  --region $DR_REGION \
  --query 'Subnets[0].VpcId' --output text)

echo "SUBNET_PRIMARY: $SUBNET_PRIMARY"
echo "VPC_PRIMARY:    $VPC_PRIMARY"
echo "SUBNET_DR:      $SUBNET_DR"
echo "VPC_DR:         $VPC_DR"
```

Set the S3 bucket names:

```bash
export APP_BUCKET_PRIMARY=${PRIMARY_CLUSTER_NAME}-app-data
export APP_BUCKET_DR=${DR_CLUSTER_NAME}-app-data
export OADP_BUCKET_PRIMARY=${PRIMARY_CLUSTER_NAME}-oadp-backups
export OADP_BUCKET_DR=${DR_CLUSTER_NAME}-oadp-backups

echo "APP_BUCKET_PRIMARY:  $APP_BUCKET_PRIMARY"
echo "APP_BUCKET_DR:       $APP_BUCKET_DR"
echo "OADP_BUCKET_PRIMARY: $OADP_BUCKET_PRIMARY"
echo "OADP_BUCKET_DR:      $OADP_BUCKET_DR"
```

## Step 1: Create S3 Buckets with Cross-Region Replication

Create the application data and OADP backup buckets in both regions with versioning enabled:

```bash
for PAIR in "$APP_BUCKET_PRIMARY:$PRIMARY_REGION" \
            "$OADP_BUCKET_PRIMARY:$PRIMARY_REGION" \
            "$APP_BUCKET_DR:$DR_REGION" \
            "$OADP_BUCKET_DR:$DR_REGION"; do
  BUCKET=${PAIR%%:*}
  REGION=${PAIR##*:}
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket $BUCKET --region $REGION
  else
    aws s3api create-bucket --bucket $BUCKET --region $REGION \
      --create-bucket-configuration LocationConstraint=$REGION
  fi
  aws s3api put-bucket-versioning \
    --bucket $BUCKET \
    --versioning-configuration Status=Enabled
done
```

Create an IAM role for S3 replication:

```bash
cat <<EOF > /tmp/s3-replication-trust.json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "s3.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name ${PRIMARY_CLUSTER_NAME}-s3-replication \
  --assume-role-policy-document file:///tmp/s3-replication-trust.json

cat <<EOF > /tmp/s3-replication-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetReplicationConfiguration",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${APP_BUCKET_PRIMARY}",
        "arn:aws:s3:::${OADP_BUCKET_PRIMARY}"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObjectVersionForReplication",
        "s3:GetObjectVersionAcl",
        "s3:GetObjectVersionTagging"
      ],
      "Resource": [
        "arn:aws:s3:::${APP_BUCKET_PRIMARY}/*",
        "arn:aws:s3:::${OADP_BUCKET_PRIMARY}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ReplicateObject",
        "s3:ReplicateDelete",
        "s3:ReplicateTags"
      ],
      "Resource": [
        "arn:aws:s3:::${APP_BUCKET_DR}/*",
        "arn:aws:s3:::${OADP_BUCKET_DR}/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name ${PRIMARY_CLUSTER_NAME}-s3-replication \
  --policy-name s3-crr-policy \
  --policy-document file:///tmp/s3-replication-policy.json
```

Configure replication rules for both bucket pairs:

```bash
export REPLICATION_ROLE_ARN=$(aws iam get-role \
  --role-name ${PRIMARY_CLUSTER_NAME}-s3-replication \
  --query 'Role.Arn' --output text)

echo "REPLICATION_ROLE_ARN: $REPLICATION_ROLE_ARN"

cat <<EOF > /tmp/app-replication.json
{
  "Role": "${REPLICATION_ROLE_ARN}",
  "Rules": [{
    "ID": "app-data-crr",
    "Priority": 1,
    "Status": "Enabled",
    "Filter": {},
    "DeleteMarkerReplication": {"Status": "Enabled"},
    "Destination": {
      "Bucket": "arn:aws:s3:::${APP_BUCKET_DR}"
    }
  }]
}
EOF

aws s3api put-bucket-replication \
  --bucket $APP_BUCKET_PRIMARY \
  --replication-configuration file:///tmp/app-replication.json

cat <<EOF > /tmp/oadp-replication.json
{
  "Role": "${REPLICATION_ROLE_ARN}",
  "Rules": [{
    "ID": "oadp-backups-crr",
    "Priority": 1,
    "Status": "Enabled",
    "Filter": {},
    "DeleteMarkerReplication": {"Status": "Enabled"},
    "Destination": {
      "Bucket": "arn:aws:s3:::${OADP_BUCKET_DR}"
    }
  }]
}
EOF

aws s3api put-bucket-replication \
  --bucket $OADP_BUCKET_PRIMARY \
  --replication-configuration file:///tmp/oadp-replication.json
```

## Step 2: Create EFS with Cross-Region Replication

### Create the primary EFS filesystem

Create a security group for EFS in the primary region:

```bash
export EFS_SG_PRIMARY=$(aws ec2 create-security-group \
  --region $PRIMARY_REGION \
  --group-name ${PRIMARY_CLUSTER_NAME}-efs-dr-sg \
  --description "EFS access for DR demo" \
  --vpc-id $VPC_PRIMARY \
  --query 'GroupId' --output text)

echo "EFS_SG_PRIMARY: $EFS_SG_PRIMARY"
```

Create the EFS filesystem:

```bash
export PRIMARY_EFS=$(aws efs create-file-system \
  --region $PRIMARY_REGION \
  --encrypted \
  --tags Key=Name,Value=${PRIMARY_CLUSTER_NAME}-dr-efs \
  --query 'FileSystemId' --output text)

echo "PRIMARY_EFS: $PRIMARY_EFS"
```

Create a mount target in the primary subnet:

```bash
aws efs create-mount-target \
  --region $PRIMARY_REGION \
  --file-system-id $PRIMARY_EFS \
  --subnet-id $SUBNET_PRIMARY \
  --security-groups $EFS_SG_PRIMARY
```

Configure cross-region replication to the DR region:

```bash
aws efs create-replication-configuration \
  --region $PRIMARY_REGION \
  --source-file-system-id $PRIMARY_EFS \
  --destinations "[{\"Region\": \"${DR_REGION}\"}]"
```

Get the replica EFS filesystem ID:

```bash
export DR_EFS=$(aws efs describe-replication-configurations \
  --region $PRIMARY_REGION \
  --file-system-id $PRIMARY_EFS \
  --query 'Replications[0].Destinations[0].FileSystemId' \
  --output text)

echo "DR_EFS: $DR_EFS"
```

### Configure security groups for the DR region

Create a security group for EFS in the DR region:

```bash
export EFS_SG_DR=$(aws ec2 create-security-group \
  --region $DR_REGION \
  --group-name ${DR_CLUSTER_NAME}-efs-dr-sg \
  --description "EFS access for DR demo" \
  --vpc-id $VPC_DR \
  --query 'GroupId' --output text)

echo "EFS_SG_DR: $EFS_SG_DR"
```

Add NFS ingress rules allowing traffic from the worker security groups on both clusters:

```bash
WORKER_SG_PRIMARY=$(aws ec2 describe-instances \
  --region $PRIMARY_REGION \
  --filters "Name=tag:Name,Values=*${PRIMARY_CLUSTER_NAME}*worker*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' \
  --output text | head -1)

aws ec2 authorize-security-group-ingress \
  --region $PRIMARY_REGION \
  --group-id $EFS_SG_PRIMARY \
  --protocol tcp --port 2049 \
  --source-group $WORKER_SG_PRIMARY

WORKER_SG_DR=$(aws ec2 describe-instances \
  --region $DR_REGION \
  --filters "Name=tag:Name,Values=*${DR_CLUSTER_NAME}*worker*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' \
  --output text | head -1)

aws ec2 authorize-security-group-ingress \
  --region $DR_REGION \
  --group-id $EFS_SG_DR \
  --protocol tcp --port 2049 \
  --source-group $WORKER_SG_DR

echo "WORKER_SG_PRIMARY: $WORKER_SG_PRIMARY"
echo "WORKER_SG_DR:      $WORKER_SG_DR"
```

### Install the EFS CSI Driver

Install the AWS EFS CSI Driver Operator on both clusters by following [Enabling the AWS EFS CSI Driver Operator on ROSA](/experts/rosa/aws-efs/). Complete these sections from the guide on each cluster:


Important:
Skip the Create an EFS file system section


1. **Set environment variables**
1. **Create the IAM policy and role** — creates the IAM role for the CSI driver operator
1. **Install the AWS EFS CSI Driver Operator** — installs the operator via the web console
1. **Create the ClusterCSIDriver** — enables the CSI driver pods
1. **Find worker subnets, VPC, security groups, and IAM roles** — only the worker IAM role name is needed from this section
1. **Attach EFS permissions to the worker role** — attaches `AmazonEFSCSIDriverPolicy` to the worker role

Stop after **Attach EFS permissions to the worker role**. Do **not** continue to "Create an EFS security group" or beyond — this DR guide handles EFS filesystem creation, security groups, mount targets, and StorageClass in the steps above and in the Helm chart.

## Step 3: Create IAM Roles

### Application S3 access roles

Create IAM roles for the demo application to access S3 from both clusters. These roles use IRSA (IAM Roles for Service Accounts) with the ROSA HCP OIDC provider.

Create the S3 access policy:

```bash
cat <<EOF > /tmp/app-s3-policy.json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "s3:DeleteObject"
    ],
    "Resource": [
      "arn:aws:s3:::${APP_BUCKET_PRIMARY}",
      "arn:aws:s3:::${APP_BUCKET_PRIMARY}/*",
      "arn:aws:s3:::${APP_BUCKET_DR}",
      "arn:aws:s3:::${APP_BUCKET_DR}/*"
    ]
  }]
}
EOF

export APP_S3_POLICY_ARN=$(aws iam create-policy \
  --policy-name ${PRIMARY_CLUSTER_NAME}-dr-demo-s3 \
  --policy-document file:///tmp/app-s3-policy.json \
  --query 'Policy.Arn' --output text)

echo "APP_S3_POLICY_ARN: $APP_S3_POLICY_ARN"
```

Create the role for the primary cluster:

```bash
cat <<EOF > /tmp/app-s3-trust-primary.json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PRIMARY}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PRIMARY}:sub": [
          "system:serviceaccount:dr-demo:s3-writer",
          "system:serviceaccount:dr-demo:default"
        ]
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name ${PRIMARY_CLUSTER_NAME}-dr-demo-s3 \
  --assume-role-policy-document file:///tmp/app-s3-trust-primary.json

aws iam attach-role-policy \
  --role-name ${PRIMARY_CLUSTER_NAME}-dr-demo-s3 \
  --policy-arn $APP_S3_POLICY_ARN
```

Create the role for the DR cluster:

```bash
cat <<EOF > /tmp/app-s3-trust-dr.json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_DR}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_DR}:sub": [
          "system:serviceaccount:dr-demo:s3-writer",
          "system:serviceaccount:dr-demo:default"
        ]
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name ${DR_CLUSTER_NAME}-dr-demo-s3 \
  --assume-role-policy-document file:///tmp/app-s3-trust-dr.json

aws iam attach-role-policy \
  --role-name ${DR_CLUSTER_NAME}-dr-demo-s3 \
  --policy-arn $APP_S3_POLICY_ARN
```

### OADP/Velero roles

Create IAM roles for OADP on both clusters.

Create the OADP policy:

```bash
cat <<EOF > /tmp/oadp-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::${OADP_BUCKET_PRIMARY}/*",
        "arn:aws:s3:::${OADP_BUCKET_DR}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": [
        "arn:aws:s3:::${OADP_BUCKET_PRIMARY}",
        "arn:aws:s3:::${OADP_BUCKET_DR}"
      ]
    }
  ]
}
EOF

export OADP_POLICY_ARN=$(aws iam create-policy \
  --policy-name ${PRIMARY_CLUSTER_NAME}-oadp-velero \
  --policy-document file:///tmp/oadp-policy.json \
  --query 'Policy.Arn' --output text)

echo "OADP_POLICY_ARN: $OADP_POLICY_ARN"
```

Create the OADP role for the primary cluster:

```bash
cat <<EOF > /tmp/oadp-trust-primary.json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PRIMARY}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PRIMARY}:sub": [
          "system:serviceaccount:openshift-adp:openshift-adp-controller-manager",
          "system:serviceaccount:openshift-adp:velero"
        ]
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name ${PRIMARY_CLUSTER_NAME}-oadp-velero \
  --assume-role-policy-document file:///tmp/oadp-trust-primary.json

aws iam attach-role-policy \
  --role-name ${PRIMARY_CLUSTER_NAME}-oadp-velero \
  --policy-arn $OADP_POLICY_ARN
```

Create the OADP role for the DR cluster:

```bash
cat <<EOF > /tmp/oadp-trust-dr.json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_DR}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_DR}:sub": [
          "system:serviceaccount:openshift-adp:openshift-adp-controller-manager",
          "system:serviceaccount:openshift-adp:velero"
        ]
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name ${DR_CLUSTER_NAME}-oadp-velero \
  --assume-role-policy-document file:///tmp/oadp-trust-dr.json

aws iam attach-role-policy \
  --role-name ${DR_CLUSTER_NAME}-oadp-velero \
  --policy-arn $OADP_POLICY_ARN
    ```

## Step 4: Install OADP on Both Clusters

Repeat these steps on both the primary and DR clusters. The examples below show the primary cluster. Replace the role ARN and bucket name with DR values when installing on the DR cluster.

### Install the OADP Operator

Create the `openshift-adp` namespace and install the OADP Operator:

```bash
oc create namespace openshift-adp || true

cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: adp
  namespace: openshift-adp
spec:
  targetNamespaces:
    - openshift-adp
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  channel: stable
  installPlanApproval: Automatic
  name: redhat-oadp-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait for the Operator to install:

```bash
oc get csv -n openshift-adp -w
```

### Create credentials and DataProtectionApplication

Repeat this section on both clusters, using the appropriate values for each.

**On the primary cluster:**

```bash
cat <<EOF > /tmp/oadp-credentials
[default]
role_arn = arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PRIMARY_CLUSTER_NAME}-oadp-velero
web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF

oc create secret generic cloud-credentials \
  -n openshift-adp \
  --from-file=cloud=/tmp/oadp-credentials
```

```bash
cat <<EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dr-demo-dpa
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - aws
        - openshift
        - csi
    nodeAgent:
      enable: false
      uploaderType: kopia
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${OADP_BUCKET_PRIMARY}
          prefix: velero
        config:
          region: ${PRIMARY_REGION}
        credential:
          name: cloud-credentials
          key: cloud
EOF
```

**On the DR cluster:**

```bash
cat <<EOF > /tmp/oadp-credentials
[default]
role_arn = arn:aws:iam::${AWS_ACCOUNT_ID}:role/${DR_CLUSTER_NAME}-oadp-velero
web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF

oc create secret generic cloud-credentials \
  -n openshift-adp \
  --from-file=cloud=/tmp/oadp-credentials
```

```bash
cat <<EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dr-demo-dpa
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - aws
        - openshift
        - csi
    nodeAgent:
      enable: false
      uploaderType: kopia
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${OADP_BUCKET_DR}
          prefix: velero
        config:
          region: ${DR_REGION}
        credential:
          name: cloud-credentials
          key: cloud
EOF
```

Verify the Backup Storage Location is available on each cluster:

```bash
oc get backupstoragelocation -n openshift-adp
```

The `PHASE` column should show `Available`.

## Step 5: Deploy the Demo Application

Deploy the [Phoenix Mission Control](https://github.com/rh-mobb/phoenix-mission-control) demo application on the primary cluster.

Clone the Helm chart:

```bash
git clone https://github.com/rh-mobb/phoenix-mission-control.git
cd phoenix-mission-control
```

Install the application on the primary cluster:

```bash
helm install phoenix-mission-control ./chart \
  --namespace dr-demo --create-namespace \
  --set region=$PRIMARY_REGION \
  --set clusterName=$PRIMARY_CLUSTER_NAME \
  --set s3.bucket=$APP_BUCKET_PRIMARY \
  --set s3.roleArn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PRIMARY_CLUSTER_NAME}-dr-demo-s3 \
  --set efs.fileSystemId=$PRIMARY_EFS \
  --set primaryRegion=$PRIMARY_REGION \
  --set primaryCluster=$PRIMARY_CLUSTER_NAME
```

Verify pods are running:

```bash
oc get pods -n dr-demo
```

Access the dashboard:

```bash
oc get route -n dr-demo
```

Open the route URL in your browser to verify the application is working.

## Step 6: Configure Route 53 DNS Failover (Optional)

This step sets up automatic DNS failover using Route 53 health checks and failover routing.

Get the router ELB hostnames from both clusters:

```bash
export PRIMARY_ROUTER=$(oc get -n dr-demo route phoenix-mission-control \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')
export DR_ROUTER=$(oc get -n dr-demo route phoenix-mission-control \
  -o jsonpath='{.status.ingress[0].routerCanonicalHostname}')

echo "PRIMARY_ROUTER: $PRIMARY_ROUTER"
echo "DR_ROUTER:      $DR_ROUTER"
```

Create a health check on the primary route:

```bash
export HEALTH_CHECK_ID=$(aws route53 create-health-check \
  --caller-reference "dr-demo-$(date +%s)" \
  --health-check-config \
    Type=HTTPS,FullyQualifiedDomainName=${PRIMARY_ROUTER},Port=443,ResourcePath=/healthz,RequestInterval=10,FailureThreshold=3 \
  --query 'HealthCheck.Id' --output text)

echo "HEALTH_CHECK_ID: $HEALTH_CHECK_ID"
```

Create the PRIMARY failover CNAME record:

```bash
export HOSTED_ZONE_ID=<your-hosted-zone-id>
export DR_DOMAIN=dr-demo.example.com

aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "'$DR_DOMAIN'",
        "Type": "CNAME",
        "SetIdentifier": "primary",
        "Failover": "PRIMARY",
        "TTL": 60,
        "ResourceRecords": [{"Value": "'$PRIMARY_ROUTER'"}],
        "HealthCheckId": "'$HEALTH_CHECK_ID'"
      }
    }]
  }'
```

Create the SECONDARY failover CNAME record:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "'$DR_DOMAIN'",
        "Type": "CNAME",
        "SetIdentifier": "secondary",
        "Failover": "SECONDARY",
        "TTL": 60,
        "ResourceRecords": [{"Value": "'$DR_ROUTER'"}]
      }
    }]
  }'
```

Create a TLS certificate for the custom domain. You can use Let's Encrypt with `certbot` and the `certbot-dns-route53` plugin, or any other certificate provider.

Add the custom domain route on both clusters:

```bash
oc create route edge dr-demo-custom \
  --service=phoenix-mission-control \
  --hostname=$DR_DOMAIN \
  --cert=/path/to/cert.pem \
  --key=/path/to/key.pem \
  -n dr-demo
```

## DR Scenario 1: Hot-to-Hot Failover

Both clusters have running worker nodes. This is the fastest failover scenario.

### Failover (Primary to DR)

Create an OADP backup on the primary cluster:

```bash
export BACKUP_NAME=dr-backup-$(date +%Y%m%d-%H%M)

cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: openshift-adp
spec:
  includedNamespaces:
    - dr-demo
  storageLocation: dr-demo-dpa-1
  defaultVolumesToFsBackup: false
  snapshotVolumes: false
EOF
```

Wait for the backup to complete:

```bash
oc get backup -n openshift-adp $BACKUP_NAME -w
```

Wait until the `PHASE` shows `Completed`.

Sync the backup to the DR bucket:

```bash
aws s3 sync \
  s3://$OADP_BUCKET_PRIMARY/velero/backups/$BACKUP_NAME/ \
  s3://$OADP_BUCKET_DR/velero/backups/$BACKUP_NAME/ \
  --source-region $PRIMARY_REGION --region $DR_REGION
```

Delete EFS replication to promote the replica to read-write:

```bash
aws efs delete-replication-configuration \
  --source-file-system-id $PRIMARY_EFS \
  --region $PRIMARY_REGION
```

Create EFS mount targets on the replica filesystem in the DR region:

```bash
aws efs create-mount-target \
  --region $DR_REGION \
  --file-system-id $DR_EFS \
  --subnet-id $SUBNET_DR \
  --security-groups $EFS_SG_DR
```

Create EFS access points on the replica for the same directory paths used by the application:

```bash
export DR_AP=$(aws efs create-access-point \
  --region $DR_REGION \
  --file-system-id $DR_EFS \
  --root-directory "Path=/data,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755}" \
  --query 'AccessPointId' --output text)

echo "DR_AP: $DR_AP"
```

Create static PVs on the DR cluster pointing to the replica EFS and new access points:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: dr-efs-pv
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: efs.csi.aws.com
    volumeHandle: ${DR_EFS}::${DR_AP}
EOF
```

Log in to the DR cluster, restart Velero to discover the backup, then restore:

```bash
oc rollout restart deployment/velero -n openshift-adp
oc rollout status deployment/velero -n openshift-adp --timeout=120s
```

Wait for the backup to appear in the DR cluster:

```bash
oc get backup -n openshift-adp
```

Create the restore:

```bash
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: dr-restore-$(date +%Y%m%d-%H%M)
  namespace: openshift-adp
spec:
  backupName: ${BACKUP_NAME}
  includedNamespaces:
    - dr-demo
  restorePVs: false
  existingResourcePolicy: update
EOF
```

Update environment variables to point to the DR region:

```bash
oc set env deployment/telemetry-transmitter -n dr-demo \
  S3_BUCKET=$APP_BUCKET_DR \
  AWS_REGION=$DR_REGION \
  CLUSTER_NAME=$DR_CLUSTER_NAME
```

DNS failover happens automatically when the Route 53 health check detects the primary is down. To trigger a manual failover, update the health check to force failure or directly update the DNS records.

### Failback (DR to Primary)

Create an OADP backup on the DR cluster:

```bash
export FAILBACK_BACKUP=dr-failback-$(date +%Y%m%d-%H%M)

cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${FAILBACK_BACKUP}
  namespace: openshift-adp
spec:
  includedNamespaces:
    - dr-demo
  storageLocation: dr-demo-dpa-1
  defaultVolumesToFsBackup: false
  snapshotVolumes: false
EOF
```

Sync the backup to the primary bucket:

```bash
aws s3 sync \
  s3://$OADP_BUCKET_DR/velero/backups/$FAILBACK_BACKUP/ \
  s3://$OADP_BUCKET_PRIMARY/velero/backups/$FAILBACK_BACKUP/ \
  --source-region $DR_REGION --region $PRIMARY_REGION
```

Sync application S3 data back to the primary bucket to prevent data loss:

```bash
aws s3 sync \
  s3://$APP_BUCKET_DR/telemetry/ \
  s3://$APP_BUCKET_PRIMARY/telemetry/ \
  --source-region $DR_REGION --region $PRIMARY_REGION
```

On the primary cluster, restart Velero and restore from the failback backup:

```bash
oc rollout restart deployment/velero -n openshift-adp
oc rollout status deployment/velero -n openshift-adp --timeout=120s
oc get backup -n openshift-adp

cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: dr-failback-restore-$(date +%Y%m%d-%H%M)
  namespace: openshift-adp
spec:
  backupName: ${FAILBACK_BACKUP}
  includedNamespaces:
    - dr-demo
  restorePVs: false
  existingResourcePolicy: update
EOF
```

Update environment variables back to primary values:

```bash
oc set env deployment/telemetry-transmitter -n dr-demo \
  S3_BUCKET=$APP_BUCKET_PRIMARY \
  AWS_REGION=$PRIMARY_REGION \
  CLUSTER_NAME=$PRIMARY_CLUSTER_NAME
```

Re-establish EFS replication from primary to DR:

```bash
aws efs create-replication-configuration \
  --region $PRIMARY_REGION \
  --source-file-system-id $PRIMARY_EFS \
  --destinations "[{\"Region\": \"${DR_REGION}\", \"FileSystemId\": \"${DR_EFS}\"}]"
```

DNS fails back automatically when the primary health check passes again.

## DR Scenario 2: Cold DR (Scaled-Down DR Cluster)

The DR cluster has worker nodes stopped to save costs. This requires starting instances before the restore can proceed.

### Setup: Scale Down DR Cluster

Stop the DR cluster worker nodes to reduce costs during normal operation:

```bash
rosa edit machinepool workers \
  --cluster $DR_CLUSTER_NAME \
  --autorepair=false

WORKER_IDS=$(aws ec2 describe-instances \
  --region $DR_REGION \
  --filters "Name=tag:Name,Values=*${DR_CLUSTER_NAME}*worker*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)

aws ec2 stop-instances \
  --instance-ids $WORKER_IDS \
  --region $DR_REGION
```

### Failover to Cold DR

Create an OADP backup on the primary cluster (same as Scenario 1).

Sync the backup to the DR bucket:

```bash
aws s3 sync \
  s3://$OADP_BUCKET_PRIMARY/velero/backups/$BACKUP_NAME/ \
  s3://$OADP_BUCKET_DR/velero/backups/$BACKUP_NAME/ \
  --source-region $PRIMARY_REGION --region $DR_REGION
```

Delete EFS replication to promote the replica to read-write:

```bash
aws efs delete-replication-configuration \
  --source-file-system-id $PRIMARY_EFS \
  --region $PRIMARY_REGION
```

Create EFS access points and static PVs on the DR cluster (same as Scenario 1).

Start the DR worker instances:

```bash
aws ec2 start-instances \
  --instance-ids $WORKER_IDS \
  --region $DR_REGION

rosa edit machinepool workers \
  --cluster $DR_CLUSTER_NAME \
  --autorepair=true
```

Wait for the nodes to become ready:

```bash
oc get nodes -w
```

Restart Velero and restore from the backup:

```bash
oc rollout restart deployment/velero -n openshift-adp
oc rollout status deployment/velero -n openshift-adp --timeout=120s

cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: dr-cold-restore-$(date +%Y%m%d-%H%M)
  namespace: openshift-adp
spec:
  backupName: ${BACKUP_NAME}
  includedNamespaces:
    - dr-demo
  restorePVs: false
  existingResourcePolicy: update
EOF
```

Update environment variables for the DR region:

```bash
oc set env deployment/telemetry-transmitter -n dr-demo \
  S3_BUCKET=$APP_BUCKET_DR \
  AWS_REGION=$DR_REGION \
  CLUSTER_NAME=$DR_CLUSTER_NAME
```

DNS failover happens automatically via Route 53 health check, or update DNS manually.

## Cleanup

Remove all resources created by this guide.

### Delete the demo application on both clusters

```bash
oc delete namespace dr-demo
helm uninstall phoenix-mission-control -n dr-demo 2>/dev/null || true
```

### Delete the OADP operator on both clusters

```bash
oc delete dpa dr-demo-dpa -n openshift-adp
oc delete secret cloud-credentials -n openshift-adp
oc delete subscription redhat-oadp-operator -n openshift-adp

OADP_CSV=$(oc get csv -n openshift-adp -o name | grep oadp || true)
if [ -n "$OADP_CSV" ]; then
  oc delete $OADP_CSV -n openshift-adp
fi
```

### Delete S3 buckets

```bash
for BUCKET in $APP_BUCKET_PRIMARY $APP_BUCKET_DR \
              $OADP_BUCKET_PRIMARY $OADP_BUCKET_DR; do
  aws s3 rb s3://$BUCKET --force
done
```

### Delete EFS filesystems

Delete any remaining replication configuration, mount targets, access points, and the filesystems:

```bash
for EFS_ID in $PRIMARY_EFS $DR_EFS; do
  REGION=$PRIMARY_REGION
  if [ "$EFS_ID" = "$DR_EFS" ]; then REGION=$DR_REGION; fi

  for AP in $(aws efs describe-access-points \
    --file-system-id $EFS_ID --region $REGION \
    --query 'AccessPoints[*].AccessPointId' --output text); do
    aws efs delete-access-point --access-point-id $AP --region $REGION
  done

  for MT in $(aws efs describe-mount-targets \
    --file-system-id $EFS_ID --region $REGION \
    --query 'MountTargets[*].MountTargetId' --output text); do
    aws efs delete-mount-target --mount-target-id $MT --region $REGION
  done

  aws efs delete-file-system --file-system-id $EFS_ID --region $REGION
done
```

### Delete security groups

```bash
aws ec2 delete-security-group --group-id $EFS_SG_PRIMARY --region $PRIMARY_REGION
aws ec2 delete-security-group --group-id $EFS_SG_DR --region $DR_REGION
```

### Delete IAM roles and policies

```bash
for ROLE in ${PRIMARY_CLUSTER_NAME}-dr-demo-s3 \
            ${DR_CLUSTER_NAME}-dr-demo-s3 \
            ${PRIMARY_CLUSTER_NAME}-oadp-velero \
            ${DR_CLUSTER_NAME}-oadp-velero \
            ${PRIMARY_CLUSTER_NAME}-s3-replication; do
  for POLICY_ARN in $(aws iam list-attached-role-policies \
    --role-name $ROLE \
    --query 'AttachedPolicies[*].PolicyArn' \
    --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name $ROLE --policy-arn $POLICY_ARN
  done
  aws iam delete-role-policy --role-name $ROLE \
    --policy-name s3-crr-policy 2>/dev/null || true
  aws iam delete-role --role-name $ROLE 2>/dev/null || true
done

for POLICY_ARN in $APP_S3_POLICY_ARN $OADP_POLICY_ARN; do
  aws iam delete-policy --policy-arn $POLICY_ARN 2>/dev/null || true
done
```

### Delete Route 53 records and health checks (if created)

```bash
aws route53 delete-health-check --health-check-id $HEALTH_CHECK_ID
```

Delete the failover CNAME records from your hosted zone using the Route 53 console or `change-resource-record-sets` with `Action: DELETE`.
