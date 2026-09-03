---
date: '2026-09-02'
title: Configuring Customer KMS Key for the OpenShift Image Registry on ROSA ( Classic and HCP )
tags: ["ROSA","ROSA HCP"]
authors:
  - Kevin Collins
  - Diana Sari
validated_version: "4.22"
---

By default, ROSA clusters ( Classic and HCP ) store container images in an S3 bucket encrypted with an AWS-managed key. Organizations with compliance or data-sovereignty requirements may need to use a customer-managed AWS KMS key instead, giving them full control over key rotation, access policies, and audit trails.

This guide walks through creating a customer-managed KMS key and configuring the ROSA image registry to use it for server-side encryption of all stored container images.

## Prerequisites

You need:

* A ROSA cluster (running and logged into)
* The `rosa` CLI
* The `oc` CLI
* The AWS CLI
* AWS permissions to create and manage KMS keys
* AWS permissions to modify IAM role policies

## Set environment variables

Set the following environment variables to match your cluster:

```bash
export CLUSTER_NAME=<your-cluster-name>
export REGION=$(rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.region.id')
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_PAGER=""
```

## Create a customer-managed KMS key

1. Create the KMS key:

   ```bash
   KMS_KEY_ID=$(aws kms create-key \
     --region $REGION \
     --description "Customer KMS key for ROSA image registry - $CLUSTER_NAME" \
     --query 'KeyMetadata.KeyId' \
     --output text)

   echo "KMS Key ID: $KMS_KEY_ID"
   ```

1. Create an alias for easier identification:

   ```bash
   aws kms create-alias \
     --alias-name alias/${CLUSTER_NAME}-image-registry \
     --target-key-id $KMS_KEY_ID \
     --region $REGION
   ```

1. Get the full KMS key ARN:

   ```bash
   KMS_ARN=$(aws kms describe-key \
     --key-id $KMS_KEY_ID \
     --region $REGION \
     --query 'KeyMetadata.Arn' \
     --output text)

   echo "KMS ARN: $KMS_ARN"
   ```

1. Ensure the KMS key policy allows IAM roles in your account to use the key:

   ```bash
   aws kms put-key-policy \
     --key-id $KMS_KEY_ID \
     --region $REGION \
     --policy-name default \
     --policy '{
       "Version": "2012-10-17",
       "Statement": [
         {
           "Sid": "Enable IAM User Permissions",
           "Effect": "Allow",
           "Principal": {
             "AWS": "arn:aws:iam::'$AWS_ACCOUNT_ID':root"
           },
           "Action": "kms:*",
           "Resource": "*"
         }
       ]
     }'
   ```

## Grant the image registry operator KMS permissions

The image registry operator role needs permissions to encrypt and decrypt objects using the customer KMS key.

1. Identify the image registry operator role:

   ```bash
   OPERATOR_PREFIX=$(rosa describe cluster -c $CLUSTER_NAME -o json \
     | jq -r '.aws.sts.operator_role_prefix')

   REGISTRY_ROLE="${OPERATOR_PREFIX}-openshift-image-registry-installer-cloud-credentials"

   echo "Image registry role: $REGISTRY_ROLE"
   ```

1. Attach a KMS policy to the role:

   ```bash
   aws iam put-role-policy \
     --role-name $REGISTRY_ROLE \
     --policy-name ImageRegistryKMSAccess \
     --policy-document '{
       "Version": "2012-10-17",
       "Statement": [
         {
           "Effect": "Allow",
           "Action": [
             "kms:Decrypt",
             "kms:Encrypt",
             "kms:DescribeKey",
             "kms:GenerateDataKey*",
             "kms:ReEncrypt*"
           ],
           "Resource": "'"$KMS_ARN"'"
         }
       ]
     }'
   ```

## Configure the image registry to use the KMS key

ROSA configures the default image registry with S3 encryption enabled (`spec.storage.s3.encrypt: true`). This procedure changes the encryption key used by the existing registry S3 backend by setting `spec.storage.s3.keyID`.

1. Patch the image registry operator configuration to use the customer KMS key:

   ```bash
   oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
     --patch '{"spec":{"storage":{"s3":{"keyID":"'"$KMS_KEY_ID"'"}}}}'
   ```

1. Monitor the image registry operator rollout:

   ```bash
   watch oc get co image-registry
   ```

   Wait until the operator shows `AVAILABLE=True`, `PROGRESSING=False`, and `DEGRADED=False`.

## Verify KMS encryption

1. Confirm the image registry configuration includes the KMS key:

   ```bash
   oc get configs.imageregistry.operator.openshift.io cluster \
     -o jsonpath='{.spec.storage.s3}' | jq .
   ```

   The output should include `"keyID"` set to your KMS key ID.

1. Check the S3 bucket default encryption:

   ```bash
   BUCKET=$(oc get configs.imageregistry.operator.openshift.io cluster \
     -o jsonpath='{.spec.storage.s3.bucket}')

   aws s3api get-bucket-encryption \
     --bucket $BUCKET \
     --region $REGION \
     --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault'
   ```

   Expected output:

   ```json
   {
     "SSEAlgorithm": "aws:kms",
     "KMSMasterKeyID": "<your-kms-key-id>"
   }
   ```

1. Build and push an image to the internal registry to create objects encrypted with the customer KMS key. Objects written before the KMS configuration was applied retain their original encryption.

   ```bash
   oc new-project kms-test

   cat <<'EOF' | oc apply -f -
   apiVersion: build.openshift.io/v1
   kind: BuildConfig
   metadata:
     name: kms-test-build
   spec:
     output:
       to:
         kind: ImageStreamTag
         name: kms-test:latest
     source:
       dockerfile: |
         FROM registry.access.redhat.com/ubi9/ubi-micro:latest
         RUN echo "kms-test" > /tmp/test.txt
     strategy:
       dockerStrategy: {}
   EOF

   oc create imagestream kms-test -n kms-test
   oc start-build kms-test-build --follow -n kms-test
   ```

1. Verify that the newly written object is encrypted with the customer KMS key:

   ```bash
   NEWEST_KEY=$(aws s3api list-objects-v2 \
     --bucket $BUCKET \
     --region $REGION \
     --query 'sort_by(Contents, &LastModified)[-1].Key' \
     --output text)

   aws s3api head-object \
     --bucket $BUCKET \
     --key "$NEWEST_KEY" \
     --region $REGION \
     --query '{ServerSideEncryption: ServerSideEncryption, SSEKMSKeyId: SSEKMSKeyId}'
   ```

   Expected output:

   ```json
   {
     "ServerSideEncryption": "aws:kms",
     "SSEKMSKeyId": "arn:aws:kms:<region>:<account-id>:key/<your-kms-key-id>"
   }
   ```

## Cleanup

If you want to revert the image registry back to the default AWS-managed encryption:

1. Remove the `keyID` from the image registry configuration:

   ```bash
   oc patch configs.imageregistry.operator.openshift.io cluster --type json \
     --patch '[{"op": "remove", "path": "/spec/storage/s3/keyID"}]'
   ```

1. Remove the KMS policy from the image registry operator role:

   ```bash
   aws iam delete-role-policy \
     --role-name $REGISTRY_ROLE \
     --policy-name ImageRegistryKMSAccess
   ```

1. Optionally, schedule the KMS key for deletion:

   ```bash
   aws kms schedule-key-deletion \
     --key-id $KMS_KEY_ID \
     --region $REGION \
     --pending-window-in-days 7
   ```

   {{% alert state="warning" %}}
   Do not delete the KMS key while the image registry is still using it. Deleting the key renders all encrypted images in the registry permanently unreadable.
   {{% /alert %}}
