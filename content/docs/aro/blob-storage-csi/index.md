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

## Prerequisites

* ARO cluster up and running.
* [Helm - command line utility] (https://helm.sh/docs/intro/install/)
* oc - command line utility. 

## Create an identity for the CSI Driver to access the Blob Storage

The cluster must use an identity with proper permissions to access the blob storage. To do that, the best approach is to create a specific service principal for this purpose. 

1. In the Azure Portal, go to AAD and register a new application with a proper name to identify that this registration is for the driver to access the Blob Storage

![Image](Images/blob-sp0.png)

![Image](Images/blob-sp1.png)

1. Once created, take note of the Client Id in the overview section.


![Image](Images/blob-sp1-1.png)

1. Set an environment variable with the value of the Client ID.

    ```bash
    export AAD_CLIENT_ID=REPLACE-WITH-YOUR-CLIENT-ID
    ```

1. Then, you need to create a secret for this registration. Go to "certificates & secrets" within the registration and create the new secret.

![Image](Images/blob-sp2.png)

1. Take note of the secret just created, and copy the value of it.

![Image](Images/blob-sp3.png)

1. Set another environment variable with the value of the Client Secret Value.

    ```bash
    export AAD_CLIENT_SECRET=REPLACE-WITH-YOUR-CLIENT-SECRET-VALUE
    ```

1. Set other environment variables:

    > Update the `LOCATION`, `CLUSTER_NAME`, and `RG_NAME` variables to match your cluster details

    ```bash
    export LOCATION=eastus
    export CLUSTER_NAME=my-cluster
    export RG_NAME=myresourcegroup 
    export TENANT_ID=$(az account show --query tenantId -o tsv)
    export SUB_ID=$(az account show --query id)
    export MANAGED_RG=$(az aro show -n $CLUSTER_NAME -g $RG_NAME --query 'clusterProfile.resourceGroupId' -o tsv)
    export MANAGED_RG_NAME=`echo -e $MANAGED_RG | cut -d  "/" -f5`
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

1. Create the project where you are going to install the driver.

    ```bash
    export CSI_BLOB_PROJECT=csi-azure-blob
    oc new-project ${CSI_BLOB_PROJECT}
    ```

1. Then, create the secret into the project just created.

    ```bash
    export CSI_BLOB_SECRET=csi-azure-blob-secret
    oc create secret generic ${CSI_BLOB_SECRET} --from-file=cloud-config=cloud.conf
    ```


## Driver installation

Now, we need to install the driver, which could be done using a helm chart. 

1. Assign permissions to the service accounts defined in the helm chart for the driver pods.

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

1. Use helm to install the driver. 

    > Note Blob Fuse Proxy is not supported for ARO yet, so we disable it.

    ```bash
    helm repo add blob-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/charts

    helm repo update

    helm install blob-csi-driver blob-csi-driver/blob-csi-driver --namespace ${CSI_BLOB_PROJECT} --set linux.distro=fedora --set node.enableBlobfuseProxy=false --set node.cloudConfigSecretNamespace=${CSI_BLOB_PROJECT} --set node.cloudConfigSecretName=${CSI_BLOB_SECRET} --set controller.cloudConfigSecretNamespace=${CSI_BLOB_PROJECT} --set controller.cloudConfigSecretName=${CSI_BLOB_SECRET}

    ```

## Test the CSI driver is working

1. The first step for the test is the creation of the storage account and the blob container.

    ```bash
    export APP_NAME=Myapp

    #bash
    export STORAGE_ACCOUNT_NAME="stweblob""${APP_NAME,,}"
    #zsh
    export STORAGE_ACCOUNT_NAME="stweblob""${APP_NAME:l}"

    export BLOB_CONTAINER_NAME=aroblob

    az storage account create --name $STORAGE_ACCOUNT_NAME --kind StorageV2 --sku Standard_LRS --location $LOCATION -g $RG_NAME 

    export AZURE_STORAGE_ACCESS_KEY=$(az storage account keys list --account-name $STORAGE_ACCOUNT_NAME -g $RG_NAME --query "[0].value" | tr -d '"')
    
    az storage account list -g $RG_NAME -o tsv

    az storage container create --name $BLOB_CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME

    az storage container show --name $BLOB_CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME

    ```

1. At this point, you must give permissions to the driver to access the Blob storage.

    Go to Azure Active Directory and locate the  identity you created manually in the previous section. 
    ![Image](images/blob-storage0.png)

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
   az ad app delete --id $(az ad app list --app-id=${AAD_CLIENT_ID} | jq -r '.[0].id')

   ```


References:

- https://github.com/kubernetes-sigs/blob-csi-driver/blob/master/charts/README.md