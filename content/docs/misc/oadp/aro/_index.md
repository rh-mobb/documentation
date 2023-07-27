---
date: '2023-07-26'
title: Deploying OpenShift API for Data Protection on an ARO cluster
tags: ["ARO", "OADP", "Velero", "Backup", "Restore", "Storage"]
authors:
  - Dustin Scott
---


## Prerequisites

* [An ARO Cluster](/docs/quickstart-aro)


## Getting Started

1. Create the following environment variables, substituting appropriate values for your environment:

```bash
export AZR_CLUSTER_NAME=oadp
export AZR_SUBSCRIPTION_ID=$(az account show --query 'id' -o tsv)
export AZR_TENANT_ID=$(az account show --query 'tenantId' -o tsv)
export AZR_RESOURCE_GROUP=oadp
export AZR_STORAGE_ACCOUNT_ID=oadp
export AZR_STORAGE_CONTAINER=oadp
export AZR_STORAGE_ACCOUNT_SP_NAME=oadp
export AZR_IAM_ROLE=oadp
```


## Prepare Azure Account

1. Create an Azure Storage Account as a backup target:

```bash
az storage account create \
  --name $AZR_STORAGE_ACCOUNT_ID \
  --resource-group $AZR_RESOURCE_GROUP \
  --sku Standard_GRS \
  --encryption-services blob \
  --https-only true \
  --kind BlobStorage \
  --access-tier Cool
```

2. Create an Azure Blob storage container:

```bash
az storage container create \
  --name $AZR_STORAGE_CONTAINER \
  --public-access off \
  --account-name $AZR_STORAGE_ACCOUNT_ID
```

3. Create a role definition that will allow the operator minimal permissions to 
access the storage account where the backups are stored:

```bash
az role definition create --role-definition '{
   "Name": "'$AZR_IAM_ROLE'",
   "Description": "OADP related permissions to perform backups, restores and deletions",
   "Actions": [
       "Microsoft.Compute/disks/read",
       "Microsoft.Compute/disks/write",
       "Microsoft.Compute/disks/endGetAccess/action",
       "Microsoft.Compute/disks/beginGetAccess/action",
       "Microsoft.Compute/snapshots/read",
       "Microsoft.Compute/snapshots/write",
       "Microsoft.Compute/snapshots/delete",
       "Microsoft.Storage/storageAccounts/listkeys/action",
       "Microsoft.Storage/storageAccounts/regeneratekey/action"
   ],
   "AssignableScopes": ["/subscriptions/'$AZR_SUBSCRIPTION_ID'"]
   }'
```

4. Create a service principal for interacting with the Azure API, being sure to 
take note of the `appID` and `password` from the output.  In this command, we will 
store these as `AZR_CLIENT_ID` and `AZR_CLIENT_SECRET` and use them in a 
subsequent command:

```bash
az ad sp create-for-rbac --name $AZR_STORAGE_ACCOUNT_SP_NAME
```

> **IMPORTANT** be sure to store the client id and client secret for your service 
principal, as they will be needed later in this walkthrough.  You will see the below 
output from the above command:

```
{
  "appId": "xxxxx",
  "displayName": "oadp",
  "password": "xxxx",
  "tenant": "xxxx"
}
```

Set the following variables:

```bash
export AZR_CLIENT_ID=<VALUE_FROM_appId_ABOVE>
export AZR_CLIENT_SECRET=<VALUE_FROM_password_ABOVE>
```

5. Retrieve the object ID for the service principal you just created.  This is used
to assign permissions for this service principal using the previously created 
role:

```bash
export AZR_SP_ID=$(az ad sp list --display-name oadp --query "[?appDisplayName == '$AZR_CLUSTER_NAME'].id" -o tsv)
```

6. Assign permissions on the storage account for the service principal 
using the permissions from the previously created role:

```bash
az role assignment create \
    --role $AZR_IAM_ROLE \
    --assignee-object-id $AZR_SP_ID \
    --scope "/subscriptions/$AZR_SUBSCRIPTION_ID/resourceGroups/$AZR_RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$AZR_STORAGE_ACCOUNT_ID"
```


## Deploy OADP on ARO Cluster

1. Create a namespace for OADP:

```bash
oc create namespace openshift-adp
```

2. Deploy OADP Operator:

```bash
cat << EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: openshift-adp-
  namespace: openshift-adp
  name: oadp
spec:
  targetNamespaces:
  - openshift-adp
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  channel: stable-1.2
  installPlanApproval: Automatic
  name: redhat-oadp-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

4. Wait for the operator to be ready:

```bash
watch oc -n openshift-adp get pods
```

```
NAME                                                READY   STATUS    RESTARTS   AGE
openshift-adp-controller-manager-546684844f-qqjhn   1/1     Running   0          22s
```

5. Create a file containing all of the environment variables needed.  These are stored in
the `cloud` key of the secret created in the next step and is required by the operator 
to locate configuration information:


```bash
cat << EOF > /tmp/credentials-velero
AZURE_SUBSCRIPTION_ID=${AZR_SUBSCRIPTION_ID}
AZURE_TENANT_ID=${AZR_TENANT_ID}
AZURE_RESOURCE_GROUP=${AZR_RESOURCE_GROUP}
AZURE_CLIENT_ID=${AZR_CLIENT_ID}
AZURE_CLIENT_SECRET=${AZR_CLIENT_SECRET}
AZURE_CLOUD_NAME=AzurePublicCloud
EOF
```

5. Create the secret that the operator will use to access the storage account.  This 
is created from the secret file you created in the previous step:

```bash
oc create secret generic cloud-credentials-azure \
  --namespace openshift-adp \
  --from-file cloud=/tmp/credentials-velero
```

> **WARNING** be sure to delete the file at `/tmp/credentials-velero` once you
are comfortable with the configuration and setup of the operator and have it working 
to avoid exposing sensitive credentials to anyone who may be sharing the system 
you are running these commands from.

6. Deploy a Data Protection Application:

```bash
cat << EOF | oc create -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: $AZR_CLUSTER_NAME
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - azure
        - openshift 
      resourceTimeout: 10m 
    restic:
      enable: true 
  backupLocations:
    - velero:
        config:
          resourceGroup: $AZR_RESOURCE_GROUP
          storageAccount: $AZR_STORAGE_ACCOUNT_ID 
          subscriptionId: $AZR_SUBSCRIPTION_ID 
        credential:
          key: cloud
          name: cloud-credentials-azure
        provider: azure
        default: true
        objectStorage:
          bucket: $AZR_STORAGE_CONTAINER
          prefix: oadp
  snapshotLocations: 
    - velero:
        config:
          resourceGroup: $AZR_RESOURCE_GROUP
          subscriptionId: $AZR_SUBSCRIPTION_ID 
          incremental: "true"
        name: default
        provider: azure
EOF
```


## Perform a Backup

1. Create a workload to backup:

```bash
oc create namespace hello-world
oc new-app -n hello-world --image=docker.io/openshift/hello-openshift
```

2. Expose the route:

```bash
oc expose service/hello-openshift -n hello-world
```

3. Make a request to see if the application is working:

```bash
curl `oc get route/hello-openshift -n hello-world -o jsonpath='{.spec.host}'`
```

If the application is working, you should see a response such as:

```
Hello OpenShift!
```

4. Backup workload:

```bash
cat << EOF | oc create -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: hello-world
  namespace: openshift-adp
spec:
  includedNamespaces:
    - hello-world
  storageLocation: ${AZR_CLUSTER_NAME}-1
  ttl: 720h0m0s
EOF
```

5. Wait until backup is done:

```bash
watch "oc -n openshift-adp get backup hello-world -o json | jq .status"
```

> **NOTE** backup is done when `phase` is `Completed` like below:

```json
{
  "completionTimestamp": "2022-09-07T22:20:44Z",
  "expiration": "2022-10-07T22:20:22Z",
  "formatVersion": "1.1.0",
  "phase": "Completed",
  "progress": {
    "itemsBackedUp": 58,
    "totalItems": 58
  },
  "startTimestamp": "2022-09-07T22:20:22Z",
  "version": 1
}
```

6. Delete the demo workload:

```bash
oc delete ns hello-world
```

7. Restore from the backup:

```bash
cat << EOF | oc create -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: hello-world
  namespace: openshift-adp
spec:
  backupName: hello-world
EOF
```

8. Wait for the restore to finish:

```bash
watch "oc -n openshift-adp get restore hello-world -o json | jq .status"
```

> **NOTE** restore is done when `phase` is `Completed` like below:

```json
{
  "completionTimestamp": "2022-09-07T22:25:47Z",
  "phase": "Completed",
  "progress": {
    "itemsRestored": 38,
    "totalItems": 38
  },
  "startTimestamp": "2022-09-07T22:25:28Z",
  "warnings": 9
}
```

9. Ensure that workload is restored:

```bash
oc -n hello-world get pods
```

You should see:

```
NAME                              READY   STATUS    RESTARTS   AGE
hello-openshift-9f885f7c6-kdjpj   1/1     Running   0          90s
```

```bash
curl `oc get route/hello-openshift -n hello-world -o jsonpath='{.spec.host}'`
```

If the application is working, you should see a response such as:

```
Hello OpenShift!
```


* For troubleshooting tips please refer to the OADP team's [troubleshooting documentation](https://github.com/openshift/oadp-operator/blob/master/docs/TROUBLESHOOTING.md)

* Additional sample applications can be found in the OADP team's [sample applications directory](https://github.com/openshift/oadp-operator/tree/master/tests/e2e/sample-applications)


## Cleanup

> **IMPORTANT** this is only necessary if you do not need to keep any of your work


### Cleanup Cluster Resources

1. Delete the workload:

```bash
oc delete ns hello-world
```

2. Delete the Data Protection Application:

```bash
oc -n openshift-adp delete dpa ${AZR_CLUSTER_NAME}
```

2. Remove the operator if it is no longer required:

```bash
oc -n openshift-adp delete subscription oadp-operator
```

3. Remove the namespace for the operator:

```bash
oc delete ns openshift-adp
```

4. Remove the backup and restore resources from the cluster if they are no longer required:

```bash
oc delete backup hello-world
oc delete restore hello-world
```

To delete the backup/restore and remote objects in Azure Blob storage:

```bash
velero backup delete hello-world
velero restore delete hello-world
```

5. Remove the Custom Resource Definitions from the cluster if you no longer wish to have them:

```bash
for CRD in `oc get crds | grep velero | awk '{print $1}'`; do oc delete crd $CRD; done
for CRD in `oc get crds | grep -i oadp | awk '{print $1}'`; do oc delete crd $CRD; done
```


### Cleanup Azure Resources

1. Delete the Azure Storage Account:

```bash
az storage account delete \
  --name $AZR_STORAGE_ACCOUNT_ID \
  --resource-group $AZR_RESOURCE_GROUP \
  --yes
```

2. Delete the IAM Role:

```bash
az role definition delete --name $AZR_IAM_ROLE
```

3. Delete the Service Principal:

```bash
az ad sp delete --id $AZR_SP_ID
```
