---
date: '2026-09-15'
title: Configuring Microsoft Entra Workload Identity on Self-Managed OpenShift
tags: ["Azure", "Miscellaneous"]
authors:
  - Philipp Bergsmann
---

Microsoft Entra Workload Identity allows Kubernetes workloads to access Azure resources without storing credentials. It works by federating Kubernetes service account tokens with Microsoft Entra ID, so pods can obtain Azure access tokens using short-lived, automatically rotated credentials.

On Azure Red Hat OpenShift (ARO), Managed Identities and Workload Identity (MIWI) are supported as a first-class deployment model. On **self-managed OpenShift clusters**, however, you need to configure the federation manually. This guide walks through the full setup: hosting an OIDC discovery document on Azure Blob Storage, configuring the cluster's service account issuer, and installing the Workload Identity webhook. A validation section at the end creates a test managed identity and pod to verify the end-to-end flow.

{{% alert state="info" %}}This guide works for any self-managed OpenShift cluster, regardless of where it runs. The cluster does not need to be hosted on Azure. The OIDC discovery endpoint is hosted on Azure Blob Storage, and Microsoft Entra ID validates tokens by fetching the public keys from that endpoint. No inbound network access to the cluster is required. Workloads using Workload Identity must have outbound HTTPS connectivity to Microsoft Entra ID and to the Azure services they access.{{% /alert %}}

## Prerequisites

* A self-managed OpenShift cluster (on any infrastructure)
* `oc` CLI (logged in as a cluster admin)
* `az` CLI (logged in with a subscription that has permissions to create managed identities, role assignments, and storage accounts)
* `helm` CLI
* `jq` and `yq`
* `envsubst` (from GNU gettext)

### Prepare environment variables

{{% alert state="info" %}}Adjust `AZ_LOCATION` and `OCP_AZ_MIWI_RESOURCE_PREFIX` for your environment. The resulting Azure Storage account name must be globally unique across Azure, between 3 and 24 characters long, and contain only lowercase letters and numbers.{{% /alert %}}

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

Enable static website hosting, which automatically provisions the `$web` container:

```bash
az storage blob service-properties update \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --static-website \
  --index-document index.html
```

Retrieve the static website endpoint. The zone identifier in the URL varies by region and storage cluster, so it must be queried dynamically:

```bash
export ISSUER_URL="$(az storage account show \
  --name "${AZURE_STORAGE_ACCOUNT}" \
  --resource-group "${AZURE_RG_NAME}" \
  --query "primaryEndpoints.web" -o tsv)"

echo "Issuer URL: ${ISSUER_URL}"
```

### Upload the OpenID Connect discovery document

Create and upload the OIDC discovery document to the storage account's static website:

```bash
cat <<EOF > openid-configuration.json
{
  "issuer": "${ISSUER_URL}",
  "jwks_uri": "${ISSUER_URL}openid/v1/jwks",
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
curl -s "${ISSUER_URL}.well-known/openid-configuration" | jq .
```

### Upload the JWKS document

The OpenShift API server publishes the complete public JWKS at `/openid/v1/jwks`. Fetch it directly and upload:

```bash
oc get --raw /openid/v1/jwks > jwks.json

az storage blob upload \
  --account-name "${AZURE_STORAGE_ACCOUNT}" \
  --container-name '$web' \
  --file jwks.json \
  --name openid/v1/jwks \
  --overwrite
```

Verify the JWKS endpoint:

```bash
curl -s "${ISSUER_URL}openid/v1/jwks" | jq .
```

{{% alert state="warning" %}}The JWKS document contains the public signing keys that Microsoft Entra ID uses to validate service account tokens. If the cluster's signing keys are rotated or manually revoked, the JWKS document on the storage account must be re-uploaded. Tokens signed with the new key will fail validation until the JWKS is updated. See [Automate OIDC key synchronization](#automate-oidc-key-synchronization) for an experimental watcher that reduces the need for manual JWKS synchronization.{{% /alert %}}

---

## Configure the OpenShift service account issuer

Patch the cluster's `Authentication` resource to use the storage account's static website URL as the service account token issuer. This tells the API server to include this URL as the `iss` claim in all service account tokens, which Microsoft Entra ID will validate against the OIDC discovery document.

Save the current issuer so it can be restored during cleanup, then check the full configuration:

```bash
export ORIGINAL_SERVICE_ACCOUNT_ISSUER="$(
  oc get authentication cluster \
    -o jsonpath='{.spec.serviceAccountIssuer}'
)"

echo "Current issuer: ${ORIGINAL_SERVICE_ACCOUNT_ISSUER}"
oc get authentication cluster -o yaml | yq '.spec'
```

Apply the patch:

```bash
oc patch authentication cluster --type=merge \
  -p "{\"spec\":{\"serviceAccountIssuer\":\"${ISSUER_URL}\"}}"
```

Verify the change:

```bash
oc get authentication cluster -o yaml | yq '.spec'
```

Changing the service account issuer triggers a rolling restart of the kube-apiserver pods. Wait until all nodes have reached the latest revision before continuing:

```bash
oc get kubeapiserver cluster \
  -o jsonpath='{.status.conditions[?(@.type=="NodeInstallerProgressing")].reason}{"\n"}'
```

The output should be `AllNodesAtLatestRevision`. If it shows a different value, wait and re-check until the rollout completes.

---

## Install the Azure Workload Identity webhook

The [Azure Workload Identity webhook](https://azure.github.io/azure-workload-identity/) mutates pods that opt in (via the `azure.workload.identity/use: "true"` label) to inject the federated token volume and environment variables needed for Microsoft Entra ID authentication.

On OpenShift, the webhook components require the `privileged` SCC. The SCC is granted to the service account group of the dedicated `azure-workload-identity-system` namespace because the Helm chart creates multiple service accounts. Do not deploy unrelated workloads into this namespace.

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
  --version 1.6.1 \
  --namespace azure-workload-identity-system \
  --create-namespace \
  --set azureTenantID="${AZURE_TENANT_ID}"
```

At this point the cluster-level setup is complete. The OIDC discovery document is hosted, the service account issuer is configured, and the webhook is running. For opted-in pods (carrying the `azure.workload.identity/use: "true"` label) using a service account with the Workload Identity annotations, the webhook injects the projected token volume and the `AZURE_AUTHORITY_HOST`, `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_FEDERATED_TOKEN_FILE` environment variables.

{{% alert state="info" %}}The JWKS document uploaded earlier is a point-in-time snapshot. To reduce the need for manual re-uploads when the cluster's signing keys change, consider deploying the experimental sync watcher described in [Automate OIDC key synchronization](#automate-oidc-key-synchronization) after completing the validation below.{{% /alert %}}

---

## Validate the setup

To verify the end-to-end flow, create a test managed identity with a federated credential, deploy a test pod, and confirm it can authenticate against Azure.

{{% alert state="info" %}}Newly created federated credentials, managed identities, and Azure RBAC assignments can take a few minutes to propagate. If an initial authentication or authorization attempt fails, wait a moment and retry before investigating the OpenShift configuration.{{% /alert %}}

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
  --issuer "${ISSUER_URL}" \
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
  --assignee-object-id "${MI_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
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
      image: mcr.microsoft.com/azure-cli:2.87.0-azurelinux3.0
      env:
        - name: AZURE_STORAGE_ACCOUNT
          value: "${AZURE_STORAGE_ACCOUNT}"
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

Inside the pod, the webhook has injected the `AZURE_AUTHORITY_HOST`, `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_FEDERATED_TOKEN_FILE` environment variables. Use them to log in:

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

To also remove the cluster-level setup, first restore the original service account issuer and wait for the kube-apiserver rollout to complete before deleting the Azure resources:

```bash
if [ -z "${ORIGINAL_SERVICE_ACCOUNT_ISSUER}" ]; then
  export ORIGINAL_SERVICE_ACCOUNT_ISSUER="https://kubernetes.default.svc"
fi

oc patch authentication cluster --type=merge \
  -p "{\"spec\":{\"serviceAccountIssuer\":\"${ORIGINAL_SERVICE_ACCOUNT_ISSUER}\"}}"
```

Wait until the rollout completes before deleting the Azure resources. Deleting the OIDC endpoint while the cluster still references it as its issuer will break token validation.

```bash
oc get kubeapiserver cluster \
  -o jsonpath='{.status.conditions[?(@.type=="NodeInstallerProgressing")].reason}{"\n"}'
```

Continue once the output is `AllNodesAtLatestRevision`.

```bash
oc adm policy remove-scc-from-group privileged \
  system:serviceaccounts:azure-workload-identity-system

helm uninstall workload-identity-webhook \
  --namespace azure-workload-identity-system
oc delete namespace azure-workload-identity-system

az group delete --name "${AZURE_RG_NAME}" --yes --no-wait

rm -f openid-configuration.json jwks.json
```

{{% alert state="info" %}}If you deployed the OIDC sync watcher, clean it up **before** deleting the Azure resource group. Each option includes its own cleanup steps: [Option A cleanup](#a7-cleanup) or [Option B cleanup](#b6-cleanup).{{% /alert %}}

---

## Automate OIDC key synchronization

The OIDC discovery and JWKS documents uploaded in the initial setup are a point-in-time snapshot of the cluster's service account signing keys. These keys can change in two scenarios:

* **Signing key rotation**: OpenShift's signer rotation process temporarily publishes both the existing and the next public signing key in the JWKS endpoint while the signer is transitioned, giving existing tokens time to expire naturally.
* **Manual revocation**: if an administrator manually revokes or deletes the signing keys, the old keys are removed immediately with no overlap period.

In both cases, the JWKS document on Azure Storage must be updated to reflect the new keys. The Deployment below watches the `bound-service-account-signing-key` secret in the `openshift-kube-apiserver` namespace for changes. On startup it performs an initial sync, then re-uploads the JWKS whenever the secret is modified.

{{% alert state="warning" %}}This synchronization mechanism is experimental. It keeps the externally hosted JWKS aligned with the JWKS currently exposed by the OpenShift API server, but it is not a replacement for OpenShift's documented service account signing key rotation procedure. It reacts to changes of the active signing key rather than participating in the complete `next-bound-service-account-signing-key` rotation sequence. Test key rotation carefully before relying on this mechanism in production.{{% /alert %}}

The sync pod must authenticate to Azure **independently of Workload Identity**. If the signing keys change and the JWKS on Azure Storage has not been updated yet, a Workload Identity-based pod would present a token signed with the new key that Microsoft Entra ID cannot validate against the stale JWKS. Two options avoid this circular dependency. Pick the one that fits your security model and follow that option through to the end.

* **Option A** uses a Microsoft Entra service principal authenticated with a client secret and authorized to the storage account through Azure RBAC. This provides audit trails and scoped permissions.
* **Option B** uses a storage account access key for a simpler setup, but the key grants full access to the entire storage account.

### Option A: Service principal

{{% alert state="info" %}}Option A requires Microsoft Entra ID directory permissions to register applications, create service principals, and create application credentials. These are separate from Azure subscription RBAC.{{% /alert %}}

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
  --assignee-object-id "${OIDC_SYNC_SP_OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
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
    verbs: ["watch", "list"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["bound-service-account-signing-key"]
    verbs: ["get"]
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
cat <<'OUTER' | envsubst '$OIDC_SYNC_NAMESPACE $AZURE_STORAGE_ACCOUNT $ISSUER_URL' | oc apply -f -
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
      initContainers:
        - name: install-oc
          image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
          command:
            - /bin/sh
            - -c
            - |
              cp "$(command -v oc)" /cli/oc
              chmod 0755 /cli/oc
          volumeMounts:
            - name: cli
              mountPath: /cli
      containers:
        - name: oidc-sync
          image: mcr.microsoft.com/azure-cli:2.87.0-azurelinux3.0
          env:
            - name: PATH
              value: "/opt/openshift-cli:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
          volumeMounts:
            - name: cli
              mountPath: /opt/openshift-cli
              readOnly: true
          command:
            - /bin/sh
            - -c
            - |
              set -e

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
                    echo "[$(date -Iseconds)] Signing key changed, synchronizing JWKS..."
                    sync_jwks
                  done
                }

                echo "[$(date -Iseconds)] Watch disconnected, reconnecting in 10s..."
                sleep 10
                sync_jwks
              done
      volumes:
        - name: cli
          emptyDir: {}
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

az role assignment delete \
  --assignee-object-id "${OIDC_SYNC_SP_OBJECT_ID}" \
  --role "Storage Blob Data Contributor" \
  --scope "${STORAGE_SCOPE}"

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
    verbs: ["watch", "list"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["bound-service-account-signing-key"]
    verbs: ["get"]
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
cat <<'OUTER' | envsubst '$OIDC_SYNC_NAMESPACE $AZURE_STORAGE_ACCOUNT $ISSUER_URL' | oc apply -f -
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
      initContainers:
        - name: install-oc
          image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
          command:
            - /bin/sh
            - -c
            - |
              cp "$(command -v oc)" /cli/oc
              chmod 0755 /cli/oc
          volumeMounts:
            - name: cli
              mountPath: /cli
      containers:
        - name: oidc-sync
          image: mcr.microsoft.com/azure-cli:2.87.0-azurelinux3.0
          env:
            - name: PATH
              value: "/opt/openshift-cli:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            - name: AZURE_STORAGE_KEY
              valueFrom:
                secretKeyRef:
                  name: oidc-sync-credentials
                  key: AZURE_STORAGE_KEY
            - name: STORAGE_ACCOUNT_NAME
              value: "${AZURE_STORAGE_ACCOUNT}"
            - name: ISSUER_URL
              value: "${ISSUER_URL}"
          volumeMounts:
            - name: cli
              mountPath: /opt/openshift-cli
              readOnly: true
          command:
            - /bin/sh
            - -c
            - |
              set -e

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
                    echo "[$(date -Iseconds)] Signing key changed, synchronizing JWKS..."
                    sync_jwks
                  done
                }

                echo "[$(date -Iseconds)] Watch disconnected, reconnecting in 10s..."
                sleep 10
                sync_jwks
              done
      volumes:
        - name: cli
          emptyDir: {}
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
