---
date: '2026-05-25'
title: 'ARO Service Principal to Managed Identity: Hands-On Migration Walkthrough'
tags: ["ARO"]
authors:
  - Kevin Ye
---

This is **Part 2** of a two-part series. [Part 1](/experts/aro/aro-sp-mi/) covers what changes in authentication and how to plan your move. This article walks through a hands-on migration of two demo applications from an SP cluster to an MI cluster.

## What This Demo Covers

In Part 1, we outlined five migration phases and a scenario table showing what changes for different application types. This article puts that methodology into practice with two Python Flask applications that access Azure services:

**keyvault-reader**: A stateless REST API that reads secrets from Azure Key Vault. It demonstrates the most common migration case: changing from `ClientSecretCredential` to `DefaultAzureCredential` (a one-line code change) and replacing the K8s Secret with a ServiceAccount annotation.

**blob-writer**: A stateless REST API that writes entries to Azure Blob Storage. It demonstrates that apps already using `DefaultAzureCredential` need no code change at all; only K8s manifest changes are needed (replace the Secret with a ServiceAccount annotation).

| Demo App | Azure Service | SP Auth Method | Code Change? | Config Change? |
|----------|--------------|----------------|-------------|---------------|
| **keyvault-reader** (stateless) | Azure Key Vault | `ClientSecretCredential` with K8s Secret | **Yes**: one-line change to `DefaultAzureCredential` | **Yes**: replace Secret with ServiceAccount |
| **blob-writer** (stateless) | Azure Blob Storage | `DefaultAzureCredential` with K8s Secret | **No**: SDK auto-detects workload identity | **Yes**: replace Secret with ServiceAccount |

### Demo Environment

This walkthrough assumes you have an existing SP cluster with applications and a new MI cluster as the migration target. Both clusters access the same shared Azure services (Key Vault, Blob Storage).

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Services (shared)                      │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │  Azure Key Vault  │  │  Azure Blob      │  │ Entra ID     │  │
│  │  (demo-secret)    │  │  Storage          │  │ (auth)       │  │
│  └──────────────────┘  └──────────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────┐    ┌──────────────────────────┐
  │  ARO SP Cluster (Before) │    │  ARO MI Cluster (After)  │
  │                          │    │                          │
  │  keyvault-reader         │    │  keyvault-reader         │
  │   └─ ClientSecretCred    │    │   └─ DefaultAzureCred    │
  │   └─ K8s Secret ⚠       │    │   └─ ServiceAccount ✓    │
  │                          │    │                          │
  │  blob-writer             │    │  blob-writer             │
  │   └─ DefaultAzureCred    │    │   └─ DefaultAzureCred    │
  │   └─ K8s Secret ⚠       │    │   └─ ServiceAccount ✓    │
  └──────────────────────────┘    └──────────────────────────┘
  ⚠ Long-lived client secret       ✓ Short-lived OIDC token
    stored in cluster                 no secrets in cluster
```

## Prerequisites

- An existing ARO **SP cluster** (optional; the SP state is described below for reference)
- An existing ARO **MI cluster** (see [Create an ARO cluster with managed identities](https://learn.microsoft.com/en-us/azure/openshift/howto-create-openshift-cluster?pivots=aro-deploy-az-cli))
- Azure CLI v2.84.0+ with `aro` extension
- `oc` CLI
- A Red Hat pull secret (for internal registry access)
- Contributor + User Access Administrator on the subscription

## The SP Cluster: Starting State

This section describes how the two demo applications are configured on an existing SP cluster. If you already have applications running on your SP cluster, the patterns here will look familiar: a K8s Secret holding Azure credentials, injected into pods via `envFrom`.

### keyvault-reader on SP

The app uses `ClientSecretCredential` to authenticate to Key Vault. Azure credentials are stored in a K8s Secret and injected into the pod.

**Application code (`app_sp.py`):**

```python
from azure.identity import ClientSecretCredential
from azure.keyvault.secrets import SecretClient

credential = ClientSecretCredential(
    tenant_id=os.environ["AZURE_TENANT_ID"],
    client_id=os.environ["AZURE_CLIENT_ID"],
    client_secret=os.environ["AZURE_CLIENT_SECRET"],
)
client = SecretClient(vault_url=VAULT_URL, credential=credential)
```

**K8s manifest (key resources):**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: azure-sp-credentials
type: Opaque
stringData:
  AZURE_TENANT_ID: "<your-tenant-id>"
  AZURE_CLIENT_ID: "<your-sp-client-id>"
  AZURE_CLIENT_SECRET: "<your-sp-client-secret>"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keyvault-reader
spec:
  template:
    spec:
      containers:
        - name: keyvault-reader
          env:
            - name: AZURE_KEYVAULT_URL
              value: "https://<your-keyvault>.vault.azure.net/"
          envFrom:
            - secretRef:
                name: azure-sp-credentials
```

**Expected behavior:**

```bash
curl -s https://$KV_URL/ | jq .
# {"status":"ok","app":"keyvault-reader","auth_method":"service-principal (ClientSecretCredential)"}

curl -s https://$KV_URL/secret/demo-secret | jq .
# {"name":"demo-secret","value":"Hello from ARO MI migration demo","auth_method":"service-principal (ClientSecretCredential)"}
```

### blob-writer on SP

The app already uses `DefaultAzureCredential` (best practice). Azure credentials are still stored in a K8s Secret; `DefaultAzureCredential` detects the `AZURE_CLIENT_SECRET` environment variable and uses `ClientSecretCredential` under the hood.

**Application code (`app.py`):**

```python
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

credential = DefaultAzureCredential()
blob_service = BlobServiceClient(account_url=STORAGE_ACCOUNT_URL, credential=credential)
```

**K8s manifest (key resources):**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: azure-sp-credentials
type: Opaque
stringData:
  AZURE_TENANT_ID: "<your-tenant-id>"
  AZURE_CLIENT_ID: "<your-sp-client-id>"
  AZURE_CLIENT_SECRET: "<your-sp-client-secret>"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blob-writer
spec:
  template:
    spec:
      containers:
        - name: blob-writer
          env:
            - name: AZURE_STORAGE_ACCOUNT_URL
              value: "https://<your-storage-account>.blob.core.windows.net"
            - name: AZURE_STORAGE_CONTAINER
              value: "demo-data"
          envFrom:
            - secretRef:
                name: azure-sp-credentials
```

**Expected behavior:**

```bash
curl -s https://$BLOB_URL/ | jq .
# {"status":"ok","app":"blob-writer","auth_method":"service-principal (ClientSecretCredential)"}
```

## The MI Cluster: Target State

After migration, both apps run on the MI cluster using workload identity; no Azure secrets are stored in the cluster. This section shows what changes for each app.

### keyvault-reader on MI

**Code change:** Replace `ClientSecretCredential` with `DefaultAzureCredential` (one line).

```python
# Before (SP)
from azure.identity import ClientSecretCredential
credential = ClientSecretCredential(
    tenant_id=os.environ["AZURE_TENANT_ID"],
    client_id=os.environ["AZURE_CLIENT_ID"],
    client_secret=os.environ["AZURE_CLIENT_SECRET"],
)

# After (MI)
from azure.identity import DefaultAzureCredential
credential = DefaultAzureCredential()
```

`DefaultAzureCredential` auto-detects the authentication method. On an MI cluster with workload identity, it uses the federated token injected by the webhook. On an SP cluster, it falls back to environment variables, making it work in both environments.

**Manifest changes:**

| What | SP Cluster | MI Cluster |
|------|-----------|-----------|
| **Secret** | `azure-sp-credentials` with client ID, secret, tenant ID | **Removed** |
| **ServiceAccount** | Default | `keyvault-reader-sa` with `azure.workload.identity/client-id` annotation |
| **Pod label** | None | `azure.workload.identity/use: "true"` |
| **serviceAccountName** | Not set | `keyvault-reader-sa` |
| **envFrom** | `secretRef: azure-sp-credentials` | **Removed** |

**MI manifest (key resources):**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: keyvault-reader-sa
  annotations:
    azure.workload.identity/client-id: "<your-managed-identity-client-id>"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keyvault-reader
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: keyvault-reader-sa
      containers:
        - name: keyvault-reader
          env:
            - name: AZURE_KEYVAULT_URL
              value: "https://<your-keyvault>.vault.azure.net/"
          # No envFrom, no secretRef — workload identity webhook injects credentials
```

**Expected behavior:**

```bash
curl -s https://$KV_URL/ | jq .
# {"status":"ok","app":"keyvault-reader","auth_method":"workload-identity (DefaultAzureCredential)"}

curl -s https://$KV_URL/secret/demo-secret | jq .
# {"name":"demo-secret","value":"Hello from ARO MI migration demo","auth_method":"workload-identity (DefaultAzureCredential)"}
```

### blob-writer on MI

**Code change:** None. The app already uses `DefaultAzureCredential`.

**Manifest changes:**

| What | SP Cluster | MI Cluster |
|------|-----------|-----------|
| **Secret** | `azure-sp-credentials` with client ID, secret, tenant ID | **Removed** |
| **ServiceAccount** | Default | `blob-writer-sa` with `azure.workload.identity/client-id` annotation |
| **Pod label** | None | `azure.workload.identity/use: "true"` |
| **serviceAccountName** | Not set | `blob-writer-sa` |
| **envFrom** | `secretRef: azure-sp-credentials` | **Removed** |

**Expected behavior:**

```bash
curl -s https://$BLOB_URL/ | jq .
# {"status":"ok","app":"blob-writer","auth_method":"workload-identity (DefaultAzureCredential)"}

curl -s -X POST https://$BLOB_URL/write -H "Content-Type: application/json" \
  -d '{"message": "First entry from MI cluster"}' | jq .
# {"status":"written","blob":"entry-20260528-095721.json"}
```

## Migration Steps

Now that we have seen the before and after states, here are the detailed steps to set up the MI cluster and deploy the applications.

### Environment Setup

Set the variables used throughout this walkthrough. Adjust values to match your environment:

```bash
LOCATION=southeastasia
RESOURCEGROUP=aro-mi-rg
CLUSTER=aro-mi-cluster

# Azure services for demo apps
KEYVAULT_NAME=aro-demo-kv-${RANDOM}
STORAGE_ACCOUNT=arodemostore${RANDOM}
STORAGE_CONTAINER=demo-data

# Get cluster OIDC issuer (MI clusters only)
OIDC_ISSUER=$(az aro show \
  --name $CLUSTER \
  --resource-group $RESOURCEGROUP \
  --query "clusterProfile.oidcIssuer" -o tsv)

echo "OIDC Issuer: $OIDC_ISSUER"
```

{{% alert state="info" %}}The OIDC issuer URL is only available on MI clusters. If this returns empty, the cluster is SP-based and does not support workload identity.{{% /alert %}}

### Step 1: Create Azure Resources

#### Key Vault (for keyvault-reader)

```bash
az keyvault create \
  --name $KEYVAULT_NAME \
  --resource-group $RESOURCEGROUP \
  --location $LOCATION

az keyvault secret set \
  --vault-name $KEYVAULT_NAME \
  --name demo-secret \
  --value "Hello from ARO MI migration demo"
```

#### Storage Account (for blob-writer)

```bash
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCEGROUP \
  --location $LOCATION \
  --sku Standard_LRS

STORAGE_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net"
```

### Step 2: Create Managed Identities

Each application gets its own user-assigned managed identity with only the permissions it needs.

#### keyvault-reader identity

```bash
az identity create \
  --name keyvault-reader-identity \
  --resource-group $RESOURCEGROUP \
  --location $LOCATION

KV_IDENTITY_CLIENT_ID=$(az identity show \
  --name keyvault-reader-identity \
  --resource-group $RESOURCEGROUP \
  --query clientId -o tsv)

KV_IDENTITY_OBJECT_ID=$(az identity show \
  --name keyvault-reader-identity \
  --resource-group $RESOURCEGROUP \
  --query principalId -o tsv)

# Grant Key Vault Secrets User role
az role assignment create \
  --assignee-object-id $KV_IDENTITY_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope $(az keyvault show --name $KEYVAULT_NAME --query id -o tsv)
```

#### blob-writer identity

```bash
az identity create \
  --name blob-writer-identity \
  --resource-group $RESOURCEGROUP \
  --location $LOCATION

BLOB_IDENTITY_CLIENT_ID=$(az identity show \
  --name blob-writer-identity \
  --resource-group $RESOURCEGROUP \
  --query clientId -o tsv)

BLOB_IDENTITY_OBJECT_ID=$(az identity show \
  --name blob-writer-identity \
  --resource-group $RESOURCEGROUP \
  --query principalId -o tsv)

# Grant Storage Blob Data Contributor role
az role assignment create \
  --assignee-object-id $BLOB_IDENTITY_OBJECT_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope $(az storage account show --name $STORAGE_ACCOUNT --query id -o tsv)
```

### Step 3: Create Federated Credentials

Federated credentials link each managed identity to a Kubernetes ServiceAccount. This is what enables secretless authentication: the workload identity webhook exchanges a K8s token for an Azure token automatically.

```bash
# Federated credential for keyvault-reader
az identity federated-credential create \
  --name keyvault-reader-fedcred \
  --identity-name keyvault-reader-identity \
  --resource-group $RESOURCEGROUP \
  --issuer $OIDC_ISSUER \
  --subject system:serviceaccount:keyvault-reader:keyvault-reader-sa \
  --audiences api://AzureADTokenExchange

# Federated credential for blob-writer
az identity federated-credential create \
  --name blob-writer-fedcred \
  --identity-name blob-writer-identity \
  --resource-group $RESOURCEGROUP \
  --issuer $OIDC_ISSUER \
  --subject system:serviceaccount:blob-writer:blob-writer-sa \
  --audiences api://AzureADTokenExchange
```

{{% alert state="info" %}}The `--subject` format is `system:serviceaccount:<namespace>:<serviceaccount-name>`. This must exactly match the ServiceAccount in your K8s manifests.{{% /alert %}}

### Step 4: Build and Deploy

#### Login to the MI cluster

```bash
API_SERVER=$(az aro show \
  --name $CLUSTER \
  --resource-group $RESOURCEGROUP \
  --query "apiserverProfile.url" -o tsv)

KUBEADMIN_PASSWORD=$(az aro list-credentials \
  --name $CLUSTER \
  --resource-group $RESOURCEGROUP \
  --query "kubeadminPassword" -o tsv)

oc login $API_SERVER -u kubeadmin -p $KUBEADMIN_PASSWORD
```

#### Get the demo application source

The demo application source code lives alongside this guide in the [rh-mobb/documentation](https://github.com/rh-mobb/documentation) repository. Clone it and navigate to the demo apps directory:

```bash
git clone https://github.com/rh-mobb/documentation.git
cd documentation/content/aro/aro-sp-mi
```

The rest of the build commands run from this directory.

#### Deploy keyvault-reader

```bash
oc new-project keyvault-reader

# Build from source using OpenShift binary build
oc new-build --binary --name=keyvault-reader -n keyvault-reader
oc start-build keyvault-reader --from-dir=demo-apps/keyvault-reader -n keyvault-reader --follow

# Create ServiceAccount with workload identity annotation
oc create serviceaccount keyvault-reader-sa -n keyvault-reader
oc annotate serviceaccount keyvault-reader-sa \
  azure.workload.identity/client-id=$KV_IDENTITY_CLIENT_ID \
  -n keyvault-reader

# Deploy
oc create deployment keyvault-reader \
  --image=image-registry.openshift-image-registry.svc:5000/keyvault-reader/keyvault-reader:latest \
  -n keyvault-reader

# Patch for workload identity
oc patch deployment keyvault-reader -n keyvault-reader --type=json -p='[
  {"op": "add", "path": "/spec/template/metadata/labels/azure.workload.identity~1use", "value": "true"},
  {"op": "add", "path": "/spec/template/spec/serviceAccountName", "value": "keyvault-reader-sa"},
  {"op": "add", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "AZURE_KEYVAULT_URL", "value": "https://'"$KEYVAULT_NAME"'.vault.azure.net/"}
  ]}
]'

# Expose
oc expose deployment keyvault-reader --port=8080 -n keyvault-reader
oc create route edge --service=keyvault-reader -n keyvault-reader
```

#### Deploy blob-writer

```bash
oc new-project blob-writer

oc new-build --binary --name=blob-writer -n blob-writer
oc start-build blob-writer --from-dir=demo-apps/blob-writer -n blob-writer --follow

# Create ServiceAccount with workload identity annotation
oc create serviceaccount blob-writer-sa -n blob-writer
oc annotate serviceaccount blob-writer-sa \
  azure.workload.identity/client-id=$BLOB_IDENTITY_CLIENT_ID \
  -n blob-writer

# Deploy
oc create deployment blob-writer \
  --image=image-registry.openshift-image-registry.svc:5000/blob-writer/blob-writer:latest \
  -n blob-writer

# Patch for workload identity + env vars
oc patch deployment blob-writer -n blob-writer --type=json -p='[
  {"op": "add", "path": "/spec/template/metadata/labels/azure.workload.identity~1use", "value": "true"},
  {"op": "add", "path": "/spec/template/spec/serviceAccountName", "value": "blob-writer-sa"},
  {"op": "add", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "AZURE_STORAGE_ACCOUNT_URL", "value": "'"$STORAGE_URL"'"},
    {"name": "AZURE_STORAGE_CONTAINER", "value": "demo-data"},
    {"name": "CLUSTER_NAME", "value": "mi-cluster"}
  ]}
]'

# Expose
oc expose deployment blob-writer --port=8080 -n blob-writer
oc create route edge --service=blob-writer -n blob-writer
```

### Step 5: Validate

```bash
KV_URL=$(oc get route keyvault-reader -n keyvault-reader -o jsonpath='{.spec.host}')
BLOB_URL=$(oc get route blob-writer -n blob-writer -o jsonpath='{.spec.host}')

echo "keyvault-reader: https://$KV_URL"
echo "blob-writer:     https://$BLOB_URL"
```

#### Test keyvault-reader

```bash
# Health check — should return auth_method: workload-identity
curl -s https://$KV_URL/ | jq .

# Read the demo secret from Key Vault
curl -s https://$KV_URL/secret/demo-secret | jq .
```

#### Test blob-writer

```bash
# Health check
curl -s https://$BLOB_URL/ | jq .

# Write an entry to Blob Storage
curl -s -X POST https://$BLOB_URL/write \
  -H "Content-Type: application/json" \
  -d '{"message": "First entry from MI cluster"}' | jq .

# List blobs in Azure Blob Storage
curl -s https://$BLOB_URL/blobs | jq .
```

#### Verify workload identity injection

You can confirm that no secrets are in the pod by inspecting the injected environment variables:

```bash
oc exec -n keyvault-reader deploy/keyvault-reader -- env | grep AZURE_

# Expected output (no AZURE_CLIENT_SECRET):
# AZURE_CLIENT_ID=<managed-identity-client-id>
# AZURE_TENANT_ID=<tenant-id>
# AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
# AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/
```

## Key Takeaways

1. **Code change is only needed when using explicit credential classes** like `ClientSecretCredential`. If your app already uses `DefaultAzureCredential`, no code change is required.

2. **K8s manifest changes are the same pattern for every app**: remove the Secret reference, add a ServiceAccount with the workload identity annotation, set `.spec.serviceAccountName`, and add the pod label.

3. **The application container image is identical** on both SP and MI clusters. The difference is entirely in how credentials are provided to the pod.

4. **`DefaultAzureCredential` is the best practice** for any new Azure SDK code. It works transparently across SP clusters (using env vars), MI clusters (using workload identity), and local development (using Azure CLI credentials).

## Cleanup

```bash
# Delete demo app namespaces
oc delete project keyvault-reader
oc delete project blob-writer

# Delete Azure resources
az keyvault delete --name $KEYVAULT_NAME --resource-group $RESOURCEGROUP
az keyvault purge --name $KEYVAULT_NAME
az storage account delete --name $STORAGE_ACCOUNT --resource-group $RESOURCEGROUP --yes
az identity delete --name keyvault-reader-identity --resource-group $RESOURCEGROUP
az identity delete --name blob-writer-identity --resource-group $RESOURCEGROUP
```

To delete the entire cluster and all resources:

```bash
az group delete --name $RESOURCEGROUP --yes --no-wait
```

## Demo Application Source Code

The complete source code for both demo applications is in the [rh-mobb/documentation](https://github.com/rh-mobb/documentation) repository under `content/aro/aro-sp-mi/demo-apps/`:

```
demo-apps/
├── keyvault-reader/
│   ├── app.py              # MI version (DefaultAzureCredential)
│   ├── app_sp.py           # SP version (ClientSecretCredential)
│   ├── requirements.txt
│   ├── Dockerfile
│   └── k8s/
│       ├── deploy-sp.yaml  # Full SP manifest (with K8s Secret)
│       └── deploy-mi.yaml  # Full MI manifest (with ServiceAccount)
└── blob-writer/
    ├── app.py              # Works on both SP and MI (DefaultAzureCredential)
    ├── requirements.txt
    ├── Dockerfile
    └── k8s/
        ├── deploy-sp.yaml  # Full SP manifest (with K8s Secret)
        └── deploy-mi.yaml  # Full MI manifest (with ServiceAccount)
```

## References

- [Part 1: Service Principal vs Managed Identity Explained](/experts/aro/aro-sp-mi/)
- [Use workload identity with an ARO cluster](https://learn.microsoft.com/en-us/azure/openshift/howto-create-a-workloadidentitypool)
- [Azure Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [DefaultAzureCredential documentation](https://learn.microsoft.com/en-us/python/api/azure-identity/azure.identity.defaultazurecredential)
- [Create an ARO cluster with managed identities](https://learn.microsoft.com/en-us/azure/openshift/howto-create-openshift-cluster?pivots=aro-deploy-az-cli)