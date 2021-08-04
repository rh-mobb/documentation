# Using Cluster Logging Forwarder with Azure Monitor

Based on [docs](https://github.com/microsoft/fluent-bit-azure-log-analytics)


## Set up initial cluster operators

1. Deploy Elasticsearch Operator

1. Deploy cluster logging operator

## Set up ARO Monitor workspace

1. Set up local environment

    ```bash
    az extension add --name log-analytics
    export LogAppLoc=centralus
    export LogAppRG=LogAppRG

    # this value must be unique
    export LogAppName=LogAppLogs
    ```

1. Create resource group

    ```bash
    az group create -n $LogAppRG -l $LogAppLoc
    ```

1. Create workspace

    ```bash
    az monitor log-analytics workspace create \
      -g $LogAppRG -n $LogAppName -l $LogAppLoc
    ```

## Configure OpenShift

1. Create Namespace

    ```bash
    kubectl apply -f manifests/account.yaml
    ```

1. Create secret

    ```bash
    kubectl delete secret fluentbit-secrets -n log-test

    kubectl create secret generic fluentbit-secrets -n log-test \
      --from-literal=WorkspaceId=$(az monitor log-analytics workspace show -g $LogAppRG -n $LogAppName --query customerId -o tsv) \
      --from-literal=SharedKey=$(az monitor log-analytics workspace get-shared-keys -g $LogAppRG -n $LogAppName --query primarySharedKey -o tsv)

    kubectl get secret fluentbit-secrets -n log-test -o jsonpath='{.data}'
    ```

1. Create fluent-bit daemonset

    ```bash
    kubectl apply -f manifests/config.yaml
    kubectl apply -f manifests/fluentbit-daemonset.yaml
    kubectl apply -f manifests/service.yaml
    ```

1. Configure cluster logging forwarder

    ```bash
    kubectl apply -f manifests/clf.yaml
    ```

## Check for logs in Azure

1. Log into [Azure Log Insights](https://portal.azure.com/#blade/Microsoft_Azure_Monitoring/AzureMonitoringBrowseBlade/logs)

1. Find the "LogAppLogs" workspace

1. Run the Query

    ```
    fluentbit_CL
      | take 10
    ```