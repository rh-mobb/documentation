---
title: Cluster Logging Forwarder to Loki using Vector and Managed Grafana
tags: ["ARO", "Azure", "ROSA", "Observability", "Logging", "Loki", "Vector", "Grafana"]
authors:
  - Dustin Scott
---

In many public cloud services, it is generally easy to forward logs to the native logging 
service for the public cloud (e.g. AWS/CloudWatch or Azure/Monitor).  However, the native 
logging services do not generally expose the best user experience for viewing logs and 
often times the native logging services are extremely costly.

In addition to the above, OpenShift Cluster Logging Operator will eventually plan to 
prefer moving to a Vector > Loki pattern for log aggregation rather than the 
traditional Fluentd.  This starts with [version 5.7](https://docs.openshift.com/container-platform/4.12/logging/v5_7/logging-5-7-configuration.html) 
of the logging operator.

This article covers sending logs to Loki using Vector as an object-storage backend 
in order to cut down on cost.  In addition, it covers using a managed Grafana service 
to improve the user experience for viewing log data.


## Prepare Cluster

Deploy one of the following clusters:
- [ARO Cluster](https://mobb.ninja/docs/quickstart-aro/)
- [ROSA Cluster](https://mobb.ninja/docs/quickstart-rosa/)

Set environment variables for Azure:

```bash
export AZR_RESOURCE_LOCATION=eastus
export AZR_RESOURCE_GROUP=aro-mobb-rg
export AZR_LOG_STORAGE_ACCOUNT=arologging
export AZR_ENVIRONMENT=AzureGlobal # NOTE: replace with AzureUSGovernment for MAG
export AZR_LOG_SIZE="1x.extra-small" # NOTE: supported values: "1x.extra-small", "1x.small", "1x.medium"
```

Set environment variables for AWS:

```bash
# TODO
```


## Prerequisite Tooling

- `az`
- `aws`
- `jq`
- `oc`


## Install Operators

Install the [Cluster Logging Operator](https://docs.openshift.com/container-platform/4.12/logging/config/cluster-logging-configuring-cr.html).  
This is used to configure log forwarding:

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
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

Install the [Loki Operator](https://docs.openshift.com/container-platform/4.12/logging/cluster-logging-loki.html).  This is 
used as the log backed for log forwarding:

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable
  installPlanApproval: Automatic
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```


### Install Grafana Operator (Self-Managed)

If you would like to simply deploy your own local Grafana instance instead of a
full-blown hyperscaler-managed Grafana, you can deploy Grafana locally to your cluster:

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: openshift-logging
spec:
  channel: v4
  installPlanApproval: Automatic
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
  startingCSV: grafana-operator.v4.10.1
EOF
```


## Configure Loki as a Backend


### Azure

1. Create an Azure Storage Account for Loki logs:

```bash
az storage account create \
  -n $AZR_LOG_STORAGE_ACCOUNT \
  -g $AZR_RESOURCE_GROUP \
  -l $AZR_RESOURCE_LOCATION \
  --sku Standard_LRS
```

2. Create blob container storage for storing Loki logs:

```bash
az storage container create \
  -n $AZR_LOG_STORAGE_ACCOUNT \
  --account-name $AZR_LOG_STORAGE_ACCOUNT
```

3. Retrieve the storage account key:

```bash
export AZR_STORAGE_ACCOUNT_KEY=$(az storage account keys list -n $AZR_LOG_STORAGE_ACCOUNT --query '[0].value' -o tsv)
```

4. Create a secret containing storage credentials:

```bash
oc create secret generic $AZR_LOG_STORAGE_ACCOUNT \
  --namespace=openshift-logging \
  --from-literal=container=$AZR_LOG_STORAGE_ACCOUNT \
  --from-literal=environment=$AZR_ENVIRONMENT \
  --from-literal=account_name=$AZR_LOG_STORAGE_ACCOUNT \
  --from-literal=account_key=$AZR_STORAGE_ACCOUNT_KEY
```

5. Create the `LokiStack` resource:

```bash
cat <<EOF | oc apply -f -
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: $AZR_LOG_STORAGE_ACCOUNT
  namespace: openshift-logging
spec:
  size: $AZR_LOG_SIZE
  storage:
    schemas:
      - version: v12
        effectiveDate: "2022-06-01"
    secret:
      name: $AZR_LOG_STORAGE_ACCOUNT
      type: azure
  storageClassName: managed-csi
  tenants:
    mode: openshift-logging
EOF
```


### AWS

TODO


## Configure Log Forwarding to Loki

To configure log forwarding to Loki, deploy a `ClusterLogging` resource:

```bash
cat <<EOF | oc apply -f -
apiVersion: logging.openshift.io/v1
kind: ClusterLogging
metadata:
  name: instance
  namespace: openshift-logging
spec:
  managementState: Managed
  logStore:
    type: lokistack
    lokistack:
      name: $AZR_LOG_STORAGE_ACCOUNT
  collection:
    type: vector
EOF
```


## Deploy Grafana


### Azure

1. Create the Grafana Service using the Azure CLI:

```bash
az grafana create \
  -n $AZR_LOG_STORAGE_ACCOUNT \
  -g $AZR_RESOURCE_GROUP
```

> **NOTE** Be sure to follow the [Azure Documentation for creating Private Endpoints](https://learn.microsoft.com/en-us/azure/private-link/create-private-endpoint-cli?tabs=dynamic-ip) 
if your service needs to be behind a private endpoint.  Also see documentation for 
[creating private endpoints for managed grafana](https://learn.microsoft.com/en-us/azure/managed-grafana/how-to-connect-to-data-source-privately#supported-azure-data-sources).

2. Find the URL associated with the Grafana Service.  You will use this to login 
to the service in the next step:

```bash
az grafana show \
  -n $AZR_LOG_STORAGE_ACCOUNT \
  -g $AZR_RESOURCE_GROUP \
  --query 'properties.endpoint' -o tsv
```


### AWS

TODO


### Self-Managed

If you would like to simply deploy your own local Grafana instance instead of a
full-blown hyperscaler-managed Grafana, you can deploy Grafana locally to your cluster:

```bash
cat << EOF | oc apply -f -
apiVersion: integreatly.org/v1alpha1
kind: Grafana
metadata:
  name: $AZR_LOG_STORAGE_ACCOUNT
  namespace: openshift-logging
spec:
  adminPassword: bad-password
  adminUser: admin
  basicAuth: true
  config:
    auth:
      disable_signout_menu: false
    auth.anonymous:
      enabled: false
    log:
      level: warn
      mode: console
    security:
      admin_password: secret
      admin_user: root
  dashboardLabelSelector:
    - matchExpressions:
        - key: app
          operator: In
          values:
            - grafana
  ingress:
    enabled: true
EOF
```

Note that you will login with the following credentials:

```yaml
admin_password: secret
admin_user: root
```


## Find the Loki Information Needed for Grafana Integration

For managed Grafana (e.g. Azure-managed or AWS-managed):

```bash
TODO
```

For self-managed Grafana:

```bash
export GRAFANA_URL=http://arologging-ingester-http:3100
```


## Configure Grafana

> **IMPORTANT** The following documentation images may vary slightly between 
Azure/AWS/Self-Managed, but should be relatively similar.

1. Once logged in, navigate to `Configuration > Data Sources`.


## View Logs in Grafana
