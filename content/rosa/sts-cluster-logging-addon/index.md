---
date: '2021-11-02'
title: Work Around to fix the issue with the logging-addon on ROSA STS Clusters
tags: ["AWS", "ROSA", "STS"]
authors:
  - Connor Wooley
---

Currently, the logging-addon is not working on ROSA STS clusters. This is due to permissions missing from the Operator itself. This is a work around to provide credentials to the addon.

> **Note:** Please see the official [Red Hat KCS](https://access.redhat.com/solutions/6485391) for more information.

## Prerequisites

1. An STS based ROSA Cluster

## Workaround

1. Uninstall the logging-addon from the cluster

    ```bash
    rosa uninstall addon -c <mycluster> cluster-logging-operator -y
    ```

1. Create a IAM Trust Policy document

    ```bash
    cat << EOF > /tmp/trust-policy.json
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
                    "logs:GetLogEvents",
                    "logs:PutRetentionPolicy",
                    "logs:GetLogRecord"
                ],
                "Resource": "arn:aws:logs:*:*:*"
            }
        ]
    }
    EOF
    ```

1. Create IAM Policy

    ```bash
    POLICY_ARN=$(aws iam create-policy --policy-name "RosaCloudWatchAddon" --policy-document file:///tmp/trust-policy.json --query Policy.Arn --output text)
    echo $POLICY_ARN
    ```

1. Create service account

    ```bash
    aws iam create-user --user-name RosaCloudWatchAddon  \
      --query User.Arn --output text
    ```

1. Attach policy to user

    ```bash
    aws iam attach-user-policy --user-name RosaCloudWatchAddon \
      --policy-arn ${POLICY_ARN}
    ```

1. Create access key and save the output (Paste the `AccessKeyId` and `SecretAccessKey` into `values.yaml`)

    ```bash
    aws iam create-access-key --user-name RosaCloudWatchAddon
    ```

    ```bash
    export AWS_ID=<from above>
    export AWS_KEY=<from above>
    ```

1. Create a secret for the addon to use

    ```bash
    cat << EOF | kubectl apply -f -
    apiVersion: v1
    kind: Secret
    metadata:
     name: instance
     namespace: openshift-logging
    stringData:
      aws_access_key_id: ${AWS_ID}
      aws_secret_access_key: ${AWS_KEY}
    EOF
    ```

1. Install the logging-addon from the cluster

    ```bash
    rosa install addon -c <mycluster> cluster-logging-operator -y
    ```

    Accept the defaults (or change them as appropriate)

    ```
    ? Use AWS CloudWatch: Yes
    ? Collect Applications logs: Yes
    ? Collect Infrastructure logs: Yes
    ? Collect Audit logs (optional): No
    ? CloudWatch region (optional):
    I: Add-on 'cluster-logging-operator' is now installing. To check the status run 'rosa list addons -c mycluster'
    ```
