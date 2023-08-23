---
date: '2023-08-23'
title: Azure Blob Integration
tags: ["ARO", "Azure", "Blob"]
authors:
  - Daniel Penagos
---

Guide to integrate an ARO cluster with an Azure Blob in an Azure Storage Account.

# Create the secret.

```bash
mkdir deploy
tenantId=$(az account show --query tenantId -o tsv)

# ---IMPORTANT
# You need to set your location, cluster name and resource group name as environment variables

# location=eastus
# cluster_name=my-cluster
# rg_name=myresourcegroup

oc describe secret azure-cloud-provider -n kube-system
azure_cnf_secret=$(oc get secret azure-cloud-provider -n kube-system -o jsonpath="{.data.cloud-config}" | base64 --decode)
echo "Azure Cloud Provider config secret " $azure_cnf_secret

azure_cnf_secret_length=$(echo -n $azure_cnf_secret | wc -c)
echo "Azure Cloud Provider config secret length " $azure_cnf_secret_length

aadClientId="${azure_cnf_secret:13:36}"
echo "aadClientId " $aadClientId

aadClientSecret="${azure_cnf_secret:67:$azure_cnf_secret_length}"
echo "aadClientSecret" $aadClientSecret

subId=$(az account show --query id)
echo "subscription ID :" $subId

managed_rg=$(az aro show -n $cluster_name -g $rg_name --query 'clusterProfile.resourceGroupId' -o tsv)
echo "ARO Managed Resource Group : " $managed_rg

managed_rg_name=`echo -e $managed_rg | cut -d  "/" -f5`
echo "ARO RG Name" $managed_rg_name
```

Once we have all the environment variables set, we need to create the configuration file we will use to populate the secret.

```bash
cat <<EOF >> deploy/cloud.conf
{
"tenantId": "$tenantId",
"subscriptionId": $subId,
"resourceGroup": "$managed_rg_name",
"location": "$location",
"useManagedIdentityExtension": false,
"aadClientId": "$aadClientId",
"aadClientSecret": "$aadClientSecret"
}
EOF

```

Check all the attributes are populated. 
```bash
cat deploy/cloud.conf
```

Then, create the secret with the information in place.
```bash
export AZURE_CLOUD_SECRET=`cat deploy/cloud.conf | base64 | awk '{printf $0}'; echo`

cat << EOF > deploy/azure-cloud-provider.yaml
apiVersion: v1
data:
  cloud-config: ${AZURE_CLOUD_SECRET}
kind: Secret
metadata:
  name: azure-cloud-provider
  namespace: kube-system
type: Opaque
EOF

cat deploy/azure-cloud-provider.yaml
oc apply -f ./deploy/azure-cloud-provider.yaml

```

Assign permissions to the service account.

```bash
oc adm policy add-scc-to-user privileged system:serviceaccount:kube-system:csi-azureblob-node-sa
oc describe scc privileged
```
# Driver installation

Use helm to install the driver. (Blob Fuse Proxy is not supported for ARO yet)

```bash
helm repo add blob-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/charts

helm install blob-csi-driver blob-csi-driver/blob-csi-driver --namespace kube-system --set linux.distro=fedora --set node.enableBlobfuseProxy=false
```

# Test 

```bash
appName=Myapp

#bash
str_name="stweblob""${appName,,}"
#zsh
str_name="stweblob""${appName:l}"

export AZURE_STORAGE_ACCOUNT=$str_name

az storage account create --name $str_name --kind StorageV2 --sku Standard_LRS --location $location -g $rg_name 
az storage account list -g $rg_name -o tsv

httpEndpoint=$(az storage account show --name $str_name -g $rg_name --query "primaryEndpoints.blob" | tr -d '"')
echo "httpEndpoint" $httpEndpoint 

export AZURE_STORAGE_ACCESS_KEY=$(az storage account keys list --account-name $str_name -g $rg_name --query "[0].value" | tr -d '"')
echo "storageAccountKey" $AZURE_STORAGE_ACCESS_KEY 

blob_container_name=aroblob
az storage container create --name $blob_container_name
az storage container list --account-name $str_name
az storage container show --name $blob_container_name --account-name $str_name

export RESOURCE_GROUP=$rg_name
export STORAGE_ACCOUNT_NAME=$str_name
export CONTAINER_NAME=$blob_container_name

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

Now, you are ready to create the storage class, the persistent volume claim and the testing pod. 

```bash
cat << EOF > deploy/storageclass-blobfuse-existing-container.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: blob
provisioner: blob.csi.azure.com
parameters:
  resourceGroup:  $RESOURCE_GROUP
  storageAccount: $STORAGE_ACCOUNT_NAME
  containerName:  $CONTAINER_NAME
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

cat deploy/storageclass-blobfuse-existing-container.yaml

oc create -f ./deploy/storageclass-blobfuse-existing-container.yaml


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