---
date: '2022-09-14T22:07:09.804151'
title: Azure Key Vault CSI on Azure Red Hat OpenShift
aliases: ['/docs/security/secrets-store-csi/azure-key-vault']
tags: ["Azure", "ARO"]
---

Author: [Paul Czarkowski](https://github.com/paulczar)

*Last modified: 03/29/2023*

This document is adapted from the [Azure Key Vault CSI Walkthrough](https://azure.github.io/secrets-store-csi-driver-provider-azure/docs/demos/standard-walkthrough/) specifically to run with Azure Red Hat OpenShift (ARO).

## Prerequisites

1. [An ARO cluster](/docs/quickstart-aro)
2. The AZ CLI (logged in)
3. The OC CLI (logged in)
4. Helm 3.x CLI

### Environment Variables

1. Run this command to set some environment variables to use throughout

    > Note if you created the cluster from the instructions linked [above](/docs/quickstart-aro) these will re-use the same environment variables, or default them to `openshift` and `eastus`.

    ```bash
    export KEYVAULT_RESOURCE_GROUP=${AZR_RESOURCE_GROUP:-"openshift"}
    export KEYVAULT_LOCATION=${AZR_RESOURCE_LOCATION:-"eastus"}
    export KEYVAULT_NAME=secret-store-$(cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
    export AZ_TENANT_ID=$(az account show -o tsv --query tenantId)
    ```

{{< readfile file="/docs/misc/secrets-store-csi/install-kubernetes-secret-store-driver.md" markdown="true" >}}

## Deploy Azure Key Store CSI

1. Add the Azure Helm Repository

    ```bash
    helm repo add csi-secrets-store-provider-azure \
      https://azure.github.io/secrets-store-csi-driver-provider-azure/charts
    ```

1. Update your local Helm Repositories

    ```bash
    helm repo update
    ```

1. Install the Azure Key Vault CSI provider

    ```bash
    helm install -n k8s-secrets-store-csi azure-csi-provider \
      csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
      --set linux.privileged=true --set secrets-store-csi-driver.install=false \
      --set "linux.providersDir=/var/run/secrets-store-csi-providers" \
      --version=v1.4.1
    ```

1. Set SecurityContextConstraints to allow the CSI driver to run

    ```bash
    oc adm policy add-scc-to-user privileged \
      system:serviceaccount:k8s-secrets-store-csi:csi-secrets-store-provider-azure
    ```

## Create Keyvault and a Secret

1. Create a namespace for your application

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

   > Note: If this gives you an error, you may need upgrade your Azure CLI to the latest version.

   ```bash
   export SERVICE_PRINCIPAL_CLIENT_SECRET="$(az ad sp create-for-rbac \
     --name http://$KEYVAULT_NAME --query 'password' -otsv)"

   export SERVICE_PRINCIPAL_CLIENT_ID="$(az ad sp list \
     --display-name http://$KEYVAULT_NAME --query '[0].appId' -otsv)"
   ```

1. Set an Access Policy for the Service Principal

    ```bash
    az keyvault set-policy -n ${KEYVAULT_NAME} \
      --secret-permissions get \
      --spn ${SERVICE_PRINCIPAL_CLIENT_ID}
    ```

1. Create and label a secret for Kubernetes to use to access the Key Vault

    ```bash
    oc create secret generic secrets-store-creds \
      -n my-application \
      --from-literal clientid=${SERVICE_PRINCIPAL_CLIENT_ID} \
      --from-literal clientsecret=${SERVICE_PRINCIPAL_CLIENT_SECRET}
    
    oc -n my-application label secret \
      secrets-store-creds secrets-store.csi.k8s.io/used=true
    ```

## Deploy an Application that uses the CSI

1. Create a Secret Provider Class to give access to this secret

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: secrets-store.csi.x-k8s.io/v1
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
   cat <<EOF | oc apply -f -
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
    oc exec busybox-secrets-store-inline -- ls /mnt/secrets-store/
    ```

    Output should match:

    ```
    secret1
    ```

1. Print the Secret

    ```bash
    oc exec busybox-secrets-store-inline \
      -- cat /mnt/secrets-store/secret1
    ```

    Output should match:

    ```
    Hello
    ```

## Cleanup

1. Uninstall Helm

    ```bash
    helm uninstall -n k8s-secrets-store-csi azure-csi-provider
    ```

1. Delete the app

    ```bash
    oc delete project my-application
    ```

1. Delete the Azure Key Vault

    ```bash
    az keyvault delete -n ${KEYVAULT_NAME}
    ```

1. Delete the Service Principal

    ```bash
    az ad sp delete --id ${SERVICE_PRINCIPAL_CLIENT_ID}
    ```

{{< readfile file="/docs/misc/secrets-store-csi/uninstall-kubernetes-secret-store-driver.md" markdown="true" >}}
