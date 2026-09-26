---
date: '2026-07-21'
title: AI-Assisted ROSA HCP Management with Claude
tags: ["ROSA", "ROSA HCP", "OCM"]
authors:
  - Kumudu Herath
  - Shanna Chan
  - Kevin Collins
---

{{% alert state="info" %}}This guide has been validated on **ROSA HCP with OpenShift 4.22** using the ROSA MCP Server v0.1.0, the OpenShift MCP Server, and Claude Code. Commands and outputs may differ on other versions.{{% /alert %}}

AI assistants like Claude can help manage ROSA HCP clusters at every level — from provisioning clusters through OCM to troubleshooting workloads inside the cluster. This guide covers three complementary approaches and helps you choose the right one for your use case.

## Choosing Your Approach

There is no single "right" tool — each approach adds value in different scenarios:

| Approach | Best for | Setup | Scope |
|---|---|---|---|
| Claude Code + `rosa`/`oc` CLI | Single user with CLI access, full command surface, zero setup | None — CLIs on PATH | OCM lifecycle + in-cluster |
| ROSA MCP Server | Non-CLI environments (portals, chat), structured output, guided cluster creation | Deploy to cluster | OCM lifecycle (6 tools, growing) |
| OpenShift MCP Server | In-cluster Day 2 operations — pods, metrics, logs, Helm, events | Helm chart to cluster | Kubernetes API |
| OpenShift Lightspeed | Developers in the OpenShift console needing contextual AI help | Operator + Bedrock or Vertex AI | In-console assistant |

{{% alert state="info" %}}**Starting from zero?** If you have `rosa` and `oc` on your PATH, Claude Code can already run them directly via its shell — no MCP server needed. The MCP servers add value when you need structured output, non-CLI access, or RBAC-enforced governance.{{% /alert %}}

The rest of this guide walks through each approach in detail.

---

# Part 1: ROSA MCP Server — OCM Cluster Lifecycle

The [ROSA MCP Server](https://github.com/redhat-community-ai-tools/rosa-mcp-server) is a Model Context Protocol (MCP) server that enables AI assistants to manage ROSA HCP clusters through the OpenShift Cluster Manager (OCM) API. It currently exposes six tools — cluster listing, cluster details, cluster creation, identity provider setup, authentication status, and a prerequisites guide — through the open MCP standard.

### When to use the ROSA MCP Server over the CLI

* **Non-CLI environments** — Web portals, chat interfaces, or AI tools without shell access (e.g., Claude on claude.ai)
* **Structured JSON output** — Cleaner than parsing CLI text tables, less room for the AI to misread output
* **The prerequisites guide** — The most unique tool: it injects verified domain knowledge (IAM roles, OIDC configs, operator role setup) so the AI doesn't have to guess. This knowledge isn't available from `rosa --help`
* **Future: policy guardrails** — An MCP server can enforce organizational policies ("always encrypt", "require cost-center tag") that raw CLI access cannot

## Prerequisites

* A ROSA HCP cluster in `ready` state
* `rosa` CLI installed and logged in (`rosa login`)
* `ocm` CLI installed and logged in (`ocm login`)
* `oc` CLI logged in to your cluster
* `helm` CLI installed
* **One of the following** for OCM authentication:
  * An OCM service account with client credentials (client ID + client secret) from [console.redhat.com/iam/service-accounts](https://console.redhat.com/iam/service-accounts) — **recommended**
  * An OCM offline token from [console.redhat.com/openshift/token](https://console.redhat.com/openshift/token)
* [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed

## Architecture Overview

The ROSA MCP Server acts as a bridge between AI assistants and the OpenShift Cluster Manager (OCM) API:

```
AI Assistant (Claude Code)  ──MCP Protocol──▶  ROSA MCP Server  ──OCM SDK──▶  OCM API
```

### Available Tools

| Tool | Description |
|---|---|
| `whoami` | Get the authenticated OCM account information |
| `get_clusters` | List clusters filtered by state (ready, installing, error) |
| `get_cluster` | Get detailed information about a specific cluster by ID |
| `create_rosa_hcp_cluster` | Provision a new ROSA HCP cluster with AWS configuration |
| `get_rosa_hcp_prerequisites_guide` | Get the complete prerequisites workflow for cluster creation |
| `setup_htpasswd_identity_provider` | Configure HTPasswd identity provider with username/password authentication |

### Transport Modes

The server supports two transport modes with different authentication models:

* **stdio** — For local, single-user usage. The server reads JSON-RPC messages from stdin and writes responses to stdout. Authentication uses environment variables (`OCM_CLIENT_ID` + `OCM_CLIENT_SECRET` for service accounts, or `OCM_OFFLINE_TOKEN` for user tokens), meaning a single identity is baked into the process for its lifetime.
* **SSE (Server-Sent Events)** — For remote, multi-user usage. The server exposes HTTP endpoints (`/sse` for the event stream, `/message` for requests). Authentication is per-request via HTTP headers, making it multi-tenant — each user authenticates independently, which is the right choice for shared platform portals.

### Authentication Methods

The server supports three authentication methods, checked in priority order:

| Method | SSE Header(s) | Stdio Env Var(s) | Best for |
|---|---|---|---|
| **Client credentials** (highest priority) | `X-OCM-CLIENT-ID` + `X-OCM-CLIENT-SECRET` | `OCM_CLIENT_ID` + `OCM_CLIENT_SECRET` | Service accounts — no token expiration, SDK handles refresh |
| **Access token** | `Authorization: Bearer <token>` | — | Short-lived tokens from OAuth flows |
| **Offline token** | `X-OCM-OFFLINE-TOKEN` | `OCM_OFFLINE_TOKEN` | User tokens from [console.redhat.com](https://console.redhat.com/openshift/token) |

{{% alert state="info" %}}**Recommended for deployed servers:** Use OCM service account client credentials. Create a service account at [console.redhat.com/iam/service-accounts](https://console.redhat.com/iam/service-accounts) and pass the client ID and secret via headers. Unlike offline tokens, client credentials never expire — the OCM SDK handles the OAuth2 `client_credentials` grant and token refresh automatically.{{% /alert %}}

## Set Environment Variables

Set the variables used throughout this guide:

```bash
export CLUSTER_NAME=<your-cluster-name>
export CLUSTER_DOMAIN=$(rosa describe cluster -c ${CLUSTER_NAME} -o json | jq -r '.dns.base_domain')
echo "Cluster: ${CLUSTER_NAME}"
echo "Domain:  ${CLUSTER_DOMAIN}"
```

### Local vs. Cluster Deployment

| Aspect | Local (stdio) | Deployed on OpenShift (SSE) |
|---|---|---|
| Users | Single user | Multi-tenant (per-request auth) |
| Auth | Client credentials or token via env vars | Client credentials or token per-request via HTTP headers |
| Setup | Build binary, run locally | Deploy to cluster, expose Route |
| Best for | Development / testing | Shared team or platform usage |

This guide focuses on deploying to OpenShift for shared team access. For local development and testing, see the [ROSA MCP Server README](https://github.com/redhat-community-ai-tools/rosa-mcp-server#readme).

## Deploy to OpenShift

The project includes an OpenShift template for production deployment. This creates a Deployment, Service, and Route with TLS termination:

1. Log in to your cluster

    ```bash
    oc login --server=https://api.${CLUSTER_NAME}.${CLUSTER_DOMAIN}:443
    ```

1. Create a project for the MCP server

    ```bash
    oc new-project rosa-mcp-server
    ```

1. Deploy using the template

    ```bash
    oc process -f openshift/template.yaml \
      -p MCP_HOST=rosa-mcp-server.apps.rosa.${CLUSTER_NAME}.${CLUSTER_DOMAIN} \
      | oc apply -f -
    ```

    You can customize template parameters:

    | Parameter | Default | Description |
    |---|---|---|
    | `IMAGE` | `quay.io/redhat-ai-tools/rosa-mcp-server` | Container image |
    | `IMAGE_TAG` | `latest` | Image tag |
    | `PORT` | `8080` | SSE transport port |
    | `MCP_HOST` | `rosa-mcp-server.example.com` | Route hostname |
    | `CERT_MANAGER_ISSUER_NAME` | `letsencrypt-dns` | TLS certificate issuer (requires cert-manager) |

    {{% alert state="info" %}}The `CERT_MANAGER_ISSUER_NAME` parameter requires [cert-manager](https://cert-manager.io/) to be installed on the cluster. If cert-manager is not available, remove the `cert-manager.io` annotations from the Route in the template and configure TLS separately using your cluster's certificate setup.{{% /alert %}}

1. Verify the deployment

    ```bash
    oc get pods -n rosa-mcp-server
    oc get route rosa-mcp-server -n rosa-mcp-server
    ```

1. Test the deployed endpoint

    ```bash
    ROUTE_URL=$(oc get route rosa-mcp-server -n rosa-mcp-server -o jsonpath='{.spec.host}')
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 https://${ROUTE_URL}/sse
    ```

    A `200` response confirms the SSE endpoint is reachable. Note that `curl` may return a non-zero exit code (18 or 28) because SSE connections stream indefinitely — this is expected behavior.

## Configure Claude Code MCP Integration

Claude Code can connect to the deployed ROSA MCP Server, enabling you to manage ROSA clusters through natural language.

1. Get the Route URL for the deployed server

    ```bash
    ROUTE_URL=$(oc get route rosa-mcp-server -n rosa-mcp-server -o jsonpath='{.spec.host}')
    echo "https://${ROUTE_URL}/sse"
    ```

1. Get your OCM credentials — either service account client credentials (recommended) or an offline token:

    * **Service account:** Create one at [console.redhat.com/iam/service-accounts](https://console.redhat.com/iam/service-accounts). Note the client ID and client secret.
    * **Offline token:** Get one from [console.redhat.com/openshift/token](https://console.redhat.com/openshift/token).

1. Create or update `.claude/settings.local.json` in your project directory

    **Option A — Client credentials (recommended):**

    ```json
    {
      "mcpServers": {
        "rosa-hcp": {
          "url": "https://rosa-mcp-server.apps.rosa.${CLUSTER_NAME}.${CLUSTER_DOMAIN}/sse",
          "headers": {
            "X-OCM-CLIENT-ID": "<your-client-id>",
            "X-OCM-CLIENT-SECRET": "<your-client-secret>"
          }
        }
      }
    }
    ```

    **Option B — Offline token:**

    ```json
    {
      "mcpServers": {
        "rosa-hcp": {
          "url": "https://rosa-mcp-server.apps.rosa.${CLUSTER_NAME}.${CLUSTER_DOMAIN}/sse",
          "headers": {
            "X-OCM-OFFLINE-TOKEN": "<your-ocm-offline-token>"
          }
        }
      }
    }
    ```

    Replace `${CLUSTER_NAME}` and `${CLUSTER_DOMAIN}` with the values from the environment variables set earlier.

    {{% alert state="warning" %}}The `settings.local.json` file contains your OCM credentials. This file is gitignored by default and should never be committed to version control.{{% /alert %}}

1. Restart Claude Code to load the MCP server

1. Verify the connection by listing the registered MCP tools

    ```bash
    claude mcp list
    ```

    You should see the `rosa-hcp` server listed with six tools: `whoami`, `get_clusters`, `get_cluster`, `create_rosa_hcp_cluster`, `get_rosa_hcp_prerequisites_guide`, and `setup_htpasswd_identity_provider`.

    You can also type `/mcp` inside a Claude Code session to see connected MCP servers and their status.

## Verify End-to-End

With the MCP server configured in Claude Code, test the integration with these example prompts:

| Prompt | Expected Tool |
|---|---|
| "Who am I on OCM?" | `whoami` |
| "List all my ready ROSA clusters" | `get_clusters` |
| "Show me details of my cluster" | `get_cluster` |
| "What do I need before creating a ROSA HCP cluster?" | `get_rosa_hcp_prerequisites_guide` |
| "Set up an htpasswd identity provider on my cluster" | `setup_htpasswd_identity_provider` |

The AI assistant will call the appropriate MCP tool and return formatted results directly in the conversation.

## Troubleshooting

### MCP Server Not Connecting

If Claude Code cannot connect to the deployed ROSA MCP Server:

1. Verify the pod is running:

    ```bash
    oc get pods -n rosa-mcp-server
    ```

1. Check the pod logs for errors:

    ```bash
    oc logs -n rosa-mcp-server deployment/rosa-mcp-server
    ```

1. Verify the Route is accessible:

    ```bash
    ROUTE_URL=$(oc get route rosa-mcp-server -n rosa-mcp-server -o jsonpath='{.spec.host}')
    curl -s -o /dev/null -w "%{http_code}" https://${ROUTE_URL}/sse
    ```

    A `200` response confirms the SSE endpoint is reachable.

### SSE: "Missing sessionId" Error

```json
{"error": {"code": -32602, "message": "Missing sessionId"}}
```

**Cause:** Sending a POST to `/message` without establishing an SSE session first. The SSE transport requires a two-step protocol:

1. **GET `/sse`** — receives a session ID via SSE event
2. **POST `/message?sessionId=<id>`** — sends requests using that session ID

This is handled automatically by MCP client libraries (Claude Code). Do not test the SSE endpoint manually with `curl` POST requests.

### HTPasswd: Password Validation Errors

```
Password must be at least 14 characters (got 12)
```

**Solution:** HTPasswd passwords must be at least 14 characters. The server uses ROSA CLI validation rules. Usernames cannot contain `/`, `:`, or `%` characters, and `cluster-admin` is a reserved username.

### Token Expiration

If you see authentication failures, the OCM token in your `settings.local.json` may have expired.

**Solution:** Switch to OCM service account client credentials (`X-OCM-CLIENT-ID` + `X-OCM-CLIENT-SECRET`), which never expire — the SDK handles the OAuth2 token lifecycle automatically. Alternatively, OCM offline tokens (from [console.redhat.com/openshift/token](https://console.redhat.com/openshift/token)) are long-lived and do not expire under normal use. If you are using a short-lived access token, replace it with either option for persistent setups.

---

# Part 2: OpenShift MCP Server — In-Cluster Day 2 Operations

The [OpenShift MCP Server](https://github.com/openshift/openshift-mcp-server) is a Kubernetes-native MCP server that gives AI assistants direct, RBAC-enforced access to your cluster's Kubernetes API. While the ROSA MCP Server handles OCM-level cluster lifecycle, this server handles what happens *inside* the cluster — the Day 2 operations where most troubleshooting time is spent.

### Why This Matters

Most operational questions are about workloads, not fleet management: "Why is my pod crashing?", "What's consuming memory in this namespace?", "Show me the last deploy's events." The OpenShift MCP Server exposes these capabilities through MCP tools without requiring users to learn `oc` or `kubectl` syntax.

### Key Toolsets

| Toolset | Capabilities |
|---|---|
| `core` | Pods, deployments, services, events, namespaces, resource YAML |
| `observability/metrics` | Prometheus queries, CPU/memory utilization, custom metrics |
| `helm` | Helm releases, chart status, values, rollback |

### How It Complements ROSA MCP

| Concern | ROSA MCP Server | OpenShift MCP Server |
|---|---|---|
| API target | OCM (fleet management) | Kubernetes API (in-cluster) |
| Scope | Cluster lifecycle, identity providers | Pods, logs, metrics, Helm, events |
| Auth | OCM service account or token | ServiceAccount / RBAC |
| Use case | "Create a cluster", "List my clusters" | "Why is my pod failing?", "Show CPU usage" |

## Deploy to OpenShift via Helm

The OpenShift MCP Server provides an OCI Helm chart for deployment. The chart creates a Deployment, ServiceAccount, RBAC bindings, Service, and Ingress/Route.

1. Create a namespace

    ```bash
    oc new-project mcp-server-k8s
    ```

    {{% alert state="warning" %}}OpenShift restricts project names starting with `kubernetes-` or `openshift-`. Use a different name such as `mcp-server-k8s`.{{% /alert %}}

1. Deploy with Helm

    ```bash
    helm upgrade -i kubernetes-mcp-server \
      oci://ghcr.io/containers/charts/kubernetes-mcp-server \
      -n mcp-server-k8s \
      --set ingress.host=kubernetes-mcp-server.apps.rosa.${CLUSTER_NAME}.${CLUSTER_DOMAIN} \
      --set openshift=true \
      --set rbac.extraClusterRoleBindings[0].name=use-view-role \
      --set rbac.extraClusterRoleBindings[0].roleRef.name=view \
      --set rbac.extraClusterRoleBindings[0].roleRef.external=true
    ```

    The `${CLUSTER_DOMAIN}` variable was set in the environment variables step above.

    {{% alert state="info" %}}This deployment uses the built-in `view` ClusterRole, which grants **read-only** access to most cluster resources. For write access (e.g., scaling deployments, managing Helm releases), bind to the `edit` or `admin` ClusterRole instead. You can also add `--set readOnly=true` for defense-in-depth at the application level.{{% /alert %}}

1. Verify the deployment

    ```bash
    oc get pods -n mcp-server-k8s
    oc get route -n mcp-server-k8s
    ```

    {{% alert state="info" %}}The Helm chart generates the Route name with a random suffix (e.g., `kubernetes-mcp-server-jh7zt`). Use the namespace-scoped commands below to discover the actual Route URL.{{% /alert %}}

1. Test the endpoint

    ```bash
    ROUTE_URL=$(oc get route -n mcp-server-k8s -o jsonpath='{.items[0].spec.host}')
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 https://${ROUTE_URL}/sse
    ```

    A `200` response confirms the SSE endpoint is available. Note that `curl` may return a non-zero exit code (18 or 28) because SSE connections stream indefinitely — this is expected behavior, not an error.

## Configure Claude Code

1. Get the Route URL

    ```bash
    ROUTE_URL=$(oc get route -n mcp-server-k8s -o jsonpath='{.items[0].spec.host}')
    echo "https://${ROUTE_URL}/sse"
    ```

1. Add the server to `.claude/settings.local.json`

    ```json
    {
      "mcpServers": {
        "openshift": {
          "url": "https://kubernetes-mcp-server.apps.rosa.${CLUSTER_NAME}.${CLUSTER_DOMAIN}/sse"
        }
      }
    }
    ```

    Replace the URL with the actual Route URL from step 1.

    {{% alert state="info" %}}The OpenShift MCP Server deployed in-cluster uses its ServiceAccount for authentication — no user token is needed in the Claude Code configuration. Access is governed by the RBAC bindings configured during Helm deployment.{{% /alert %}}

1. Restart Claude Code and verify

    ```bash
    claude mcp list
    ```

    You should see the `openshift` server listed with tools for pods, deployments, logs, events, metrics, and Helm operations.

{{% alert state="info" %}}**Local alternative:** For local development without deploying to the cluster, you can also run `npx kubernetes-mcp-server@latest` with your kubeconfig. See the [OpenShift MCP Server repository](https://github.com/openshift/openshift-mcp-server) for details.{{% /alert %}}

## Example Prompts

With the OpenShift MCP Server connected, test the integration with these prompts:

| Prompt | What it does |
|---|---|
| "Show me failing pods in the `myapp` namespace" | Lists pods in CrashLoopBackOff or Error state with recent events |
| "Get the logs for the last crashed container in pod X" | Retrieves previous container logs |
| "What's the CPU and memory usage for my application?" | Queries Prometheus metrics via the observability toolset |
| "List recent events in the default namespace" | Shows Kubernetes events sorted by time |
| "Show me the Helm releases in this cluster" | Lists installed Helm charts with status |

Use both MCP servers together for full-stack AI-assisted management: ROSA MCP for provisioning and fleet operations, OpenShift MCP Server for Day 2 troubleshooting and workload visibility.

For full documentation and advanced configuration, see the [OpenShift MCP Server repository](https://github.com/openshift/openshift-mcp-server).

---

# Part 3: OpenShift Lightspeed — AI in the Console

[OpenShift Lightspeed](https://docs.openshift.com/container-platform/latest/lightspeed/lightspeed-understanding.html) is an AI assistant embedded directly in the OpenShift web console. It provides contextual help to developers and administrators without leaving the console UI.

### When to Use Lightspeed

Lightspeed is ideal for developers who work primarily in the OpenShift web console and want in-context AI assistance — explaining error messages, suggesting fixes, or answering "how do I" questions about the resource they're currently viewing.

### Connecting Lightspeed to Claude

Lightspeed supports Claude as its backing model through two providers:

* **AWS Bedrock** — Uses an IRSA-based proxy for authentication between the OpenShift cluster and the Bedrock API. See [Configuring OpenShift Lightspeed with Claude via AWS Bedrock](/rosa/lightspeed-bedrock/) for the complete setup guide.
* **Google Vertex AI** — Officially supported integration. See the [Red Hat documentation for configuring Vertex AI](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html/configure/ols-configuring-integrating-google-vertex-ai).

### Comparison

Think of it this way: **Lightspeed puts Claude inside the console; MCP servers put the cluster inside Claude.** Lightspeed is best for console-first workflows. MCP servers are best for CLI-first or automation workflows where Claude orchestrates operations across multiple tools.

---

## Cleanup

1. Remove the ROSA MCP Server deployment

    ```bash
    oc process -f openshift/template.yaml | oc delete -f -
    oc delete project rosa-mcp-server
    ```

1. Remove the OpenShift MCP Server deployment (if deployed)

    ```bash
    helm uninstall kubernetes-mcp-server -n mcp-server-k8s
    oc delete project mcp-server-k8s
    ```

1. Remove any test identity providers

    ```bash
    rosa list idps -c ${CLUSTER_NAME}
    rosa delete idp test-htpasswd -c ${CLUSTER_NAME} -y
    ```

1. Remove Claude Code MCP configuration

    Remove the `rosa-hcp` and `openshift` entries from `.claude/settings.local.json`.

## Additional Resources

- [ROSA MCP Server GitHub Repository](https://github.com/redhat-community-ai-tools/rosa-mcp-server)
- [OpenShift MCP Server GitHub Repository](https://github.com/openshift/openshift-mcp-server)
- [Configuring OpenShift Lightspeed with Claude via AWS Bedrock](/rosa/lightspeed-bedrock/)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code)
- [OCM API Documentation](https://api.openshift.com/)
- [ROSA Documentation](https://docs.openshift.com/rosa/)
- [Red Hat AI on OpenShift — What's New in 4.22](https://www.redhat.com/en/blog/whats-new-openshift-ai-openshift-422)
- [MCP Gateway with Kuadrant Connectivity Link](https://developers.redhat.com/articles/2025/07/15/introducing-mcp-gateway-kuadrant-connectivity-link)
