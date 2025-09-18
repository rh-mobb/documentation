---
date: '2025-09-03'
title: Backup and Restore for Azure Red Hat OpenShift using OpenShift API for Data Protection
tags: ["ARO", "Azure", "OADP"]
authors:
  - Nerav Doshi
---

This guide outlines how to implement OpenShift API for Data Protection (OADP) for comprehensive backup and recovery for Azure Red Hat OpenShift (ARO) clusters using a storage account.

### Overview of OADP

OADP provides robust  disaster recovery solution, covering OpenShift applications, application-related cluster resources, persistent volumes. OADP is also capable of backing up both containerized applications and virtual machines (VMs). However,it is important to note that etcd and Operators are not covered under OADP's disaster recovery capabilities.OADP support is provided to customer workload namespaces, and cluster scope resources.

OADP includes a built-in Data Mover feature that allows you to move Container Storage Interface (CSI) volume snapshots to a remote object store, such as Azure Blob Storage. This enables you to restore stateful applications from the remote store in the event of a cluster failure, accidental deletion, or data corruption. The Data Mover uses Kopia as the uploader mechanism to read snapshot data and write it to the repository

For additional information about OADP refer to [documentation](https://github.com/openshift/oadp-operator/blob/oadp-dev/docs/TROUBLESHOOTING.md)

### Prerequisites checklist

Before starting, ensure you have:
* An [ARO 4.14 cluster](/experts/aro/terraform-install) with cluster-admin access
* Configure [EntraID for authentication](https://cloud.redhat.com/experts/idp/group-claims/aro/)
* [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
* [OpenShift CLI](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/cli_tools/openshift-cli-oc#installing-openshift-cli)
* Azure subscription with permissions to create storage accounts and resource groups


#### Step 1: Preparing Azure Resources

You must create the necessary Azure infrastructure to store the backup data. This involves setting up a dedicated resource group, a storage account, and a service principal with the correct permissions

##### 1.1 Create environment variables
A resource group will contain the storage account, and the storage account will house a container for your backup files

```bash
# Set variables
export ARO_RG="aro-cluster-rg"
export ARO_CLUSTER_NAME="aro-cluster"
export LOCATION="eastus" 
export STORAGE_ACCOUNT="aroprojectbackups"
export BACKUP_RG="aro-backup-rg"
export CONTAINER_NAME="aro-project"
export SUBSCRIPTION_ID=$(az account show --query id --output tsv)
export OADP_NAMESPACE="openshift-adp"
export TEST_PROJECT_NAME="database-test"
```

##### 1.2 Create resource group for storage account

```bash
az group create \
  --name $BACKUP_RG \
  --location $LOCATION
```

##### 1.3 Create Azure storage account


```bash
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $BACKUP_RG \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --access-tier Hot \
  --allow-blob-public-access false \
  --allow-shared-key-access false
```

##### 1.4 Create container (using Azure EntraID auth)

```bash
az storage container create \
  --name $CONTAINER_NAME \
  --account-name $STORAGE_ACCOUNT \
  --resource-group $BACKUP_RG \
  --auth-mode login
```

##### 1.5 Create service principal
A service principal is required for OADP to securely access Azure resources without using personal credentials. It needs permissions to access both the storage account and the resources required for volume snapshots.

Create service principal with appropriate permissions to access both storage and snapshot resources

```bash
export SERVICE_PRINCIPAL_NAME="aro-backup-sp"

SP_INFO=$(az ad sp create-for-rbac \
  --name $SERVICE_PRINCIPAL_NAME \
  --role Contributor \
  --scopes "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$BACKUP_RG")
```

##### 1.6 Get service principal values
```bash
SP_CLIENT_ID=$(echo "${SP_INFO}" | jq -r .appId)
SP_CLIENT_SECRET=$(echo "${SP_INFO}" | jq -r .password)
SP_TENANT_ID=$(echo "${SP_INFO}" | jq -r .tenant)
```

##### 1.7 Validating client ID and tenant ID values

```bash
echo "Service Principal Client ID: $SP_CLIENT_ID"
echo "Tenant ID: $SP_TENANT_ID"
```

##### 1.8 Assign additional permissions for Storage account and ARO resource group for snapshot location

```bash
az role assignment create \
  --assignee $SP_CLIENT_ID \
  --role "Storage Blob Data Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$BACKUP_RG/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

az role assignment create \
  --assignee $SP_CLIENT_ID \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$ARO_RG"
```

#### Step 2: Install the OADP Operator

The OADP Operator automates the management of Velero, plugins, and custom resources required for backup and restore operations. You can install it from OperatorHub in the OpenShift web console.
- Log in to your ARO cluster as a user with cluster-admin privileges.
- Navigate to OperatorHub and search for the OADP Operator.
- Install the operator in the openshift-adp namespace.
- Verify the installation by checking the operator pods and the ClusterServiceVersion (CSV) status. It may take a few minutes for the operator to be ready.

##### 2.1 Connect to your ARO cluster. 

Reference [link](https://learn.microsoft.com/en-us/azure/openshift/connect-cluster#connect-using-the-openshift-cli)

oc login $apiServer --username kubeadmin --password $kubevar

##### 2.2 Install OADP operator 1.4 via OperatorHub

You must be logged in as a user with `cluster-admin` privileges. You can install operator via [webconsole](https://docs.redhat.com/en/documentation/openshift_container_platform/4.10/html/backup_and_restore/application-backup-and-restore#oadp-installing-operator_installing-oadp-azure) 

Install operator in openshift-adp namespace

##### 2.3 Verify operator installation

Wait for operator to be ready (may take 2-3 minutes)

```bash
oc get csv -n openshift-adp
```

Check operator pods
```bash
oc get pods -n openshift-adp
```
Example output:
```
NAME                                READY   STATUS    RESTARTS   AGE
# oadp-operator-controller-manager-*  1/1     Running   0          2m
```

#### Step 3: Configure OADP with Data Mover
After installation, you must configure OADP by creating a DataProtectionApplication (DPA) custom resource. This CR defines the backup storage location, volume snapshot location, and enables the Data Mover feature

##### 3.1 Create cloud credentials secret

This will store secret of the service principal credentials, allowing OADP to authenticate with Azure

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: openshift-adp
type: Opaque
stringData:
  cloud: |
    AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
    AZURE_TENANT_ID=${SP_TENANT_ID}
    AZURE_CLIENT_ID=${SP_CLIENT_ID}
    AZURE_CLIENT_SECRET=${SP_CLIENT_SECRET}
EOF
```

##### 3.2 Create DataProtectionApplication (DPA)
This resource configures Velero and its plugins.
- **backupLocations:** Defines the Azure blob container as the destination for backups.
- **snapshotLocations:** Configures the provider for creating volume snapshots. For Azure, the CSI snapshot is stored within Azure's disk infrastructure, not the blob container.
- **defaultPlugins:** Enables the openshift, csi, and azure plugins for full functionality.
- **defaultSnapshotMoveData: true:** Enables the Data Mover feature by default for all CSI snapshots.
- **nodeAgent.enable: true:** Deploys the node-agent daemonset, which is required for data movement operations


```bash
oc apply -f - <<EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: azure-dpa
  namespace: openshift-adp
spec:
  backupLocations:
    - name: azure-backup
      velero:
        provider: azure
        default: true
        objectStorage:
          bucket: ${CONTAINER_NAME}
          prefix: backups
        config:
          resourceGroup: ${BACKUP_RG}
          storageAccount: ${STORAGE_ACCOUNT}
          subscriptionId: ${SUBSCRIPTION_ID}
          useAAD: 'true'
        credential:
          name: cloud-credentials
          key: cloud
  snapshotLocations:
    - name: azure-snapshot
      velero:
        provider: azure
        config:
          resourceGroup: ${ARO_RG}
          subscriptionId: ${SUBSCRIPTION_ID}
          apiTimeout: 2m0s
        credential:
          name: cloud-credentials
          key: cloud  
  configuration:
    velero:
      defaultPlugins:
        - openshift
        - csi
        - azure
      defaultSnapshotMoveData: true
    nodeAgent:
      enable: true
      uploaderType: kopia
EOF
```
After applying the DPA, wait for it to reconcile and for all OADP-related pods (Velero, node-agent) to be running

Note: Important Considerations for **Azure GovCloud and Private Endpoints**
While this procedure works with standard Azure, there are specific configurations required for other environments, such as Azure GovCloud or when using a private endpoint.

 By default, OADP and Velero assume the standard public cloud endpoint. However, in specialized environments, this endpoint is different. OADP is flexible enough to handle this, but you must explicitly define the correct URI in manifest

**What to Do:**

You need to specify the correct URI for your storage account in the `storageAccountURI` field within the `backupLocations` section of your DPA manifest.

**Example for Azure GovCloud:**

For users operating in Azure GovCloud, the `storageAccountURI` will be different. Your `spec` block should be configured as shown below, using the `.usgovcloudapi.net` domain:

```bash
spec:
  backupLocations:
    - name: azure-backup
      velero:
        config:
          resourceGroup: ${BACKUP_RG}
          storageAccount: ${STORAGE_ACCOUNT}
          storageAccountURI: 'https://aroprojectbackups.blob.core.usgovcloudapi.net'
          subscriptionId: ${SUBSCRIPTION_ID}
          useAAD: 'true'
```          

#### 3.3 Wait for DPA to be ready

Check DPA status (wait for Reconcile Succeeded)
```bash
oc get dpa -n openshift-adp -o jsonpath='{.items[0].status.conditions[0].type}'
```

Check all OADP pods are running
```bash
oc get pods -n openshift-adp
```
Example output:
```bash
oc get pods -n openshift-adp

NAME                                                READY   STATUS      RESTARTS   AGE
node-agent-7m4tz                                    1/1     Running     0          20s
node-agent-blmhm                                    1/1     Running     0          20s
node-agent-ck7gn                                    1/1     Running     0          20s
openshift-adp-controller-manager-744cdc6589-bqzmx   1/1     Running     0          27h
repo-maintain-job-1756910770495-sztvg               0/1     Completed   0          3h47m
repo-maintain-job-1756914370506-ftg8l               0/1     Completed   0          167m
repo-maintain-job-1756917970513-ffdn4               0/1     Completed   0          107m
velero-7f6f5d6c54-tnrxx                             1/1     Running     0          20s
```

#### Step 4: Verify OADP Installation
To verify a successful installation of the OADP operator, you must check the status of the operator and its related resources in the OpenShift cluster. The verification can be performed using either the OpenShift web console or the oc command-line tool. 

Confirm that OADP is correctly configured by checking the status of the BackupStorageLocation and VolumeSnapshotLocation resources

##### 4.1 Check Backup storage location
Verify the backup storage location is available

```bash
oc get backupstoragelocations -n openshift-adp
```
Example output:
```bash
NAME           PHASE       LAST VALIDATED   AGE   DEFAULT
azure-backup   Available   8s               12m   true
```

Describe the location and check that the Phase is "Available"

```bash
oc describe backupstoragelocations azure-backup -n openshift-adp |grep Phase
```
Example output:
```
oc describe backupstoragelocations azure-backup -n openshift-adp |grep Phase
  Phase:                 Available
```
##### 4.2 Check Volume snapshot location
An Azure Disk CSI snapshot is stored within Azure's disk infrastructure, not in blob storage bucket.The snapshotLocation is used to tell Velero where to interact with the underlying storage system's snapshot APIs.

Verify the volume snapshot location is created

```bash
oc get volumesnapshotlocations -n openshift-adp
```
Example output:
```bash
oc get volumesnapshotlocations -n openshift-adp
NAME             AGE
azure-snapshot   15m
```

##### 4.3 Check details for volume snapshot

```bash
oc describe volumesnapshotlocations azure-snapshot -n openshift-adp
```

#### Step 5: Create test database for validation of backup and restore
To validate the backup and restore functionality, deploy a stateful application with persistent storage. The following example uses a PostgreSQL database with a PersistentVolumeClaim 

##### 5.1 Create test namespace

```bash
oc new-project $TEST_PROJECT_NAME
```

##### 5.2 Apply the manifest to create a Deployment, PVC, and Service for PostgreSQL

```bash
cat << EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql-test
  namespace: $TEST_PROJECT_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql-test
  template:
    metadata:
      labels:
        app: postgresql-test
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
      - name: postgresql
        image: registry.redhat.io/rhel8/postgresql-13:latest
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRESQL_USER
          value: "testuser"
        - name: POSTGRESQL_PASSWORD
          value: "testpassword"
        - name: POSTGRESQL_DATABASE
          value: "testdb"
        volumeMounts:
        - name: postgresql-data
          mountPath: /var/lib/pgsql/data
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          # The runAsUser is also removed here. OpenShift will use the
          # one defined at the pod level.
      volumes:
      - name: postgresql-data
        persistentVolumeClaim:
          claimName: postgresql-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-pvc
  namespace: $TEST_PROJECT_NAME
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql-service
  namespace: $TEST_PROJECT_NAME
spec:
  selector:
    app: postgresql-test
  ports:
  - port: 5432
    targetPort: 5432
EOF
```


##### 5.3 Wait for the database pod to be ready

```bash
oc wait --for=condition=ready pod -l app=postgresql-test -n $TEST_PROJECT_NAME --timeout=300s
```

##### 5.4 Add test data to the database to verify data integrity after restore

```bash
oc exec -it deployment/postgresql-test -n $TEST_PROJECT_NAME -- psql -U testuser -d testdb -c "
CREATE TABLE test_table (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO test_table (name) VALUES ('Test Data 1'), ('Test Data 2'), ('Test Data 3');
SELECT * FROM test_table;"
```

#### Step 6: Create and validate backup
Now, create a Backup custom resource to back up the test application's namespace

##### 6.1 Create backup resource

```bash
cat << EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: database-test-backup
  namespace: openshift-adp
spec:
  includedNamespaces:
  - $TEST_PROJECT_NAME
  storageLocation: azure-backup
  ttl: 720h0m0s
EOF
```

##### 6.2 Monitor backup progress

Get the name of the latest backup

```bash
BACKUP_NAME=$(oc get backups -n openshift-adp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```
Check backup status of the backup object

For backups using the Data Mover, a DataUpload CR is created. You can monitor its status.phase field, which will transition from InProgress to Completed upon successful transfer of snapshot data to the remote object store

Describe the backup to check its phase and any errors
```bash
oc describe backup $BACKUP_NAME -n openshift-adp
```

![Image3](images/backup.png)

##### (Advanced) Check the data upload status for Data Mover backups
```bash
oc get datauploads -n openshift-adp
```

##### 6.3 Verify backup in Azure
You can also verify that backup files have been created in your Azure Storage container

Note you need to have **Storage Blob Reader Role** assigned to container within storage account

Navigation Steps for setting IAM role for storage account

1. **Go to Azure Portal** - [portal.azure.com](https://portal.azure.com)
2. In the top search bar, type: `aroprojectbackups` (your storage account name)
3. Click on your storage account when it appears
4. In the left sidebar, navigate to **Data storage** → **Containers**
5. Click on **project-backups** container
6. Once inside the container, in the left sidebar click **Access Control (IAM)**
7. Click on the **Role assignments** tab
8. Look for "Storage Blob Data Reader" or "Storage Blob Data Contributor" roles

![Image](images/storage_container.png)
##### Verification of backup 

1. From the same container (`aro-project`)
2. Click **Overview** in the left sidebar (or click "aro-project" in the breadcrumb)
3. You should see folders like:
   - **backups** (since you used `prefix: backups` in your DPA)
   - Inside might be: backup files, kopia data, etc.

##### What to Verify

- **In the IAM view**: Verify your user or service principal has "Storage Blob Data Reader" role
- **In the container view**: Look for a **backups** folder (this is your prefix from the DPA configuration)

The backup should show **Phase: Completed** before files appear in Azure.(refer 6.2)

![Image2](images/storageaccount-backuprestore.png)

##### Troubleshooting
If you don't see the backup files yet, check if your backup completed successfully:

```bash
oc describe backup database-test-backup -n openshift-adp | grep Phase
```

#### Step 7: Test restore (Optional Validation)
To simulate a disaster recovery scenario, delete the test project and then restore it from the backup

##### 7.1 Delete the test project
```bash
# Delete the test namespace to simulate disaster
oc delete project $TEST_PROJECT_NAME

# Verify it's gone
oc get projects | grep $TEST_PROJECT_NAME
```

##### 7.2 Restore from backup
Create a Restore resource, referencing the backup name

```bash
cat << EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: database-test-restore
  namespace: openshift-adp
spec:
  backupName: $BACKUP_NAME
  includedNamespaces:
    - $TEST_PROJECT_NAME
  restorePVs: true
EOF
```

#### 7.3 Verify restore

Monitor the restore progress:
- Check the status of the Restore object.
- When restoring CSI volumes, a DataDownload CR is created. You can monitor its status.phase to track the data transfer from the object store back to the new volume.

Get name of latest restore
```bash
RESTORE_NAME=$(oc get restores -n openshift-adp --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```
Check the restore status
```bash
oc get restore $RESTORE_NAME -n openshift-adp
```
##### (Advanced) Check the data download status
```bash
oc get datadownloads -n openshift-adp
```
After the restore completes, verify the application pods are running
```bash
oc get pods -n $TEST_PROJECT_NAME
``` 
Verify that the test data exists in the restored database
```bash
oc exec -it deployment/postgresql-test -n $TEST_PROJECT_NAME -- psql -U testuser -d testdb -c "SELECT * FROM test_table;"
```

#### Step 8: Configure Backup Schedules (Optional)
OADP allows you to create scheduled backups using a Schedule custom resource, which uses standard cron syntax.
This example creates a daily backup at 1:00 AM with a 7-day retention period (ttl)

##### 8.1 Create daily backup schedule
```bash
cat << EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup
  namespace: openshift-adp
spec:
  schedule: "0 1 * * *"  # Daily at 1 AM
  template:
    includedNamespaces:
      - $TEST_PROJECT_NAME
    storagePolicy: snapshot
    ttl: 168h0m0s  # 7 days retention
EOF
```
#### Step 9: Cleanup Steps

##### 9.1 Delete OpenShift Resources

```bash
# delete test project 
oc delete project $TEST_PROJECT_NAME --ignore-not-found=true

# delete backups and restores
oc delete backup --all -n $OADP_NAMESPACE
oc delete restore --all -n $OADP_NAMESPACE
oc delete schedule --all -n $OADP_NAMESPACE

# delete DataProtectionApplication
oc delete dpa azure-dpa -n $OADP_NAMESPACE

# delete the secret
oc delete secret cloud-credentials -n $OADP_NAMESPACE

# uninstall OADP Operator (via OpenShift Console or CLI)
# if using CLI:
oc delete subscription redhat-oadp-operator -n $OADP_NAMESPACE
oc delete csv -n $OADP_NAMESPACE -l operators.coreos.com/redhat-oadp-operator.$OADP_NAMESPACE
oc delete operatorgroup oadp -n $OADP_NAMESPACE

# delete the namespace
oc delete namespace $OADP_NAMESPACE
```
##### 9.2 Delete Azure Service Principal and Role Assignments

```bash
# get the service principal ID
SP_ID=$(az ad sp list --display-name $SERVICE_PRINCIPAL_NAME --query "[0].id" -o tsv)

# delete role assignments for the service principal
echo "Deleting role assignments for service principal..."
az role assignment list --assignee $SP_ID --query "[].id" -o tsv | while read assignment; do
    az role assignment delete --ids $assignment
done

# delete the service principal
echo "Deleting service principal..."
az ad sp delete --id $SP_ID
```
##### 9.3. Delete Storage Container and Storage Account

```bash
# delete the container first
echo "Deleting storage container..."
az storage container delete \
  --name $CONTAINER_NAME \
  --account-name $STORAGE_ACCOUNT \
  --auth-mode login

# delete the storage account
echo "Deleting storage account..."
az storage account delete \
  --name $STORAGE_ACCOUNT \
  --resource-group $BACKUP_RG \
  --yes
```

##### 9.4. Verify Cleanup

```bash
# check if storage account is gone
az storage account show \
  --name $STORAGE_ACCOUNT \
  --resource-group $BACKUP_RG 2>/dev/null || echo "Storage account deleted successfully"

# check if service principal is gone
az ad sp show --id $SP_ID 2>/dev/null || echo "Service principal deleted successfully"

# delete the backup resource group
az group delete --name $BACKUP_RG --yes

# check if the backup resource group is gone
az group show --name aro-backup-rg 2>/dev/null && echo " Resource group still exists" || echo "Resource group deleted successfully"
```
#### Additional Note
Please note that this cleanup process **DOES NOT** delete your cluster nor the resource group of your cluster.
