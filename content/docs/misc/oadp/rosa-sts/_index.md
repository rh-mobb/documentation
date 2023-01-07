---
date: '2022-09-14T22:07:09.804151'
title: Deploying OpenShift Advanced Data Protection on a ROSA cluster
tags: ["ROSA", "AWS", "STS"]
---

## Prerequisites

* [An STS enabled ROSA cluster](./docs/rosa/sts)

## Getting Started

1. Create the following environment variables

   > Change the cluster name to match your ROSA cluster and ensure you're logged into the cluster as an Administrator. Ensure all fields are outputted correctly before moving on.

   ```bash
   export CLUSTER_NAME=my-cluster
   export ROSA_CLUSTER_ID=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .id)
   export REGION=$(rosa describe cluster -c ${CLUSTER_NAME} --output json | jq -r .region.id)
   export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer)
   export AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text`
   export CLUSTER_VERSION=`rosa describe cluster -c ${CLUSTER_NAME} -o json | jq -r .version.raw_id | cut -f -2 -d '.'`
   export ROLE_NAME="${CLUSTER_NAME}-openshift-oadp-aws-cloud-credentials"
   export AWS_PAGER=""
   export SCRATCH="/tmp/${CLUSTER_NAME}/oadp"
   mkdir -p ${SCRATCH}
   echo "Cluster ID: ${ROSA_CLUSTER_ID}, Region: ${REGION}, OIDC Endpoint: ${OIDC_ENDPOINT}, AWS Account ID: ${AWS_ACCOUNT_ID}"
   ```

## Prepare AWS Account

1. Create an IAM Policy to allow for S3 Access

   ```bash
   POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='RosaOadp'].{ARN:Arn}" --output text)
   if [[ -z "${POLICY_ARN}" ]]; then
   cat << EOF > ${SCRATCH}/policy.json
   {
   "Version": "2012-10-17",
   "Statement": [
     {
       "Effect": "Allow",
       "Action": [
         "s3:CreateBucket",
         "s3:DeleteBucket",
         "s3:PutBucketTagging",
         "s3:GetBucketTagging",
         "s3:PutEncryptionConfiguration",
         "s3:GetEncryptionConfiguration",
         "s3:PutLifecycleConfiguration",
         "s3:GetLifecycleConfiguration",
         "s3:GetBucketLocation",
         "s3:ListBucket",
         "s3:GetObject",
         "s3:PutObject",
         "s3:DeleteObject",
         "s3:ListBucketMultipartUploads",
         "s3:AbortMultipartUpload",
         "s3:ListMultipartUploadParts",
         "ec2:DescribeSnapshots",
         "ec2:CreateTags",
         "ec2:CreateVolume",
         "ec2:CreateSnapshot",
         "ec2:DeleteSnapshot"
       ],
       "Resource": "*"
     }
    ]}
   EOF
   POLICY_ARN=$(aws iam create-policy --policy-name "RosaOadp" \
   --policy-document file:///${SCRATCH}/policy.json --query Policy.Arn \
   --tags Key=rosa_openshift_version,Value=4.9 Key=rosa_role_prefix,Value=ManagedOpenShift Key=operator_namespace,Value=openshift-oadp Key=operator_name,Value=openshift-oadp \
   --output text)
   fi
   echo ${POLICY_ARN}
   ```

1. Create an IAM Role trust policy for the cluster

   ```bash
   cat <<EOF > ${SCRATCH}/trust-policy.json
   {
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {
          "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/${ROSA_CLUSTER_ID}"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
             "rh-oidc.s3.us-east-1.amazonaws.com/${ROSA_CLUSTER_ID}:sub": [
               "system:serviceaccount:openshift-adp:openshift-adp-controller-manager",
               "system:serviceaccount:openshift-adp:velero"]
          }
        }
      }]
   }
   EOF
   ROLE_ARN=$(aws iam create-role --role-name \
     "${ROLE_NAME}" \
      --assume-role-policy-document file://${SCRATCH}/trust-policy.json \
      --tags Key=rosa_cluster_id,Value=${ROSA_CLUSTER_ID} Key=rosa_openshift_version,Value=${CLUSTER_VERSION} Key=rosa_role_prefix,Value=ManagedOpenShift Key=operator_namespace,Value=openshift-adp Key=operator_name,Value=openshift-oadp \
      --query Role.Arn --output text)

   echo ${ROLE_ARN}
   ```

1. Attach the IAM Policy to the IAM Role

   ```bash
   aws iam attach-role-policy --role-name "${ROLE_NAME}" \
     --policy-arn ${POLICY_ARN}
   ```

## Deploy OADP on cluster

1. Create a namespace for OADP

   ```bash
   oc create namespace openshift-adp
   ```

1. Create a credentials secret

   ```bash
   cat <<EOF > ${SCRATCH}/credentials
   [default]
   role_arn = ${ROLE_ARN}
   web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
   EOF
   oc -n openshift-adp create secret generic cloud-credentials \
     --from-file=${SCRATCH}/credentials
   ```

1. Deploy OADP Operator

   ```bash
   cat << EOF | oc create -f -
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     generateName: openshift-adp-
     namespace: openshift-adp
     name: oadp
   spec:
     targetNamespaces:
     - openshift-adp
   ---
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     labels:
       operators.coreos.com/oadp-operator.openshift-adp: ""
     name: oadp-operator
     namespace: openshift-adp
   spec:
     channel: stable
     installPlanApproval: Automatic
     name: oadp-operator
     source: community-operators
     sourceNamespace: openshift-marketplace
     startingCSV: oadp-operator.v0.5.6
   EOF
   ```

1. Wait for the operator to be ready

   ```bash
   watch oc -n openshift-adp get pods
   ```

   ```
   NAME                                                READY   STATUS    RESTARTS   AGE
   openshift-adp-controller-manager-546684844f-qqjhn   1/1     Running   0          22s
   ```

1. Create Cloud Storage

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

1. Deploy a Data Protection Application

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
     configuration:
       velero:
         defaultPlugins:
         - openshift
         - aws
         restic:
           enable: false
     volumeSnapshots:
     - velero:
         config:
           credentialsFile: /tmp/credentials/openshift-adp/cloud-credentials-credentials
           enableSharedConfig: "true"
           region: ${REGION}
         provider: aws
   EOF
   ```

## Perform a backup

1. Create a workload to backup

   ```bash
   oc create namespace hello-world
   oc new-app -n hello-world --docker-image=docker.io/openshift/hello-openshift
   ```

1. Backup workload

   ```bash
   cat << EOF | oc create -f -
   apiVersion: velero.io/v1
   kind: Backup
   metadata:
     name: hello-world
     namespace: openshift-adp
   spec:
     includedNamespaces:
     - hello-world
     storageLocation: ${CLUSTER_NAME}-dpa-1
     ttl: 720h0m0s
   EOF
   ```

1. Wait until backup is done

   ```bash
   watch "oc -n openshift-adp get backup hello-world -o json | jq .status"
   ```

   ```json
   {
     "completionTimestamp": "2022-09-07T22:20:44Z",
     "expiration": "2022-10-07T22:20:22Z",
     "formatVersion": "1.1.0",
     "phase": "Completed",
     "progress": {
       "itemsBackedUp": 58,
       "totalItems": 58
     },
     "startTimestamp": "2022-09-07T22:20:22Z",
     "version": 1
   }
   ```

1. Delete the demo workload

   ```bash
   oc delete ns hello-world
   ```

1. Restore from the backup

   ```bash
   cat << EOF | oc create -f -
   apiVersion: velero.io/v1
   kind: Restore
   metadata:
     name: hello-world
     namespace: openshift-adp
   spec:
     backupName: hello-world
   EOF
   ```

1. Wait for the Restore to finish

   ```bash
   watch "oc -n openshift-adp get restore hello-world -o json | jq .status"
   ```

   ```
   {
     "completionTimestamp": "2022-09-07T22:25:47Z",
     "phase": "Completed",
     "progress": {
       "itemsRestored": 38,
       "totalItems": 38
     },
     "startTimestamp": "2022-09-07T22:25:28Z",
     "warnings": 9
   }
   ```

1. Check the workload is restored

   ```bash
   oc -n hello-world get pods
   ```

   ```
   NAME                              READY   STATUS    RESTARTS   AGE
   hello-openshift-9f885f7c6-kdjpj   1/1     Running   0          90s
   ```

## Cleanup

1. Delete the workload

   ```bash
   oc delete ns hello-world
   ```

1. Delete the Data Protection Application

   ```bash
   oc delete dpa ${CLUSTER_NAME}-dpa
   ```

1. Delete the Cloud Storage

   ```bash
   oc delete cloudstorage ${CLUSTER_NAME}-oadp
   ```
<<<<<<< HEAD:content/docs/misc/oadp/rosa-sts/_index.md
=======

1. Delete the AWS S3 Bucket

   ```bash
   aws s3 rm s3://${CLUSTER_NAME}-oadp --recursive
   aws s3api delete-bucket --bucket ${CLUSTER_NAME}-oadp
   ```

1. Detach the Policy from the role

   ```bash
   aws iam detach-role-policy --role-name "${ROLE_NAME}" \
     --policy-arn "${POLICY_ARN}"
   ```

1. Delete the role

   ```bash
   aws iam delete-role --role-name "${ROLE_NAME}"
   ```
>>>>>>> main:docs/misc/oadp/rosa-sts/README.md
