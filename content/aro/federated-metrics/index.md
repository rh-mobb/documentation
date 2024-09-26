---
date: '2021-06-04'
title: 'Federating System and User metrics to Azure Blob storage in Azure Red Hat OpenShift'
tags: ["ARO", "Azure"]
authors:
  - Paul Czarkowski
  - Kumudu Herath
---

By default Azure Red Hat OpenShift (ARO) stores metrics in Ephemeral volumes, and its advised that users do not change this setting. However its not unreasonable to expect that metrics should be persisted for a set amount of time.

This guide shows how to set up Thanos to federate both System and User Workload Metrics to a Thanos gateway that stores the metrics in Azure Blob Container and makes them available via a Grafana instance (managed by the Grafana Operator).

> ToDo - Add Authorization in front of Thanos APIs

## Pre-Prequsites

1. [An ARO cluster](/experts/quickstart-aro.md)

1. Set some environment variables to use throughout to suit your environment

    > **Note: AZR_STORAGE_ACCOUNT_NAME must be unique**

    ```bash
    export AZR_RESOURCE_LOCATION="eastus"
    export AZR_RESOURCE_GROUP="openshift"
    export CLUSTER_NAME="openshift"
    export UNIQUE="$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | fold -w 5 | head -n 1)"
    export AZR_STORAGE_ACCOUNT_NAME="arometrics${UNIQUE}"
    export NAMESPACE="aro-thanos-af"
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
    helm upgrade -n $NAMESPACE grafana-operator \
      mobb/operatorhub --install \
      --values https://raw.githubusercontent.com/rh-mobb/helm-charts/main/charts/aro-thanos-af/files/grafana-operator.yaml
    ```

1. Wait for the Operator to be ready

    ```bash
    oc rollout status -n $NAMESPACE \
      deployment/grafana-operator-controller-manager
    ```

1. Use Helm deploy the OpenShift Patch Operator

    ```bash
    helm upgrade -n patch-operator patch-operator --create-namespace \
      mobb/operatorhub --install \
      --values https://raw.githubusercontent.com/rh-mobb/helm-charts/main/charts/aro-thanos-af/files/patch-operator.yaml
    ```

1. Wait for the Operator to be ready

    ```bash
    oc rollout status -n patch-operator \
      deployment/patch-operator-controller-manager
    ```

1. Deploy ARO Thanos Azure Blob container Helm Chart (mobb/aro-thanos-af)

    **> Note: `enableUserWorkloadMetrics=true` will overwrite configs for cluster and userworkload metrics. If you have customized them already, you may need to modify `patch-monitoring-configs.yaml` in the Helm chart to include your changes.
   
   **> Note: If you do not explicitly define values for either retention or retentionSize, retention time defaults to 15 days for core platform monitoring and 24 hours for user-defined project monitoring. For specifying the retention time you need to modify the `patch-monitoring-configs.yaml` with the relevant retention parameters following [Modifying the retention time and size for Prometheus metrics data](https://docs.openshift.com/container-platform/4.14/observability/monitoring/configuring-the-monitoring-stack.html#modifying-retention-time-and-size-for-prometheus-metrics-data_configuring-the-monitoring-stack))


    ```bash
    helm upgrade -n $NAMESPACE aro-thanos-af \
      --install mobb/aro-thanos-af \
      --set "aro.storageAccount=$AZR_STORAGE_ACCOUNT_NAME" \
      --set "aro.storageAccountKey=$AZR_STORAGE_KEY" \
      --set "aro.storageContainer=$CLUSTER_NAME" \
      --set "aro.clusterName=$CLUSTER_NAME" \
      --set "enableUserWorkloadMetrics=true"
    ```

## Validate Grafana is installed and seeing metrics from Azure Blob storage

1. get the Route URL for Grafana (remember its https) and login using username `admin` and the password `password`.

    ```bash
    oc -n $NAMESPACE get route grafana-route
    ```

1. Once logged in go to **Dashboards->Manage** and expand the **aro-thanos-af** group and you should see the cluster metrics dashboards.  Click on the **Use Method / Cluster** Dashboard and you should see metrics.  \o/.

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
