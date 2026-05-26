---
date: '2026-05-26'
title: 'OpenShift MCP Server Deployment on ARO'
tags: ["ARO", "Miscellaneous"]
authors:
  - dbhamre
---

This guide walks through deploying the [OpenShift Kubernetes MCP Server](https://github.com/openshift/openshift-mcp-server) on an **Azure Red Hat OpenShift (ARO)** cluster. You install the server with Helm, bind a read-only ClusterRole to a dedicated service account, and expose the MCP endpoint on an OpenShift route for client testing.

The MCP server runs in **read-only** mode with destructive operations disabled, which is appropriate for assistant and automation clients that need cluster visibility without mutating production resources.

## Prerequisites

* OpenShift CLI (oc) installed and configured
* Helm 3.x installed
* Git installed
* Cluster admin credentials for the ARO cluster
* Network access to the cluster API endpoint

## Deployment procedure

### Step 1: Login to ARO Cluster

Authenticate to the ARO cluster using the OpenShift CLI. Replace the placeholders with your admin username, password, and cluster API URL.

```bash
oc login -u <Admin user> -p <password> https://api.xxx.xxx:6443
```

### Step 2: Create New Project

Create a dedicated namespace (project) for the MCP server deployment.

```bash
oc new-project mcp-server
```

### Step 3: Create Service Account

Create a service account that the MCP server will use for Kubernetes API access.

```bash
oc create serviceaccount kubernetes-mcp-server -n mcp-server
```

### Step 4: Verify Service Account

Confirm the service account was created successfully.

```bash
oc get sa -n mcp-server
```

### Step 5: Create RBAC for Agent

Create a ClusterRole with read-only permissions for the MCP server agent. Save the following YAML to a file named mcp-readonly-clusterrole.yaml.

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
# Required for live metrics access from console/CLI
#
- apiGroups: ["metrics.k8s.io"]
  resources:
    - pods
    - nodes
  verbs: ["get", "list", "watch"]

#
# OpenShift monitoring stack (Prometheus/Alertmanager rules)
# Optional but useful for observability dashboards
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

Use this reduced permission set if you need the smallest possible RBAC footprint.

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

### Step 6: Apply ClusterRole

Apply the ClusterRole manifest to the cluster.

```bash
oc apply -f mcp-readonly-clusterrole.yaml
```

### Step 7: Assign Role to Service Account

Bind the mcp-readonly ClusterRole to the kubernetes-mcp-server service account.

```bash
oc adm policy add-cluster-role-to-user \
  mcp-readonly \
  -z kubernetes-mcp-server \
  -n mcp-server
```

### Step 8: Clone the OpenShift MCP Server Repository

Clone the official OpenShift MCP server GitHub repository.

```bash
git clone https://github.com/openshift/openshift-mcp-server.git
```

### Step 9: Navigate to Helm Chart Directory

Change to the kubernetes-mcp-server Helm chart directory.

```bash
cd openshift-mcp-server/charts/kubernetes-mcp-server
```

### Step 10: Verify Helm Values

Review the default Helm chart values before customization.

```bash
cat values.yaml
```

### Step 11: Customize Helm Chart Values

Create a custom values file named values-openshift.yaml with the following content:

```yaml
# values-openshift.yaml

replicaCount: 1

image:
  pullPolicy: IfNotPresent

serviceAccount:
  create: false
  name: kubernetes-mcp-server

service:
  type: ClusterIP
  port: 8080

mcp:
  args:
    - --port=8080
    - --read-only
    - --disable-destructive
    - --toolsets=config,core,helm

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false

ingress:
  enabled: false
```

### Step 12: Install Helm Chart with Custom Values

Deploy the MCP server using the customized values file.

```bash
helm install kubernetes-mcp-server . \
  -n mcp-server \
  -f values-openshift.yaml
```

### Step 13: Verify Deployment

Confirm the Helm release, pods, and application logs are healthy.

```bash
helm list -n mcp-server

oc get pods -n mcp-server

oc logs deployment/kubernetes-mcp-server -n mcp-server
```

### Step 14: Expose as Service (Route)

Create an OpenShift route to expose the MCP server externally.

```bash
oc expose svc kubernetes-mcp-server -n mcp-server
```

### Step 15: Check Routes

Verify the route was created and note the hostname for testing.

```bash
oc get route -n mcp-server
```

### Step 16: Test the MCP Server

Send an initialize JSON-RPC request to the MCP endpoint. Replace the hostname with your cluster's route URL from Step 15.

```bash
curl -i -X POST \
  http://kubernetes-mcp-server-mcp-server.apps.<xxx>.<xxx>.aroapp.io/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"initialize",
    "params":{
      "protocolVersion":"2025-03-26",
      "capabilities":{},
      "clientInfo":{
        "name":"test-client",
        "version":"1.0"
      }
    }
  }'
```

A successful response returns HTTP 200 with a JSON-RPC result containing server capabilities and protocol version information.

## Summary

| Step | Description |
|------|-------------|
| 1 | Login to ARO cluster |
| 2 | Create mcp-server project |
| 3 | Create service account |
| 4 | Verify service account |
| 5 | Create RBAC ClusterRole |
| 6 | Apply ClusterRole |
| 7 | Assign role to service account |
| 8 | Clone openshift-mcp-server repo |
| 9 | Navigate to Helm chart |
| 10 | Review default values.yaml |
| 11 | Create values-openshift.yaml |
| 12 | Helm install MCP server |
| 13 | Verify pods and logs |
| 14 | Expose service via route |
| 15 | Verify route |
| 16 | Test MCP endpoint |

## References

* [Model Context Protocol server for Red Hat OpenShift now available in technology preview](https://www.redhat.com/en/blog/model-context-protocol-server-red-hat-openshift-now-available-technology-preview)
* [OpenShift MCP Server (GitHub)](https://github.com/openshift/openshift-mcp-server)
