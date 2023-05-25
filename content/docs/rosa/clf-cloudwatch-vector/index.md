---
date: '2022-10-21'
title: Configuring the Cluster Log Forwarder for CloudWatch Logs using Vector
tags: ["AWS", "ROSA"]
authors:
  - Thatcher Hubbard
  - Connor Wooley
---

This guide shows how to deploy the Cluster Log Forwarder operator and configure it to use the [Vector](https://vector.dev) logging agent to forward logs to CloudWatch.

> Vector will replaced FluentD as the default logging agent used by the Openshift Logging Operator when version 5.6 is released in Q4 2022. Version 5.5.3 of the operator can enable Vector by configuring it in the `ClusterLogging` resource.

> Version 5.5.3 of the operator **does not** support passing an STS role to Vector, but version 5.6 **will**. Until 5.6 is released, using Vector will require passing traditional IAM creds, but the conversion from IAM to STS will be relatively straightforward and will be documented here when it's available.

## Prerequisites

* A ROSA cluster (configured with STS)
* The `jq` cli command
* The `aws` cli command

### Environment Setup

1. Configure the following environment variables

   > Change the cluster name to match your ROSA cluster and ensure you're logged into the cluster as an Administrator. Ensure all fields are outputted correctly before moving on.

   ```bash
   export ROSA_CLUSTER_NAME=<cluster_name>
   export ROSA_CLUSTER_ID=$(rosa describe cluster -c ${ROSA_CLUSTER_NAME} --output json | jq -r .id)
   export REGION=$(rosa describe cluster -c ${ROSA_CLUSTER_NAME} --output json | jq -r .region.id)
   export AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text`
   export AWS_PAGER=""
   export SCRATCH="/tmp/${ROSA_CLUSTER_NAME}/clf-cloudwatch-vector"
   mkdir -p ${SCRATCH}
   echo "Cluster ID: ${ROSA_CLUSTER_ID}, Region: ${REGION}, AWS Account ID: ${AWS_ACCOUNT_ID}"
   ```

## Prepare AWS Account

1. Create an IAM Policy for OpenShift Log Forwarding

   ```bash
   POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='RosaCloudWatch'].{ARN:Arn}" --output text)
   if [[ -z "${POLICY_ARN}" ]]; then
   cat << EOF > ${SCRATCH}/policy.json
   {
   "Version": "2012-10-17",
   "Statement": [
      {
            "Effect": "Allow",
            "Action": [
               "logs:CreateLogGroup",
               "logs:CreateLogStream",
               "logs:DescribeLogGroups",
               "logs:DescribeLogStreams",
               "logs:PutLogEvents",
               "logs:PutRetentionPolicy"
            ],
            "Resource": "arn:aws:logs:*:*:*"
      }
   ]
   }
   EOF
   POLICY_ARN=$(aws iam create-policy --policy-name "RosaCloudWatch" \
   --policy-document file:///${SCRATCH}/policy.json --query Policy.Arn --output text)
   fi
   echo ${POLICY_ARN}
   ```

1. Create an IAM user for logging

   ```bash
    aws iam create-user \
      --user-name $ROSA_CLUSTER_NAME-cloud-watch \
      > $SCRATCH/aws-user.json
    ```

1. Fetch Access and Secret Keys for IAM User

    ```bash
    aws iam create-access-key \
      --user-name $ROSA_CLUSTER_NAME-cloud-watch \
      > $SCRATCH/aws-access-key.json
    ```

1. Attach Policy to AWS IAM User

    ```bash
    aws iam attach-user-policy \
      --user-name $ROSA_CLUSTER_NAME-cloud-watch \
      --policy-arn ${POLICY_ARN}
    ```

1. Create an OCP Secret to hold the AWS creds:

   ```bash
   AWS_ID=`cat $SCRATCH/aws-access-key.json | jq -r '.AccessKey.AccessKeyId'`
   AWS_KEY=`cat $SCRATCH/aws-access-key.json | jq -r '.AccessKey.SecretAccessKey'`

   cat << EOF | oc apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
      name: cloudwatch-credentials
      namespace: openshift-logging
   stringData:
      aws_access_key_id: $AWS_ID
      aws_secret_access_key: $AWS_KEY
   EOF
   ```

## Deploy Operators

1. Deploy the Cluster Logging operator

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     labels:
      operators.coreos.com/cluster-logging.openshift-logging: ""
     name: cluster-logging
     namespace: openshift-logging
   spec:
     channel: stable
     installPlanApproval: Automatic
     name: cluster-logging
     source: redhat-operators
     sourceNamespace: openshift-marketplace
     startingCSV: cluster-logging.5.5.3
   EOF
   ```

## Configure Cluster Logging

1. Create a cluster log forwarding resource

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: "logging.openshift.io/v1"
   kind: ClusterLogForwarder
   metadata:
      name: instance
      namespace: openshift-logging
   spec:
   outputs:
      - name: cw
         type: cloudwatch
         cloudwatch:
         groupBy: namespaceName
         groupPrefix: rosa-${ROSA_CLUSTER_NAME}
         region: ${REGION}
         secret:
         name: cloudwatch-credentials
   pipelines:
      - name: to-cloudwatch
         inputRefs:
         - infrastructure
         - audit
         - application
         outputRefs:
         - cw
   EOF
   ```

1. Create a cluster logging resource

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: logging.openshift.io/v1
   kind: ClusterLogging
   metadata:
   name: instance
   namespace: openshift-logging
   spec:
   collection:
      logs:
         type: vector
         vector: {}
   forwarder:
   managementState: Managed
   EOF
   ```

## Check AWS CloudWatch for logs

1. Use the AWS console or CLI to validate that there are log streams from the cluster

   > Note: If this is a fresh cluster you may not see a log group for `application` logs as there are no applications running yet.

   ```bash
   aws logs describe-log-groups --log-group-name-prefix rosa-${ROSA_CLUSTER_NAME}
   ```

   ```
   {
      "logGroups": [
         {
               "logGroupName": "rosa-xxxx.audit",
               "creationTime": 1661286368369,
               "metricFilterCount": 0,
               "arn": "arn:aws:logs:us-east-2:xxxx:log-group:rosa-xxxx.audit:*",
               "storedBytes": 0
         },
         {
               "logGroupName": "rosa-xxxx.infrastructure",
               "creationTime": 1661286369821,
               "metricFilterCount": 0,
               "arn": "arn:aws:logs:us-east-2:xxxx:log-group:rosa-xxxx.infrastructure:*",
               "storedBytes": 0
         }
      ]
   }
   ```

### Cleanup

1. Delete the Cluster Log Forwarding resource

   ```bash
   oc delete -n openshift-logging clusterlogforwarder instance
   ```

1. Delete the Cluster Logging resource

   ```bash
   oc delete -n openshift-logging clusterlogging instance
   ```

1. Delete the IAM credential secret

   ```bash
   oc -n openshift-logging delete secret cloudwatch-credentials
   ```

1. Detach the IAM Policy to the IAM Role

   ```bash
   aws iam detach-user-policy --user-name "$ROSA_CLUSTER_NAME-cloud-watch" \
   --policy-arn "${POLICY_ARN}"

  ```

1. Delete the IAM User access keys

   ```bash
   aws iam delete-access-key --user-name "$ROSA_CLUSTER_NAME-cloud-watch" \
   --access-key-id "${AWS_ID}"

1. Delete the IAM User

   ```bash
   aws iam delete-user --user-name "$ROSA_CLUSTER_NAME-cloud-watch"
   ```

1. Delete the IAM Policy

   > Only run this command if there are no other resources using the Policy

   ```bash
   aws iam delete-policy --policy-arn "${POLICY_ARN}"
   ```

1. Delete the CloudWatch Log Groups

   > If there are any user workloads on the cluster they'll have their own log groups that will also need to be deleted

   ```bash
   aws logs delete-log-group --log-group-name "rosa-${ROSA_CLUSTER_NAME}.audit"
   aws logs delete-log-group --log-group-name "rosa-${ROSA_CLUSTER_NAME}.infrastructure"
   ```
