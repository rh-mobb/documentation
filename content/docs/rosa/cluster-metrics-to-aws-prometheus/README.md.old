## Prerequisites

* [A ROSA cluster deployed with STS](/docs/rosa/sts/)
* aws CLI
* jq

### Preparing Environment

1. Validate that your cluster has STS

    ```bash
    oc get authentication.config.openshift.io cluster -o json \
    | jq .spec.serviceAccountIssuer
    ```

    You should see something like the following, if not, you could try adding support yourself like [this](https://cloud.redhat.com/blog/fine-grained-iam-roles-for-openshift-applications), but YMMV.

    ```
    "https://rh-oidc.s3.us-east-1.amazonaws.com/xxxxxx"
    ```

1. Create some environment variables to refer to later

    ```bash
    export ROSA_CLUSTER_NAME=mycluster
    export ROSA_CLUSTER_ID=$(rosa describe cluster -c $ROSA_CLUSTER_NAME --output json | jq -r .id)
    export AWS_REGION=us-east-2 \
    export OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer| sed -e "s/^https:\/\///")
    export AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text`
    export SERVICE_ACCOUNT_NAMESPACE=aws-prometheus-proxy
    export SERVICE_ACCOUNT_AMP_INGEST_NAME=aws-prometheus-proxy
    export SERVICE_ACCOUNT_IAM_AMP_INGEST_ROLE=amp-iamproxy-ingest-role
    export SERVICE_ACCOUNT_IAM_AMP_INGEST_POLICY=AMPIngestPolic
    export AWS_PAGER=""
    ```

1. Create AWS Roles and Policies

    ```bash
    export ROLE_ARN=$(./create-aws-roles.sh | tail -1)
    ```

1. Create Namespace

    ```bash
    oc new-project $SERVICE_ACCOUNT_NAMESPACE
    ```

1. Create Service Account

    ```bash
    oc create serviceaccount -n $SERVICE_ACCOUNT_NAMESPACE \
      $SERVICE_ACCOUNT_AMP_INGEST_NAME
    ```
1. Annotate the service account with the role ARN from above

    ```bash
    oc annotate -n $SERVICE_ACCOUNT_NAMESPACE \
      serviceaccount $SERVICE_ACCOUNT_AMP_INGEST_NAME \
      eks.amazonaws.com/role-arn=$ROLE_ARN
    ```

1. Create AWS Metrics Proxy

    ```bash
cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aws-sigv4-proxy
  labels:
    app: aws-sigv4-proxy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: aws-sigv4-proxy
  template:
    metadata:
      labels:
        app: aws-sigv4-proxy
    spec:
      serviceAccount: $SERVICE_ACCOUNT_AMP_INGEST_NAME
      containers:
        - name: aws-sigv4-proxy
          image: public.ecr.aws/aws-observability/aws-sigv4-proxy:1.0
          args:
            - --name
            - aps
            - --region
            - ${AWS_REGION}
            - --host
            - aps-workspaces.${AWS_REGION}.amazonaws.com
            - --port
            - :8005
          ports:
          - name: aws-sigv4-proxy
            containerPort: 8005
---
apiVersion: v1
kind: Service
metadata:
  name: aws-sigv4-proxy
spec:
  selector:
    app: aws-sigv4-proxy
  ports:
    - protocol: TCP
      port: 8005
      targetPort: 8005
EOF
    ```


1. Append remoteWrite settings to the cluster-monitoring config to forward cluster metrics to Thanos.

    ```bash
    oc -n openshift-monitoring edit configmaps cluster-monitoring-config
    ```

    ```yaml
      data:
        config.yaml: |
          ...
          prometheusK8s:
          ...
            remoteWrite:
              - url: "http://aws-sigv4-proxy.aws-prometheus-proxy.svc.cluster.local:8005/workspaces/ws-0d99e6d0-ab1d-41b8-b706-3b1c2306757b/api/v1/remote_write"
    ```

## Grafana

1. Create a values file

    ```bash
cat << EOF > grafana-values.yaml
serviceAccount:
    create: false
    name: "${SERVICE_ACCOUNT_AMP_INGEST_NAME}"
grafana.ini:
  auth:
    sigv4_auth_enabled: true
EOF
    ```

1. Load the Grafana Helm Repo

    ```bash
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo update
    ```

1. Allow Grafana to be evil

    ```bash
    oc -n $SERVICE_ACCOUNT_NAMESPACE adm policy \
          add-scc-to-user privileged -z $SERVICE_ACCOUNT_AMP_INGEST_NAME
    ```

1. Install Grafana

    ```bash
    helm upgrade --install grafana grafana/grafana \
      -n $SERVICE_ACCOUNT_NAMESPACE -f ./grafana-values.yaml
    ```

1. Create a Grafana Datasource

    1. log into Grafana using the instructions from Helm

    1. Create a new Datasource.

      **URL:** https://aps-workspaces.us-east-2.amazonaws.com/workspaces/<workspace id>

      **Auth SigV4 Auth:** Enabled

      **Save & test**

1. Explore Metrics

    1. use PromQL `prometheus_tsdb_head_series` to see if the Grafana datasource is working.
