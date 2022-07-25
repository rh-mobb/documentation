# Setting up Quay on an ARO cluster using Azure Container Storage 

**Kristopher White x Connor Wooley**

*07/25/2022*

## Pre Requisites

* an ARO cluster
* oc/azure cli

## Steps

### Create Azure Resources
1. Create Storage Account
    ```bash
    az login
    az group create --name <resource-group>  --location <location>
    az storage account create --name <storage-account> --resource-group <resource-group> \ --location eastus --sku Standard_LRS --kind  StorageV2
    ```
2. Create Storage Container
    ```bash
    az storage account keys list --account-name <storage_account_name> --resource-group <resource_group> --output yaml
    ```
    Note: this command returns a json by default with your keyName and Values, command above specifies yaml
    
    ```bash
    az storage container create --name <container_name> --public-access blob \ --account-name <AZURE_STORAGE_ACCOUNT> --account-key <AZURE_STORAGE_ACCOUNT_KEY>
    ```
    Note: Will need the storage container creds for later use

### Install Quay-Operator and Create Quay Registry

1. Login to your cluster's OCM
2. Create a sub.yaml file with this template to install the quay operator

    ```yaml
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
        name: quay-operator
        namespace: <namespace>
    spec:
        channel: <release_channel>
        name: quay-operator
        source: redhat-operators
        sourceNamespace: openshift-marketplace
        startingCSV: quay-operator.<version>
    ```

    ```bash
    oc apply -f sub.yaml
    ```
3. Create the Quay Registry
    1. Create the Azure Storage Secret Bundle
        - Create a config.yaml file that injects the azure resource info from the storage container created in step 2 of Create Azure Resources
        ```yaml
        DISTRIBUTED_STORAGE_CONFIG:
            local_us:
            - AzureStorage
            - azure_account_key: <AZURE_STORAGE_ACCOUNT_KEY>
                azure_account_name: <AZURE_STORAGE_ACCOUNT>
                azure_container: <AZURE_CONTAINER_NAME>
                storage_path: /datastorage/registry
        DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
        - local_us
        DISTRIBUTED_STORAGE_PREFERENCE:
        - local_us
        ```
    
        ```bash
        oc create secret generic --from-file config.yaml=./config.yaml -n <namespace> <config_bundle_secret_name>
        ```
    2. Create the Quay Registry with the Secret
        - Create a `quayregistry.yaml` file with this format
            ```yaml
            apiVersion: quay.redhat.com/v1
            kind: QuayRegistry
            metadata:
                name: <registry_name>
                namespace: <namespace>
                finalizers:
                    - quay-operator/finalizer
                generation: 3
            spec:
                configBundleSecret: <config_bundle_secret_name>
                components:
                    - kind: clair
                    managed: true
                    - kind: postgres
                    managed: true
                    - kind: objectstorage
                    managed: false
                    - kind: redis
                    managed: true
                    - kind: horizontalpodautoscaler
                    managed: true
                    - kind: route
                    managed: true
                    - kind: mirror
                    managed: true
                    - kind: monitoring
                    managed: true
                    - kind: tls
                    managed: true
                    - kind: quay
                    managed: true
                    - kind: clairpostgres
                    managed: true```
        ```bash
        oc create -n <namespace> -f quayregistry.yaml
        ```
4. Login to your Quay Registry and begin pushing images to it!

TODO:

* Creating users in the registry (how do we tie this into the cluster RBAC or AAD)


