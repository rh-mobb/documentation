---
date: '2026-05-26'
title: 'OpenShift MCP Server Deployment on ARO'
tags: ["ARO", "ROSA", "OSD"]
authors:
  - Dharmeshkumar Bhamre
---

{{% notice info %}}
The [OpenShift MCP Server](https://www.redhat.com/en/blog/model-context-protocol-server-red-hat-openshift-now-available-technology-preview) is **Technology Preview**. Features, APIs, and configuration may change before general availability. Use in non-production environments first.
{{% /notice %}}

This guide walks through deploying the [OpenShift Kubernetes MCP Server](https://github.com/openshift/openshift-mcp-server) on **Azure Red Hat OpenShift (ARO)**. The same steps apply to **ROSA**, **OSD**, and self-managed OpenShift; only API URLs and route hostnames differ (this guide uses ARO `*.aroapp.io` examples).

You install the server with Helm, bind a read-only ClusterRole to authorized users or groups, require a bearer token on the MCP HTTP endpoint, and test locally with **`oc port-forward`** before optionally exposing an edge-terminated HTTPS route.

The MCP server runs in **read-only** mode with destructive operations disabled. With authentication enabled, callers must send a bearer token; the server uses **token passthrough** so each user's identity is used for Kubernetes API calls.

{{% notice warning %}}
**OAuth-related settings are preview.** Validate in a non-production cluster before production rollout. See the upstream [OAuth configuration](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/configuration.md).
{{% /notice %}}

## Prerequisites

- OpenShift CLI (`oc`) installed and configured
- Helm 3.x installed
- Git installed
- Cluster admin credentials for the ARO cluster
- Network access to the cluster API endpoint

## Security and authentication

Two separate security layers apply:

| Layer | Purpose | How this guide configures it |
| ----- | ------- | ------------------------------ |
| **MCP HTTP endpoint** | Controls who can call `/mcp` | `require_oauth: true`: requests without a bearer token receive **401 Unauthorized** |
| **Kubernetes API** | Controls what MCP tools can read | `mcp-readonly` ClusterRole bound to your **user or group**; `cluster_auth_mode: passthrough` forwards the caller's token |

**Do not expose a public route without authentication.** For initial testing, this guide uses **`oc port-forward`** so the MCP endpoint is not reachable from the internet. To expose the server externally, enable the chart's edge-terminated ingress only after auth is working, or add an OAuth proxy sidecar (out of scope here).

The service account token must remain mounted (`automountToken: true`) so the server can discover the cluster API URL and CA certificate, even in passthrough mode. The SA token is used for discovery only; API calls use the forwarded user bearer token.

## Deployment procedure

### Step 1: Login to ARO Cluster

Authenticate to the ARO cluster. Replace placeholders with your credentials and API URL.

```bash
oc login -u <Admin user> -p <password> https://api.<cluster-id>.<region>:6443
```

### Step 2: Create New Project

```bash
oc new-project mcp-server
```

### Step 3: Create Service Account

The chart is configured to use a pre-created service account (`serviceAccount.create: false`). Create it in the project:

```bash
oc create serviceaccount kubernetes-mcp-server -n mcp-server
```

### Step 4: Create RBAC for MCP Users

Create a ClusterRole with read-only permissions. Save **one** manifest as `mcp-readonly-clusterrole.yaml` (Options A and B share the same name; apply only one).

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

### Step 5: Apply ClusterRole and Grant Access

```bash
oc apply -f mcp-readonly-clusterrole.yaml
```

Bind the role to the users or groups that will call the MCP server. For a solo test, bind your current `oc` user:

```bash
oc adm policy add-cluster-role-to-user mcp-readonly $(oc whoami)
```

For a team, bind an Entra ID or OpenShift group instead:

```bash
oc adm policy add-cluster-role-to-group mcp-readonly <mcp-users-group>
```

### Step 6: Clone the OpenShift MCP Server Repository

```bash
git clone https://github.com/openshift/openshift-mcp-server.git
cd openshift-mcp-server/charts/kubernetes-mcp-server
```

The chart already ships `values-openshift.yaml` (sets `openshift: true` and OpenShift image defaults). Your overlay file layers on top of that—do not replace it.

### Step 7: Determine the Ingress Hostname (if exposing a route later)

The chart **requires** `ingress.host` when `ingress.enabled` is `true`. Retrieve your cluster apps domain and set a hostname now so it is ready if you enable the route.

**ARO example:**

```bash
# Console URL: https://console-openshift-console.apps.<name>.<region>.aroapp.io
export APPS_DOMAIN=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')
export MCP_ROUTE_HOST="kubernetes-mcp-server-mcp-server.apps.${APPS_DOMAIN}"
echo "${MCP_ROUTE_HOST}"
```

On ROSA, you can also use `rosa describe cluster -c <cluster> -o json | jq -r '.dns.base_domain'` and build `kubernetes-mcp-server-mcp-server.apps.<base_domain>`.

### Step 8: Create the ARO Values Overlay

Create `values-aro.yaml`. This file intentionally does **not** set `securityContext` or `podSecurityContext`—the chart defaults already satisfy OpenShift's `restricted-v2` SCC (`readOnlyRootFilesystem`, dropped capabilities, `seccompProfile`, and so on). Overriding those fields with a partial block removes those protections.

Do **not** use `mcp.args`—that key is ignored by Helm. Use the `config` block (rendered to `config.toml`) for server settings.

```yaml
# values-aro.yaml — layer on the chart's values-openshift.yaml

rbac:
  create: false

serviceAccount:
  create: false
  name: kubernetes-mcp-server
  automountToken: true

service:
  type: ClusterIP
  port: 8080

# Keep disabled for safe local testing; enable after auth works (see below).
ingress:
  enabled: false
  termination: edge
  host: "kubernetes-mcp-server-mcp-server.apps.<cluster-id>.<region>.aroapp.io"

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 100m
    memory: 128Mi

config:
  read_only: true
  disable_destructive: true
  toolsets:
    - config
    - core
    - helm
  require_oauth: true
  skip_jwt_verification: true
  cluster_auth_mode: passthrough
  trust_proxy_headers: true
```

Replace `ingress.host` with the value from Step 7 before enabling ingress.

### Step 9: Install the Helm Chart

```bash
helm install kubernetes-mcp-server . \
  -n mcp-server \
  -f values-openshift.yaml \
  -f values-aro.yaml
```

### Step 10: Verify Deployment

```bash
helm list -n mcp-server
oc get pods -n mcp-server
oc logs deployment/kubernetes-mcp-server -n mcp-server
```

The pod should be **Running**. If it is in **CrashLoopBackOff** with `no current-context is set` in the logs, confirm `serviceAccount.automountToken` is `true`.

### Step 11: Test Locally With Port-Forward

Forward the service to your workstation (no external route required):

```bash
oc port-forward svc/kubernetes-mcp-server 8080:8080 -n mcp-server
```

In another terminal, confirm unauthenticated access is denied:

```bash
curl -si -X POST "http://localhost:8080/mcp" \
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

Expect **HTTP 401 Unauthorized**.

Test with your OpenShift bearer token (user must have the `mcp-readonly` role):

```bash
export MCP_TOKEN=$(oc whoami --show-token)

curl -si -X POST "http://localhost:8080/mcp" \
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

Expect **HTTP 200** with a JSON-RPC `result` containing server capabilities.

### Step 12: Expose an Edge-Terminated HTTPS Route (Optional)

Only after local testing succeeds, enable the chart ingress. The chart adds `route.openshift.io/termination: edge` when `openshift: true` (from `values-openshift.yaml`), creating an HTTPS route—do **not** use `oc expose svc`, which creates a plain HTTP route.

Set `ingress.enabled: true` and a non-empty `ingress.host` in `values-aro.yaml`, then upgrade:

```bash
helm upgrade kubernetes-mcp-server . \
  -n mcp-server \
  -f values-openshift.yaml \
  -f values-aro.yaml
```

Verify the route:

```bash
oc get route -n mcp-server
export ROUTE_HOST=$(oc get route kubernetes-mcp-server -n mcp-server -o jsonpath='{.spec.host}')

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

### Step 13: Configure MCP Clients

Point MCP clients at:

```text
http://localhost:8080/mcp
```

when using port-forward, or:

```text
https://<route-host>/mcp
```

when using the optional route. Clients must send a valid OpenShift bearer token (or complete a full OIDC flow if you add Entra ID settings—see below).

## Optional: Full Entra ID OIDC

For clusters that use Microsoft Entra ID (typical on ARO), you can replace `skip_jwt_verification: true` with full OIDC validation:

1. Register an app in Entra ID with redirect URI `https://<route-host>/oauth/callback`.
2. Set `authorization_url`, `oauth_audience`, `oauth_scopes`, `server_url`, `sts_client_id`, and `sts_client_secret` in the Helm `config` block.
3. See the upstream [Entra ID setup guide](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/ENTRA_ID_SETUP.md).

Store client secrets in a Kubernetes Secret and pass them at install time with `--set config.sts_client_secret="$MCP_OAUTH_SECRET"` rather than committing secrets to Git.

## Summary

| Step | Description |
| ---- | ----------- |
| 1 | Login to ARO cluster |
| 2 | Create `mcp-server` project |
| 3 | Create `kubernetes-mcp-server` service account |
| 4 | Create `mcp-readonly` ClusterRole (Option A or B) |
| 5 | Apply ClusterRole and bind to user or group |
| 6 | Clone `openshift-mcp-server` and enter chart directory |
| 7 | Determine apps domain / ingress hostname |
| 8 | Create `values-aro.yaml` overlay |
| 9 | Helm install with `values-openshift.yaml` + `values-aro.yaml` |
| 10 | Verify pods and logs |
| 11 | Test with `oc port-forward` (401 without token, 200 with token) |
| 12 | Optionally enable edge HTTPS ingress |
| 13 | Configure MCP clients |

## References

- [Model Context Protocol server for Red Hat OpenShift (technology preview)](https://www.redhat.com/en/blog/model-context-protocol-server-red-hat-openshift-now-available-technology-preview)
- [OpenShift MCP Server (GitHub)](https://github.com/openshift/openshift-mcp-server)
- [Kubernetes MCP Server — configuration (OAuth)](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/configuration.md)
- [Kubernetes MCP Server — Entra ID setup](https://github.com/containers/kubernetes-mcp-server/blob/main/docs/ENTRA_ID_SETUP.md)
- [Configure Azure AD as an ARO identity provider](/experts/aro/idp/azuread-aro/)
