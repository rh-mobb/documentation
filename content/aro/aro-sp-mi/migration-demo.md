---
date: '2026-05-25'
title: 'ARO Migration Demo: Moving Applications from SP to MI Cluster (Part 2)'
tags: ["ARO", "Azure"]
authors:
  - Kevin Ye
---

This is **Part 2** of a two-part series. [Part 1](../aro-sp-mi) covers the what, why, and how to choose between service principal and managed identity for ARO. This article walks through a hands-on migration of two demo applications from an SP cluster to an MI cluster.

## What This Demo Covers

In Part 1, we outlined five migration phases and a scenario table showing what changes for different application types. This article puts that methodology into practice with two Python Flask applications:

| Demo App | Azure Service | SP Auth Method | Code Change? | Config Change? |
|----------|--------------|----------------|-------------|---------------|
| **keyvault-reader** (stateless) | Azure Key Vault | `ClientSecretCredential` with K8s Secret | **Yes** — one-line change to `DefaultAzureCredential` | **Yes** — replace Secret with ServiceAccount |
| **blob-writer** (stateful + PVC) | Azure Blob Storage | `DefaultAzureCredential` with K8s Secret | **No** — SDK auto-detects workload identity | **Yes** — replace Secret with ServiceAccount + PVC migration |

By the end, both apps run on the MI cluster using workload identity — no Azure secrets stored in the cluster.

## Prerequisites

- An existing ARO **MI cluster** (see [Create an ARO cluster with managed identities](https://learn.microsoft.com/en-us/azure/openshift/howto-create-openshift-cluster?pivots=aro-deploy-az-cli))
- Azure CLI v2.84.0+ with `aro` extension
- `oc` CLI logged into the MI cluster
- A Red Hat pull secret (for internal registry access)
- Contributor + User Access Administrator on the subscription

## Environment Setup

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

## Step 1: Create Azure Resources

### Key Vault (for keyvault-reader)

```bash
# Create Key Vault
az keyvault create \
  --name $KEYVAULT_NAME \
  --resource-group $RESOURCEGROUP \
  --location $LOCATION

# Add a test secret
az keyvault secret set \
  --vault-name $KEYVAULT_NAME \
  --name demo-secret \
  --value "Hello from ARO MI migration demo"
```

### Storage Account (for blob-writer)

```bash
# Create Storage Account
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCEGROUP \
  --location $LOCATION \
  --sku Standard_LRS

# Get the storage account URL
STORAGE_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net"
```

## Step 2: Create Managed Identities for Applications

Each application gets its own user-assigned managed identity with only the permissions it needs.

### keyvault-reader identity

```bash
# Create managed identity
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

### blob-writer identity

```bash
# Create managed identity
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

## Step 3: Create Federated Credentials

Federated credentials link each managed identity to a Kubernetes ServiceAccount. This is what enables secretless authentication — the workload identity webhook exchanges a K8s token for an Azure token automatically.

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

## Step 4: Build and Deploy the Applications

### Login to the cluster

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

### Deploy keyvault-reader

```bash
# Create namespace and build from source
oc new-project keyvault-reader

# Build using OpenShift's built-in S2I or binary build
oc new-build --binary --name=keyvault-reader -n keyvault-reader
oc start-build keyvault-reader --from-dir=demo-apps/keyvault-reader -n keyvault-reader --follow

# Create the ServiceAccount with workload identity annotation
oc create serviceaccount keyvault-reader-sa -n keyvault-reader
oc annotate serviceaccount keyvault-reader-sa \
  azure.workload.identity/client-id=$KV_IDENTITY_CLIENT_ID \
  -n keyvault-reader

# Deploy the application
oc create deployment keyvault-reader \
  --image=image-registry.openshift-image-registry.svc:5000/keyvault-reader/keyvault-reader:latest \
  -n keyvault-reader

# Patch the deployment to use workload identity
oc patch deployment keyvault-reader -n keyvault-reader --type=json -p='[
  {"op": "add", "path": "/spec/template/metadata/labels/azure.workload.identity~1use", "value": "true"},
  {"op": "add", "path": "/spec/template/spec/serviceAccountName", "value": "keyvault-reader-sa"},
  {"op": "add", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "AZURE_KEYVAULT_URL", "value": "https://'"$KEYVAULT_NAME"'.vault.azure.net/"}
  ]}
]'

# Expose the service
oc expose deployment keyvault-reader --port=8080 -n keyvault-reader
oc create route edge --service=keyvault-reader -n keyvault-reader
```

### Deploy blob-writer

```bash
# Create namespace and build from source
oc new-project blob-writer

oc new-build --binary --name=blob-writer -n blob-writer
oc start-build blob-writer --from-dir=demo-apps/blob-writer -n blob-writer --follow

# Create the ServiceAccount with workload identity annotation
oc create serviceaccount blob-writer-sa -n blob-writer
oc annotate serviceaccount blob-writer-sa \
  azure.workload.identity/client-id=$BLOB_IDENTITY_CLIENT_ID \
  -n blob-writer

# Create PVC for local state
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: blob-writer-data
  namespace: blob-writer
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: managed-csi
EOF

# Deploy the application
oc create deployment blob-writer \
  --image=image-registry.openshift-image-registry.svc:5000/blob-writer/blob-writer:latest \
  -n blob-writer

# Patch the deployment for workload identity + PVC + env vars
oc patch deployment blob-writer -n blob-writer --type=json -p='[
  {"op": "add", "path": "/spec/template/metadata/labels/azure.workload.identity~1use", "value": "true"},
  {"op": "add", "path": "/spec/template/spec/serviceAccountName", "value": "blob-writer-sa"},
  {"op": "add", "path": "/spec/template/spec/containers/0/env", "value": [
    {"name": "AZURE_STORAGE_ACCOUNT_URL", "value": "'"$STORAGE_URL"'"},
    {"name": "AZURE_STORAGE_CONTAINER", "value": "demo-data"},
    {"name": "LOCAL_LOG_PATH", "value": "/data/entries.json"},
    {"name": "CLUSTER_NAME", "value": "mi-cluster"}
  ]},
  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts", "value": [
    {"name": "data", "mountPath": "/data"}
  ]},
  {"op": "add", "path": "/spec/template/spec/volumes", "value": [
    {"name": "data", "persistentVolumeClaim": {"claimName": "blob-writer-data"}}
  ]}
]'

# Expose the service
oc expose deployment blob-writer --port=8080 -n blob-writer
oc create route edge --service=blob-writer -n blob-writer
```

## Step 5: Validate the Applications

### Get the route URLs

```bash
KV_URL=$(oc get route keyvault-reader -n keyvault-reader -o jsonpath='{.spec.host}')
BLOB_URL=$(oc get route blob-writer -n blob-writer -o jsonpath='{.spec.host}')

echo "keyvault-reader: https://$KV_URL"
echo "blob-writer:     https://$BLOB_URL"
```

### Test keyvault-reader

```bash
# Health check — should return auth_method: workload-identity
curl -s https://$KV_URL/ | jq .

# Read the demo secret from Key Vault
curl -s https://$KV_URL/secret/demo-secret | jq .
```

Expected output:

```json
{
  "name": "demo-secret",
  "value": "Hello from ARO MI migration demo",
  "auth_method": "workload-identity (DefaultAzureCredential)"
}
```

### Test blob-writer

```bash
# Health check
curl -s https://$BLOB_URL/ | jq .

# Write an entry to Blob Storage + local PVC
curl -s -X POST https://$BLOB_URL/write \
  -H "Content-Type: application/json" \
  -d '{"message": "First entry from MI cluster"}' | jq .

# Check local entries (stored on PVC)
curl -s https://$BLOB_URL/entries | jq .

# Check Azure Blob Storage entries
curl -s https://$BLOB_URL/blobs | jq .
```

## What Changed: SP vs MI Comparison

Now that both apps are running on workload identity, let's look at exactly what changed from an SP deployment.

### keyvault-reader (code change required)

This app originally used `ClientSecretCredential` — a one-line code change was required.

**Before (SP cluster — `app_sp.py`):**

```python
from azure.identity import ClientSecretCredential

credential = ClientSecretCredential(
    tenant_id=os.environ["AZURE_TENANT_ID"],
    client_id=os.environ["AZURE_CLIENT_ID"],
    client_secret=os.environ["AZURE_CLIENT_SECRET"],
)
```

**After (MI cluster — `app.py`):**

```python
from azure.identity import DefaultAzureCredential

credential = DefaultAzureCredential()
```

`DefaultAzureCredential` auto-detects the authentication method. On an MI cluster with workload identity, it uses the federated token injected by the webhook. On an SP cluster, it would fall back to environment variables — making it work in both environments.

**K8s manifest changes:**

| What | SP Cluster | MI Cluster |
|------|-----------|-----------|
| **Secret** | `azure-sp-credentials` with `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` | **Removed** |
| **ServiceAccount** | Default | `keyvault-reader-sa` with `azure.workload.identity/client-id` annotation |
| **Pod label** | None | `azure.workload.identity/use: "true"` |
| **envFrom** | `secretRef: azure-sp-credentials` | **Removed** |

### blob-writer (no code change)

This app already used `DefaultAzureCredential` — no code change was needed.

**K8s manifest changes:**

| What | SP Cluster | MI Cluster |
|------|-----------|-----------|
| **Secret** | `azure-sp-credentials` with `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` | **Removed** |
| **ServiceAccount** | Default | `blob-writer-sa` with `azure.workload.identity/client-id` annotation |
| **Pod label** | None | `azure.workload.identity/use: "true"` |
| **envFrom** | `secretRef: azure-sp-credentials` | **Removed** |
| **PVC** | `blob-writer-data` (1Gi, managed-csi) | Same — recreated on new cluster, data restored from Blob Storage |

### PVC data migration

For stateful applications, PVC data must be migrated separately since PVCs are cluster-scoped. In this demo, blob-writer's data is also stored in Azure Blob Storage, which provides a natural backup/restore path:

1. **Verify data in Blob Storage** — data written by the SP cluster is already available in Azure Blob Storage (shared across clusters)
2. **Recreate PVC on MI cluster** — the PVC is created fresh (same StorageClass, same size)
3. **Restore local state** — the app rebuilds its local log from the next write operation

For applications where the PVC is the only data store (no cloud backup), use one of these approaches:

- **Azure Disk snapshot:** Create a snapshot of the old PVC's Azure Disk, then create a new PVC from the snapshot on the MI cluster
- **rsync:** Use `oc rsync` to copy data between pods across clusters
- **Application-level backup:** Use the application's own backup/restore mechanism (e.g., database dump/restore)

## How Workload Identity Works Behind the Scenes

When you add the ServiceAccount annotation and pod label, the workload identity webhook does the following at pod startup:

1. **Injects environment variables** into the pod:
   - `AZURE_CLIENT_ID` — the managed identity's client ID (from the ServiceAccount annotation)
   - `AZURE_TENANT_ID` — the cluster's Azure tenant
   - `AZURE_FEDERATED_TOKEN_FILE` — path to a projected volume containing a K8s JWT token
   - `AZURE_AUTHORITY_HOST` — the Azure AD authority URL

2. **Mounts a projected volume** containing a short-lived K8s service account token

3. **At runtime**, `DefaultAzureCredential` detects these variables and performs an OIDC token exchange:
   - Reads the K8s JWT from the projected volume
   - Exchanges it with Azure AD for an Azure access token
   - Uses the Azure access token to call Azure services (Key Vault, Blob Storage, etc.)

No secrets are stored in the cluster. The K8s JWT is short-lived and automatically rotated. The Azure token expires within approximately one hour.

You can verify the injected environment variables:

```bash
# Check keyvault-reader pod
oc exec -n keyvault-reader deploy/keyvault-reader -- env | grep AZURE_

# Expected output (no AZURE_CLIENT_SECRET):
# AZURE_CLIENT_ID=<managed-identity-client-id>
# AZURE_TENANT_ID=<tenant-id>
# AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token
# AZURE_AUTHORITY_HOST=https://login.microsoftonline.com/
```

## Key Takeaways

1. **Code change is only needed when using explicit credential classes** like `ClientSecretCredential`. If your app already uses `DefaultAzureCredential`, no code change is required.

2. **K8s manifest changes are the same for every app**: remove the Secret reference, add a ServiceAccount with the workload identity annotation, and add the pod label.

3. **The application container image is identical** on both SP and MI clusters. The difference is entirely in how credentials are provided to the pod.

4. **PVC migration is independent of SP-to-MI** — it's a standard cluster migration concern. Use Azure Disk snapshots, `oc rsync`, or application-level backup/restore.

5. **`DefaultAzureCredential` is the best practice** for any new Azure SDK code. It works transparently across SP clusters (using env vars), MI clusters (using workload identity), and local development (using Azure CLI credentials).

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

The complete source code for both demo applications is available in the `demo-apps/` directory:

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
        ├── deploy-sp.yaml  # Full SP manifest (with K8s Secret + PVC)
        └── deploy-mi.yaml  # Full MI manifest (with ServiceAccount + PVC)
```

## References

- [Part 1: Service Principal vs Managed Identity Explained](../aro-sp-mi)
- [Use workload identity with an ARO cluster](https://learn.microsoft.com/en-us/azure/openshift/howto-create-a-workloadidentitypool)
- [Azure Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [DefaultAzureCredential documentation](https://learn.microsoft.com/en-us/python/api/azure-identity/azure.identity.defaultazurecredential)
- [Create an ARO cluster with managed identities](https://learn.microsoft.com/en-us/azure/openshift/howto-create-openshift-cluster?pivots=aro-deploy-az-cli)
