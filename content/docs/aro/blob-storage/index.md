---
date: '2023-08-23'
title: Use Azure Blob storage Container Storage Interface (CSI) driver on an ARO cluster
tags: ["ARO", "Azure", "Blob", "csi"]
authors:
  - Daniel Penagos
---


The Azure Blob storage Container Storage Interface (CSI) is a CSI compliant driver that can be installed to an Azure Red Hat OpenShift (ARO) cluster to manage the lifecycle of Azure Blob storage.

When you use this CSI driver to mount an Azure Blob storage into an pod it allows you to use blob storage to work with massive amounts of data.

# Prerequisites

+ ARO cluster up and running.
+ Helm - command line utility (https://helm.sh/docs/intro/install/)
+ oc - command line utility. 
# Update the secret.

This driver should access a storage account to use the Blob containers in Azure. To do that, the driver uses proper credentials which must be populated in a secret.

When an ARO cluster is created, the installer creates also a secret named azure-cloud-provider in the kube-system namespace. This secret contains a json object. This step is just to populate this secret with other attributes needed by the CSI driver.

1. Create the secret's backup

```bash
oc get secret/azure-cloud-provider -n kube-system -o yaml > azure-cloud-provider.backup.yaml
```

1. Set the environment variables to populate the secret.

```bash
# ---IMPORTANT
# You need to set your location, cluster name and resource group name as environment variables

# LOCATION=eastus
#
# CLUSTER_NAME=my-cluster
#
# RG_NAME=myresourcegroup

TENANT_ID=$(az account show --query tenantId -o tsv)

AZURE_CNF_SECRET=$(oc get secret azure-cloud-provider -n kube-system -o jsonpath="{.data.cloud-config}" | base64 --decode)

AZURE_CNF_SECRET_LENGTH=$(echo -n $AZURE_CNF_SECRET | wc -c)

AAD_CLIENT_ID="${AZURE_CNF_SECRET:13:36}"

AAD_CLIENT_SECRET="${AZURE_CNF_SECRET:67:$AZURE_CNF_SECRET_LENGTH}"

SUB_ID=$(az account show --query id)

MANAGED_RG=$(az aro show -n $CLUSTER_NAME -g $RG_NAME --query 'clusterProfile.resourceGroupId' -o tsv)

MANAGED_RG_NAME=`echo -e $MANAGED_RG | cut -d  "/" -f5`
```

Once we have all the environment variables set, we need to create the configuration file we will use to populate the secret. 



```bash

cat <<EOF >> cloud.conf
{
"tenantId": "$TENANT_ID",
"subscriptionId": $SUB_ID,
"resourceGroup": "$MANAGED_RG_NAME",
"location": "$LOCATION",
"useManagedIdentityExtension": false,
"aadClientId": "$AAD_CLIENT_ID",
"aadClientSecret": "$AAD_CLIENT_SECRET"
}
EOF

```

Check all the attributes are populated. 

>NOTE: Take care when executing this validation, since sensitive information should be disclose in your screen. 

```bash
cat cloud.conf
```

Then, override the existing azure-cloud-provider secret.
```bash

oc create secret generic azure-cloud-provider --from-file=cloud-config=cloud.conf -n kube-system

export AZURE_CLOUD_SECRET=`cat cloud.conf | base64 | awk '{printf $0}'; echo`

cat << EOF > azure-cloud-provider.yaml
apiVersion: v1
data:
  cloud-config: ${AZURE_CLOUD_SECRET}
kind: Secret
metadata:
  name: azure-cloud-provider
  namespace: kube-system
type: Opaque
EOF

cat azure-cloud-provider.yaml
oc apply -f azure-cloud-provider.yaml

```


# Driver installation

Now, we need to install the driver, which could be installed with a helm chart. 

Create the project where you are going to install the driver. 

```bash
export CSI_BLOB_PROJECT=csi-azure-blob4
oc new-project ${CSI_BLOB_PROJECT}
```

Assign permissions to the service accounts defined in the helm chart for the driver pods.

```bash 
cat <<EOF | oc apply -f -
allowHostPorts: true
allowPrivilegedContainer: true
runAsUser:
  type: RunAsAny
users:
  - 'system:serviceaccount:${CSI_BLOB_PROJECT}:csi-blob-controller-sa'
  - 'system:serviceaccount:${CSI_BLOB_PROJECT}:csi-blob-node-sa'
allowHostDirVolumePlugin: true
seccompProfiles: 
  - '*'
seLinuxContext:
  type: RunAsAny
metadata:
  annotations:
    kubernetes.io/description: >-
      allows access to all privileged and host features and the
      ability to run as any user, any group, any fsGroup, and with any SELinux
      context.
  name: csi-azureblob-scc
fsGroup:
  type: RunAsAny
groups:
  - 'system:cluster-admins'
  - 'system:nodes'
  - 'system:masters'
kind: SecurityContextConstraints
volumes:
  - '*'
allowHostNetwork: true
apiVersion: security.openshift.io/v1
EOF

oc describe scc csi-azureblob-scc
```

Use helm to install the driver. (Blob Fuse Proxy is not supported for ARO yet)

```bash
helm repo add blob-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/charts

helm repo update

helm install blob-csi-driver blob-csi-driver/blob-csi-driver --namespace ${CSI_BLOB_PROJECT} --set linux.distro=fedora --set node.enableBlobfuseProxy=false

helm install blob-csi-driver blob-csi-driver/blob-csi-driver --set linux.distro=fedora --set node.enableBlobfuseProxy=false

```

# Test 

The first step for the test is creation of the storage account and the blob container.

```bash
APP_NAME=Myapp

#bash
export STORAGE_ACCOUNT_NAME="stweblob""${APP_NAME,,}"
#zsh
export STORAGE_ACCOUNT_NAME="stweblob""${APP_NAME:l}"

export BLOB_CONTAINER_NAME=aroblob

az storage account create --name $STORAGE_ACCOUNT_NAME --kind StorageV2 --sku Standard_LRS --location $LOCATION -g $RG_NAME 

export AZURE_STORAGE_ACCESS_KEY=$(az storage account keys list --account-name $STORAGE_ACCOUNT_NAME -g $RG_NAME --query "[0].value" | tr -d '"')

az storage account list -g $RG_NAME -o tsv

az storage container create --name $BLOB_CONTAINER_NAME

az storage container show --name $BLOB_CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME

```

At this point you need to give permissions to the cluster to access the Blob storage.

You need to go to Azure Active Directory and identify the Identity for your cluster. 
![Image](Images/blob-storage0.png)

After getting the name of your identity, you must give it access in the StorageAccount you created in the previous step.

![Image](Images/blob-storage1.png)
![Image](Images/blob-storage2.png)
![Image](Images/blob-storage3.png)
![Image](Images/blob-storage4.png)
![Image](Images/blob-storage5.png)

We need to create another project where the testing pod will run. 
```bash
export CSI_TESTING_PROJECT=testing-project
oc new-project ${CSI_TESTING_PROJECT}
```


Now, you are ready to create the storage class, the persistent volume claim and the testing pod. 

```bash
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: blob
provisioner: blob.csi.azure.com
parameters:
  resourceGroup:  $RG_NAME
  storageAccount: $STORAGE_ACCOUNT_NAME
  containerName:  $BLOB_CONTAINER_NAME
  # server: SERVER_ADDRESS  # optional, provide a new address to replace default "accountname.blob.core.windows.net"
reclaimPolicy: Retain  # if set as "Delete" container would be removed after pvc deletion
volumeBindingMode: Immediate
mountOptions:
  - -o allow_other
  - --file-cache-timeout-in-seconds=120
  - --use-attr-cache=true
  - -o attr_timeout=120
  - -o entry_timeout=120
  - -o negative_timeout=120
EOF

cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-blob
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: blob
EOF

cat <<EOF | oc apply -f -
kind: Pod
apiVersion: v1
metadata:
  name: nginx-blob
spec:
  nodeSelector:
    "kubernetes.io/os": linux
  containers:
    - image: mcr.microsoft.com/oss/nginx/nginx:1.17.3-alpine
      name: nginx-blob
      command:
        - "/bin/sh"
        - "-c"
        - while true; do echo $(date) >> /mnt/blob/outfile; sleep 1; done
      volumeMounts:
        - name: blob01
          mountPath: "/mnt/blob"
  volumes:
    - name: blob01
      persistentVolumeClaim:
        claimName: pvc-blob
EOF

oc get po
oc exec -it nginx-blob -- sh
df -h
ls -al /mnt/blob/outfile
cat /mnt/blob/outfile
```

References:

- https://github.com/kubernetes-sigs/blob-csi-driver/blob/master/charts/README.md