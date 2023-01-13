---
date: '2022-09-14T22:07:09.764151'
title: Creating a ROSA cluster in STS mode with custom KMS key
tags: ["AWS", "ROSA"]
---
**Byron Miller**

*Last updated 4/21/2022*

> **Tip** Official Documentation [ROSA STS with custom KMS key](https://docs.openshift.com/rosa/rosa_getting_started/rosa-sts-creating-a-cluster-with-customizations.html#rosa-sts-creating-cluster-customizations_rosa-sts-creating-a-cluster-with-customizations)

This guide will walk you through installing ROSA (Red Hat OpenShift Service on AWS) with a customer-provided KMS key that will be used to encrypt both the root volumes of nodes as well as persistent volumes for mounted EBS claims.

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [ROSA CLI](https://github.com/openshift/rosa/releases/) v1.1.11 or higher
* OpenShift CLI - `rosa download openshift-client`

### Prepare AWS Account for ROSA

1. Configure the AWS CLI by running the following command

   ```bash
   aws configure
   ```

2. You will be required to enter an `AWS Access Key ID` and an `AWS Secret Access Key` along with a default region name and output format

   ```bash
   % aws configure
   AWS Access Key ID []:
   AWS Secret Access Key []:
   Default region name [us-east-2]:
   Default output format [json]:
   ```
    The `AWS Access Key ID` and `AWS Secret Access Key` values can be obtained by logging in to the AWS console and creating an **Access Key** in the **Security Credentials** section of the IAM dashboard for your user

3. Validate your credentials

   ```bash
   aws sts get-caller-identity
   ```

    You should receive output similar to the following
   ```json
   {
     "UserId": <your ID>,
     "Account": <your account>,
     "Arn": <your arn>
   }
   ```

    You will need to save the account ID for adding it to your KMS key to define installer role, so take note.

4. If this is a brand new AWS account that has never had a AWS Load Balancer installed in it, you should run the following

   ```bash
   aws iam create-service-linked-role --aws-service-name \
   "elasticloadbalancing.amazonaws.com"
   ```

5. Set the AWS region you plan to deploy your cluser into. For this example, we will deploy into `us-east-2`.

   ```bash
   export AWS_REGION="us-east-2"
   ```

## Create KMS Key

For this example, we will create a custom KMS key using the AWS CLI. If you would prefer, you could use an existing key instead.

1. Create a customer-managed KMS key

   ```bash
   KMS_ARN=$(aws kms create-key --region $AWS_REGION --description 'Custom ROSA Encryption Key' --query KeyMetadata.Arn --output text)
   ```

   This command will save the ARN output of this custom key for further steps.

1. Generate the necessary key policy to allow the ROSA STS roles to access the key. Use the below command to populate a sample policy, or create your own.

   > Important note, if you specify a custom STS role prefix, you will need to update that in the command below.

   ```bash
   AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text); cat << EOF > rosa-key-policy.json
   {
       "Version": "2012-10-17",
       "Id": "key-rosa-policy-1",
       "Statement": [
           {
               "Sid": "Enable IAM User Permissions",
               "Effect": "Allow",
               "Principal": {
                   "AWS": "arn:aws:iam::${AWS_ACCOUNT}:root"
               },
               "Action": "kms:*",
               "Resource": "*"
           },
           {
               "Sid": "Allow ROSA use of the key",
               "Effect": "Allow",
               "Principal": {
                   "AWS": [
                       "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Support-Role",
                       "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Installer-Role",
                       "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Worker-Role",
                       "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-ControlPlane-Role"
                   ]
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
               "Sid": "Allow attachment of persistent resources",
               "Effect": "Allow",
               "Principal": {
                   "AWS": [
                       "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Support-Role",
                       "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Installer-Role",
                       "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-Worker-Role",
                       "arn:aws:iam::${AWS_ACCOUNT}:role/ManagedOpenShift-ControlPlane-Role"
                   ]
               },
               "Action": [
                   "kms:CreateGrant",
                   "kms:ListGrants",
                   "kms:RevokeGrant"
               ],
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

1. Apply the newly generated key policy to the custom KMS key.

   ```bash
   aws kms put-key-policy --key-id $KMS_ARN \
   --policy file://rosa-key-policy.json \
   --policy-name default
   ```

## Create ROSA Cluster

1. Make sure your ROSA CLI version is at minimum v1.1.11 or higher.

   ```bash
   rosa version
   ```

1. Create the ROSA STS Account Roles

    > If you have already installed account-roles into your aws account, you can skip this step.

   ```bash
   rosa create account-roles --mode auto -y
   ```

1. Set Environment Variables

   ```bash
   ROSA_CLUSTER_NAME=poc-kmskey
   ```

2. Using the ROSA CLI, create your cluster.

   > While this is an example, feel free to customize this command to best suit your needs.

   ```bash
   rosa create cluster --cluster-name $ROSA_CLUSTER_NAME --sts \
   --region $AWS_REGION --compute-nodes 2 --machine-cidr 10.0.0.0/16 \
   --service-cidr 172.30.0.0/16 --pod-cidr 10.128.0.0/14 --host-prefix 23 \
   --kms-key-arn $KMS_ARN
   ```

1. Create the operator roles necessary for the cluster to function.

   ```bash
   rosa create operator-roles -c $ROSA_CLUSTER_NAME --mode auto --yes
   ```

2. Create the OIDC provider necessary for the cluster to authenticate.

   ```bash
   rosa create oidc-provider -c $ROSA_CLUSTER_NAME --mode auto --yes
   ```

3. Validate that the cluster is now installing. Within 5 minutes, the cluster state should move beyond `pending` and show `installing`.

   ```bash
   watch "rosa describe cluster -c $ROSA_CLUSTER_NAME"
   ```

4. Watch the install logs as the cluster installs.

   ```bash
   rosa logs install -c $ROSA_CLUSTER_NAME --watch --tail 10
   ```

## Validate the cluster

Once the cluster has finished installing we can validate our access to the cluster.

1. Create an Admin user

   ```bash
   rosa create admin -c $ROSA_CLUSTER_NAME
   ```
   Run the resulting login statement from output. May take 2-3 minutes before authentication is fully synced

2. Verify the default persistent volumes in the cluster.

   ```bash
   oc get pv
   ```

   Output:
   ```bash
   NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM
                                       STORAGECLASS       REASON   AGE
   pvc-00dac374-a45e-43fa-a313-ae0491e8edf1   10Gi       RWO            Delete           Bound    openshift-monitoring/alertmanager-data-alertmanager-main-1   gp2-customer-kms            26m
   pvc-7d211496-4ddf-4200-921c-1404b754afa5   10Gi       RWO            Delete           Bound    openshift-monitoring/alertmanager-data-alertmanager-main-0   gp2-customer-kms            26m
   pvc-b5243cef-ec30-4e5c-a348-aeb8136a908c   100Gi      RWO            Delete           Bound    openshift-monitoring/prometheus-data-prometheus-k8s-0        gp2-customer-kms            26m
   pvc-ec60c1cf-72cf-4ac6-ab12-8e9e5afdc15f   100Gi      RWO            Delete           Bound    openshift-monitoring/prometheus-data-prometheus-k8s-1        gp2-customer-kms            26m
   ```
You should see the StroageClass set to `gp2-customer-kms`. This is the default StorageClass which is encrypted using the customer-provided key.

## Cleanup

1. Delete the ROSA cluster

   ```bash
   rosa delete cluster -c $ROSA_CLUSTER_NAME
   ```

1. Once the cluster is deleted, delete the cluster's STS roles.

   ```bash
   rosa delete operator-roles -c $ROSA_CLUSTER_NAME --yes --mode auto
   rosa delete oidc-provider -c $ROSA_CLUSTER_NAME  --yes --mode auto
   ```
