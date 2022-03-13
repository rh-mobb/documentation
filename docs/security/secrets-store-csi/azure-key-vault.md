# Azure Key Vault CSI on Azure Red Hat OpenShift (ARO)

**Author: [Paul Czarkowski](https://github.com/paulczar) (Red Hat) on 08/16/2021**<br>
Updated by: [Stuart Kirk](https://github.com/stuartatmicrosoft) (Microsoft) on 03/13/2022<br>

This document is adapted from the [Azure Key Vault CSI Walkthrough](https://azure.github.io/secrets-store-csi-driver-provider-azure/docs/demos/standard-walkthrough) specifically to run with Azure Red Hat OpenShift (ARO).

## Prerequisites

1. [A pre-existing ARO cluster](/docs/quickstart-aro)
2. Be logged in to the [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
3. Helm 3.x CLI

### Environment Variables

1. Run this command to set environment variables to use throughout:

    > Note if you created the cluster from the instructions linked [above](/docs/quickstart-aro) these will re-use the same environment variables, or default them to `openshift` and `eastus`.

    ```bash
    export KEYVAULT_RESOURCE_GROUP=${AZR_RESOURCE_GROUP:-"openshift"}
    export KEYVAULT_LOCATION=${AZR_RESOURCE_LOCATION:-"eastus"}
    export KEYVAULT_NAME=secret-store-$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
    export AZ_TENANT_ID=$(az account show -o tsv --query tenantId)
    ```

{% include_relative install-kubernetes-secret-store-driver.md %}

## Deploy the Azure CSI driver

1. Deploy the Azure CSI provider to ARO

    ```bash
    oc apply -n k8s-secrets-store-csi -f \
      https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/deployment/provider-azure-installer.yaml
    ```

1. Set SecurityContextConstraints to allow the CSI driver to run

    ```bash
    oc adm policy add-scc-to-user privileged \
      system:serviceaccount:k8s-secrets-store-csi:csi-secrets-store-provider-azure
    ```

## Create an Azure Key Vault and populate it with a secret

1. Create a new ARO project for your test application

    ```bash
    oc new-project my-application
    ```

1. Create a new Azure Key Vault in the Azure Resource Group which contains ARO

    ```bash
    az keyvault create -n ${KEYVAULT_NAME} \
      --resource-group ${KEYVAULT_RESOURCE_GROUP} \
      --location ${KEYVAULT_LOCATION}
    ```

1. Create a new secret named **secret1** in the Azure Key Vault

    ```bash
    az keyvault secret set \
      --vault-name ${KEYVAULT_NAME} \
      --name secret1 --value "Azure Red Hat OpenShift rocks!"
    ```

1. Create a new Service Principal to allow ARO to access the Azure Key Vault

    ```bash
    export SERVICE_PRINCIPAL_CLIENT_SECRET="$(az ad sp create-for-rbac --skip-assignment --name http://$KEYVAULT_NAME --query 'password' -o tsv)"
    export SERVICE_PRINCIPAL_CLIENT_ID="$(az ad sp list --display-name http://$KEYVAULT_NAME --query '[0].appId' -o tsv)"
    ```

1. Set the required access policy for the Azure Service Principal

    ```bash
    az keyvault set-policy -n ${KEYVAULT_NAME} \
      --secret-permissions get \
      --spn ${SERVICE_PRINCIPAL_CLIENT_ID}
    ```

1. Create and label a secret for ARO to use to access the Azure Key Vault

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
  namespace: keyvault-app
spec:
  containers:
  - name: busybox
    image: busybox:latest
    imagePullPolicy: IfNotPresent
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
    oc exec busybox-secrets-store-inline -- cat /mnt/secrets-store/secret1
    ```

    Output should match:

    ```
    Azure Red Hat OpenShift rocks!
    ```

## Cleanup

1. Delete the test application

    ```bash
    oc delete project my-application
    ```

1. Remove the Azure CSI provider
    ```bash
    oc delete -n k8s-secrets-store-csi -f \
      https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/deployment/provider-azure-installer.yaml
    ```

1. Remove the Azure Key Vault

    ```bash
    az keyvault delete -n ${KEYVAULT_NAME}
    ```

1. Delete the Azure Service Principal

    ```bash
    az ad sp delete --id ${SERVICE_PRINCIPAL_CLIENT_ID}
    ```

{% include_relative uninstall-kubernetes-secret-store-driver.md %}
