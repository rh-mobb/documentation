---
date: '2023-08-23'
title: Use Azure Blob storage Container Storage Interface (CSI) driver on an ARO cluster
tags: ["ARO", "Azure", "Blob", "csi"]
authors:
  - Daniel Penagos
  - Paul Czarkowski
---


The Azure Blob storage Container Storage Interface (CSI) is a CSI compliant driver that can be installed to an Azure Red Hat OpenShift (ARO) cluster to manage the lifecycle of Azure Blob storage.

When you use this CSI driver to mount an Azure Blob storage into an pod it allows you to use blob storage to work with massive amounts of data.

## Prerequisites

* ARO cluster up and running.
* [Helm - command line utility](https://helm.sh/docs/intro/install/)
* oc - command line utility. 

## Environment


1. Set the environment variables to populate the secret.

    > Update the `LOCATION`, `CLUSTER_NAME`, and `RG_NAME` variables to match your cluster details

    > Update `BLOB_CONTAINER_NAME` and `APP_NAME` to unique values

    ```bash
    export LOCATION=eastus
    export CLUSTER_NAME=my-cluster
    export RG_NAME=myresourcegroup
    export BLOB_CONTAINER_NAME=aroblob
    export APP_NAME=Myapp
    export CSI_TESTING_PROJECT=testing-project
    export TENANT_ID=$(az account show --query tenantId -o tsv)
    export AZURE_CNF_SECRET=$(oc get secret azure-cloud-provider -n kube-system -o jsonpath="{.data.cloud-config}" | base64 --decode)
    export AZURE_CNF_SECRET_LENGTH=$(echo -n ${AZURE_CNF_SECRET} | wc -c)
    export AAD_CLIENT_ID="${AZURE_CNF_SECRET:13:36}"
    export AAD_CLIENT_SECRET="${AZURE_CNF_SECRET:67:$AZURE_CNF_SECRET_LENGTH}"
    export SUB_ID=$(az account show --query id)
    export MANAGED_RG=$(az aro show -n $CLUSTER_NAME -g $RG_NAME --query 'clusterProfile.resourceGroupId' -o tsv)
    export MANAGED_RG_NAME=$(echo -e $MANAGED_RG | cut -d  "/" -f5)
    export CSI_BLOB_PROJECT=csi-azure-blob

    export SCRATCH_DIR="/tmp/$CLUSTER_NAME/aro-blob-csi"
    mkdir -p "${SCRATCH_DIR}"
    cd "${SCRATCH_DIR}"
    ```

## Create a secret for the Azure Blob Storage CSI

This driver should access a storage account to use the Blob containers in Azure. To do that, the driver uses proper credentials which must be populated in a secret.

When an ARO cluster is created, the installer creates also a secret named azure-cloud-provider in the kube-system namespace. This secret contains a json object. This step is just to populate this secret with other attributes needed by the CSI driver.

1. Create a backup for the azure cloud provider secret

    ```bash
    oc get secret/azure-cloud-provider -n kube-system -o yaml > azure-cloud-provider.backup.yaml
    ```

1. Create a config file for the CSI driver

    ```bash
    cat <<EOF > cloud.conf
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

1. Check all the attributes are populated. 

    > NOTE: Take care when executing this validation, since sensitive information should be disclose in your screen. 

    ```bash
    # cat cloud.conf
    ```

1. Override the existing azure-cloud-provider secret.

    ```bash
    oc set data -n kube-system secret azure-cloud-provider --from-file=cloud-config=cloud.conf
    ```


## Azure Blob Storage CSI Driver installation

Now, we need to install the driver, which could be installed with a helm chart. 

1. Create the project where you are going to install the driver. 

    ```bash
    oc new-project ${CSI_BLOB_PROJECT}
    ```

1. Assign permissions to the service accounts defined in the helm chart for the driver pods.

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: security.openshift.io/v1
    kind: SecurityContextConstraints
    metadata:
      annotations:
        kubernetes.io/description: >-
          allows access to all privileged and host features and the
          ability to run as any user, any group, any fsGroup, and with any SELinux
          context.
      name: csi-azureblob-scc
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

    oc describe scc csi-azureblob-scc
    ```

1. Use helm to install the driver. 

    > Note Blob Fuse Proxy is not supported for ARO yet, so we disable it.

    ```bash
    helm repo add blob-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/charts

    helm repo update

    helm install blob-csi-driver blob-csi-driver/blob-csi-driver --namespace ${CSI_BLOB_PROJECT} \
      --set linux.distro=fedora --set node.enableBlobfuseProxy=false
    ```

## Test the CSI driver is working

1. The first step for the test is creation of the storage account and the blob container.

    ```bash
    export STORAGE_ACCOUNT_NAME="$(echo "${CLUSTER_NAME}${APP_NAME}" | tr '[:upper:]' '[:lower:]')"

    az storage account create --name $STORAGE_ACCOUNT_NAME --kind StorageV2 --sku Standard_LRS --location $LOCATION -g $RG_NAME 

    export AZURE_STORAGE_ACCESS_KEY=$(az storage account keys list --account-name $STORAGE_ACCOUNT_NAME -g $RG_NAME --query "[0].value" | tr -d '"')

    az storage account list -g $RG_NAME -o tsv

    az storage container create --name $BLOB_CONTAINER_NAME

    az storage container show --name $BLOB_CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME
    ```

1. At this point you need to give permissions to the cluster to access the Blob storage.

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
    oc rsh nginx-blob
    ls -al /mnt/blob/outfile
    cat /mnt/blob/outfile
    ```

## Cleanup

TODO Add instructions to clean up the environment

References:

- https://github.com/kubernetes-sigs/blob-csi-driver/blob/master/charts/README.md