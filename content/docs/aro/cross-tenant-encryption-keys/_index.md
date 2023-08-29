---
date: '2023-08-25'
title: ARO - Cross Tenant Provisioning
tags: ["ARO", "Azure"]
authors:
  - Dustin Scott
---

## Summary

There may be situations where you want to create an ARO cluster where the organization 
has a policy which has a central entity that controls things such as encryption keys or 
networking components.  This is desirable in large enterprises due to separation of concerns 
and limiting areas of control for groups to a small scope.  This does present challenges, as 
those different groups must be able to integrate with one another.  Often times, the integration 
is difficult, complex, and confusing.  This document serves as a way to clear up some of 
the confusion by walking you through scenarios for cross-tenancy in ARO.

This guide covers the below use case.  Feel free to ignore sections not related to your
use case:

- Use Encryption Keys that resides within a separate Azure subscription


## Environment Setup

We need to set the following inputs related to the tenant where ARO and its 
networking is being installed before proceeding:

* `SCRATCH_DIR` - a location from your workstation where temporary files are stored
* `ARO_CLUSTER_NAME` - the name of the cluster you are creating (also used as the prefix for other resources)
* `ARO_PULL_SECRET` - the pull secret to use when provisioning the OpenShift cluster
* `ARO_RESOURCE_GROUP` - the resource group where the ARO cluster will be created
* `ARO_LOCATION` - the location where the ARO cluster will be created
* `ARO_VNET_RESOURCE_GROUP` - the resource group where the VNET for the ARO cluster will be created
* `ARO_VNET` - the VNET where the ARO cluster will be created
* `ARO_CONTROL_PLANE_SUBNET` - the subnet which hosts the ARO control plane
* `ARO_WORKER_SUBNET` - the control plane subnet which hosts the ARO worker nodes
* `ARO_APP_NAME` - the application name which represents the ARO identity which is 
used to access resources in other tenants.

We need to set the following inputs related to the tenant where the Azure Key Vault
exists before proceeding:

* `KV_RESOURCE_GROUP` - the resource group where the Azure Key Vault will be created
* `KV_LOCATION` - the location where the Azure Key Vault will be created
* `KV_VAULT_NAME` - the name of the Azure Key Vault that will be created
* `KV_KEY_NAME` - the name of the key within the Azure Key Vault that will be created

Feel free to use the sensible defaults below if you need to quickly see how this works:

```bash
SCRATCH_DIR=/tmp/scratch

ARO_CLUSTER_NAME=multi-tenant
ARO_PULL_SECRET=~/.azure/aro-pull-secret.txt
ARO_RESOURCE_GROUP=${ARO_CLUSTER_NAME}-rg
ARO_LOCATION=eastus
ARO_VNET_RESOURCE_GROUP=${ARO_CLUSTER_NAME}-vnet-rg
ARO_VNET=${ARO_CLUSTER_NAME}-vnet
ARO_CONTROL_PLANE_SUBNET=${ARO_CLUSTER_NAME}-control-plane-subnet
ARO_WORKER_SUBNET=${ARO_CLUSTER_NAME}-worker-subnet
ARO_APP_NAME=${ARO_CLUSTER_NAME}-aro

KV_RESOURCE_GROUP=${ARO_CLUSTER_NAME}-kv-rg
KV_LOCATION=eastus
KV_VAULT_NAME=${ARO_CLUSTER_NAME}-vault
KV_KEY_NAME=${ARO_CLUSTER_NAME}-key
```

## Cross-Tenant Encryption Setup

This section covers the guide for cross-tenant encryption.


### Setup the ARO Tenant

1. Be sure to login the *the tenant that will host your **ARO cluster***:

```
az login
```

2. Create the application and store the client ID and client secret of the application.  This 
application represents ARO when it is authenticating against other resources:

```bash
APP_OBJECT_ID=$(az ad app create \
  --display-name ${ARO_APP_NAME} \
  --sign-in-audience AzureADMultipleOrgs \
  --query id \
  --output tsv)

APP_CLIENT_ID=$(az ad app show \
  --id ${APP_OBJECT_ID} \
  --query appId \
  --output tsv)

APP_CLIENT_SECRET=$(az ad app credential reset --id ${APP_OBJECT_ID} --append)
```

3. Create the resource group to host the ARO cluster:

```bash
az group create \
  --location ${ARO_LOCATION} \
  --resource-group ${ARO_RESOURCE_GROUP}
```

4. Create the managed identity for the application.  This will be used as the identity 
to host the federated credential required for cross-tenant authentication.  We will store
the id output for use in followon steps:

```bash
APP_FEDERATED_ID=$(az identity create \
  --name ${ARO_APP_NAME} \
  --resource-group ${ARO_RESOURCE_GROUP} \
  --location ${ARO_LOCATION} \
  --query principalId \
   --out tsv)
```

5. Create the federated credential for the managed identity:

```bash
mkdir -p ${SCRATCH_DIR}

cat <<EOF > ${SCRATCH_DIR}/federated.json
{
    "name": "AROCrossTenantIdentity",
    "issuer": "https://login.microsoftonline.com/$(az account show --query 'tenantId' -o tsv)/v2.0",
    "subject": "${APP_FEDERATED_ID}",
    "description": "Federated Identity Credential for ARO CMK",
    "audiences": [
        "api://AzureADTokenExchange"
    ]
}
EOF

az ad app federated-credential create \
  --id ${APP_OBJECT_ID} \
  --parameters ${SCRATCH_DIR}/federated.json
```


### Setup the Key Vault Tenant

This step configures the Key Vault and grants access to the application created in 
the ARO tenant.

1. Be sure to login the *the tenant that will host your **Azure Key Vault and Key***:

```
az login
```

2. Create the service principal with the registered application name.  This will link the 
managed identity to this newly created service account:

```bash
az ad sp create --id ${APP_CLIENT_ID}
```

3. Create the resource group to host the Azure Key Vault and and the encryption key:

```bash
az group create \
  --location ${KV_LOCATION} \
  --resource-group ${KV_RESOURCE_GROUP}
```

4. Create the Azure Key Vault and store the id for use in followon steps:

```bash
KV_RESOURCE_ID=$(az keyvault create \
  --name ${KV_VAULT_NAME} \
  --location ${KV_LOCATION} \
  --resource-group ${KV_RESOURCE_GROUP} \
  --enable-purge-protection true \
  --enable-rbac-authorization true \
  --query id \
  --output tsv)
```

5. In order to create keys in the vault, you need to be assigned the 
`Key Vault Crypto Officer` role.  You can assign yourself the role with 
the following:

```bash
az role assignment create \
  --role "Key Vault Crypto Officer" \
  --scope ${KV_RESOURCE_ID} \
  --assignee-object-id $(az ad signed-in-user show --query id --output tsv)
```

6. Create the encryption key and store the Key URL in a variable:

```bash
KV_KEY_URL=$(az keyvault key create \
  --name ${KV_KEY_NAME} \
  --vault-name ${KV_VAULT_NAME} \
  --query 'key.kid' \
  -o tsv)
```

7. Grant the ability for the ARO identity to use the key:

```bash
az role assignment create \
  --role "Key Vault Crypto Service Encryption User" \
  --scope ${KV_RESOURCE_ID} \
  --assignee-object-id $(az ad sp show --id ${APP_CLIENT_ID} --query id --output tsv)
```

### Create the Disk Encryption Set

1. Be sure to login the *the tenant that will host your **ARO cluster***:

```
az login
```

2. Create the disk encryption set which uses the newly created encryption key.  Store the 
id from the output as it will be used in provisioning the cluster:

```bash
DES_ID=$(az disk-encryption-set create \
  --resource-group ${ARO_RESOURCE_GROUP} \
  --name ${ARO_CLUSTER_NAME} \
  --key-url ${KV_KEY_URL} \
  --mi-user-assigned $(az identity show -n ${ARO_APP_NAME} -g ${ARO_RESOURCE_GROUP} --query id -o tsv) \
  --federated-client-id ${APP_CLIENT_ID} \
  --location ${ARO_LOCATION} \
  --query id \
  -o tsv)
```


## Create the Networking

1. Create the resource group to host the ARO networking components:

```bash
az group create \
  --location ${ARO_LOCATION} \
  --resource-group ${ARO_VNET_RESOURCE_GROUP}
```

2. Create the VNET for the ARO cluster.  We need to store the fully qualified resource ID 
and use it in the provisioning process:

```bash
ARO_VNET_ID=$(az network vnet create \
  --address-prefixes ${ARO_VNET_CIDR} \
  --name "${ARO_VNET}" \
  --resource-group ${ARO_VNET_RESOURCE_GROUP} \
  --query 'newVNet.id' \
  -o tsv)
```

3. Create the control plane subnet.  We need to store the fully qualified resource ID 
and use it in the provisioning process:

```bash
ARO_CONTROL_PLANE_SUBNET_ID=$(az network vnet subnet create \
  --resource-group ${ARO_VNET_RESOURCE_GROUP} \
  --vnet-name "${ARO_VNET}" \
  --name "${ARO_CONTROL_PLANE_SUBNET}" \
  --address-prefixes "${ARO_CONTROL_PLANE_CIDR}" \
  --service-endpoints Microsoft.ContainerRegistry \
  --query id \
  -o tsv)
```

4. Disable network policies on the control plane subnet.  This is required for the 
ARO service to be able to connect to and manage the cluster:

```bash
az network vnet subnet update \
  --name "${ARO_CONTROL_PLANE_SUBNET}" \
  --resource-group ${ARO_VNET_RESOURCE_GROUP} \
  --vnet-name "${ARO_VNET}" \
  --disable-private-link-service-network-policies true
```

5. Create the worker subnet.  We need to store the fully qualified resource ID 
and use it in the provisioning process:

```bash
ARO_WORKER_SUBNET_ID=$(az network vnet subnet create \
  --resource-group ${ARO_VNET_RESOURCE_GROUP} \
  --vnet-name "${ARO_VNET}" \
  --name "${ARO_WORKER_SUBNET}" \
  --address-prefixes "${ARO_WORKER_CIDR}" \
  --service-endpoints Microsoft.ContainerRegistry \
  --query id \
  -o tsv)
```


## Provision the ARO Cluster

Finally you can provision the cluster.  Keep in mind that your command may be different 
if you did not use both use cases above.  For reference the inputs from each use case are:

- Use Encryption Keys that resides within a separate Azure subscription
  - `DES_ID` - the fully qualified disk encryption set resource ID which exists in a separate
Azure tenant.
- Inputs from network creation
  - `ARO_VNET_ID` - the fully qualified VNET resource ID which exists in a separate Azure tenant.
  - `ARO_CONTROL_PLANE_SUBNET_ID` - the fully qualified control plane subnet resource ID which exists in a separate Azure tenant.
  - `ARO_WORKER_SUBNET_ID` - the fully qualified worker subnet resource ID which exists in a separate Azure tenant.

1. Run the command to create the cluster:

```bash
az aro create \
  --resource-group ${ARO_RESOURCE_GROUP} \
  --name ${ARO_CLUSTER_NAME} \
  --client-id "${APP_CLIENT_ID}" \
  --client-secret "${APP_CLIENT_SECRET}" \
  --vnet "${ARO_VNET_ID}" \
  --master-subnet "${ARO_CONTROL_PLANE_SUBNET_ID}" \
  --worker-subnet "${ARO_WORKER_SUBNET_ID}" \
  --disk-encryption-set "${DES_ID}" \
  --master-encryption-at-host true \
  --worker-encryption-at-host true \
  --pull-secret @${ARO_PULL_SECRET}
```


## Additional Resources

- [Cross Tenant Customer-Managed Keys](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-cross-tenant-customer-managed-keys?tabs=azure-cli)
- [ARO BYO-Key How-To Guide](https://learn.microsoft.com/en-us/azure/openshift/howto-byok)
