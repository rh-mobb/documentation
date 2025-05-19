---
date: '2023-06-27T22:07:09.774151'
title: Configure an ARO cluster with Azure Files using a private endpoint
tags: ["ARO", "Azure"]
authors:
  - Kevin Collins
  - Kumudu Herath
  - Connor Wooley
  - Dustin Scott
---

Effectively securing your Azure Storage Account requires more than just basic access controls. Azure Private Endpoints provide a powerful layer of protection by establishing a direct, private connection between your virtual network and storage resources—completely bypassing the public internet. This approach not only minimizes your attack surface and the risk of data exfiltration, but also enhances performance through reduced latency, simplifies network architecture, supports compliance efforts, and enables secure hybrid connectivity. It's a comprehensive solution for protecting your critical cloud data.

There are two way to configure this set up
1. Self provision the storage account and file share (static method)
  - Requires pre-existing storage account and file share
2. Auto provision the storage account and file share (dynamic method)
  - CSI will create the storage account and file share

Configuring private endpoint access to an Azure Storage Account involves three key steps:

1) (Static method only) Create the storage account

2) Create the private endpoint

3) Define a new storage class for Azure Red Hat OpenShift (ARO)

>Note: In many environments, Azure administrators use automation to streamline steps 1 and 2. This typically ensures the storage account is provisioned according to organizational policies—such as encryption and security configurations—along with the automatic creation of the associated private endpoint.




> **WARNING** please note that this approach does not work on FIPS-enabled clusters.  This is due to the CIFS protocol being largely non-compliant with FIPS cryptographic requirements.  Please see the following for more 
information:

- [Red Hat Article on CIFS/FIPS](https://access.redhat.com/solutions/256053)
- [Microsoft Article on CIFS/FIPS](https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/fail-to-mount-azure-file-share#fipsnodepool)

## Pre Requisites

- ARO cluster logged into
- oc cli

## Set Environment Variables

Set the following variables to match your ARO cluster and Azure storage account naming.

```bash
AZR_CLUSTER_NAME=<my-cluster-name>
AZR_RESOURCE_GROUP=<my-rg>
AZR_STORAGE_ACCOUNT_NAME=<my-storage-account> # Name of the storage account
SECRET_NAME=azure-files-secret # Name of the secret used to access Azure Files
SECRET_NAMESPACE=default # OpenShift Project where the secret will be create in
STORAGECLASS_NAME=azure-files # Name of the OpenShift Storage Class that will be created

```

Dynamically get the region the ARO cluster is in

```bash
 export AZR_REGION=$(az aro show  -n ${AZR_CLUSTER_NAME} -g ${AZR_RESOURCE_GROUP} | jq -r '.location')
```

The Azure Private endpoint needs to be placed in a subnet.  General best practices are to place private endpoints in their own subnet.  Often times however, this might not be possible due to the vnet design and the privae endpoint will need to placed in the worker node subnet.

Option 1: Retrieve the worker node subnet that the private endpoint will be create it.

```bash
SUBNET_ID=$(az aro show  -n ${AZR_CLUSTER_NAME} -g ${AZR_RESOURCE_GROUP} | jq -r '.workerProfiles[0].subnetId') 

AZR_VNET=$(echo ${SUBNET_ID} | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="virtualNetworks") print $(i+1)}')
```

Option 2: Manually specify the private service endpoint subnet and vnet you would like to use.

```bash
SUBNET_ID=<SUBNET_ID> # The SubnetId you want to use for private endpoints
AZR_VNET=<Azure VNet> # The name of the VNet the subnet you want to use for private endpoints
```

## Self-Provision Storage Account and File Share (Static Method) 

>Note if you would like to dynamically provision the storage account using the CSI provisioner skip the first step

1. Create the storage account and attach the private endpoint to it  

```bash
az storage account create \
    --name ${AZR_STORAGE_ACCOUNT_NAME} \
    --resource-group ${AZR_RESOURCE_GROUP} \
    --location ${AZR_REGION} \
    --sku Premium_LRS \
    --public-network-access Disabled \
    --kind StorageV2
```

```bash
az storage account create \
    --name ${AZR_STORAGE_ACCOUNT_NAME} \
    --resource-group ${AZR_RESOURCE_GROUP} \
    --location ${AZR_REGION} \
    --sku Premium_LRS \
    --public-network-access Disabled \
    --kind FileStorage \
    --enable-large-file-share \
    --file-share-access-tier Premium
```

## Create/Configure the Private Endpoint

1. Create private endpoint 

```bash
az network private-endpoint create \
  --name $AZR_CLUSTER_NAME \
  --resource-group ${AZR_RESOURCE_GROUP} \
  --vnet-name ${AZR_VNET} \
  --subnet ${SUBNET_ID} \
  --private-connection-resource-id $(az resource show -g ${AZR_RESOURCE_GROUP} -n ${AZR_STORAGE_ACCOUNT_NAME} --resource-type "Microsoft.Storage/storageAccounts" --query "id" -o tsv) \
  --location ${AZR_REGION} \
  --group-id file \
  --connection-name ${AZR_STORAGE_ACCOUNT_NAME}
```

### DNS Resolution for Private Connection

2. Configure the private DNS zone for the private link connection

In order to use the private endpoint connection you will need to create a private DNS zone, if not configured correctly, the connection will attempt to use the public IP (file.core.windows.net) whereas the private connection's domain is prefixed with 'privatelink'

```bash
az network private-dns zone create \
  --resource-group ${AZR_RESOURCE_GROUP} \
  --name "privatelink.file.core.windows.net"
  
az network private-dns link vnet create \
  --resource-group ${AZR_RESOURCE_GROUP} \
  --zone-name "privatelink.file.core.windows.net" \
  --name $AZR_CLUSTER_NAME \
  --virtual-network ${AZR_VNET} \
  --registration-enabled false
```


  If you are using a custom DNS server on your network, clients must be able to resolve the FQDN for the storage account endpoint to the private endpoint IP address. You should configure your DNS server to delegate your private link subdomain to the private DNS zone for the VNet, or configure the A records for `StorageAccountA.privatelink.file.core.windows.net` with the private endpoint IP address.

  When using a custom or on-premises DNS server, you should configure your DNS server to resolve the storage account name in the privatelink subdomain to the private endpoint IP address. You can do this by delegating the privatelink subdomain to the private DNS zone of the VNet or by configuring the DNS zone on your DNS server and adding the DNS A records.


*For MAG customers:*

  [GOV Private Endpoint DNS](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns#government)

  [Custom DNS Config](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns#virtual-network-workloads-without-custom-dns-server)


3. Retrieve the private IP from the private link connection:

```bash
PRIVATE_IP=`az resource show \
  --ids $(az network private-endpoint show --name $AZR_CLUSTER_NAME --resource-group ${AZR_RESOURCE_GROUP} --query 'networkInterfaces[0].id' -o tsv) \
  --api-version 2019-04-01 \
  -o json | jq -r '.properties.ipConfigurations[0].properties.privateIPAddress'`
```
4. Create the DNS records for the private link connection:

```bash
az network private-dns record-set a create \
  --name ${AZR_STORAGE_ACCOUNT_NAME} \
  --zone-name privatelink.file.core.windows.net \
  --resource-group ${AZR_RESOURCE_GROUP}

az network private-dns record-set a add-record \
  --record-set-name ${AZR_STORAGE_ACCOUNT_NAME} \
  --zone-name privatelink.file.core.windows.net \
  --resource-group ${AZR_RESOURCE_GROUP} \
  -a ${PRIVATE_IP}
```

5. test private endpoint connectivity
  - on a Vm in the vnet run 

```bash 
nslookup ${AZR_STORAGE_ACCOUNT_NAME}.file.core.windows.net
```

- Should return:

```
Server:		x.x.x.x
Address:	x.x.x.x#x

Non-authoritative answer:
<storage_account_name>.file.core.windows.net	canonical name = <storage_account_name>.privatelink.file.core.windows.net.
Name:	<storage_account_name>.privatelink.file.core.windows.net
Address: x.x.x.x
```

## Configure ARO Storage Resources

1. Login to your cluster

2. Set ARO Cluster permissions

```bash
oc create clusterrole azure-secret-reader \
  --verb=create,get \
  --resource=secrets

oc adm policy add-cluster-role-to-user azure-secret-reader system:serviceaccount:kube-system:persistent-volume-binder
```

2. Create a secret object containing azure file creds

```bash
AZR_STORAGE_KEY=$(az storage account keys list --account-name ${AZR_STORAGE_ACCOUNT_NAME} --query "[0].value" -o tsv)

oc create secret generic ${SECRET_NAME}--from-literal=azurestorageaccountname=${AZR_STORAGE_ACCOUNT_NAME} --from-literal=azurestorageaccountkey=${AZR_STORAGE_KEY}
```

3. Create a static storage class (see below for dynamic method)

> **NOTE** only needed if using the static provisioning method

- The CSI can either create volumes in pre created storage accounts or dynamically create the storage account with a volume inside the dynamic storage account

- Using an existing storage account
```bash
cat  <<EOF | oc apply -f -
    allowVolumeExpansion: true
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: ${STORAGECLASS_NAME}
    parameters:
      resourceGroup: ${AZR_RESOURCE_GROUP}
      server: ${AZR_STORAGE_ACCOUNT_NAME}.file.core.windows.net
      secretNamespace: kube-system
      skuName: Premium_LRS
      storageAccount: ${AZR_STORAGE_ACCOUNT_NAME}
    provisioner: file.csi.azure.com
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
EOF
```

- Create a dynamic storage class

> **NOTE** only needed if using the dynamic provisioning method (see above for static method)

```bash
cat  <<EOF | oc apply -f -
    allowVolumeExpansion: true
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: ${STORAGECLASS_NAME}
    parameters:
      resourceGroup: ${AZR_RESOURCE_GROUP}
      skuName: Premium_LRS
      secretName: ${SECRET_NAME}
      secretNamespace: ${SECRET_NAMESPACE}
      networkEndpointType: privateEndpoint
    provisioner: file.csi.azure.com
    reclaimPolicy: Delete
    volumeBindingMode: Immediate
EOF
```

## Test it out
1. Create a PVC

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-azure-files-volume
   spec:
     storageClassName: azure-files
     accessModes:
       - ReadWriteMany
     resources:
       requests:
         storage: 5Gi
   EOF
   ```

1. Create a Pod to write to the Azure Files Volume

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
    name: test-files
   spec:
    volumes:
      - name: files-storage-vol
        persistentVolumeClaim:
          claimName: pvc-azure-files-volume
    containers:
      - name: test-files
        image: centos:latest
        command: [ "/bin/bash", "-c", "--" ]
        args: [ "while true; do echo 'hello azure files' | tee -a /mnt/files-data/verify-files && sleep 5; done;" ]
        volumeMounts:
          - mountPath: "/mnt/files-data"
            name: files-storage-vol
   EOF
   ```

   > It may take a few minutes for the pod to be ready.  

1. Wait for the Pod to be ready

   ```bash
   watch oc get pod test-files
   ```

1. Create a Pod to read from the Azure Files Volume

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
    name: test-files-read
   spec:
    volumes:
      - name: files-storage-vol
        persistentVolumeClaim:
          claimName: pvc-azure-files-volume
    containers:
      - name: test-files-read
        image: centos:latest
        command: [ "/bin/bash", "-c", "--" ]
        args: [ "tail -f /mnt/files-data/verify-files" ]
        volumeMounts:
          - mountPath: "/mnt/files-data"
            name: files-storage-vol
   EOF
   ```

1. Verify the second POD can read the Azure Files Volume

   ```bash
   oc logs test-files-read
   ```

    You should see a stream of "hello azure files"

   ```
   hello azure files
   hello azure files
   hello azure files
   hello azure files
   hello azure files
   hello azure files
   hello azure files
   hello azure files
   hello azure files
   hello azure files
   ```