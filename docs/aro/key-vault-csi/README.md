# Azure Key Vault CSI on Azure Red Hat OpenShift

**Author: Paul Czarkowski**
*Modified: 08/16/2021*

This document is adapted from the [Azure Key Vault CSI Walkthrough](https://azure.github.io/secrets-store-csi-driver-provider-azure/demos/standard-walkthrough/) specifically to run with Azure Red Hat OpenShift (ARO).

## Prerequisites

1. [An ARO cluster](/docs/quickstart-aro)
2. The AZ CLI (logged in)
3. Helm 3.x CLI

### Environment Variables

1. Run this command to set some environment variables to use throughout

    > Note if you created the cluster from the instructions linked [above](/docs/quickstart-aro) these will re-use the same environment variables, or default them to `openshift` and `eastus`.

    ```bash
    export KEYVAULT_RESOURCE_GROUP=${AZR_RESOURCE_GROUP:-"openshift"}
    export KEYVAULT_LOCATION=${AZR_RESOURCE_LOCATION:-"eastus"}
    export KEYVAULT_NAME=secret-store-$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
    export AZ_TENANT_ID=$(az account show -o tsv --query tenantId)
    ```

## Deploy Azure Key Store CSI

1. Add the Azure Helm Repository

    ```bash
    helm repo add csi-secrets-store-provider-azure \
      https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts
    ```

1. Update your local Helm Repositories

    ```bash
    helm repo update
    ```

1. Create an OpenShift Project for the CSI driver

    ```bash
    oc new-project azure-secrets-store-csi
    ```


1. Install the CSI driver

    ```bash
    helm install -n azure-secrets-store-csi csi \
      csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
      --set linux.privileged=true
    ```

1. Set SecurityContextConstraints to allow the CSI driver to run

    ```bash
    oc adm policy add-scc-to-user privileged \
      system:serviceaccount:azure-secrets-store-csi:secrets-store-csi-driver
    oc adm policy add-scc-to-user privileged \
      system:serviceaccount:azure-secrets-store-csi:csi-secrets-store-provider-azure
    ```

## Create Keyvault and a Secret

1. Create a namespace for your application

    > This service principal will be used by your application

    ```bash
    oc new-project my-application
    ```

1. Create an Azure Keyvault in your Resource Group that contains ARO

    ```bash
    az keyvault create -n ${KEYVAULT_NAME} \
      -g ${KEYVAULT_RESOURCE_GROUP} \
      --location ${KEYVAULT_LOCATION}
    ```

1. Create a secret in the Keyvault

    ```bash
    az keyvault secret set \
      --vault-name ${KEYVAULT_NAME} \
      --name secret1 --value "Hello"
    ```

1. Create a Service Principal for the keyvault

    ```bash
    export SERVICE_PRINCIPAL_CLIENT_SECRET="$(az ad sp create-for-rbac --skip-assignment --name http://secrets-store-test --query 'password' -otsv)"
    export SERVICE_PRINCIPAL_CLIENT_ID="$(az ad sp show --id http://secrets-store-test --query 'appId' -otsv)"
    ```

1. Set an Access Policy for the Service Principal

    ```bash
    az keyvault set-policy -n ${KEYVAULT_NAME} \
      --secret-permissions get \
      --spn ${SERVICE_PRINCIPAL_CLIENT_ID}
    ```

1. Create and label a secret for Kubernetes to use to access the Key Vault

    ```bash
    kubectl create secret generic secrets-store-creds \
      -n my-application \
      --from-literal clientid=${SERVICE_PRINCIPAL_CLIENT_ID} \
      --from-literal clientsecret=${SERVICE_PRINCIPAL_CLIENT_SECRET}
    kubectl -n my-application label secret \
      secrets-store-creds secrets-store.csi.k8s.io/used=true
    ```

## Deploy an Application that uses the CSI

1. Create a Secret Provider Class to give access to this secret

    ```bash
    cat <<EOF | kubectl apply -f -
    apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
    kind: SecretProviderClass
    metadata:
      name: azure-kvname
      namespace: my-application
    spec:
      provider: azure
      parameters:
        usePodIdentity: "false"
        useVMManagedIdentity: "false"
        userAssignedIdentityID: ""
        keyvaultName: "${KEYVAULT_NAME}"
        objects: |
          array:
            - |
              objectName: secret1
              objectType: secret
              objectVersion: ""
        tenantId: "${AZ_TENANT_ID}"
    EOF
    ```

1. Create a Pod that uses the above Secret Provider Class

    ```bash
    cat <<EOF | kubectl apply -f -
    kind: Pod
    apiVersion: v1
    metadata:
      name: busybox-secrets-store-inline
      namespace: my-application
    spec:
      containers:
      - name: busybox
        image: k8s.gcr.io/e2e-test-images/busybox:1.29
        command:
          - "/bin/sleep"
          - "10000"
        volumeMounts:
        - name: secrets-store-inline
          mountPath: "/mnt/secrets-store"
          readOnly: true
      volumes:
        - name: secrets-store-inline
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "azure-kvname"
            nodePublishSecretRef:
              name: secrets-store-creds
    EOF
    ```

1. Check the Secret is mounted

    ```bash
    kubectl exec busybox-secrets-store-inline -- ls /mnt/secrets-store/
    ```

    Output should match:

    ```
    secret1
    ```

1. Print the Secret

    ```bash
    kubectl exec busybox-secrets-store-inline \
      -- cat /mnt/secrets-store/secret1
    ```

    Output should match:

    ```
    Hello
    ```

## Cleanup

1. Delete the app and csi Projects

    ```bash
    oc delete project my-application azure-secrets-store-csi
    ```

1. Delete the Azure Key Vault

    ```bash
    az keyvault delete -n ${KEYVAULT_NAME} \
    ```
