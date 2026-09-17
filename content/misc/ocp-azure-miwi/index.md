---
date: '2026-09-15'
title: Configuring Microsoft Entra Workload Identity on Self-Managed OpenShift
tags: ["Azure", "Miscellaneous"]
authors:
  - Philipp Bergsmann
---

Microsoft Entra Workload Identity allows Kubernetes workloads to access Azure resources without storing credentials. It works by federating Kubernetes service account tokens with Microsoft Entra ID, so pods can obtain Azure access tokens using short-lived, automatically rotated credentials.

On Azure Red Hat OpenShift (ARO), Workload Identity (MIWI) is available as a first-class deployment option. On **self-managed OpenShift clusters**, however, you need to configure the federation manually. This guide walks through the full setup: hosting an OIDC discovery document on Azure Blob Storage, configuring the cluster's service account issuer, and installing the Workload Identity webhook. A validation section at the end creates a test managed identity and pod to verify the end-to-end flow.

{{% alert state="info" %}}This guide works for any self-managed OpenShift cluster, regardless of where it runs. The cluster does not need to be hosted on Azure. The OIDC discovery endpoint is hosted on Azure Blob Storage, and Microsoft Entra ID validates tokens by fetching the public keys from that endpoint. No inbound network access to the cluster is required.{{% /alert %}}

## Prerequisites

* A self-managed OpenShift cluster (on any infrastructure)
* `oc` CLI (logged in as a cluster admin)
* `az` CLI (logged in with a subscription that has permissions to create managed identities, role assignments, and storage accounts)
* `helm` CLI
* `jq` and `yq`

### Install the Azure Workload Identity CLI

The `azwi` CLI is used to generate JWKS documents from the cluster's service account signing keys.

```bash
brew install Azure/azure-workload-identity/azwi
```

{{% alert state="info" %}}On Linux or other platforms, see the [Azure Workload Identity installation guide](https://azure.github.io/azure-workload-identity/docs/installation.html) for alternative install methods.{{% /alert %}}

### Prepare environment variables

{{% alert state="info" %}}Adjust `AZ_LOCATION` and `OCP_AZ_MIWI_RESOURCE_PREFIX` to match your environment.{{% /alert %}}

```bash
export AZ_LOCATION="eastus"
export OCP_AZ_MIWI_RESOURCE_PREFIX="ocp-azure-miwi"

export AZURE_RG_NAME="${OCP_AZ_MIWI_RESOURCE_PREFIX}-rg"
export AZURE_TENANT_ID="$(az account show --query tenantId -o tsv)"
```

Create a dedicated resource group:

```bash
az group create --name "${AZURE_RG_NAME}" --location "${AZ_LOCATION}"
```

---

## Retrieve the cluster's service account signing keys

OpenShift stores the service account signing key pair in a secret in the `openshift-kube-apiserver` namespace. These keys are used to sign the service account tokens that Microsoft Entra ID will validate.

Export the private and public keys to local files:

```bash
oc get secret bound-service-account-signing-key \
  -n openshift-kube-apiserver \
  -o jsonpath='{.data.service-account\.key}' | base64 -d > service-account.key

oc get secret bound-service-account-signing-key \
  -n openshift-kube-apiserver \
  -o jsonpath='{.data.service-account\.pub}' | base64 -d > service-account.pub
```

---

## Create an Azure Storage account for OIDC discovery

Microsoft Entra ID needs to discover the cluster's OIDC configuration over HTTPS. A static website hosted in Azure Blob Storage provides a simple, publicly accessible endpoint for the `.well-known/openid-configuration` and JWKS documents.

### Create the storage account and enable static website hosting

```bash
export AZURE_STORAGE_ACCOUNT="${OCP_AZ_MIWI_RESOURCE_PREFIX//-/}oidcsa"

az storage account create \
  --resource-group "${AZURE_RG_NAME}" \
  --name "${AZURE_STORAGE_ACCOUNT}" \
  --location "${AZ_LOCATION}"
```

{{% alert state="info" %}}The `$web` container is the fixed, required name for Azure Blob Storage static websites. Azure serves content from this container at the storage account's static website endpoint.{{% /alert %}}

```bash
az storage container create \
  --name '$web' \
  --account-name "${AZURE_STORAGE_ACCOUNT}"

az storage blob service-properties update \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --static-website \
  --index-document index.html
```

### Upload the OpenID Connect discovery document

Create and upload the OIDC discovery document to the storage account's static website:

```bash
cat <<EOF > openid-configuration.json
{
  "issuer": "https://${AZURE_STORAGE_ACCOUNT}.z13.web.core.windows.net/",
  "jwks_uri": "https://${AZURE_STORAGE_ACCOUNT}.z13.web.core.windows.net/openid/v1/jwks",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [
    "public"
  ],
  "id_token_signing_alg_values_supported": [
    "RS256"
  ]
}
EOF

az storage blob upload \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --container-name '$web' \
  --file openid-configuration.json \
  --name .well-known/openid-configuration \
  --overwrite
```

Verify the document is accessible:

```bash
curl -s "https://${AZURE_STORAGE_ACCOUNT}.z13.web.core.windows.net/.well-known/openid-configuration" | jq .
```

### Upload the JWKS document

Generate the JWKS document from the cluster's public signing key and upload it:

```bash
azwi jwks --public-keys service-account.pub --output-file jwks.json

az storage blob upload \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --container-name '$web' \
  --file jwks.json \
  --name openid/v1/jwks \
  --overwrite
```

Verify the JWKS endpoint:

```bash
curl -s "https://${AZURE_STORAGE_ACCOUNT}.z13.web.core.windows.net/openid/v1/jwks" | jq .
```

{{% alert state="warning" %}}The JWKS document contains the public signing keys that Microsoft Entra ID uses to validate service account tokens. If the cluster's signing keys rotate (for example during an OpenShift upgrade or manual revocation), the JWKS document on the storage account must be re-uploaded. Tokens signed with the new key will fail validation until the JWKS is updated. See [Automate OIDC key synchronization](#automate-oidc-key-synchronization) for a Deployment that watches for key changes and handles this automatically.{{% /alert %}}

---

## Configure the OpenShift service account issuer

Patch the cluster's `Authentication` resource to use the storage account's static website URL as the service account token issuer. This tells the API server to include this URL as the `iss` claim in all service account tokens, which Microsoft Entra ID will validate against the OIDC discovery document.

Check the current configuration:

```bash
oc get authentication cluster -o yaml | yq '.spec'
```

Apply the patch:

```bash
oc patch authentication cluster --type=merge \
  -p "{\"spec\":{\"serviceAccountIssuer\":\"https://${AZURE_STORAGE_ACCOUNT}.z13.web.core.windows.net/\"}}"
```

Verify the change:

```bash
oc get authentication cluster -o yaml | yq '.spec'
```

{{% alert state="warning" %}}Changing the service account issuer triggers a rolling restart of the kube-apiserver pods. Wait for all API server pods to stabilize before continuing.{{% /alert %}}

---

## Install the Azure Workload Identity webhook

The [Azure Workload Identity webhook](https://azure.github.io/azure-workload-identity/) mutates pods that opt in (via the `azure.workload.identity/use: "true"` label) to inject the federated token volume and environment variables needed for Microsoft Entra ID authentication.

Grant the privileged SCC to the webhook's service accounts:

```bash
oc adm policy add-scc-to-group privileged \
  system:serviceaccounts:azure-workload-identity-system
```

Install the webhook via Helm:

```bash
helm repo add azure-workload-identity \
  https://azure.github.io/azure-workload-identity/charts
helm repo update

helm install workload-identity-webhook \
  azure-workload-identity/workload-identity-webhook \
  --namespace azure-workload-identity-system \
  --create-namespace \
  --set azureTenantID="${AZURE_TENANT_ID}"
```

At this point the cluster-level setup is complete. The OIDC discovery document is hosted, the service account issuer is configured, and the webhook is running. Every pod that carries the `azure.workload.identity/use: "true"` label will have a federated token volume and the `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_FEDERATED_TOKEN_FILE` environment variables injected automatically.

{{% alert state="info" %}}The JWKS document uploaded earlier is a point-in-time snapshot. To keep it in sync automatically when the cluster's signing keys change (rotation or manual revocation), deploy the sync watcher described in [Automate OIDC key synchronization](#automate-oidc-key-synchronization) after completing the validation below.{{% /alert %}}

---

## Validate the setup

To verify the end-to-end flow, create a test managed identity with a federated credential, deploy a test pod, and confirm it can authenticate against Azure.

### Create a test managed identity

```bash
export AZURE_MIWI_IDENTITY_NAME="openshift-workload-identity-test"

az identity create \
  --name "${AZURE_MIWI_IDENTITY_NAME}" \
  --resource-group "${AZURE_RG_NAME}" \
  --location "${AZ_LOCATION}"

export AZURE_MIWI_CLIENT_ID="$(az identity show \
  --name "${AZURE_MIWI_IDENTITY_NAME}" \
  --resource-group "${AZURE_RG_NAME}" \
  --query clientId -o tsv)"
```

### Create a federated credential

The federated credential binds the managed identity to a specific Kubernetes service account. When the pod presents a service account token with the matching issuer and subject, Microsoft Entra ID will issue an access token for the managed identity.

```bash
az identity federated-credential create \
  --name "openshift-federated-cred" \
  --identity-name "${AZURE_MIWI_IDENTITY_NAME}" \
  --resource-group "${AZURE_RG_NAME}" \
  --issuer "https://${AZURE_STORAGE_ACCOUNT}.z13.web.core.windows.net/" \
  --subject "system:serviceaccount:azure-workload-identity-test:azure-identity-test-sa" \
  --audiences "api://AzureADTokenExchange"
```

### Assign a role to the managed identity

Grant the managed identity access to the storage account so the test pod can verify authentication:

```bash
export MI_PRINCIPAL_ID="$(az identity show \
  --name "${AZURE_MIWI_IDENTITY_NAME}" \
  --resource-group "${AZURE_RG_NAME}" \
  --query principalId \
  -o tsv)"

export STORAGE_SCOPE="$(az storage account show \
  --name "${AZURE_STORAGE_ACCOUNT}" \
  --resource-group "${AZURE_RG_NAME}" \
  --query id \
  -o tsv)"

az role assignment create \
  --assignee "${MI_PRINCIPAL_ID}" \
  --role "Storage Blob Data Contributor" \
  --scope "${STORAGE_SCOPE}"
```

### Deploy test resources in OpenShift

Create a test namespace, service account, and pod:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: azure-workload-identity-test
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: azure-identity-test-sa
  namespace: azure-workload-identity-test
  annotations:
    azure.workload.identity/client-id: "${AZURE_MIWI_CLIENT_ID}"
    azure.workload.identity/tenant-id: "${AZURE_TENANT_ID}"
---
apiVersion: v1
kind: Pod
metadata:
  name: azure-cli-test-pod
  namespace: azure-workload-identity-test
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: azure-identity-test-sa
  containers:
    - name: azure-cli
      image: mcr.microsoft.com/azure-cli:latest
      command:
        - /bin/sh
        - -c
        - "sleep infinity"
EOF
```

Wait for the pod to reach `Running`:

```bash
oc get pod azure-cli-test-pod -n azure-workload-identity-test -w
```

### Verify from inside the pod

Open a shell in the test pod:

```bash
oc exec -it azure-cli-test-pod -n azure-workload-identity-test -- bash
```

Inside the pod, the webhook has injected the `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_FEDERATED_TOKEN_FILE` environment variables. Use them to log in:

```bash
az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -t "${AZURE_TENANT_ID}" \
  --federated-token "$(cat ${AZURE_FEDERATED_TOKEN_FILE})" \
  --allow-no-subscriptions
```

Verify access to the storage account:

```bash
az storage container list \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --auth-mode login
```

If the command returns a list of containers, the entire Workload Identity pipeline is working correctly: the pod's service account token was accepted by Microsoft Entra ID, and the resulting access token has the expected permissions.

---

## Cleanup

Remove the test resources:

```bash
oc delete namespace azure-workload-identity-test

az identity delete \
  --name "${AZURE_MIWI_IDENTITY_NAME}" \
  --resource-group "${AZURE_RG_NAME}"
```

To also remove the cluster-level setup:

```bash
helm uninstall workload-identity-webhook \
  --namespace azure-workload-identity-system
oc delete namespace azure-workload-identity-system

az group delete --name "${AZURE_RG_NAME}" --yes --no-wait

rm -f service-account.key service-account.pub \
  openid-configuration.json jwks.json
```

{{% alert state="info" %}}If you deployed the OIDC sync watcher, each option includes its own cleanup steps: [Option A cleanup](#a7-cleanup) or [Option B cleanup](#b6-cleanup).{{% /alert %}}

---

## Automate OIDC key synchronization

The OIDC discovery and JWKS documents uploaded in the initial setup are a point-in-time snapshot of the cluster's service account signing keys. These keys can change in two scenarios:

* **Automatic rotation**: during OpenShift upgrades, the cluster may rotate the signing keys. The API server keeps the previous key in its JWKS endpoint for a **24-hour grace period**, so tokens signed with the old key remain valid during the transition.
* **Manual revocation**: if an administrator manually revokes or deletes the signing keys, the old keys are removed immediately with no grace period.

In both cases, the JWKS document on Azure Storage must be updated to reflect the new keys. The Deployment below watches the `bound-service-account-signing-key` secret in the `openshift-kube-apiserver` namespace for changes. On startup it performs an initial sync, then re-uploads the JWKS whenever the secret is modified.

The sync pod must authenticate to Azure **independently of Workload Identity**. If the signing keys change and the JWKS on Azure Storage has not been updated yet, a Workload Identity-based pod would present a token signed with the new key that Microsoft Entra ID cannot validate against the stale JWKS. Two options avoid this circular dependency. Pick the one that fits your security model and follow that option through to the end.

* **Option A** uses a service principal with Entra ID RBAC, audit trails, and scoped permissions.
* **Option B** uses a storage account access key for a simpler setup, but the key grants full access to the entire storage account.

### Option A: Service principal

#### A1) Create a service principal

Register an application in Microsoft Entra ID and create a client secret:

```bash
export OIDC_SYNC_APP_NAME="${OCP_AZ_MIWI_RESOURCE_PREFIX}-oidc-sync"

OIDC_SYNC_APP_ID="$(az ad app create \
  --display-name "${OIDC_SYNC_APP_NAME}" \
  --query appId -o tsv)"

az ad sp create --id "${OIDC_SYNC_APP_ID}"

OIDC_SYNC_CLIENT_SECRET="$(az ad app credential reset \
  --id "${OIDC_SYNC_APP_ID}" \
  --display-name "oidc-sync-key" \
  --query password -o tsv)"

echo "App (client) ID: ${OIDC_SYNC_APP_ID}"
```

{{% alert state="warning" %}}Save the `OIDC_SYNC_CLIENT_SECRET` value now. It cannot be retrieved again after this step.{{% /alert %}}

#### A2) Grant blob upload permissions

```bash
export OIDC_SYNC_SP_OBJECT_ID="$(az ad sp show \
  --id "${OIDC_SYNC_APP_ID}" \
  --query id -o tsv)"

export STORAGE_SCOPE="$(az storage account show \
  --name "${AZURE_STORAGE_ACCOUNT}" \
  --resource-group "${AZURE_RG_NAME}" \
  --query id \
  -o tsv)"

az role assignment create \
  --assignee "${OIDC_SYNC_SP_OBJECT_ID}" \
  --role "Storage Blob Data Contributor" \
  --scope "${STORAGE_SCOPE}"
```

#### A3) Create the sync namespace, service account, and credentials

```bash
export OIDC_SYNC_NAMESPACE="azure-oidc-sync"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${OIDC_SYNC_NAMESPACE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: oidc-key-sync-sa
  namespace: ${OIDC_SYNC_NAMESPACE}
EOF

oc create secret generic oidc-sync-credentials \
  -n "${OIDC_SYNC_NAMESPACE}" \
  --from-literal=AZURE_SP_CLIENT_ID="${OIDC_SYNC_APP_ID}" \
  --from-literal=AZURE_SP_CLIENT_SECRET="${OIDC_SYNC_CLIENT_SECRET}" \
  --from-literal=AZURE_SP_TENANT_ID="${AZURE_TENANT_ID}"
```

#### A4) Grant RBAC

```bash
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: oidc-jwks-reader
rules:
  - nonResourceURLs:
      - /openid/v1/jwks
    verbs:
      - get
  - apiGroups: ["console.openshift.io"]
    resources: ["consoleclidownloads"]
    resourceNames: ["oc-cli-downloads"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-jwks-reader-binding
subjects:
  - kind: ServiceAccount
    name: oidc-key-sync-sa
    namespace: ${OIDC_SYNC_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: oidc-jwks-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: signing-key-watcher
  namespace: openshift-kube-apiserver
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["bound-service-account-signing-key"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: signing-key-watcher-binding
  namespace: openshift-kube-apiserver
subjects:
  - kind: ServiceAccount
    name: oidc-key-sync-sa
    namespace: ${OIDC_SYNC_NAMESPACE}
roleRef:
  kind: Role
  name: signing-key-watcher
  apiGroup: rbac.authorization.k8s.io
EOF
```

#### A5) Deploy the sync watcher

```bash
export ISSUER_URL="https://${AZURE_STORAGE_ACCOUNT}.z13.web.core.windows.net/"

cat <<'OUTER' | envsubst | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azure-oidc-key-sync
  namespace: ${OIDC_SYNC_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: azure-oidc-key-sync
  template:
    metadata:
      labels:
        app: azure-oidc-key-sync
    spec:
      serviceAccountName: oidc-key-sync-sa
      containers:
        - name: oidc-sync
          image: mcr.microsoft.com/azure-cli:latest
          env:
            - name: AZURE_SP_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: oidc-sync-credentials
                  key: AZURE_SP_CLIENT_ID
            - name: AZURE_SP_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: oidc-sync-credentials
                  key: AZURE_SP_CLIENT_SECRET
            - name: AZURE_SP_TENANT_ID
              valueFrom:
                secretKeyRef:
                  name: oidc-sync-credentials
                  key: AZURE_SP_TENANT_ID
            - name: STORAGE_ACCOUNT_NAME
              value: "${AZURE_STORAGE_ACCOUNT}"
            - name: ISSUER_URL
              value: "${ISSUER_URL}"
          command:
            - /bin/sh
            - -c
            - |
              set -e

              # Download the oc CLI from the cluster's ConsoleCLIDownload endpoint
              echo "[$(date -Iseconds)] Installing oc CLI..."
              CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              OC_URL=$(curl -s --cacert "${CA}" -H "Authorization: Bearer ${TOKEN}" \
                "https://kubernetes.default.svc/apis/console.openshift.io/v1/consoleclidownloads/oc-cli-downloads" \
                | sed -n 's/.*"href":"\(https:[^"]*linux\/oc\.tar\)".*/\1/p' | head -1)
              curl -sk "${OC_URL}" | tar xf - -C /usr/local/bin/

              sync_jwks() {
                echo "[$(date -Iseconds)] Authenticating to Azure..."
                az login --service-principal \
                  -u "${AZURE_SP_CLIENT_ID}" \
                  -p "${AZURE_SP_CLIENT_SECRET}" \
                  -t "${AZURE_SP_TENANT_ID}" \
                  --output none

                echo "[$(date -Iseconds)] Fetching live JWKS from API server..."
                oc get --raw /openid/v1/jwks > /tmp/jwks.json

                cat > /tmp/openid-configuration.json <<OIDC
              {
                "issuer": "${ISSUER_URL}",
                "jwks_uri": "${ISSUER_URL}openid/v1/jwks",
                "response_types_supported": ["id_token"],
                "subject_types_supported": ["public"],
                "id_token_signing_alg_values_supported": ["RS256"]
              }
              OIDC

                echo "[$(date -Iseconds)] Uploading to Azure Storage..."
                az storage blob upload \
                  --account-name "${STORAGE_ACCOUNT_NAME}" \
                  --container-name '$web' \
                  --name ".well-known/openid-configuration" \
                  --file /tmp/openid-configuration.json \
                  --overwrite --auth-mode login --output none

                az storage blob upload \
                  --account-name "${STORAGE_ACCOUNT_NAME}" \
                  --container-name '$web' \
                  --name "openid/v1/jwks" \
                  --file /tmp/jwks.json \
                  --overwrite --auth-mode login --output none

                echo "[$(date -Iseconds)] OIDC key sync completed."
              }

              # Initial sync on startup
              sync_jwks

              # Watch the signing key secret, re-sync on every change
              echo "[$(date -Iseconds)] Watching bound-service-account-signing-key for changes..."
              while true; do
                oc get secret bound-service-account-signing-key \
                  -n openshift-kube-apiserver \
                  --watch -o jsonpath='{.metadata.resourceVersion}{"\n"}' \
                | {
                  read -r _  # skip initial output (already synced)
                  while read -r _; do
                    echo "[$(date -Iseconds)] Signing key changed, waiting 60s for API server rollout..."
                    sleep 60
                    sync_jwks
                  done
                }

                echo "[$(date -Iseconds)] Watch disconnected, reconnecting in 10s..."
                sleep 10
                sync_jwks
              done
OUTER
```

#### A6) Verify the sync watcher

```bash
oc get pods -n "${OIDC_SYNC_NAMESPACE}" -l app=azure-oidc-key-sync

oc logs -f deployment/azure-oidc-key-sync -n "${OIDC_SYNC_NAMESPACE}"
```

You should see `OIDC key sync completed.` followed by `Watching bound-service-account-signing-key for changes...`

#### A7) Cleanup

```bash
oc delete namespace "${OIDC_SYNC_NAMESPACE}"
oc delete clusterrolebinding oidc-jwks-reader-binding
oc delete clusterrole oidc-jwks-reader
oc delete rolebinding signing-key-watcher-binding -n openshift-kube-apiserver
oc delete role signing-key-watcher -n openshift-kube-apiserver

az ad app delete --id "${OIDC_SYNC_APP_ID}"
```

---

### Option B: Storage account access key

#### B1) Retrieve the access key

```bash
STORAGE_ACCOUNT_KEY="$(az storage account keys list \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --resource-group "${AZURE_RG_NAME}" \
  --query '[0].value' -o tsv)"
```

{{% alert state="info" %}}The access key grants **full access to the entire storage account**, not just the `$web` container. For a dedicated storage account that only holds OIDC documents, this is an acceptable tradeoff. If the storage account holds other data, use [Option A](#option-a-service-principal) instead.{{% /alert %}}

#### B2) Create the sync namespace, service account, and credentials

```bash
export OIDC_SYNC_NAMESPACE="azure-oidc-sync"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${OIDC_SYNC_NAMESPACE}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: oidc-key-sync-sa
  namespace: ${OIDC_SYNC_NAMESPACE}
EOF

oc create secret generic oidc-sync-credentials \
  -n "${OIDC_SYNC_NAMESPACE}" \
  --from-literal=AZURE_STORAGE_KEY="${STORAGE_ACCOUNT_KEY}"
```

#### B3) Grant RBAC

```bash
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: oidc-jwks-reader
rules:
  - nonResourceURLs:
      - /openid/v1/jwks
    verbs:
      - get
  - apiGroups: ["console.openshift.io"]
    resources: ["consoleclidownloads"]
    resourceNames: ["oc-cli-downloads"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-jwks-reader-binding
subjects:
  - kind: ServiceAccount
    name: oidc-key-sync-sa
    namespace: ${OIDC_SYNC_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: oidc-jwks-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: signing-key-watcher
  namespace: openshift-kube-apiserver
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["bound-service-account-signing-key"]
    verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: signing-key-watcher-binding
  namespace: openshift-kube-apiserver
subjects:
  - kind: ServiceAccount
    name: oidc-key-sync-sa
    namespace: ${OIDC_SYNC_NAMESPACE}
roleRef:
  kind: Role
  name: signing-key-watcher
  apiGroup: rbac.authorization.k8s.io
EOF
```

#### B4) Deploy the sync watcher

```bash
export ISSUER_URL="https://${AZURE_STORAGE_ACCOUNT}.z13.web.core.windows.net/"

cat <<'OUTER' | envsubst | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: azure-oidc-key-sync
  namespace: ${OIDC_SYNC_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: azure-oidc-key-sync
  template:
    metadata:
      labels:
        app: azure-oidc-key-sync
    spec:
      serviceAccountName: oidc-key-sync-sa
      containers:
        - name: oidc-sync
          image: mcr.microsoft.com/azure-cli:latest
          env:
            - name: AZURE_STORAGE_KEY
              valueFrom:
                secretKeyRef:
                  name: oidc-sync-credentials
                  key: AZURE_STORAGE_KEY
            - name: STORAGE_ACCOUNT_NAME
              value: "${AZURE_STORAGE_ACCOUNT}"
            - name: ISSUER_URL
              value: "${ISSUER_URL}"
          command:
            - /bin/sh
            - -c
            - |
              set -e

              # Download the oc CLI from the cluster's ConsoleCLIDownload endpoint
              echo "[$(date -Iseconds)] Installing oc CLI..."
              CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              OC_URL=$(curl -s --cacert "${CA}" -H "Authorization: Bearer ${TOKEN}" \
                "https://kubernetes.default.svc/apis/console.openshift.io/v1/consoleclidownloads/oc-cli-downloads" \
                | sed -n 's/.*"href":"\(https:[^"]*linux\/oc\.tar\)".*/\1/p' | head -1)
              curl -sk "${OC_URL}" | tar xf - -C /usr/local/bin/

              sync_jwks() {
                echo "[$(date -Iseconds)] Fetching live JWKS from API server..."
                oc get --raw /openid/v1/jwks > /tmp/jwks.json

                cat > /tmp/openid-configuration.json <<OIDC
              {
                "issuer": "${ISSUER_URL}",
                "jwks_uri": "${ISSUER_URL}openid/v1/jwks",
                "response_types_supported": ["id_token"],
                "subject_types_supported": ["public"],
                "id_token_signing_alg_values_supported": ["RS256"]
              }
              OIDC

                echo "[$(date -Iseconds)] Uploading to Azure Storage..."
                az storage blob upload \
                  --account-name "${STORAGE_ACCOUNT_NAME}" \
                  --account-key "${AZURE_STORAGE_KEY}" \
                  --container-name '$web' \
                  --name ".well-known/openid-configuration" \
                  --file /tmp/openid-configuration.json \
                  --overwrite --output none

                az storage blob upload \
                  --account-name "${STORAGE_ACCOUNT_NAME}" \
                  --account-key "${AZURE_STORAGE_KEY}" \
                  --container-name '$web' \
                  --name "openid/v1/jwks" \
                  --file /tmp/jwks.json \
                  --overwrite --output none

                echo "[$(date -Iseconds)] OIDC key sync completed."
              }

              # Initial sync on startup
              sync_jwks

              # Watch the signing key secret, re-sync on every change
              echo "[$(date -Iseconds)] Watching bound-service-account-signing-key for changes..."
              while true; do
                oc get secret bound-service-account-signing-key \
                  -n openshift-kube-apiserver \
                  --watch -o jsonpath='{.metadata.resourceVersion}{"\n"}' \
                | {
                  read -r _  # skip initial output (already synced)
                  while read -r _; do
                    echo "[$(date -Iseconds)] Signing key changed, waiting 60s for API server rollout..."
                    sleep 60
                    sync_jwks
                  done
                }

                echo "[$(date -Iseconds)] Watch disconnected, reconnecting in 10s..."
                sleep 10
                sync_jwks
              done
OUTER
```

#### B5) Verify the sync watcher

```bash
oc get pods -n "${OIDC_SYNC_NAMESPACE}" -l app=azure-oidc-key-sync

oc logs -f deployment/azure-oidc-key-sync -n "${OIDC_SYNC_NAMESPACE}"
```

You should see `OIDC key sync completed.` followed by `Watching bound-service-account-signing-key for changes...`

#### B6) Cleanup

```bash
oc delete namespace "${OIDC_SYNC_NAMESPACE}"
oc delete clusterrolebinding oidc-jwks-reader-binding
oc delete clusterrole oidc-jwks-reader
oc delete rolebinding signing-key-watcher-binding -n openshift-kube-apiserver
oc delete role signing-key-watcher -n openshift-kube-apiserver
```

---

## Additional resources

* [Azure Workload Identity documentation](https://azure.github.io/azure-workload-identity/docs/)
* [Microsoft Entra Workload ID federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
* [OpenShift authentication configuration](https://docs.openshift.com/container-platform/latest/authentication/understanding-authentication.html)
* [Bound service account tokens and key rotation](https://docs.openshift.com/container-platform/latest/authentication/bound-service-account-tokens.html)
* [Automating ACR Pull Secrets on ARO Using the External Secrets Operator and Workload Identity](/experts/aro/acr-external-secrets-miwi/)
