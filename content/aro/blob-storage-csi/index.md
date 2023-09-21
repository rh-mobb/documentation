---
date: '2023-08-23'
title: Use Azure Blob storage Container Storage Interface (CSI) driver on an ARO cluster
tags: ["ARO", "Azure", "Blob", "csi"]
authors:
  - Daniel Penagos
  - Paul Czarkowski
---


The Azure Blob Storage Container Storage Interface (CSI) is a CSI compliant driver that can be installed to an Azure Red Hat OpenShift (ARO) cluster to manage the lifecycle of Azure Blob storage.

When you use this CSI driver to mount an Azure Blob storage into a pod, it allows you to use blob storage to work with massive amounts of data.

You can refer also to the driver's documentation [here](https://github.com/kubernetes-sigs/blob-csi-driver/blob/master/charts/README.md).

## Prerequisites

* ARO cluster up and running.
* [Helm - command line utility](https://helm.sh/docs/intro/install/)
* oc - command line utility. 
* jq - command line utility.

1. Set the environment variables related to your cluster environment:

    > Update the `LOCATION`, `CLUSTER_NAME`, and `RG_NAME` variables in the snippet below to match your cluster details:

    ```bash
    export LOCATION=eastus
    export CLUSTER_NAME=my-cluster
    export RG_NAME=myresourcegroup 
    export TENANT_ID=$(az account show --query tenantId -o tsv)
    export SUB_ID=$(az account show --query id)
    export MANAGED_RG=$(az aro show -n $CLUSTER_NAME -g $RG_NAME --query 'clusterProfile.resourceGroupId' -o tsv)
    export MANAGED_RG_NAME=`echo -e $MANAGED_RG | cut -d  "/" -f5`    
    ```
1. Set some environment variables related to the project and secret names used to install the driver, and the testing project's name where a pod will be using the configured storage:

    ```bash
    export CSI_BLOB_PROJECT=csi-azure-blob
    export CSI_BLOB_SECRET=csi-azure-blob-secret
    export CSI_TESTING_PROJECT=testing-project
    ```

1. Set other environment variables to be used to create the testing resources, such as the azure storage account and its blob container:

    ```bash
    export APP_NAME=myapp
    export STORAGE_ACCOUNT_NAME=aroblobsa
    export BLOB_CONTAINER_NAME=aroblob
    ```

## Create an identity for the CSI Driver to access the Blob Storage

The cluster must use an identity with proper permissions to access the blob storage. 
1. Create a specific service principal for this purpose. 

    ```bash
    export APP=$(az ad sp create-for-rbac --display-name aro-blob-csi)
    export AAD_CLIENT_ID=$(echo $APP | jq -r '.appId')
    export AAD_CLIENT_SECRET=$(echo $APP | jq -r '.password')
    export AAD_OBJECT_ID=$(az ad app list --app-id=${AAD_CLIENT_ID} | jq -r '.[0].id')

    ```

1. Once we have all the environment variables set, we need to create the configuration file we will use to populate a json structure with all the data needed. 


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

1. Check that all the attributes are populated. 

    >NOTE: Take care when executing this validation, since sensitive information should be disclosed in your screen. 

    ```bash
    cat cloud.conf
    ```

1. Create the project where you are going to install the driver and then create the secret in it.

    ```bash
    oc new-project ${CSI_BLOB_PROJECT}

    oc create secret generic ${CSI_BLOB_SECRET} --from-file=cloud-config=cloud.conf
    ```

    >NOTE: It is good idea to delete the cloud.conf file, since it has sensitive information. 

    ```bash
    rm cloud.conf
    ```


## Driver installation

Now, we need to install the driver, which could be done using a helm chart. This helm chart will install two pods in the driver's project. 

1. Assign permissions to the defined driver service accounts prior to the helm chart installation.

    ```bash 
    cat <<EOF | oc apply -f -
    apiVersion: security.openshift.io/v1
    kind: SecurityContextConstraints
    metadata:
      name: csi-azureblob-scc
      annotations:
        kubernetes.io/description: >-
          allows access to all privileged and host features and the
          ability to run as any user, any group, any fsGroup, and with any SELinux
          context.
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
    fsGroup:
      type: RunAsAny
    groups:
      - 'system:cluster-admins'
      - 'system:nodes'
      - 'system:masters'
    volumes:
      - '*'
    allowHostNetwork: true    
    EOF
    ```

1. Use helm to install the driver once we have the permissions set. 

    > Note Blob Fuse Proxy is not supported for ARO yet, so we disable it.

    ```bash
    helm repo add blob-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/charts

    helm repo update

    helm install blob-csi-driver blob-csi-driver/blob-csi-driver \
      --namespace ${CSI_BLOB_PROJECT} \
      --set linux.distro=fedora \
      --set node.enableBlobfuseProxy=false \
      --set node.cloudConfigSecretNamespace=${CSI_BLOB_PROJECT} \
      --set node.cloudConfigSecretName=${CSI_BLOB_SECRET} \
      --set controller.cloudConfigSecretNamespace=${CSI_BLOB_PROJECT} \
      --set controller.cloudConfigSecretName=${CSI_BLOB_SECRET}

    ```

## Test the CSI driver is working

1. The first step for the test is the creation of the storage account and the blob container.

    ```bash
    export AZURE_STORAGE_ACCOUNT=$(az storage account create --name $STORAGE_ACCOUNT_NAME --kind StorageV2 --sku Standard_LRS --location $LOCATION -g $RG_NAME)

    export AZURE_STORAGE_ACCOUNT_ID=$(echo $AZURE_STORAGE_ACCOUNT | jq -r '.id')

    export AZURE_STORAGE_ACCESS_KEY=$(az storage account keys list --account-name $STORAGE_ACCOUNT_NAME -g $RG_NAME --query "[0].value" | tr -d '"')

    az storage container create --name $BLOB_CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME

    az storage container show --name $BLOB_CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME
    ```

1. At this point, you must give permissions to the driver to access the Blob storage.
    ```bash
    az role assignment create --assignee $AAD_CLIENT_ID \
      --role "Contributor" \
      --scope ${AZURE_STORAGE_ACCOUNT_ID}
    ```

1. We need to create another project where the testing pod will run. 

    ```bash
    oc new-project ${CSI_TESTING_PROJECT}
    ```


1. Now, you are ready to create the storage class, the persistent volume claim and the testing pod. 

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
    reclaimPolicy: Retain  # if set as "Delete" container would be removed after pvc deletion
    volumeBindingMode: Immediate
    mountOptions:
      - -o allow_other
      - --file-cache-timeout-in-seconds=120
      - --use-attr-cache=true
      - -o attr_timeout=120
      - -o entry_timeout=120
      - -o negative_timeout=120
    
    ---
    
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
    
    ---
    
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
    ```

1. Wait until the Pod is created
    
    ```bash
    oc get po
    ```

1. Get a shell inside the pod and view the file in the blob storage
    
    ```bash
    oc exec -it nginx-blob -- sh
    df -h
    ls -al /mnt/blob/outfile
    cat /mnt/blob/outfile
    ```
1. You should see an output like this:

    ![Image](images/blob-test.png)


## Clean up

This section is to delete all the resources created with this guideline. 

   ```bash
   oc delete pod nginx-blob -n ${CSI_TESTING_PROJECT}
   oc delete project ${CSI_TESTING_PROJECT}
   helm uninstall blob-csi-driver -n ${CSI_BLOB_PROJECT}
   oc delete project ${CSI_BLOB_PROJECT}
   oc delete pvc pvc-blob
   oc delete sc blob
   oc delete pv $(oc get pv -o json | jq -r '.items[] | select(.spec.csi.driver | test("blob.csi.azure.com")).metadata.name')
   az storage account delete --name $STORAGE_ACCOUNT_NAME -g $RG_NAME 
   az ad app delete --id ${AAD_OBJECT_ID}

   ```
