# Configuring the Cluster Log Forwarder for CloudWatch Logs and STS

**DRAFT**

*Author: Paul Czarkowski*

*last edited: 2022-08-31*

This guide shows how to deploy the Cluster Log Forwarder operator and configure it to use STS authentication to forward logs to CloudWatch.

## Prerequisites

* A ROSA cluster (configured with STS)
* The `jq` cli command
* The `aws` cli command

### Environment Setup

1. Configure the following environment variables

   > Change the cluster name to match your ROSA cluster and ensure you're logged into the cluster as an Administrator. Ensure all fields are outputted correctly before moving on.

   ```bash
   export ROSA_CLUSTER_NAME=my-cluster
   export ROSA_CLUSTER_ID=$(rosa describe cluster -c ${ROSA_CLUSTER_NAME} --output json | jq -r .id)
   export REGION=$(rosa describe cluster -c ${ROSA_CLUSTER_NAME} --output json | jq -r .region.id)
   export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer)
   export AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text`
   export AWS_PAGER=""
   export SCRATCH="/tmp/${ROSA_CLUSTER_NAME}/clf-cloudwatch-sts"
   mkdir -p ${SCRATCH}
   echo "Cluster ID: ${ROSA_CLUSTER_ID}, Region: ${REGION}, OIDC Endpoint: ${OIDC_ENDPOINT}, AWS Account ID: ${AWS_ACCOUNT_ID}"
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
            "rh-oidc.s3.us-east-1.amazonaws.com/${ROSA_CLUSTER_ID}:sub": "system:serviceaccount:openshift-logging:logcollector"
          }
        }
      }]
   }
   EOF
   ROLE_ARN=$(aws iam create-role --role-name "${ROSA_CLUSTER_NAME}-RosaCloudWatch" \
      --assume-role-policy-document file://${SCRATCH}/trust-policy.json \
      --query Role.Arn --output text)
   echo ${ROLE_ARN}
   ```

1. Attach the IAM Policy to the IAM Role

   ```bash
   aws iam attach-role-policy --role-name "${ROSA_CLUSTER_NAME}-RosaCloudWatch" \
   --policy-arn ${POLICY_ARN}
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
   EOF
   ```

1. Deploy the Elasticsearch operator

   > Note: This is only needed for CRDs and won't actually deploy a Elasticsearch cluster.

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
      name: openshift-operators-redhat
      namespace: openshift-operators-redhat 
   spec: {}
   EOF
   ```
 
   ```bash
   cat << EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: "elasticsearch-operator"
     namespace: "openshift-operators-redhat" 
   spec:
     channel: "stable" 
     installPlanApproval: "Automatic" 
     source: "redhat-operators" 
     sourceNamespace: "openshift-marketplace"
     name: "elasticsearch-operator"
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
     role_arn: $ROLE_ARN
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
          type: fluentd
     forwarder:
       fluentd: {}
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

1. Detach the IAM Policy to the IAM Role

   ```bash
   aws iam detach-role-policy --role-name "${ROSA_CLUSTER_NAME}-RosaCloudWatch" \
   --policy-arn "${POLICY_ARN}"
   ```

1. Delete the IAM Role

   ```bash
   aws iam delete-role --role-name "${ROSA_CLUSTER_NAME}-RosaCloudWatch"
   ```

1. Delete the IAM Policy

   > Only run this command if there are no other resources using the Policy

   ```bash
   aws iam delete-policy --policy-arn "${POLICY_ARN}"
   ```

1. Delete the CloudWatch Log Groups

   ```bash
   aws logs delete-log-group --log-group-name "rosa-${ROSA_CLUSTER_NAME}.audit"
   aws logs delete-log-group --log-group-name "rosa-${ROSA_CLUSTER_NAME}.infrastructure"
   ```
