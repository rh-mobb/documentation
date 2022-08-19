# Configuring the Cluster Log Forwarder for CloudWatch Logs and STS

**DRAFT**

*Author: Paul Czarkowski*

*last edited: 2022-08-19*

This guide shows how to deploy the Cluster Log Forwarder operator and configure it to use STS authentication to forward logs to CloudWatch.

## Prerequisites

* A ROSA cluster (configured with STS)
* The `jq` cli command
* The `aws` cli command

### Environment Setup

1. Configure the following environment variables

   ```bash
   export ROSA_CLUSTER_NAME=my-cluster
   export ROSA_CLUSTER_ID=$(rosa describe cluster -c $ROSA_CLUSTER_NAME --output json | jq -r .id)
   export REGION=$(rosa describe cluster -c cz-test --output json | jq -r .region.id)
   export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o json | jq .spec.serviceAccountIssuer)
   export AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text`
   export AWS_PAGER=""
   export SCRATCH="/tmp/$ROSA_CLUSTER_NAME/clf-cloudwatch-sts"
   mkdir -p $SCRATCH
   ```

## Prepare AWS Account

1. Create an IAM Policy for OpenShift Log Forwarding

   ```bash
   cat << EOF > $SCRATCH/policy.json
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
   --policy-document file:///$SCRATCH/policy.json --query Policy.Arn --output text)
   echo $POLICY_ARN
   ```

1. Create an IAM Role trust policy for the cluster

   ```bash
   cat <<EOF > trust-policy.json
   {
   "Version": "2012-10-17",
   "Statement": [
   {
   "Effect": "Allow",
   "Principal": {
      "Federated": "arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/$ROSA_CLUSTER_ID"
   },
   "Action": "sts:AssumeRoleWithWebIdentity"
   }
   ]
   }
   EOF
   ROLE_ARN=$(aws iam create-role --role-name "${ROSA_CLUSTER_NAME}-RosaCloudWatch" \
      --assume-role-policy-document file://trust-policy.json \
      --query Role.Arn --output text)
   echo $ROLE_ARN
   ```

1. Attach the IAM Policy to the IAM Role

   ```bash
   aws iam attach-role-policy --role-name "${ROSA_CLUSTER_NAME}-RosaCloudWatch" \
   --policy-arn $POLICY_ARN
   ```

## Deploy Operators

<!--
1. Create OperatorGroup

```bash
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  labels:
    hive.openshift.io/managed: "true"
  name: openshift-logging
  namespace: openshift-logging
spec:
  targetNamespaces:
  - openshift-logging
  upgradeStrategy: Default
```
-->

1. Deploy the cluster logging operator

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
   startingCSV: cluster-logging.5.5.0
   ```

1. Deploy the Elasticsearch operator

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
   labels:
      operators.coreos.com/elasticsearch-operator.openshift-operators-redhat: ""
   name: elasticsearch-operator
   namespace: openshift-operators-redhat
   spec:
   channel: stable
   installPlanApproval: Automatic
   name: elasticsearch-operator
   source: redhat-operators
   sourceNamespace: openshift-marketplace
   startingCSV: elasticsearch-operator.5.5.0
   EOF
   ```

1. Create a secret

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
   name: cloudwatch-credentials
   namespace: openshift-logging
   stringData:
   credentials: |
      [default]
      role_arn = $ROLE_ARN
      web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
   role_arn: $ROLE_ARN
   EOF
   ```

## Configure Cluster Logging

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
      type: fluentd
   logStore:
      elasticsearch:
         nodeCount: 0
      type: elasticsearch
   visualization:
      kibana:
         replicas: 0
      type: kibana
   managementState: Managed
   EOF
   ```

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

## Check AWS CloudWatch for logs

...
