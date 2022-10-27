# Azure Red Hat Openshift - Shippings logs and metrics to Azure Blob storage

## Preparation

1. Create some environment variables to be reused through this guide

   > Modify these values to suit your environment, especially the storage account name which must be globally unique.

   ```bash
   export CLUSTER="aro-${USERNAME}"
   export WORKDIR="/tmp/${CLUSTER}"
   export NAMESPACE=mobb-aro-obs
   export AZR_STORAGE_ACCOUNT_NAME="aro${USERNAME}obs"
   mkdir -p ${WORKDIR}
   cd "${WORKDIR}"
   ```

1. Log into Azure CLI

   ```bash
   az login
   ```

## Create ARO Cluster

> You can skip this step if you already have a cluster, or if you want to create it another way.

1. Prequisites:

   * Azure CLI
   * Terraform

1. clone down the Black Belt ARO Terraform repo

   ```bash
   git clone https://github.com/rh-mobb/terraform-aro.git
   cd terraform-aro
   ```

1. Initialize, Create a plan, and apply

   ```bash
   make create
   ```

   This should take about 35 minutes and the final lines of the output should look like

   ```
   azureopenshift_redhatopenshift_cluster.cluster: Still creating... [35m30s elapsed]
   azureopenshift_redhatopenshift_cluster.cluster: Still creating... [35m40s elapsed]
   azureopenshift_redhatopenshift_cluster.cluster: Creation complete after 35m48s [id=/subscriptions/e7f88b1a-04fc-4d00-ace9-eec077a5d6af/resourceGroups/my-tf-cluster-rg/providers/Microsoft.RedHatOpenShift/openShiftClusters/my-tf-cluster]
   ```

1. Save, display the ARO credentials, and login

   ```bash
   az aro list --query \
      "[?name=='${CLUSTER}'].{Name:name,Console:consoleProfile.url,API:apiserverProfile.url, ResourceGroup:resourceGroup,Location:location}" \
      -o tsv |  read -r NAME CONSOLE API RESOURCEGROUP LOCATION
   az aro list-credentials -n $NAME -g $RESOURCEGROUP \
      -o tsv | read -r PASS USER
   oc login ${API} --username ${USER} --password ${PASS}
   echo "$ oc login ${API} --username ${USER} --password ${PASS}"
   echo "Login to ${CONSOLE} as ${USER} with password ${PASS}"
   ```

### Update the Pull Secret and enable OperatorHub

1. Download a Pull secret from [Red Hat Cloud Console](https://console.redhat.com/openshift/downloads#tool-pull-secret) and save it in `${SCRATCHDIR}/pullsecret.txt`


1. Annotate resources for Helm

   ```bash
   oc -n openshift-config annotate secret \
      pull-secret meta.helm.sh/release-name=pull-secret
   oc -n openshift-config annotate secret \
      pull-secret meta.helm.sh/release-namespace=openshift-config
   oc -n openshift-config label secret \
      pull-secret app.kubernetes.io/managed-by=Helm
  ```

1. Update the pull secret

   > Change the location of the pull secret if its not in `~/Downloads`

   ```bash
   cat << EOF > "${WORKDIR}/pullsecret.yaml"
   pullSecret: |
     $(< "${WORKDIR}/pull-secret.txt")
   EOF
   helm upgrade --install pull-secret mobb/aro-pull-secret \
  -n openshift-config --values "${WORKDIR}/pullsecret.yaml"
  ```

1. Enable OperatorHub

   ```bash
   oc patch configs.samples.operator.openshift.io cluster --type=merge \
      -p='{"spec":{"managementState":"Managed"}}'
   oc patch operatorhub cluster --type=merge \
      -p='{"spec":{"sources":[
        {"name":"redhat-operators","disabled":false},
        {"name":"certified-operators","disabled":false},
        {"name":"community-operators","disabled":false},
        {"name":"redhat-marketplace","disabled":false}
      ]}}'
   ```

1. Wait for OperatorHub pods to be ready

   ```bash
   watch oc -n openshift-marketplace get pods
   ```

   ```
   NAME                                    READY   STATUS    RESTARTS      AGE
   certified-operators-xm674               1/1     Running   0             117s
   community-operators-c5pcq               1/1     Running   0             117s
   marketplace-operator-7696c9454c-wgtzp   1/1     Running   1 (30m ago)   47m
   redhat-marketplace-sgnsg                1/1     Running   0             117s
   redhat-operators-pdbg8                  1/1     Running   0             117s
   ```

## Configure additional Azure resources

1. Create Azure Storage Account

   ```bash
   az storage account create \
      --name $AZR_STORAGE_ACCOUNT_NAME \
      --resource-group $RESOURCEGROUP \
      --location $LOCATION \
      --sku Standard_RAGRS \
      --kind StorageV2
   ```

1. Fetch the Azure storage key

   ```bash
   AZR_STORAGE_KEY=$(az storage account keys list -g "${RESOURCEGROUP}" \
      -n "${AZR_STORAGE_ACCOUNT_NAME}" --query "[0].value" -o tsv)
   ```

1. Create Azure Storage Containers

   ```bash
   az storage container create --name "${CLUSTER}-metrics" \
     --account-name "${AZR_STORAGE_ACCOUNT_NAME}" \
     --account-key "${AZR_STORAGE_KEY}"
   az storage container create --name "${CLUSTER}-logs" \
     --account-name "${AZR_STORAGE_ACCOUNT_NAME}" \
     --account-key "${AZR_STORAGE_KEY}"
   ```

## Configure Metrics Federation to Azure Blob Storage

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

### Grafana Operator

1. Create a file containing the Grafana operator

   ```yaml
   mkdir -p $WORKDIR/metrics
   cat <<EOF > $WORKDIR/metrics/grafana-operator.yaml
   subscriptions:
     - name: grafana-operator
       channel: v4
       installPlanApproval: Automatic
       source: community-operators
       sourceNamespace: openshift-marketplace
       startingCSV: grafana-operator.v4.7.0

   operatorGroups:
     - name: ${NAMESPACE}
       targetNamespace: ~
   EOF
   ```

1. Deploy the Grafana Operator using Helm

   ```bash
   helm upgrade -n "${NAMESPACE}" clf-operators \
      mobb/operatorhub --install \
      --values "${WORKDIR}/metrics/grafana-operator.yaml"
   ```

1. Wait for the Grafana Operator to be installed

   ```bash
   while ! oc get grafana; do sleep 5; echo -n .; done
   ```

   After a few minutes you should see the following

   ```
   error: the server doesn't have a resource type "grafana"
   error: the server doesn't have a resource type "grafana"
   No resources found in mobb-aro-obs namespace.
   ```


### Resource Locker Operator

1. Create the namespace `resource-locker-operator`

   ```bash
   oc create namespace resource-locker-operator
   ```

1. Create a file containing the Grafana operator

   ```yaml
   cat <<EOF > $WORKDIR/resource-locker-operator.yaml
   subscriptions:
   - name: resource-locker-operator
     channel: alpha
     installPlanApproval: Automatic
     source: community-operators
     sourceNamespace: openshift-marketplace
     namespace: resource-locker-operator

   operatorGroups:
   - name: resource-locker
     namespace: resource-locker-operator
     targetNamespace: all
   EOF
   ```

1. Deploy the Resource Locker Operator using Helm

   ```bash
   helm upgrade -n resource-locker-operator resource-locker-operator \
      mobb/operatorhub --install \
      --values "${WORKDIR}"/resource-locker-operator.yaml
   ```

1. Wait for the Operators to be installed

   ```bash
   while ! oc get resourcelocker; do sleep 5; echo -n .; done
   ```

   After a few minutes you should see the following

   ```
   error: the server doesn't have a resource type "resourcelocker"
   error: the server doesn't have a resource type "resourcelocker"
   No resources found in mobb-aro-obs namespace.
   ```

1. Deploy `mobb/aro-thanos-af` Helm Chart to configure metrics federation

   ```bash
   helm upgrade -n "${NAMESPACE}" aro-thanos-af \
      --install mobb/aro-thanos-af --version 0.3.1 \
      --set "aro.storageAccount=${AZR_STORAGE_ACCOUNT_NAME}" \
      --set "aro.storageAccountKey=${AZR_STORAGE_KEY}" \
      --set "aro.storageContainer=${CLUSTER}-metrics" \
      --set "enableUserWorkloadMetrics=true" \
      --set "grafana-cr.oauthProxy.passThrough=true"
  ```

1. Wait a few minutes and then get the `Route` for `Grafana`

   ```bash
   oc -n $NAMESPACE get route grafana-route
   ```

1. Browse to the provided route and login using your OpenShift credentials, then login as `admin` with the password `password`.

![screenshot showing federated metrics](../federated-metrics/grafana-metrics.png)

## Configure Logs Federation to Azure Blob Storage

1. Create namespaces for the OpenShift Logging Operators

   ```bash
   oc create ns openshift-logging
   oc create ns openshift-operators-redhat
   ```

1. Create a Helm values file that can be used to deploy the cluster logging and loki operators

   ```yaml
   mkdir -p "${WORKDIR}/logs"
   cat << EOF > "${WORKDIR}/logs/log-operators.yaml"
   subscriptions:
   - name: cluster-logging
     channel: stable
     installPlanApproval: Automatic
     source: redhat-operators
     sourceNamespace: openshift-marketplace
     namespace: openshift-logging
     startingCSV: cluster-logging.5.5.2
   - name: loki-operator
     channel: stable
     installPlanApproval: Automatic
     source: redhat-operators
     sourceNamespace: openshift-marketplace
     namespace: openshift-operators-redhat
     startingCSV: loki-operator.5.5.2
   operatorGroups:
   - name: openshift-logging
     namespace: openshift-logging
     targetNamespace: openshift-logging
   - name: openshift-operators-redhat
     namespace: openshift-operators-redhat
     targetNamespace: all
   EOF
   ```

1. Deploy the OpenShift Loki Operator and the Red Hat OpenShift Logging Operator

   ```bash
   helm upgrade -n $NAMESPACE clf-operators \
      mobb/operatorhub --install \
      --values "${WORKDIR}/logs/log-operators.yaml"
   ```

1. Wait for the Operators to be installed

   ```bash
   while ! oc get clusterlogging; do sleep 5; echo -n .; done
   while ! oc get lokistack; do sleep 5; echo -n .; done
   ```

1. Configure the loki stack to log to Azure Blob

   ```bash
   helm upgrade -n "${NAMESPACE}" aro-clf-blob \
      --install /home/pczarkow/development/redhat/mobb-charts/charts/aro-clf-blob \
      --set "aro.storageAccount=${AZR_STORAGE_ACCOUNT_NAME}" \
      --set "aro.storageAccountKey=${AZR_STORAGE_KEY}" \
      --set "aro.storageContainer=${CLUSTER}-logs"
   ```

1. Sometimes the log collector needs to be restarted for logs to flow correctly into Loki.  Wait a few minutes then run th following

   ```bash
   oc -n openshift-logging rollout restart daemonset collector
   ```

## Cleanup

### OpenShift Resources

1. Delete the metrics federation

   ```bash
   helm delete -n "${NAMESPACE}" aro-thanos-af
   ```


### Azure Resources

1. Delete the Azure Storage Account

   > Note: This will delete the storage account and everything in it, be sure you want to do this.

   ```bash
   az storage account delete \
      --name $AZR_STORAGE_ACCOUNT_NAME
   ```

1. Delete the ARO cluster

   ```bash
   cd "${WORKDIR}/terraform-aro"
   make delete
   ```
