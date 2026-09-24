---
date: '2026-09-23'
title: Retrofitting BYO Firewall Rules on OSD-GCP
tags: ["OSD"]
authors:
  - Kevin Collins
  - Kumudu Herath
validated_version: "4.20, 4.21, 4.22"
---

OSD-GCP clusters are provisioned with platform-managed firewall rules that use GCP network tags to target instances. The BYO (Bring Your Own) firewall feature replaces these with rules that target WIF service accounts instead. This gives customers full ownership of their firewall rules while maintaining the same network security posture.

This guide walks through retrofitting an existing OSD-GCP cluster from tag-targeted rules to SA-targeted BYO rules, disabling CCM firewall management, and validating Day-2 operations.

## Overview

The retrofit procedure:

1. Create SA-targeted BYO rules alongside the existing tag-targeted rules
2. Verify coexistence (both rule sets active, no conflicts)
3. Delete the platform-managed tag-targeted rules
4. Disable CCM firewall management so the Cloud Controller Manager does not recreate rules
5. (Optional) Validate Day-2 operations (scale-up, upgrades) with BYO rules only

## Prerequisites

* An existing OSD-GCP cluster deployed with WIF (Workload Identity Federation)
* `gcloud` CLI with permissions to manage firewall rules in the GCP project
* `oc` CLI authenticated to the cluster with `cluster-admin` privileges
* `ocm` CLI logged in to OCM

## Step 1: Set Environment Variables

Only the cluster name and GCP project need to be set manually. All other values are derived dynamically.

```bash
export CLUSTER_NAME="<your-cluster-name>"
export GCP_PROJECT="<your-gcp-project>"
```

Derive the infrastructure ID from OCM:

```bash
export INFRA_ID=$(ocm describe cluster ${CLUSTER_NAME} --json | jq -r '.infra_id')
echo "INFRA_ID: ${INFRA_ID}"
```

Derive the VPC network and BYO rule prefix:

```bash
export VPC_NETWORK="${INFRA_ID}-network"
export BYO_PREFIX="${CLUSTER_NAME}-byo"
```

Derive the WIF service accounts from the cluster's compute instances:

```bash
export CP_SA=$(gcloud compute instances list \
  --project=${GCP_PROJECT} \
  --filter="name~${INFRA_ID}-master" \
  --format="value(serviceAccounts.email)" \
  --limit=1)

export WORKER_SA=$(gcloud compute instances list \
  --project=${GCP_PROJECT} \
  --filter="name~${INFRA_ID}-worker" \
  --format="value(serviceAccounts.email)" \
  --limit=1)

echo "CP_SA: ${CP_SA}"
echo "WORKER_SA: ${WORKER_SA}"
```

Set the GCP health check probe IP ranges. These are [Google's global health check source ranges](https://cloud.google.com/load-balancing/docs/health-check-concepts#ip-ranges), used by all GCP load balancers. They do not vary by project or region.

```bash
export LB_CIDRS="35.191.0.0/16,130.211.0.0/22,209.85.152.0/22,209.85.204.0/22"
```

Verify all variables are set:

```bash
echo "CLUSTER_NAME:  ${CLUSTER_NAME}"
echo "GCP_PROJECT:   ${GCP_PROJECT}"
echo "INFRA_ID:      ${INFRA_ID}"
echo "VPC_NETWORK:   ${VPC_NETWORK}"
echo "BYO_PREFIX:    ${BYO_PREFIX}"
echo "CP_SA:         ${CP_SA}"
echo "WORKER_SA:     ${WORKER_SA}"
echo "LB_CIDRS:      ${LB_CIDRS}"
```

## Step 2: Record the Existing Platform-Managed Firewall Rules

Before making any changes, capture a snapshot of the current firewall rules:

```bash
gcloud compute firewall-rules list \
  --project=${GCP_PROJECT} \
  --filter="network=${VPC_NETWORK}" \
  --format="table(
    name,
    direction,
    allowed[].map().firewall_rule().list():label=ALLOWED,
    sourceRanges.list():label=SOURCE_RANGES,
    targetTags.list():label=TARGET_TAGS,
    targetServiceAccounts.list():label=TARGET_SVC_ACCT
  )"
```

A standard OSD-GCP cluster will have 6 platform-managed rules, all using network tags as their targeting mechanism:

| Rule Name Pattern | Ports | Targeting |
|-------------------|-------|-----------|
| `${INFRA_ID}-api` | tcp:6443 | Network tags |
| `${INFRA_ID}-etcd` | tcp:2379-2380 | Network tags |
| `${INFRA_ID}-control-plane` | tcp:2379-2380,6443,9258-9259,10257-10259,22623-22624 | Network tags |
| `${INFRA_ID}-health-checks` | tcp:6080,6443,22624 | Network tags |
| `${INFRA_ID}-internal-cluster` | tcp,udp,icmp (all) | Network tags |
| `${INFRA_ID}-internal-network` | tcp,udp (various) | Network tags |

{{% alert state="info" %}}Any additional `k8s-*` rules are GCP firewall rules automatically created by Kubernetes when a LoadBalancer Service or Ingress was provisioned on your cluster.{{% /alert %}}

## Step 3: Establish a Baseline (Optional but Recommended)

Deploy a test workload to verify networking before, during, and after the migration:

```bash
oc new-project byo-fw-test
oc create deployment hello --image=quay.io/openshift/origin-hello-openshift
oc expose deployment hello --port=8080
oc expose svc hello
```

Create a LoadBalancer service to test CCM behavior:

```bash
oc create -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: test-lb
  namespace: byo-fw-test
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: hello
EOF
```

Wait for the LoadBalancer to be assigned an external IP (this may take up to 90 seconds):

```bash
oc get svc test-lb -n byo-fw-test -w
```

Verify all networking paths:

```bash
curl -sk $(oc whoami --show-server)/healthz
```

```bash
curl -s http://$(oc get route hello -n byo-fw-test -o jsonpath='{.spec.host}')
```

All checks should pass: API healthy, ingress returning `Hello OpenShift!`.

## Step 4: Create BYO Firewall Rules (SA-Targeted)

Create 8 SA-targeted rules that mirror the platform-managed rules plus cover ingress. These rules coexist safely with the existing tag-targeted rules.

```bash
# Rule 1: API server (external access)
gcloud compute firewall-rules create ${BYO_PREFIX}-api \
  --project=${GCP_PROJECT} \
  --network=${VPC_NETWORK} \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:6443 \
  --source-ranges=0.0.0.0/0 \
  --target-service-accounts=${CP_SA} \
  --priority=1000

# Rule 2: etcd (control plane internal)
gcloud compute firewall-rules create ${BYO_PREFIX}-etcd \
  --project=${GCP_PROJECT} \
  --network=${VPC_NETWORK} \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:2379-2380 \
  --source-service-accounts=${CP_SA} \
  --target-service-accounts=${CP_SA} \
  --priority=1000

# Rule 3: GCP load balancer health checks to control plane
gcloud compute firewall-rules create ${BYO_PREFIX}-health-checks \
  --project=${GCP_PROJECT} \
  --network=${VPC_NETWORK} \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:6080,tcp:6443,tcp:22624 \
  --source-ranges=${LB_CIDRS} \
  --target-service-accounts=${CP_SA} \
  --priority=1000

# Rule 4: control plane services
gcloud compute firewall-rules create ${BYO_PREFIX}-control-plane \
  --project=${GCP_PROJECT} \
  --network=${VPC_NETWORK} \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:2379-2380,tcp:6443,tcp:9258-9259,tcp:10257-10259,tcp:22623-22624 \
  --source-service-accounts=${CP_SA} \
  --target-service-accounts=${CP_SA} \
  --priority=1000

# Rule 5: internal network (node-to-node services)
gcloud compute firewall-rules create ${BYO_PREFIX}-internal-network \
  --project=${GCP_PROJECT} \
  --network=${VPC_NETWORK} \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:9000-9999,tcp:10250-10259,tcp:22623-22624,tcp:30000-32767,udp:4789,udp:6081,udp:9000-9999,udp:500,udp:4500 \
  --source-service-accounts=${CP_SA},${WORKER_SA} \
  --target-service-accounts=${CP_SA},${WORKER_SA} \
  --priority=1000

# Rule 6: internal cluster (all traffic between nodes)
gcloud compute firewall-rules create ${BYO_PREFIX}-internal-cluster \
  --project=${GCP_PROJECT} \
  --network=${VPC_NETWORK} \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp,udp,icmp \
  --source-service-accounts=${CP_SA},${WORKER_SA} \
  --target-service-accounts=${CP_SA},${WORKER_SA} \
  --priority=1000

# Rule 7: ingress (external HTTP/HTTPS to workers)
gcloud compute firewall-rules create ${BYO_PREFIX}-ingress-k8s-fw \
  --project=${GCP_PROJECT} \
  --network=${VPC_NETWORK} \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-service-accounts=${WORKER_SA} \
  --priority=1000

# Rule 8: ingress health checks (GCP LB to worker NodePorts)
gcloud compute firewall-rules create ${BYO_PREFIX}-ingress-k8s-http-hc \
  --project=${GCP_PROJECT} \
  --network=${VPC_NETWORK} \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:30000-32767 \
  --source-ranges=${LB_CIDRS} \
  --target-service-accounts=${WORKER_SA} \
  --priority=1000
```

### BYO Rules Summary

| # | Rule | Ports | Source | Target SA |
|---|------|-------|--------|-----------|
| 1 | `${BYO_PREFIX}-api` | tcp:6443 | 0.0.0.0/0 | CP |
| 2 | `${BYO_PREFIX}-etcd` | tcp:2379-2380 | CP SA | CP |
| 3 | `${BYO_PREFIX}-health-checks` | tcp:6080,6443,22624 | GCP LB CIDRs | CP |
| 4 | `${BYO_PREFIX}-control-plane` | tcp:2379-2380,6443,9258-9259,10257-10259,22623-22624 | CP SA | CP |
| 5 | `${BYO_PREFIX}-internal-network` | tcp/udp (various) | CP+Worker SA | CP+Worker |
| 6 | `${BYO_PREFIX}-internal-cluster` | tcp,udp,icmp | CP+Worker SA | CP+Worker |
| 7 | `${BYO_PREFIX}-ingress-k8s-fw` | tcp:80,443 | 0.0.0.0/0 | Worker |
| 8 | `${BYO_PREFIX}-ingress-k8s-http-hc` | tcp:30000-32767 | GCP LB CIDRs | Worker |

### Verify BYO Rules

Confirm all 8 rules were created:

```bash
gcloud compute firewall-rules list \
  --project=${GCP_PROJECT} \
  --filter="network=${VPC_NETWORK} AND name~${BYO_PREFIX}" \
  --format="table(
    name,
    direction,
    allowed[].map().firewall_rule().list():label=ALLOWED,
    targetServiceAccounts.list():label=TARGET_SVC_ACCT
  )"
```

At this point both rule sets (tag-based and SA-based) are active simultaneously. Verify the cluster is still healthy:

```bash
oc get nodes
```

```bash
oc get co
```

```bash
curl -sk $(oc whoami --show-server)/healthz
```

## Step 5: Delete Platform-Managed Firewall Rules

With BYO rules in place, remove the original tag-targeted rules:

```bash
gcloud compute firewall-rules delete \
  ${INFRA_ID}-api \
  ${INFRA_ID}-control-plane \
  ${INFRA_ID}-etcd \
  ${INFRA_ID}-health-checks \
  ${INFRA_ID}-internal-cluster \
  ${INFRA_ID}-internal-network \
  --project=${GCP_PROJECT} --quiet
```

Leave CCM-managed `k8s-*` rules (for existing LoadBalancer services) in place for now.

Immediately verify the cluster:

```bash
curl -sk $(oc whoami --show-server)/healthz
```

```bash
oc get nodes
```

```bash
oc get co
```

If the baseline workload was deployed:

```bash
curl -s http://$(oc get route hello -n byo-fw-test -o jsonpath='{.spec.host}')
```

```bash
oc get svc test-lb -n byo-fw-test
```

The cluster should continue operating with zero disruption: API responding, all nodes Ready, all operators healthy, and networking paths functional.

## Step 6: Disable CCM Firewall Management

With BYO firewall rules, the customer owns all firewall rules. The Cloud Controller Manager (CCM) must be told not to create or delete firewall rules when LoadBalancer services are created or deleted. CCM should still manage the load balancer resources (forwarding rules, target pools); only its firewall operations should be disabled.

### Understanding the ConfigMap Sync Chain

The CCM reads its cloud config from `openshift-cloud-controller-manager/cloud-conf`, but this ConfigMap is managed by a sync controller. Patching it directly will be reverted within seconds.

The correct approach is to patch the **source** ConfigMap. Changes propagate automatically through a three-stage sync chain:

```
openshift-config/cloud-provider-config          (key: config)
    ↓ config-sync-controllers
openshift-config-managed/kube-cloud-config       (key: cloud.conf)
    ↓ config-sync-controllers
openshift-cloud-controller-manager/cloud-conf    (key: cloud.conf)
```

### Apply the Flag

Read the current cloud config, set `firewall-rules-management` to `Disabled`, and patch it back:

```bash
CURRENT_CONFIG=$(oc get configmap cloud-provider-config -n openshift-config \
  -o jsonpath='{.data.config}')

if echo "$CURRENT_CONFIG" | grep -q 'firewall-rules-management'; then
  NEW_CONFIG=$(echo "$CURRENT_CONFIG" | \
    sed 's/firewall-rules-management = Enabled/firewall-rules-management = Disabled/')
else
  NEW_CONFIG="${CURRENT_CONFIG}
firewall-rules-management = Disabled"
fi

oc patch configmap cloud-provider-config -n openshift-config \
  --type merge \
  --patch "$(jq -n --arg config "$NEW_CONFIG" '{data: {config: $config}}')"
```

### Verify Propagation

Wait approximately 30 seconds for the sync controllers, then verify the flag propagated to all three ConfigMaps:

```bash
# Source (openshift-config)
oc get cm cloud-provider-config -n openshift-config \
  -o jsonpath='{.data.config}' | grep firewall

# Intermediate (openshift-config-managed)
oc get cm kube-cloud-config -n openshift-config-managed \
  -o jsonpath='{.data.cloud\.conf}' | grep firewall

# Target, read by CCM (openshift-cloud-controller-manager)
oc get cm cloud-conf -n openshift-cloud-controller-manager \
  -o jsonpath='{.data.cloud\.conf}' | grep firewall
```

All three should show: `firewall-rules-management = Disabled`

### Verify CCM Behavior

Restart the CCM pods to pick up the new config:

```bash
oc delete pods -n openshift-cloud-controller-manager \
  -l k8s-app=gcp-cloud-controller-manager
```

Check the CCM logs for the `Disabled` flag:

```bash
oc logs -n openshift-cloud-controller-manager \
  -l k8s-app=gcp-cloud-controller-manager --tail=50 | grep -i firewall
```

When a LoadBalancer service is created with the flag disabled, CCM logs should contain entries with `firewall rules are unmanaged`, confirming that firewall operations are being skipped. The exact function names and message format may vary across OpenShift versions.

CCM will still provision load balancer resources (forwarding rules, target pools, external IPs) but will skip all firewall rule creation and deletion.

## Step 7: Validate Day-2 Operations (Optional)

### Worker Scale-Up

Scale a machinepool to verify new nodes are covered by BYO rules:

```bash
ocm edit machinepool worker --cluster=${CLUSTER_NAME} --replicas=3
```

The new node should become Ready without any firewall changes. SA-targeted rules apply to any instance running with the matching WIF service account.

```bash
oc get nodes -w
```

Scale back down when done:

```bash
ocm edit machinepool worker --cluster=${CLUSTER_NAME} --replicas=2
```

### Z-Stream Upgrade

Upgrade to a newer z-stream release to verify BYO rules and the `firewall-rules-management` flag survive the upgrade:

```bash
ocm describe cluster ${CLUSTER_NAME} --json | jq -r '.version.available_upgrades[]'
```

Schedule an upgrade:

```bash
CLUSTER_ID=$(ocm describe cluster ${CLUSTER_NAME} --json | jq -r '.id')
TARGET_VERSION="<target-version>"
# macOS:
NEXT_TS=$(date -u -v+10M '+%Y-%m-%dT%H:%M:%SZ')
# Linux:
# NEXT_TS=$(date -u -d '+10 minutes' '+%Y-%m-%dT%H:%M:%SZ')

echo '{"version":"'${TARGET_VERSION}'","schedule_type":"manual","next_run":"'${NEXT_TS}'"}' \
  > /tmp/upgrade-policy.json
ocm post /api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/upgrade_policies \
  --body=/tmp/upgrade-policy.json
rm /tmp/upgrade-policy.json
```

{{% alert state="info" %}}On OSD, upgrades should be initiated through OCM, not `oc adm upgrade`. The `Upgradeable=False` gate from the cloud-credential annotation only blocks minor version upgrades. Z-stream upgrades proceed without issue.{{% /alert %}}

Monitor progress:

```bash
ocm list upgradepolicies --cluster=${CLUSTER_NAME}
watch 'oc get clusterversion; echo "---"; oc get co | grep -v "True.*False.*False"'
```

After the upgrade completes, verify:

```bash
oc get clusterversion
```

```bash
oc get nodes
```

```bash
oc get co
```

Confirm BYO firewall rules are still present:

```bash
gcloud compute firewall-rules list \
  --project=${GCP_PROJECT} \
  --filter="network=${VPC_NETWORK} AND name~${BYO_PREFIX}" \
  --format="table(name)"
```

Confirm platform-managed rules are still gone:

```bash
gcloud compute firewall-rules list \
  --project=${GCP_PROJECT} \
  --filter="network=${VPC_NETWORK} AND name~${INFRA_ID}" \
  --format="table(name)"
```

Confirm the flag persisted through the upgrade:

```bash
oc get cm cloud-conf -n openshift-cloud-controller-manager \
  -o jsonpath='{.data.cloud\.conf}' | grep firewall
```

The BYO rules should be unchanged, platform-managed rules should remain absent, and the `firewall-rules-management = Disabled` flag should persist through the upgrade. The new CCM pod should load the flag correctly.

## Cleanup

If you deployed the baseline test workload, remove it:

```bash
oc delete project byo-fw-test
```
