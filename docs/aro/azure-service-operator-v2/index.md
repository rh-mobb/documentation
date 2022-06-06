# Installing and Using the Azure Service Operator (ASO) V2 in Azure Red Hat OpenShift (ARO)

**Thatcher Hubbard**

The Azure Service Operator (ASO) provides Custom Resource Definitions (CRDs) for Azure resources that can be used to create, update, and delete Azure services from an OpenShift cluster.

> This example uses ASO V2, which is a replacement for ASO V1. Equivalent documentation for ASO V1 can be found [here](/azure-service-operator-v1). For new installs, V2 is recommended. MOBB has not tested running them in parallel.

## Prerequisites

* [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
* [An Azure Red Hat OpenShift (ARO) cluster](/quickstart-aro)
* The `cert-manager` operator installed on your ARO cluster (this is required by ASO), this can be done via the 'OperatorHub' in the ARO web console.
* The `helm` CLI tool

## Prepare your Azure Account and ARO Cluster

1. Set the following environment variables:

    > Note: modify the cluster name, region and resource group to match your cluster

    ```bash
AZURE_TENANT_ID=$(az account show -o tsv --query tenantId)
AZURE_SUBSCRIPTION_ID=$(az account show -o tsv --query id)
CLUSTER_NAME="th-testing"
#AZURE_RESOURCE_GROUP="th-openshift"
#AZURE_REGION="westus2"
    ```

1. Create a Service Principal with Contributor permissions to your subscription:

    > Note: You may want to lock this down to a specific resource group.

    ```bash
az ad sp create-for-rbac -n "$CLUSTER_NAME-aso" \
--role contributor --scopes /subscriptions/$AZURE_SUBSCRIPTION_ID
    ```

    The result should look something like this:

    ```json
    {
      "appId": "12f48391-31ac-4565-936a-8249232aeb18",
      "displayName": "th-testing-aso",
      "password": "xsr5Pz3IsPnnYxhsc7LhnNkY00cYxe.IPk",
      "tenant": "64dc69e4-d083-49fc-9569-ebece1dd1408"
    }
    ```

    You'll need two of these values for the Helm deploy of ASO:

    ```bash
    AZURE_CLIENT_ID=<the_appId_from_above>
    AZURE_CLIENT_SECRET=<the_password_from_above>
    ```


2. Deploy the ASO Operator using Helm:

    ```bash
    helm upgrade --install --devel aso2 aso2/azure-service-operator \
    --namespace=openshift-operators \
    --set azureSubscriptionID=$AZURE_SUBSCRIPTION_ID \
    --set azureTenantID=$AZURE_TENANT_ID \
    --set azureClientID=$AZURE_CLIENT_ID \
    --set azureClientSecret=$AZURE_CLIENT_SECRET
    ```

## Deploy an Azure Redis Cache

1. Create a Project:

    ```bash
oc new-project redis-demo
    ```

1. Allow the redis app to run as any user:

    ```bash
oc adm policy add-scc-to-user anyuid -z default
    ```

1. Create a random string to use as the unique redis hostname:

    ```bash
REDIS_HOSTNAME=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)
    ```

1. Deploy a Redis service using the ASO Operator and an example application

    ```
cat <<EOF | oc apply -f -
apiVersion: azure.microsoft.com/v1alpha1
kind: RedisCache
metadata:
  name: $REDIS_HOSTNAME
spec:
  location: $AZURE_REGION
  resourceGroup: $AZURE_RESOURCE_GROUP
  properties:
    sku:
      name: Basic
      family: C
      capacity: 1
    enableNonSslPort: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azure-vote-front
spec:
  replicas: 1
  selector:
    matchLabels:
      app: azure-vote-front
  template:
    metadata:
      labels:
        app: azure-vote-front
    spec:
      containers:
      - name: azure-vote-front
        image: mcr.microsoft.com/azuredocs/azure-vote-front:v1
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 250m
            memory: 256Mi
        ports:
        - containerPort: 80
        env:
        - name: REDIS_NAME
          value: $REDIS_HOSTNAME
        - name: REDIS
          value: $REDIS_HOSTNAME.redis.cache.windows.net
        - name: REDIS_PWD
          valueFrom:
            secretKeyRef:
              name: rediscache-$REDIS_HOSTNAME
              key: primaryKey
---
apiVersion: v1
kind: Service
metadata:
  name: azure-vote-front
spec:
  ports:
  - port: 80
  selector:
    app: azure-vote-front
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: azure-vote
spec:
  port:
    targetPort: 80
  tls:
    insecureEdgeTerminationPolicy: Redirect
    termination: edge
  to:
    kind: Service
    name: azure-vote-front
EOF
    ```

1. Wait for Redis to be ready

    > This may take 10 to 15 minutes.

    ```bash
    watch oc get rediscache $REDIS_HOSTNAME
    ```

    the output should eventually show the following:

    ```
    NAME       PROVISIONED   MESSAGE
    l67for49   true          successfully provisioned
    ```

1. Get the URL of the example app

    ```bash
    oc get route azure-vote
    ```

1. Browse to the URL provided by the previous command and validate that the app is working

![screenshot of voting app](./vote.png)

## Cleanup

1. Delete the project containing the demo app

    ```bash
    oc delete project redis-demo
    ```
