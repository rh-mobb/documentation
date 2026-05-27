---
date: '2026-05-26'
title: 'OpenShift MCP Server Deployment on ARO'
tags: ["ARO", "Miscellaneous"]
authors:
  - Dharmeshkumar Bhamre
---

This guide walks through deploying the [OpenShift Kubernetes MCP Server](https://github.com/openshift/openshift-mcp-server) on an **Azure Red Hat OpenShift (ARO)** cluster. You install the server with Helm, grant read-only cluster access to authorized users or groups, enable **OAuth/OIDC** on the MCP HTTP endpoint, and expose the service on a **TLS-terminated** OpenShift route.

The MCP server runs in **read-only** mode with destructive operations disabled. With OAuth enabled, callers must present a valid bearer token; the server uses **token passthrough** so each user's identity (not a shared service account) is used for Kubernetes API calls.

{{% notice warning %}}
**OAuth on the MCP server is a preview feature.** Configuration fields may change. Validate in a non-production cluster before production rollout. See the upstream [OAuth configuration](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/configuration.md) and [Entra ID](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/ENTRA_ID_SETUP.md) guides.
{{% /notice %}}

## Prerequisites

- OpenShift CLI (`oc`) installed and configured
- Helm 3.x installed
- Git installed
- Cluster admin credentials for the ARO cluster
- Network access to the cluster API endpoint
- Permission to register an OAuth/OIDC application (Azure AD app registration for most ARO clusters, or cluster admin for an `OAuthClient`)
- A dedicated Entra ID group (recommended) or OpenShift user/group that will access the MCP server

## Security and authentication

Two separate security layers apply:


| Layer                 | Purpose                          | How this guide configures it                                           |
| --------------------- | -------------------------------- | ---------------------------------------------------------------------- |
| **MCP HTTP endpoint** | Controls who can call `/mcp`     | `require_oauth: true` in Helm `config` (OIDC bearer token required)    |
| **Kubernetes API**    | Controls what MCP tools can read | `mcp-readonly` ClusterRole bound to your **group** (token passthrough) |


**Without OAuth**, a public OpenShift route allows anyone to use the MCP server's cluster credentials. **Do not expose the route without enabling OAuth** (or keep the service internal only; see [Internal access only](#internal-access-only-optional) at the end).

**Important:** When `require_oauth` is `true`, you must use `cluster_auth_mode: passthrough`. Do **not** bind `mcp-readonly` only to the pod service account—bind it to the users or groups that will authenticate (for example, an Entra ID group on ARO).

## Deployment procedure

### Step 1: Login to ARO Cluster

Authenticate to the ARO cluster using the OpenShift CLI. Replace the placeholders with your admin username, password, and cluster API URL.

```bash
oc login -u <Admin user> -p <password> https://api.<cluster-id>.<region>:6443
```

### Step 2: Create New Project

Create a dedicated namespace (project) for the MCP server deployment.

```bash
oc new-project mcp-server
```

### Step 3: Create RBAC for MCP Users

Create a ClusterRole with read-only permissions. Save **one** of the following manifests as `mcp-readonly-clusterrole.yaml` (do not apply both options—they use the same name).

#### Option A: Full Read-Only RBAC (Recommended)

```yaml
# mcp-readonly-clusterrole.yaml

apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: mcp-readonly
rules:
#
# Core Kubernetes/OpenShift resources
#
- apiGroups: [""]
  resources:
    - pods
    - services
    - configmaps
    - namespaces
    - events
    - nodes
    - persistentvolumeclaims
    - persistentvolumes
    - replicationcontrollers
    - serviceaccounts
  verbs: ["get", "list", "watch"]

#
# Pod logs access
#
- apiGroups: [""]
  resources:
    - pods/log
  verbs: ["get", "list", "watch"]

#
# Exec/attach optional read-only troubleshooting access
# Remove if not required
#
- apiGroups: [""]
  resources:
    - pods/status
  verbs: ["get", "list", "watch"]

#
# Workloads
#
- apiGroups: ["apps"]
  resources:
    - deployments
    - daemonsets
    - statefulsets
    - replicasets
  verbs: ["get", "list", "watch"]

#
# Batch resources
#
- apiGroups: ["batch"]
  resources:
    - jobs
    - cronjobs
  verbs: ["get", "list", "watch"]

#
# OpenShift routes
#
- apiGroups: ["route.openshift.io"]
  resources:
    - routes
  verbs: ["get", "list", "watch"]

#
# OpenShift projects
#
- apiGroups: ["project.openshift.io"]
  resources:
    - projects
  verbs: ["get", "list", "watch"]

#
# OpenShift image streams
#
- apiGroups: ["image.openshift.io"]
  resources:
    - imagestreams
    - imagestreamtags
  verbs: ["get", "list", "watch"]

#
# OpenShift monitoring metrics
#
- apiGroups: ["metrics.k8s.io"]
  resources:
    - pods
    - nodes
  verbs: ["get", "list", "watch"]

#
# OpenShift monitoring stack
#
- apiGroups: ["monitoring.coreos.com"]
  resources:
    - servicemonitors
    - podmonitors
    - prometheusrules
    - prometheuses
    - alertmanagers
  verbs: ["get", "list", "watch"]

#
# OpenShift cluster operators/status
#
- apiGroups: ["config.openshift.io"]
  resources:
    - clusterversions
    - clusteroperators
    - infrastructures
    - networks
    - ingresses
  verbs: ["get", "list", "watch"]
```

#### Option B: Minimum RBAC

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: mcp-readonly
rules:
- apiGroups: [""]
  resources:
    - pods
    - services
    - configmaps
    - namespaces
    - events
    - nodes
  verbs: ["get", "list", "watch"]

- apiGroups: ["apps"]
  resources:
    - deployments
    - daemonsets
    - statefulsets
  verbs: ["get", "list", "watch"]

- apiGroups: ["route.openshift.io"]
  resources:
    - routes
  verbs: ["get", "list", "watch"]
```

### Step 4: Apply ClusterRole

```bash
oc apply -f mcp-readonly-clusterrole.yaml
```

### Step 5: Grant Cluster Access to MCP Users

Bind the ClusterRole to the Entra ID group (or OpenShift group) whose members may use the MCP server. Replace `<mcp-users-group>` with your group name or group ID.

```bash
oc adm policy add-cluster-role-to-group mcp-readonly <mcp-users-group>
```

Verify bindings:

```bash
oc describe clusterrolebinding | grep -A2 mcp-readonly
```

### Step 6: Register an OAuth / OIDC Client

Register an application with the identity provider your ARO cluster uses.

#### Option A: Microsoft Entra ID (typical for ARO)

1. In **Azure Portal** → **Microsoft Entra ID** → **App registrations**, create a new application.
2. Add a **Web** redirect URI for the MCP OAuth callback (update the hostname after Step 15):
  ```text
   https://kubernetes-mcp-server-mcp-server.apps.<cluster-id>.<region>.aroapp.io/oauth/callback
  ```
3. Create a **client secret** and note the **Application (client) ID** and **Directory (tenant) ID**.
4. Grant delegated permissions (`openid`, `profile`, `email`) and admin consent as needed.

See the upstream [Entra ID setup guide](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/ENTRA_ID_SETUP.md) for token exchange details if your cluster requires on-behalf-of flow.

#### Option B: OpenShift OAuth `OAuthClient` (cluster-local OAuth)

```yaml
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: kubernetes-mcp-server-aro
grantMethod: auto
redirectURIs:
  - https://kubernetes-mcp-server-mcp-server.apps.<cluster-id>.<region>.aroapp.io/oauth/callback
secret: "<generate-a-random-secret>"
```

```bash
oc apply -f mcp-oauthclient.yaml
```

### Step 7: Store OAuth Client Secret

Store the client secret in the `mcp-server` namespace (do not commit secrets to Git).

```bash
oc create secret generic mcp-oauth-credentials \
  -n mcp-server \
  --from-literal=sts_client_secret='<your-client-secret>'
```

{{% notice note %}}
The Helm chart renders OAuth settings into a ConfigMap. For production, restrict who can read ConfigMaps in `mcp-server`, use Sealed Secrets or External Secrets, or manage `config.toml` via a private values file in your pipeline—not in source control.
{{% /notice %}}

### Step 8: Clone the OpenShift MCP Server Repository

```bash
git clone https://github.com/openshift/openshift-mcp-server.git
cd openshift-mcp-server/charts/kubernetes-mcp-server
```

### Step 9: Review Default Helm Values

```bash
cat values.yaml
cat values-openshift.yaml
```

The chart uses a `config` block (rendered to `config.toml`), not a legacy `mcp.args` section.

### Step 10: Create ARO Values Overlay

Create `values-aro-mcp.yaml` with OpenShift settings, OAuth, and a TLS route. Replace placeholders for your tenant, client ID, and cluster domain.

```yaml
# values-aro-mcp.yaml — overlay on values.yaml + values-openshift.yaml

openshift: true

replicaCount: 1

# Use the ClusterRole you created manually; do not let the chart create duplicate RBAC.
rbac:
  create: false

serviceAccount:
  create: true
  # OAuth passthrough: the pod must not use the service account token for API calls.
  automountToken: false

service:
  type: ClusterIP
  port: 8080

ingress:
  enabled: true
  termination: edge
  # Set after install if left empty; or set your expected hostname here.
  host: ""

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

# MCP server settings (config.toml)
config:
  read_only: true
  disable_destructive: true
  toolsets:
    - config
    - core
    - helm
  require_oauth: true
  cluster_auth_mode: passthrough
  trust_proxy_headers: true
  # Entra ID (uncomment and set for typical ARO clusters)
  authorization_url: "https://login.microsoftonline.com/<TENANT_ID>/v2.0"
  oauth_audience: "<APPLICATION_CLIENT_ID>"
  oauth_scopes:
    - openid
    - profile
    - email
  server_url: "https://kubernetes-mcp-server-mcp-server.apps.<cluster-id>.<region>.aroapp.io"
  sts_client_id: "<APPLICATION_CLIENT_ID>"
  sts_client_secret: "<APPLICATION_CLIENT_SECRET>"
  # If the cluster requires Entra on-behalf-of token exchange, also set:
  # token_exchange_strategy: "entra-obo"
  # sts_audience: "<downstream-api-audience>"
```

### Step 11: Install the Helm Chart

Retrieve the client secret from the Kubernetes secret at install time (recommended):

```bash
helm install kubernetes-mcp-server . \
  -n mcp-server \
  -f values.yaml \
  -f values-openshift.yaml \
  -f values-aro-mcp.yaml \
  --set config.sts_client_secret="$MCP_OAUTH_SECRET"
```

### Step 12: Verify Deployment

```bash
helm list -n mcp-server
oc get pods -n mcp-server
oc logs deployment/kubernetes-mcp-server -n mcp-server
oc get route -n mcp-server
```

Confirm the route uses **edge** TLS termination and note the hostname. Update the Entra ID or `OAuthClient` redirect URI if the hostname differs from your placeholder.

### Step 13: Verify Unauthenticated Access Is Denied

A request without a bearer token must **not** succeed when `require_oauth` is enabled.

```bash
ROUTE_HOST=$(oc get route kubernetes-mcp-server -n mcp-server -o jsonpath='{.spec.host}')

curl -si -X POST "https://${ROUTE_HOST}/mcp" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"initialize",
    "params":{
      "protocolVersion":"2025-03-26",
      "capabilities":{},
      "clientInfo":{"name":"test-client","version":"1.0"}
    }
  }' | head -20
```

Expect **HTTP 401 Unauthorized** (or another non-2xx auth error), not a successful `initialize` result.

### Step 14: Test With a Bearer Token

Obtain an access token for a user in the `mcp-readonly` group. For Entra ID / `oc` users, use the OpenShift access token after login:

```bash
export MCP_TOKEN=$(oc whoami --show-token)

curl -si -X POST "https://${ROUTE_HOST}/mcp" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${MCP_TOKEN}" \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"initialize",
    "params":{
      "protocolVersion":"2025-03-26",
      "capabilities":{},
      "clientInfo":{"name":"test-client","version":"1.0"}
    }
  }' | head -30
```

A successful response returns **HTTP 200** with a JSON-RPC `result` containing server capabilities.

MCP clients (Cursor, VS Code, MCP Inspector) should use the route URL and complete the OAuth flow; see the upstream [Keycloak OIDC setup](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/KEYCLOAK_OIDC_SETUP.md) for inspector-based testing patterns.

### Step 15: Configure MCP Clients

Point clients at:

```text
https://<route-host>/mcp
```

Enable OAuth in the client using the same **client ID** and scopes configured in Step 6. Each authenticated user receives only the Kubernetes permissions granted by `mcp-readonly` for their identity.

## Summary


| Step | Description                                              |
| ---- | -------------------------------------------------------- |
| 1    | Login to ARO cluster                                     |
| 2    | Create `mcp-server` project                              |
| 3    | Create `mcp-readonly` ClusterRole (choose Option A or B) |
| 4    | Apply ClusterRole                                        |
| 5    | Bind role to MCP users group                             |
| 6    | Register OAuth/OIDC client (Entra ID or OpenShift)       |
| 7    | Store client secret in cluster                           |
| 8    | Clone `openshift-mcp-server` repository                  |
| 9    | Review chart `values.yaml`                               |
| 10   | Create `values-aro-mcp.yaml` with OAuth                  |
| 11   | Helm install with overlays                               |
| 12   | Verify pods, logs, and route                             |
| 13   | Confirm unauthenticated requests are rejected            |
| 14   | Test with bearer token over HTTPS                        |
| 15   | Configure MCP clients with OAuth                         |


## Internal access only (optional)

For development, you may skip a public route:

- Set `ingress.enabled: false` in your values overlay.
- Do **not** run `oc expose` on the service.
- Use `oc port-forward svc/kubernetes-mcp-server 8080:8080 -n mcp-server` from a workstation that already has a valid `oc` login.

This limits exposure to your local machine but is **not** a substitute for OAuth on shared or production clusters.

## References

- [Model Context Protocol server for Red Hat OpenShift (technology preview)](https://www.redhat.com/en/blog/model-context-protocol-server-red-hat-openshift-now-available-technology-preview)
- [OpenShift MCP Server (GitHub)](https://github.com/openshift/openshift-mcp-server)
- [Kubernetes MCP Server — configuration (OAuth)](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/configuration.md)
- [Kubernetes MCP Server — Entra ID setup](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/ENTRA_ID_SETUP.md)
- [Configure Azure AD as an ARO identity provider](https://cloud.redhat.com/experts/aro/idp/azuread-aro/)

