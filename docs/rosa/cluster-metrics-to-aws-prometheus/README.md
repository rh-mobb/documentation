# ROSA - Federating Metrics to AWS Prometheus

Federating Metrics from ROSA/OSD is a bit tricky as the cluster metrics require pulling from its `/federated` endpoint while the user workload metrics require using the prometheus `remoteWrite` configuration.

This guide will walk you through using the MOBB Helm Chart to deploy the necessary agents to federate the metrics into AWS Prometheus and then use Grafana to visualize those metrics.

As a bonus it will set up a CloudWatch datasource to view any metrics or logs you have in Cloud Watch.

## Prerequisites

* [A ROSA cluster deployed with STS](/docs/rosa/sts/)
* aws CLI
* jq

## Set up environment

1. Create environment variables

    ```bash
    export CLUSTER=my-cluster
    export PROM_NAMESPACE=custom-metrics
    export PROM_SA=aws-prometheus-proxy
    oc new-project $PROM_NAMESPACE
    export SCRATCH_DIR=/tmp/scratch
    mkdir -p $SCRATCH_DIR
    ```

1. Create namespace

    ```bash
    kubectl create namespace $PROM_NAMESPACE
    ```

## Deploy Operators

1. Create namespaces

    ```bash
    kubectl create resource-locker-operator
    ```

1. Add the MOBB chart repository to your Helm

    ```bash
    helm repo add mobb https://rh-mobb.github.io/helm-charts/
    ```

1. Update your repositories

    ```bash
    helm repo update
    ```

1. Use the `mobb/operatorhub` chart to deploy the needed operators

    ```bash
    helm upgrade -n $PROM_NAMESPACE custom-metrics-operators \
      mobb/operatorhub --version 0.1.0 --install \
      --values https://raw.githubusercontent.com/rh-mobb/helm-charts/main/charts/rosa-aws-prometheus/files/operatorhub.yaml
    ```

1. Update the Grafana Operator image

    > Note: This is a temporary fix for the Grafana Operator image until [#609](https://github.com/grafana-operator/grafana-operator/pull/609) is cut into a release.

    ```bash
    oc -n $PROM_NAMESPACE patch ClusterServiceVersion grafana-operator.v4.0.1 --type merge --patch '{"spec":{"install":{"spec":{"deployments":[{"spec":{"template":{"spec":{"containers":[{"name": "manager","image":"paulczar/grafana-operator:v4.0.1"}]}}}}]}}}}'
    ```

### Deploy and Configure the AWS Sigv4 Proxy and the Grafana Agent

1. Create a Policy for access to AWS Prometheus

    ```bash
cat <<EOF > $SCRATCH_DIR/PermissionPolicyIngest.json
{
  "Version": "2012-10-17",
   "Statement": [
       {"Effect": "Allow",
        "Action": [
           "aps:RemoteWrite",
           "aps:GetSeries",
           "aps:GetLabels",
           "aps:GetMetricMetadata"
        ],
        "Resource": "*"
      }
   ]
}
EOF
    ```

1. Apply the Policy

    ```bash
    $PROM_POLICY=$(aws iam create-policy --policy-name $PROM_SA-prom \
      --policy-document file://$SCRATCH_DIR/PermissionPolicyIngest.json \
      --query 'Policy.Arn' --output text)
    ```
1. Create a Policy for access to AWS CloudWatch

    ```bash
cat <<EOF > $SCRATCH_DIR/PermissionPolicyCloudWatch.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowReadingMetricsFromCloudWatch",
            "Effect": "Allow",
            "Action": [
                "cloudwatch:DescribeAlarmsForMetric",
                "cloudwatch:DescribeAlarmHistory",
                "cloudwatch:DescribeAlarms",
                "cloudwatch:ListMetrics",
                "cloudwatch:GetMetricStatistics",
                "cloudwatch:GetMetricData"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowReadingLogsFromCloudWatch",
            "Effect": "Allow",
            "Action": [
                "logs:DescribeLogGroups",
                "logs:GetLogGroupFields",
                "logs:StartQuery",
                "logs:StopQuery",
                "logs:GetQueryResults",
                "logs:GetLogEvents"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowReadingTagsInstancesRegionsFromEC2",
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeTags",
                "ec2:DescribeInstances",
                "ec2:DescribeRegions"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowReadingResourcesForTags",
            "Effect": "Allow",
            "Action": "tag:GetResources",
            "Resource": "*"
        }
    ]
}
EOF
    ```

1. Apply the Policy

    ```bash
    $CW_POLICY=$(aws iam create-policy --policy-name $PROM_SA-cw \
      --policy-document file://$SCRATCH_DIR/PermissionPolicyIngest.json \
      --query 'Policy.Arn' --output text)
    ```


1. Create a Trust Policy

    ```bash
cat <<EOF > $SCRATCH_DIR/TrustPolicy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": [
            "system:serviceaccount:${PROM_NAMESPACE}:${PROM_SA}",
            "system:serviceaccount:${PROM_NAMESPACE}:grafana-serviceaccount",
          ]
        }
      }
    }
  ]
}
EOF
    ```

1. Create Role for AWS Prometheus and CloudWatch

    ```bash
    PROM_ROLE=$(aws iam create-role \
      --role-name "prometheus-$CLUSTER" \
      --assume-role-policy-document file://$SCRATCH_DIR/TrustPolicy.json \
      --query "Role.Arn" --output text)
    echo $PROM_ROLE
    ```

1. Attach the Policies to the Role

    ```bash
    aws iam attach-role-policy \
      --role-name "prometheus-$CLUSTER" \
      --policy-arn $PROM_POLICY

    aws iam attach-role-policy \
      --role-name "prometheus-$CLUSTER" \
      --policy-arn $CW_POLICY
    ```

1. Create an AWS Prometheus Workspace

    ```bash
    $PROM_WS=$(aws amp create-workspace --alias $CLUSTER \
      --query "workspaceId" -- output text)
    echo $PROM_WS
    ```

1. Deploy AWS Prometheus Proxy Helm Chart

    ```bash
    helm upgrade --install -n $PROM_NAMESPACE --set "aws.region=$CLUSTER_REGION" --set "aws.roleArn=$PROM_ROLE" --set "fullnameOverride=$PROM_SA" --set "aws.workspaceId=$PROM_WS" \
    --set "grafana-cr.serviceAccountAnnotations.eks\.amazonaws\.com/role-arn=$PROM_ROLE" \
     aws-prometheus-proxy mobb/rosa-aws-prometheus
    ```

1. Configure remoteWrite for user workloads

    ```bash
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    kubernetes:
      remoteWrite:
        - url: "http://aws-prometheus-proxy.$PROM_NAMESPACE.svc.cluster.local:8005/workspaces/$PROM_WS/api/v1/remote_write"
EOF
    ```


Access Grafana and check for metrics.
