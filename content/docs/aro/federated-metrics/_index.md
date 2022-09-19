---
date: '2022-09-14T22:07:08.564151'
title: 'Federating System and User metrics to Azure Files in Azure Red Hat OpenShift'
---

**Paul Czarkowski**

*06/04/2021*

By default Azure Red Hat OpenShift (ARO) stores metrics in Ephemeral volumes, and its advised that users do not change this setting. However its not unreasonable to expect that metrics should be persisted for a set amount of time.

This guide shows how to set up Thanos to federate both System and User Workload Metrics to a Thanos gateway that stores the metrics in Azure Files and makes them available via a Grafana instance (managed by the Grafana Operator).

> ToDo - Add Authorization in front of Thanos APIs

## Pre-Prequsites

1. An ARO cluster

1. Set some environment variables to use throughout to suit your environment

    > **Note: AZR_STORAGE_ACCOUNT_NAME must be unique**

    ```bash
    export AZR_RESOURCE_LOCATION=eastus
    export AZR_RESOURCE_GROUP=openshift
    export AZR_STORAGE_ACCOUNT_NAME=arofederatedmetrics
    export CLUSTER_NAME=openshift
    export NAMESPACE=aro-thanos-af
    ```

1. Set some environment variables to use throughout

    > **Note: AZR_STORAGE_ACCOUNT_NAME must be unique**

    ```bash
    export AZR_RESOURCE_LOCATION=eastus
    export AZR_RESOURCE_GROUP=openshift
    export AZR_STORAGE_ACCOUNT_NAME=arofederatedmetrics
    export NAMESPACE=aro-thanos-af
    ```

## Azure Preperation

1. Create an Azure storage account

    > modify the arguments to suit your environment

    ```bash
    az storage account create \
      --name $AZR_STORAGE_ACCOUNT_NAME \
      --resource-group $AZR_RESOURCE_GROUP \
      --location $AZR_RESOURCE_LOCATION \
      --sku Standard_RAGRS \
      --kind StorageV2
    ```

1. Get the account key and update the secret in `thanos-store-credentials.yaml`

    ```bash
    AZR_STORAGE_KEY=$(az storage account keys list -g $AZR_RESOURCE_GROUP \
      -n $AZR_STORAGE_ACCOUNT_NAME --query "[0].value" -o tsv)
    ```

1. Create a namespace to use

    ```bash
    oc new-project $NAMESPACE
    ```

1. Add the MOBB chart repository to your Helm

    ```bash
    helm repo add mobb https://rh-mobb.github.io/helm-charts/
    ```

1. Update your repositories

    ```bash
    helm repo update
    ```

1. Use the `mobb/operatorhub` chart to deploy the grafana operator

    ```bash
    helm upgrade -n $NAMESPACE $NAMESPACE-operators \
      mobb/operatorhub --version 0.1.1 --install \
      --values ./files/grafana-operator.yaml
      --values https://raw.githubusercontent.com/rh-mobb/helm-charts/main/charts/aro-thanos-af/files/grafana-operator.yaml
    ```

1. Use the `mobb/operatorhub` chart to deploy the resource-locker operator

    **> Note: Skip this if you already have the resource-locker operator installed, or if you do not plan to use User Workload Metrics**

    ```bash
    helm upgrade -n resource-locker-operator resource-locker-operator \
      mobb/operatorhub --version 0.1.1 --create-namespace --install \
      --values https://raw.githubusercontent.com/rh-mobb/helm-charts/main/charts/aro-thanos-af/files/resourcelocker-operator.yaml
    ```

1. Deploy ARO Thanos Azure Files Helm Chart (mobb/aro-thanos-af)

    **> Note: `enableUserWorkloadMetrics=true` will overwrite configs for cluster and userworkload metrics, remove it from the helm command below if you already have custom settings.  The Addendum at the end of this doc will explain the changes you'll need to make instead.**

   ```bash
   helm upgrade -n $NAMESPACE aro-thanos-af
     --install mobb/aro-thanos-af --version 0.2.0 \
     --set "aro.storageAccount=$AZR_STORAGE_ACCOUNT_NAME" \
     --set "aro.storageAccountKey=$AZR_STORAGE_KEY" \
     --set "aro.storageContainer=$CLUSTER_NAME" \
     --set "enableUserWorkloadMetrics=true"
   ```

## Validate Grafana is installed and seeing metrics from Azure Files

1. get the Route URL for Grafana (remember its https) and login using username `root` and the password you updated to (or the default of `secret`).

    ```bash
    oc -n $NAMESPACE get route grafana-route
    ```

1. Once logged in go to **Dashboards->Manage** and expand the **thanos-receiver** group and you should see the cluster metrics dashboards.  Click on the **Use Method / Cluster** Dashboard and you should see metrics.  \o/.

    > **Note:   If it complains about a missing datasource run the following: `oc annotate -n $NAMESPACE grafanadatasource aro-thanos-af-prometheus "retry=1"`**

    ![screenshot of grafana with federated cluster metrics](./grafana-metrics.png)

## Cleanup

1. Uninstall the `aro-thanos-af` chart

    ```bash
    helm delete -n $NAMESPACE aro-thanos-af
    ```

1. Uninstall the `federated-metrics-operators` chart

    ```bash
    helm delete -n $NAMESPACE federated-metrics-operators
    ```

1. Delete the `aro-thanos-af` namespace

    ```bash
    oc delete namespace $NAMESPACE
    ```

1. Delete the storage account

    ```bash
    az storage account delete \
      --name $AZR_STORAGE_ACCOUNT_NAME \
      --resource-group $AZR_RESOURCE_GROUP
    ```

## Addendum

### Enabling User Workload Monitoring

> See [docs](https://docs.openshift.com/container-platform/4.7/monitoring/enabling-monitoring-for-user-defined-projects.html) for more indepth details.

1. Check the cluster-monitoring-config ConfigMap object

    ```bash
    oc -n openshift-monitoring get configmap cluster-monitoring-config -o yaml
    ```

1. Enable User Workload Monitoring by doing one of the following

    **If the `data.config.yaml` is not `{}` you should edit it and add the `enableUserWorkload: true` line manually.**

    ```bash
    oc -n openshift-monitoring edit configmap cluster-monitoring-config
    ```

    **Otherwise if its `{}` then you can run the following command safely.**

    ```bash
    oc patch configmap cluster-monitoring-config -n openshift-monitoring \
       -p='{"data":{"config.yaml": "enableUserWorkload: true\n"}}'
    ```

1. Check that the User workload monitoring is starting up

    ```bash
    oc -n openshift-user-workload-monitoring get pods
    ```

1. Append remoteWrite settings to the user-workload-monitoring config to forward user workload metrics to Thanos.

    **Check if the User Workload Config Map exists:**

    ```bash
    oc -n openshift-user-workload-monitoring get \
      configmaps user-workload-monitoring-config
    ```

    **If the config doesn't exist run:**

    ```bash
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    prometheus:
      remoteWrite:
        - url: "http://thanos-receive.$NAMESPACE.svc.cluster.local:9091/api/v1/receive"
EOF
    ```

    **Otherwise update it with the following:**

    ```bash
    oc -n openshift-user-workload-monitoring edit \
      configmaps user-workload-monitoring-config
    ```

    ```yaml
      data:
        config.yaml: |
          ...
          prometheus:
          ...
            remoteWrite:
              - url: "http://thanos-receive.thanos-receiver.svc.cluster.local:9091/api/v1/receive"
    ```
