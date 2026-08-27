---
date: '2026-08-24'
title: ROSA HCP Disaster Recovery with ACM and OpenShift GitOps
tags: ["ROSA HCP", "ACM", "GitOps"]
authors:
  - Kevin Collins
  - Diana Sari
  - Kumudu Herath
validated_version: "4.22"
---

This guide demonstrates how to set up an active/passive disaster recovery pattern for applications running on ROSA HCP clusters using Red Hat Advanced Cluster Management (ACM) and OpenShift GitOps (ArgoCD). ACM handles cluster health monitoring, while ArgoCD deploys the application to the active cluster.

The pattern works as follows:

- The guide first deploys the application to the primary cluster, records the EFS path mapping, pre-stages static DR PVs, and then enables the warm DR application
- After that point, ArgoCD maintains the application on both primary and warm DR
- ACM monitors cluster health via klusterlet heartbeats
- A Placement resource determines the current active/failover target
- DNS cutover follows the PlacementDecision
- Applications are not moved during failover; both are already maintained by ArgoCD

## Prerequisites

Before starting this guide, complete the [Create ROSA HCP Disaster Recovery Infrastructure](/experts/rosa/rosa-dr-infra/) guide. That guide sets up:

- EFS CSI Driver on both clusters
- S3 Cross-Region Replication for application data and backup buckets
- EFS replication from the primary to the DR Region

You need the environment variables from that guide still set in your shell:

- `PRIMARY_CLUSTER_NAME`, `DR_CLUSTER_NAME`
- `PRIMARY_REGION`, `DR_REGION`
- `APP_BUCKET_PRIMARY`, `APP_BUCKET_DR`
- `APP_S3_ROLE_ARN_PRIMARY`, `APP_S3_ROLE_ARN_DR`
- `PRIMARY_EFS`, `DR_EFS`

If you are starting a new shell session, re-run the environment variable steps from the [DR infrastructure guide](/experts/rosa/rosa-dr-infra/).

In addition to the shared infrastructure, this guide requires:

* A third ROSA HCP cluster for the ACM hub (`$CLUSTER_ACM`)
* AWS CLI, `oc` CLI, and `rosa` CLI configured
* For DNS-based failover:
  * A Route 53 public hosted zone
  * A custom domain or hostname where you are allowed to create DNS records
  * `certbot`
  * The `certbot-dns-route53` plugin

If you follow the DNS failover or custom certificate workflow, verify the Route 53 Certbot plugin before starting those steps:

```bash
certbot plugins | grep -q dns-route53
```

## Environment Variables

The following variables carry over from the [DR infrastructure guide](/experts/rosa/rosa-dr-infra/): `PRIMARY_CLUSTER_NAME`, `DR_CLUSTER_NAME`, `PRIMARY_REGION`, `DR_REGION`, `APP_BUCKET_PRIMARY`, `APP_BUCKET_DR`, `APP_S3_ROLE_ARN_PRIMARY`, `APP_S3_ROLE_ARN_DR`, `PRIMARY_EFS`, `DR_EFS`, `AWS_ACCOUNT_ID`. Set the additional variables needed for this guide:

```bash
export CLUSTER_ACM=<your-acm-cluster-name>
export ACM_PREFIX=<unique-prefix>
export NAMESPACE=${ACM_PREFIX}-demo
export CLUSTERSET_NAME=${ACM_PREFIX}-dr-clusters
export ALL_CLUSTERS_PLACEMENT_NAME=${ACM_PREFIX}-all-dr-clusters
export PLACEMENT_NAME=${ACM_PREFIX}-placement
export GITOPS_CLUSTER_NAME=${ACM_PREFIX}-gitops-cluster
export APPSET_NAME=${ACM_PREFIX}
export APP_NAME_PRIMARY=${APPSET_NAME}-${PRIMARY_CLUSTER_NAME}
export APP_NAME_DR=${APPSET_NAME}-${DR_CLUSTER_NAME}
export CUSTOM_DOMAIN=<your-custom-domain>
export HOSTED_ZONE_ID=<your-route53-hosted-zone-id>
```

## Update S3 IRSA Trust Policies

The DR infrastructure guide creates S3 IRSA roles with trust policies scoped to the `dr-demo` namespace. This guide deploys the application in the `${NAMESPACE}` namespace, so the trust policies must be updated to allow service accounts from both namespaces:

```bash
for ROLE_NAME in ${PRIMARY_CLUSTER_NAME}-dr-demo-s3 ${DR_CLUSTER_NAME}-dr-demo-s3; do
  TRUST=$(aws iam get-role --role-name $ROLE_NAME \
    --query 'Role.AssumeRolePolicyDocument' --output json)

  OIDC_KEY=$(echo "$TRUST" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cond = d['Statement'][0]['Condition']['StringEquals']
print(list(cond.keys())[0])")

  OIDC_PROVIDER=$(echo "$OIDC_KEY" | sed 's/:sub$//')

  aws iam update-assume-role-policy \
    --role-name $ROLE_NAME \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Principal\": {
          \"Federated\": \"arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}\"
        },
        \"Action\": \"sts:AssumeRoleWithWebIdentity\",
        \"Condition\": {
          \"StringEquals\": {
            \"${OIDC_KEY}\": [
              \"system:serviceaccount:dr-demo:s3-writer\",
              \"system:serviceaccount:dr-demo:dashboard\",
              \"system:serviceaccount:dr-demo:default\",
              \"system:serviceaccount:${NAMESPACE}:s3-writer\",
              \"system:serviceaccount:${NAMESPACE}:dashboard\",
              \"system:serviceaccount:${NAMESPACE}:default\"
            ]
          }
        }
      }]
    }"
  echo "Updated $ROLE_NAME to allow ${NAMESPACE} namespace"
done
```

## Log into the ACM Hub Cluster

All resources in this guide are created on the ACM hub cluster unless otherwise noted.


## Install ACM on the Hub Cluster

Install the Red Hat Advanced Cluster Management operator. Create the namespace, OperatorGroup, and Subscription:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: open-cluster-management
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: acm
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-2.17
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait for the operator CSV to reach `Succeeded`:

```bash
watch "oc get csv -n open-cluster-management | grep advanced-cluster-management"
```

Create the MultiClusterHub to deploy ACM components:

```bash
cat <<EOF | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF
```

Wait for the MultiClusterHub to be ready. This can take several minutes:

```bash
watch "oc get multiclusterhub -n open-cluster-management \
  -o jsonpath='{.items[0].status.phase}'"
```

Wait until the output shows `Running`.

## Import Managed Clusters into ACM

Import each regional cluster so ACM can monitor and manage them.

### Import the Primary Cluster

Create the ManagedCluster resource:

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${PRIMARY_CLUSTER_NAME}
  labels:
    name: ${PRIMARY_CLUSTER_NAME}
    cloud: Amazon
    region: ${PRIMARY_REGION}
    vendor: OpenShift
spec:
  hubAcceptsClient: true
EOF
```

Log in to the primary cluster and get a token:

```bash
PRIMARY_API=$(rosa describe cluster -c $PRIMARY_CLUSTER_NAME -o json | jq -r '.api.url')
PRIMARY_TOKEN=$(oc whoami -t)
```

Log back in to the ACM hub, create the namespace, then create the auto-import secret:

```bash
oc create namespace ${PRIMARY_CLUSTER_NAME} --dry-run=client -o yaml | oc apply -f -

oc create secret generic auto-import-secret \
  -n ${PRIMARY_CLUSTER_NAME} \
  --from-literal=autoImportRetry=5 \
  --from-literal=token="${PRIMARY_TOKEN}" \
  --from-literal=server="${PRIMARY_API}"
```

Wait for the cluster to be imported and available:

```bash
watch "oc get managedcluster ${PRIMARY_CLUSTER_NAME}"
```

Wait until `AVAILABLE` shows `True`:

```
NAME                    HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
${PRIMARY_CLUSTER_NAME}  true           https://api...          True     True        2m
```

### Import the DR Cluster

Create the ManagedCluster resource:

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${DR_CLUSTER_NAME}
  labels:
    name: ${DR_CLUSTER_NAME}
    cloud: Amazon
    region: ${DR_REGION}
    vendor: OpenShift
spec:
  hubAcceptsClient: true
EOF
```

Log in to the DR cluster and get a token:

```bash
DR_API=$(rosa describe cluster -c $DR_CLUSTER_NAME -o json | jq -r '.api.url')
DR_TOKEN=$(oc whoami -t)
```

Log back in to the ACM hub, create the namespace, then create the auto-import secret:

```bash
oc create namespace ${DR_CLUSTER_NAME} --dry-run=client -o yaml | oc apply -f -

oc create secret generic auto-import-secret \
  -n ${DR_CLUSTER_NAME} \
  --from-literal=autoImportRetry=5 \
  --from-literal=token="${DR_TOKEN}" \
  --from-literal=server="${DR_API}"
```

Wait for the cluster to be imported and available:

```bash
watch "oc get managedcluster ${DR_CLUSTER_NAME}"
```

Verify both clusters are imported:

```bash
oc get managedclusters
```

```
NAME                    HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
${PRIMARY_CLUSTER_NAME}  true           https://api...          True     True        5m
${DR_CLUSTER_NAME}       true           https://api...          True     True        2m
local-cluster            true           https://api...          True     True        30m
```

## Create a ManagedClusterSet

Group the regional clusters into a ManagedClusterSet so they can be referenced as a single pool for placement decisions.

Before creating shared hub resources, verify that the names derived from `ACM_PREFIX` do not already exist:

```bash
COLLISION_FOUND=false

for RESOURCE in \
  "managedclusterset/${CLUSTERSET_NAME}" \
  "placement/${PLACEMENT_NAME} -n openshift-gitops" \
  "placement/${ALL_CLUSTERS_PLACEMENT_NAME} -n openshift-gitops" \
  "gitopscluster/${GITOPS_CLUSTER_NAME} -n openshift-gitops" \
  "applicationset/${APPSET_NAME} -n openshift-gitops"; do
  if oc get ${RESOURCE} >/dev/null 2>&1; then
    echo "Resource already exists: ${RESOURCE}"
    COLLISION_FOUND=true
  fi
done

if [ "$COLLISION_FOUND" = true ]; then
  echo "Stop here. Choose a different ACM_PREFIX before continuing."
  false
else
  echo "No ACM/GitOps resource name collisions found."
fi
```

Create the ManagedClusterSet:

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: ${CLUSTERSET_NAME}
EOF
```

Add only the primary cluster to the set. The DR cluster is added after the initial failover Placement selects the primary cluster:

```bash
oc label managedcluster ${PRIMARY_CLUSTER_NAME} \
  cluster.open-cluster-management.io/clusterset=${CLUSTERSET_NAME} \
  --overwrite
```

## Install OpenShift GitOps on the Hub

Install the OpenShift GitOps operator which provides ArgoCD:

```bash
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait for the operator to install:

```bash
watch "oc get csv -n openshift-operators | grep gitops"
```

Wait until the `PHASE` shows `Succeeded`.

Grant the ArgoCD service accounts cluster-admin privileges. The application controller needs this to deploy resources to managed clusters, and the ApplicationSet controller needs it to read cluster secrets:

```bash
oc adm policy add-cluster-role-to-user cluster-admin \
  system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller

oc adm policy add-cluster-role-to-user cluster-admin \
  system:serviceaccount:openshift-gitops:openshift-gitops-applicationset-controller
```

Get the ArgoCD admin password:

```bash
ARGOCD_PASS=$(oc get secret openshift-gitops-cluster \
  -n openshift-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 -d)
echo "ArgoCD admin password: $ARGOCD_PASS"
```

### ArgoCD Health During Cluster Outages

ArgoCD uses the ACM-generated cluster secrets created by the `application-manager` addon. Those secrets connect through ACM's cluster-proxy. During a managed-cluster worker outage, use `ManagedClusterConditionAvailable` and the failover `PlacementDecision` as the authoritative failover signals. ArgoCD sync and health remain useful for validating reachable clusters, but this guide does not depend on ArgoCD marking the failed primary application as `Degraded`.

## Bind the ManagedClusterSet to GitOps

Create a ManagedClusterSetBinding in the `openshift-gitops` namespace to allow ArgoCD to use the cluster set:

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${CLUSTERSET_NAME}
  namespace: openshift-gitops
spec:
  clusterSet: ${CLUSTERSET_NAME}
EOF
```

## Configure ACM Placement for Failover

Create the Placement that monitors cluster health. This Placement selects exactly one cluster from the `${CLUSTERSET_NAME}` set. Because only the primary cluster was added to the set before this Placement is created, the initial decision is deterministic. After the DR cluster is added, the `Steady` prioritizer keeps the decision on the primary cluster while it remains healthy.

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: ${PLACEMENT_NAME}
  namespace: openshift-gitops
spec:
  clusterSets:
    - ${CLUSTERSET_NAME}
  numberOfClusters: 1
  prioritizerPolicy:
    mode: Exact
    configurations:
      - scoreCoordinate:
          type: BuiltIn
          builtIn: Steady
        weight: 10
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
      tolerationSeconds: 30
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
      tolerationSeconds: 30
EOF
```

Wait until the initial PlacementDecision selects the primary cluster:

```bash
for i in {1..60}; do
  SELECTED_CLUSTER=$(oc get placementdecision -n openshift-gitops \
    -l cluster.open-cluster-management.io/placement=${PLACEMENT_NAME} \
    -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null || true)
  echo "PlacementDecision: ${SELECTED_CLUSTER:-pending}"
  [ "$SELECTED_CLUSTER" = "$PRIMARY_CLUSTER_NAME" ] && break
  sleep 5
done

if [ "$SELECTED_CLUSTER" != "$PRIMARY_CLUSTER_NAME" ]; then
  echo "Placement did not select ${PRIMARY_CLUSTER_NAME}; stop here."
  false
fi
```

Now add the DR cluster to the set and verify the decision remains on the primary cluster:

```bash
oc label managedcluster ${DR_CLUSTER_NAME} \
  cluster.open-cluster-management.io/clusterset=${CLUSTERSET_NAME} \
  --overwrite

sleep 10
SELECTED_CLUSTER=$(oc get placementdecision -n openshift-gitops \
  -l cluster.open-cluster-management.io/placement=${PLACEMENT_NAME} \
  -o jsonpath='{.items[0].status.decisions[0].clusterName}')
echo "PlacementDecision: ${SELECTED_CLUSTER}"

if [ "$SELECTED_CLUSTER" != "$PRIMARY_CLUSTER_NAME" ]; then
  echo "Placement moved away from ${PRIMARY_CLUSTER_NAME} before failover; stop here."
  false
fi
```

The `tolerationSeconds` value is not the total failover time. Failover occurs after ACM detects the worker outage, updates `ManagedClusterConditionAvailable`, adds the `unreachable` or `unavailable` taint, the toleration period expires, and Placement reconciles the decision.

## Register Managed Clusters with ArgoCD

Enable the `application-manager` addon on both managed clusters. This addon creates the ArgoCD cluster secrets that allow ArgoCD to deploy to managed clusters via the ACM cluster-proxy:

```bash
cat << EOF | oc apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: application-manager
  namespace: ${PRIMARY_CLUSTER_NAME}
spec:
  installNamespace: open-cluster-management-agent-addon
---
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: application-manager
  namespace: ${DR_CLUSTER_NAME}
spec:
  installNamespace: open-cluster-management-agent-addon
EOF
```

Wait for the addons to become available:

```bash
watch "oc get managedclusteraddon -A | grep application-manager"
```

Wait until both clusters show `True` in the AVAILABLE column.

Create a Placement to select all clusters in the DR cluster set. This Placement is used only by the GitOpsCluster to register both clusters as ArgoCD deployment targets:

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: ${ALL_CLUSTERS_PLACEMENT_NAME}
  namespace: openshift-gitops
spec:
  clusterSets:
    - ${CLUSTERSET_NAME}
EOF
```

Create the GitOpsCluster resource:

```bash
cat << EOF | oc apply -f -
apiVersion: apps.open-cluster-management.io/v1beta1
kind: GitOpsCluster
metadata:
  name: ${GITOPS_CLUSTER_NAME}
  namespace: openshift-gitops
spec:
  argoServer:
    cluster: local-cluster
    argoNamespace: openshift-gitops
  placementRef:
    kind: Placement
    apiVersion: cluster.open-cluster-management.io/v1beta1
    name: ${ALL_CLUSTERS_PLACEMENT_NAME}
    namespace: openshift-gitops
EOF
```

Verify the clusters appear as ArgoCD cluster secrets:

```bash
oc get secrets -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster
```

You should see secrets for both managed clusters. The `application-manager` addon copies ManagedCluster labels to the cluster secrets, including the `cluster.open-cluster-management.io/clusterset` label.

### Keep ACM-Managed Cluster Secrets

The `application-manager` addon creates ArgoCD cluster secrets for the managed clusters. These secrets are managed by the ACM `gitopscluster` controller and use ACM's cluster-proxy URL in `data.server`. Do not patch the generated `*-application-manager-cluster-secret` objects to direct managed-cluster API endpoints; controller-owned fields can be reconciled back to the cluster-proxy URL.

This guide uses `ManagedClusterConditionAvailable` as the authoritative cluster outage signal and the failover `PlacementDecision` as the authoritative active/failover target. ArgoCD sync and health are used to validate application state when a target cluster is reachable.

## Tune Lease Duration for Faster Failover Detection

By default, ACM checks the klusterlet heartbeat lease every 5 minutes. For a faster demo, reduce the lease duration to 10 seconds on both managed clusters.

```bash
oc patch managedcluster ${PRIMARY_CLUSTER_NAME} --type merge \
  -p '{"spec":{"leaseDurationSeconds":10}}'
oc patch managedcluster ${DR_CLUSTER_NAME} --type merge \
  -p '{"spec":{"leaseDurationSeconds":10}}'
```

> **Note:** With a 10-second lease duration and 30-second placement toleration, total failover detection time is approximately 40 seconds. The default 5-minute lease results in failover detection of approximately 5.5 minutes. Choose values appropriate for your environment.

## Obtain a TLS Certificate (Optional)

If you want to serve the application on a custom domain with a valid TLS certificate, obtain one using Let's Encrypt with the `certbot-dns-route53` plugin. Certbot uses your AWS credentials to create a temporary TXT record in Route 53 for domain validation.

**Important:** Replace `your-email@example.com` with your actual email address.

```bash
certbot certonly \
  --dns-route53 \
  -d $CUSTOM_DOMAIN \
  --non-interactive \
  --agree-tos \
  --email your-email@example.com \
  --config-dir /tmp/certbot/config \
  --work-dir /tmp/certbot/work \
  --logs-dir /tmp/certbot/logs
```

Set the certificate directory:

```bash
export CERT_DIR=/tmp/certbot/config/live/${CUSTOM_DOMAIN}
```

## Create the Primary ArgoCD Application

The ApplicationSet maintains the Phoenix application on both clusters after DR storage is pre-staged. Placement does not decide where the ApplicationSet deploys; Placement determines the active/failover target that DNS should follow.

Create the ApplicationSet with only the primary cluster first. This lets the primary PVCs dynamically provision EFS access points so you can record their root paths before any DR PVCs exist.

The YAML is built in segments to cleanly embed the multi-line PEM certificate and key. The first heredoc writes everything up to `certificate: |`, then `sed` appends the indented PEM content directly from the cert files, and a final heredoc closes the YAML.

```bash
cat > /tmp/appset.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ${APPSET_NAME}
  namespace: openshift-gitops
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - name: ${PRIMARY_CLUSTER_NAME}
            appName: ${APP_NAME_PRIMARY}
            server: https://cluster-proxy-addon-user.multicluster-engine.svc.cluster.local:9092/${PRIMARY_CLUSTER_NAME}
            clusterRegion: ${PRIMARY_REGION}
            s3Bucket: ${APP_BUCKET_PRIMARY}
            s3RoleArn: ${APP_S3_ROLE_ARN_PRIMARY}
            efsId: ${PRIMARY_EFS}
  template:
    metadata:
      name: "{{.appName}}"
      labels:
        region: "{{.clusterRegion}}"
        cluster: "{{.name}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/rh-mobb/phoenix-mission-control.git
        targetRevision: main
        path: chart
        helm:
          releaseName: phoenix-mission-control
          valuesObject:
            region: "{{.clusterRegion}}"
            clusterName: "{{.name}}"
            s3:
              bucket: "{{.s3Bucket}}"
              roleArn: "{{.s3RoleArn}}"
            efs:
              fileSystemId: "{{.efsId}}"
              storageClassName: efs-sc
            primaryRegion: ${PRIMARY_REGION}
            primaryCluster: ${PRIMARY_CLUSTER_NAME}
            primaryHealthUrl: ""
            drRegion: ${DR_REGION}
            drCluster: ${DR_CLUSTER_NAME}
            route:
              enabled: true
              customDomain: ${CUSTOM_DOMAIN}
              tls:
                certificate: |
EOF

sed 's/^/                  /' "$CERT_DIR/fullchain.pem" >> /tmp/appset.yaml
printf '                key: |\n' >> /tmp/appset.yaml
sed 's/^/                  /' "$CERT_DIR/privkey.pem" >> /tmp/appset.yaml

cat >> /tmp/appset.yaml << EOF
      destination:
        server: "{{.server}}"
        namespace: ${NAMESPACE}
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
EOF

oc apply -f /tmp/appset.yaml
```

> **Note:** The Go template `{{.field}}` references use double curly braces and are not substituted by the shell. They are processed by ArgoCD at deploy time. If you skipped the TLS certificate step, remove the `tls` block from the `route` section, remove the `sed` and `printf` lines, and the route will use the cluster's default wildcard certificate.

Verify the primary Application is synced and healthy:

```bash
oc get applications.argoproj.io -n openshift-gitops ${APP_NAME_PRIMARY}
```

Wait until the primary application shows `Synced` and `Healthy`:

```
NAME                  SYNC STATUS   HEALTH STATUS
${APP_NAME_PRIMARY}   Synced        Healthy
```

Log in to the primary cluster and verify the PVCs are bound before recording the EFS mapping:

```bash
oc get pvc -n ${NAMESPACE}
```

## Prepare DR Cluster for EFS Data Continuity

When ArgoCD dynamically provisions a PVC, the EFS CSI driver creates a new access point with a fresh subdirectory. The replicated data from the primary EFS lives under the original primary subdirectories. To ensure the warm DR application sees the replicated data, pre-create static PersistentVolumes on the DR cluster before the DR PVCs exist. These PVs use `claimRef` pre-binding so the DR PVCs bind to the intended replicated paths instead of dynamically provisioning empty directories.

The demo application uses 3 EFS-backed PVCs:
- `shared-flight-data` -- shared volume mounted by the dashboard and flight recorder
- `flight-data-flight-recorder-0` -- StatefulSet replica 0
- `flight-data-flight-recorder-1` -- StatefulSet replica 1

### Record the PVC-to-path mapping

{{< alert >}}
Record this mapping as part of your DR preparation and keep it up to date. In a real disaster, the primary cluster API might not be available to query.
{{< /alert >}}

Log in to the primary cluster, then map each PVC to its EFS access point path. The PV `volumeHandle` format is `<efs-id>::<access-point-id>`, and each access point has a root directory path where the PVC's data is stored:

```bash
declare -A EFS_PATH_MAP
for PVC in shared-flight-data flight-data-flight-recorder-0 flight-data-flight-recorder-1; do
  PV=$(oc get pvc $PVC -n ${NAMESPACE} -o jsonpath='{.spec.volumeName}')
  AP_ID=$(oc get pv $PV -o jsonpath='{.spec.csi.volumeHandle}' | awk -F'::' '{print $2}')
  EFS_PATH_MAP[$PVC]=$(aws efs describe-access-points \
    --access-point-id $AP_ID \
    --region $PRIMARY_REGION \
    --query 'AccessPoints[0].RootDirectory.Path' \
    --output text)
  echo "$PVC -> ${EFS_PATH_MAP[$PVC]}"
done

export SHARED_FLIGHT_DATA_PATH="${EFS_PATH_MAP[shared-flight-data]}"
export FLIGHT_DATA_RECORDER_0_PATH="${EFS_PATH_MAP[flight-data-flight-recorder-0]}"
export FLIGHT_DATA_RECORDER_1_PATH="${EFS_PATH_MAP[flight-data-flight-recorder-1]}"

echo "SHARED_FLIGHT_DATA_PATH: $SHARED_FLIGHT_DATA_PATH"
echo "FLIGHT_DATA_RECORDER_0_PATH: $FLIGHT_DATA_RECORDER_0_PATH"
echo "FLIGHT_DATA_RECORDER_1_PATH: $FLIGHT_DATA_RECORDER_1_PATH"
```

### Pre-stage static PersistentVolumes on the DR cluster

Log in to the DR cluster, then create static PVs with `claimRef` pre-binding. The `claimRef` reserves each PV for a specific PVC so that when ArgoCD deploys the application, the PVCs bind to these PVs instead of dynamically provisioning new access points:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${ACM_PREFIX}-dr-shared-flight-data
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: efs-sc
  claimRef:
    namespace: ${NAMESPACE}
    name: shared-flight-data
  csi:
    driver: efs.csi.aws.com
    volumeHandle: ${DR_EFS}:${SHARED_FLIGHT_DATA_PATH}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${ACM_PREFIX}-dr-flight-data-0
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: efs-sc
  claimRef:
    namespace: ${NAMESPACE}
    name: flight-data-flight-recorder-0
  csi:
    driver: efs.csi.aws.com
    volumeHandle: ${DR_EFS}:${FLIGHT_DATA_RECORDER_0_PATH}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${ACM_PREFIX}-dr-flight-data-1
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: efs-sc
  claimRef:
    namespace: ${NAMESPACE}
    name: flight-data-flight-recorder-1
  csi:
    driver: efs.csi.aws.com
    volumeHandle: ${DR_EFS}:${FLIGHT_DATA_RECORDER_1_PATH}
EOF
```

Log back in to the ACM hub cluster.

{{< alert >}}
**Why static provisioning?** When the EFS CSI driver dynamically provisions a PVC, it creates a new access point with a unique subdirectory (e.g., `/${NAMESPACE}/pvc-xyz789`). The replicated data from the primary lives under the original subdirectory (e.g., `/${NAMESPACE}/pvc-abc123`). A dynamically provisioned PVC on the DR side would mount an empty directory. Static PVs with `claimRef` pre-binding ensure the DR PVCs mount the replicated data paths. The `claimRef` reserves each PV so only the named PVC can bind to it.
{{< /alert >}}

## Enable the Warm DR Application

After the DR static PVs exist, update the ApplicationSet to include the DR cluster. The ApplicationSet now maintains both applications, but Placement remains the source of truth for the active/failover target.

```bash
cat > /tmp/appset.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ${APPSET_NAME}
  namespace: openshift-gitops
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - name: ${PRIMARY_CLUSTER_NAME}
            appName: ${APP_NAME_PRIMARY}
            server: https://cluster-proxy-addon-user.multicluster-engine.svc.cluster.local:9092/${PRIMARY_CLUSTER_NAME}
            clusterRegion: ${PRIMARY_REGION}
            s3Bucket: ${APP_BUCKET_PRIMARY}
            s3RoleArn: ${APP_S3_ROLE_ARN_PRIMARY}
            efsId: ${PRIMARY_EFS}
          - name: ${DR_CLUSTER_NAME}
            appName: ${APP_NAME_DR}
            server: https://cluster-proxy-addon-user.multicluster-engine.svc.cluster.local:9092/${DR_CLUSTER_NAME}
            clusterRegion: ${DR_REGION}
            s3Bucket: ${APP_BUCKET_DR}
            s3RoleArn: ${APP_S3_ROLE_ARN_DR}
            efsId: ${DR_EFS}
  template:
    metadata:
      name: "{{.appName}}"
      labels:
        region: "{{.clusterRegion}}"
        cluster: "{{.name}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/rh-mobb/phoenix-mission-control.git
        targetRevision: main
        path: chart
        helm:
          releaseName: phoenix-mission-control
          valuesObject:
            region: "{{.clusterRegion}}"
            clusterName: "{{.name}}"
            s3:
              bucket: "{{.s3Bucket}}"
              roleArn: "{{.s3RoleArn}}"
            efs:
              fileSystemId: "{{.efsId}}"
              storageClassName: efs-sc
            primaryRegion: ${PRIMARY_REGION}
            primaryCluster: ${PRIMARY_CLUSTER_NAME}
            primaryHealthUrl: ""
            drRegion: ${DR_REGION}
            drCluster: ${DR_CLUSTER_NAME}
            route:
              enabled: true
              customDomain: ${CUSTOM_DOMAIN}
              tls:
                certificate: |
EOF

sed 's/^/                  /' "$CERT_DIR/fullchain.pem" >> /tmp/appset.yaml
printf '                key: |\n' >> /tmp/appset.yaml
sed 's/^/                  /' "$CERT_DIR/privkey.pem" >> /tmp/appset.yaml

cat >> /tmp/appset.yaml << EOF
      destination:
        server: "{{.server}}"
        namespace: ${NAMESPACE}
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
EOF

oc apply -f /tmp/appset.yaml
```

Verify that both Applications are synced and healthy:

```bash
oc get applications.argoproj.io -n openshift-gitops
```

Log in to the DR cluster and verify the DR PVCs bound to the pre-staged static PVs:

```bash
oc get pvc -n ${NAMESPACE} \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName
```

Expected volumes:

- `shared-flight-data` -> `${ACM_PREFIX}-dr-shared-flight-data`
- `flight-data-flight-recorder-0` -> `${ACM_PREFIX}-dr-flight-data-0`
- `flight-data-flight-recorder-1` -> `${ACM_PREFIX}-dr-flight-data-1`

## Set Up DNS

Create a Route 53 A record pointing to the router of the active cluster.

> **Note:** This guide uses a plain A record with a short TTL (30s) rather than an Alias record. Alias records with `EvaluateTargetHealth` can cause negative DNS caching if the ELB is temporarily unhealthy during failover. The trade-off is that ELB IP addresses can change without notice. With a 30s TTL this is tolerable for a demo, but for production use a CNAME or Alias record pointing to the ELB hostname with `EvaluateTargetHealth` set to `false`.

Get the router IP for each cluster by extracting the apps domain from the console URL:

```bash
PRIMARY_CONSOLE_HOST=$(rosa describe cluster -c $PRIMARY_CLUSTER_NAME -o json \
  | jq -r '.console.url' | sed 's|^https://||')
PRIMARY_IP=$(host $PRIMARY_CONSOLE_HOST | awk '/has address/{print $NF; exit}')
echo "Primary IP: $PRIMARY_IP"

DR_CONSOLE_HOST=$(rosa describe cluster -c $DR_CLUSTER_NAME -o json \
  | jq -r '.console.url' | sed 's|^https://||')
DR_IP=$(host $DR_CONSOLE_HOST | awk '/has address/{print $NF; exit}')
echo "DR IP: $DR_IP"
```

Create the DNS record pointing to the primary cluster:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${CUSTOM_DOMAIN}\",
        \"Type\": \"A\",
        \"TTL\": 30,
        \"ResourceRecords\": [{\"Value\": \"${PRIMARY_IP}\"}]
      }
    }]
  }"
```

Verify the application is accessible:

```bash
curl -sk https://${CUSTOM_DOMAIN}/healthz
```

```json
{"mission":"PHOENIX-7","status":"ok"}
```

## Failover Test

Simulate a region failure by stopping the worker instances on the primary cluster.

Delete EFS replication to promote the DR replica to read-write:

{{< alert >}}
EFS cross-region replicas are read-only while replication is active. The DR cluster's pods cannot write to the replica file system until it is promoted. Deleting the replication configuration is the only way to promote it. Once deleted, the DR EFS becomes an independent read-write file system. During failback, the guide re-establishes replication from primary to DR.
{{< /alert >}}

```bash
aws efs delete-replication-configuration \
  --source-file-system-id $PRIMARY_EFS \
  --region $PRIMARY_REGION
```

Disable auto-repair on the primary cluster's machine pools so ROSA does not replace the stopped workers, then stop the instances:

```bash
for MP in $(rosa list machinepools -c $PRIMARY_CLUSTER_NAME -o json | jq -r '.[].id'); do
  rosa edit machinepool $MP --cluster $PRIMARY_CLUSTER_NAME --autorepair=false
done

PRIMARY_INSTANCE_IDS=($(aws ec2 describe-instances --region ${PRIMARY_REGION} \
  --filters "Name=tag:Name,Values=*${PRIMARY_CLUSTER_NAME}*worker*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text))
echo "Primary instance IDs: ${PRIMARY_INSTANCE_IDS[@]}"

aws ec2 stop-instances \
  --instance-ids "${PRIMARY_INSTANCE_IDS[@]}" \
  --region $PRIMARY_REGION
```

Watch for ACM to detect the failure and for Placement to move the active decision to the DR cluster. With the tuned lease duration (10s) and toleration (30s), failover time is approximately ACM detection latency plus the 30-second toleration period and controller reconciliation:

```bash
watch -n5 "echo '=== Cluster Health ===' && \
  oc get managedcluster -o custom-columns=\
'NAME:.metadata.name,AVAILABLE:.status.conditions[?(@.type==\"ManagedClusterConditionAvailable\")].status' && \
  echo '' && echo '=== Placement Decision ===' && \
  oc get placementdecision -n openshift-gitops \
    -l cluster.open-cluster-management.io/placement=${PLACEMENT_NAME} \
    -o jsonpath='{range .items[0].status.decisions[*]}{.clusterName}{end}' && \
  echo '' && echo '' && echo '=== ArgoCD Applications ===' && \
  oc get applications.argoproj.io -n openshift-gitops"
```

Wait until the primary cluster shows `Available: Unknown` or `False` and the PlacementDecision shows only the DR cluster. ArgoCD should continue to report the reachable DR application as `Healthy`; the primary ArgoCD Application health is not the authoritative outage signal because ArgoCD reaches managed clusters through ACM's cluster-proxy.

```
=== Cluster Health ===
NAME                    AVAILABLE
${PRIMARY_CLUSTER_NAME}  Unknown
${DR_CLUSTER_NAME}       True
local-cluster            True

=== Placement Decision ===
${DR_CLUSTER_NAME}

=== ArgoCD Applications ===
NAME                 SYNC STATUS   HEALTH STATUS
${APP_NAME_PRIMARY}   Synced        Healthy
${APP_NAME_DR}        Synced        Healthy
```

Because the application is already maintained on both clusters after DR storage pre-stage, no ArgoCD redeployment is needed. The DR cluster's application is already running; DNS is switched to the cluster selected by the PlacementDecision.

Switch DNS to the DR cluster:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${CUSTOM_DOMAIN}\",
        \"Type\": \"A\",
        \"TTL\": 30,
        \"ResourceRecords\": [{\"Value\": \"${DR_IP}\"}]
      }
    }]
  }"
```

Flush local DNS cache and verify:

```bash
# macOS
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder

curl -sk https://${CUSTOM_DOMAIN}/healthz
```

## Failback

Failing back is a manual process. The Steady prioritizer in the health-monitoring Placement can keep the selection on the DR cluster after the primary recovers, preventing unnecessary flip-flopping.

{{< alert >}}
**Do not fail traffic back to the primary cluster until data written in the DR region has been reconciled.**

During failover, the DR EFS file system and DR S3 bucket become independent writable data stores. Writes made in the DR region are not automatically copied back to the primary region.

- **EFS:** The primary resumes using its original EFS, which does not contain writes made to the DR EFS during failover. Re-establishing replication (primary to DR) below will overwrite the DR EFS with the primary's data. In a production environment, copy or merge DR EFS data back to the primary before this step.
- **S3:** S3 Cross-Region Replication is one-directional (primary to DR). Objects written to the DR bucket during failover are not replicated back to the primary bucket (the primary bucket will return 404 for those objects). To preserve DR-written data, set up reverse replication (DR to primary) or manually sync with `aws s3 sync` before re-establishing normal replication.

For this demonstration, if no DR-side data needs to be preserved, you can restart the primary workers and re-establish primary-to-DR replication as shown below.
{{< /alert >}}

Start the primary worker instances:

```bash
PRIMARY_INSTANCE_IDS=($(aws ec2 describe-instances --region ${PRIMARY_REGION} \
  --filters "Name=tag:Name,Values=*${PRIMARY_CLUSTER_NAME}*worker*" \
            "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text))

aws ec2 start-instances \
  --instance-ids "${PRIMARY_INSTANCE_IDS[@]}" \
  --region $PRIMARY_REGION
```

> **Note:** Do not re-enable auto-repair during failback. The ROSA HCP machine manager detects that the previously stopped nodes were `NotReady` and cordons them for replacement. With auto-repair enabled, it replaces all worker nodes, which extends the recovery time. With auto-repair disabled, the machine manager still replaces the nodes but does so on its own schedule. The new nodes join the cluster in a schedulable state.

Wait for the primary cluster to rejoin ACM and for the nodes to be replaced. This typically takes 3-5 minutes:

```bash
watch -n10 "echo '=== ACM ===' && \
  oc get managedcluster ${PRIMARY_CLUSTER_NAME} \
    -o jsonpath='Available: {.status.conditions[?(@.type==\"ManagedClusterConditionAvailable\")].status}' && \
  echo '' && echo '' && echo '=== ArgoCD ===' && \
  oc get applications.argoproj.io -n openshift-gitops"
```

Wait until the primary cluster shows `Available: True` and `${APP_NAME_PRIMARY}` shows `Synced` and `Healthy`.

Re-establish EFS replication from primary to DR. Before allowing production traffic to return to the primary cluster, verify that the application is healthy and that any required DR-side EFS and S3 data has been reconciled. Application health alone is not sufficient to determine that a stateful workload is ready for failback.

Re-establish EFS replication so it is in place for future failovers. First, disable the overwrite protection that AWS enables on the replica after replication is deleted:

```bash
aws efs update-file-system-protection \
  --file-system-id $DR_EFS \
  --region $DR_REGION \
  --replication-overwrite-protection DISABLED

aws efs create-replication-configuration \
  --region $PRIMARY_REGION \
  --source-file-system-id $PRIMARY_EFS \
  --destinations "[{\"Region\": \"${DR_REGION}\", \"FileSystemId\": \"${DR_EFS}\"}]"
```

Switch DNS back to the primary cluster:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${CUSTOM_DOMAIN}\",
        \"Type\": \"A\",
        \"TTL\": 30,
        \"ResourceRecords\": [{\"Value\": \"${PRIMARY_IP}\"}]
      }
    }]
  }"
```

Flush local DNS cache and verify:

```bash
# macOS
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder

curl -sk https://${CUSTOM_DOMAIN}/healthz
```

## Failover Timeline Summary

| Event | Time |
|-------|------|
| Cluster failure occurs | T+0s |
| Klusterlet lease expires | T+10s |
| ACM taints cluster as unreachable | T+10s |
| ACM detects cluster is unhealthy | Detection latency |
| ACM adds unreachable/unavailable taint | After detection |
| Placement toleration expires | Detection latency + 30s |
| PlacementDecision selects DR | Detection latency + 30s + reconciliation |
| DNS switch (manual) | After DR decision |
| Traffic reaches DR cluster | DNS switch + TTL |

> **Note:** Because the application is already running on both clusters after DR storage pre-stage, failover requires only a DNS switch. There is no ArgoCD deployment delay. ACM `ManagedClusterConditionAvailable` and the failover `PlacementDecision` are the authoritative failover signals. For production environments, consider using Route 53 health checks with DNS failover routing to automate the DNS switch entirely.

## Production Considerations

- **Resource overhead:** After DR storage is pre-staged, the application runs on both clusters. For resource-intensive applications, consider whether the cost of running on both clusters is acceptable. The trade-off is faster failover (DNS-only, no deployment delay) versus higher steady-state resource consumption.
- **EFS path mapping:** Record and maintain the PVC-to-EFS access point path mapping as part of your DR runbook. In a real disaster, the primary cluster API might not be available to query. Update this mapping whenever PVCs are recreated.
- **Data reconciliation before failback:** Both EFS and S3 replication are one-directional (primary to DR). Data written during failover must be manually synced or merged back to the primary before re-establishing replication. See the [Disaster Recovery with OADP on ROSA HCP](/experts/rosa/oadp-efs-s3/) guide for detailed failback data reconciliation steps.
- **ACM hub availability:** The ACM hub is a single point of failure for failover detection. In production, deploy the hub with high availability or consider an active-passive hub configuration.
- **DNS automation:** Replace the manual DNS switch with Route 53 health checks and failover routing policies for fully automated DR.
- **Lease duration tuning:** The 10-second lease used in this guide is aggressive. For production, balance detection speed against the risk of false positives from transient network issues. A 60-second lease is a reasonable starting point.
- **EFS mount targets:** Ensure the DR cluster has EFS mount targets in all worker subnets before a disaster occurs. Creating mount targets during a failover adds delay to the recovery process.

## Cleanup

Delete the ApplicationSet and demo namespace resources:

```bash
oc delete applicationset ${APPSET_NAME} -n openshift-gitops
oc delete namespace ${NAMESPACE} --ignore-not-found
oc delete pv \
  ${ACM_PREFIX}-dr-shared-flight-data \
  ${ACM_PREFIX}-dr-flight-data-0 \
  ${ACM_PREFIX}-dr-flight-data-1 \
  --ignore-not-found
```

Delete the Placements and GitOpsCluster:

```bash
oc delete gitopscluster ${GITOPS_CLUSTER_NAME} -n openshift-gitops
oc delete placement ${PLACEMENT_NAME} -n openshift-gitops
oc delete placement ${ALL_CLUSTERS_PLACEMENT_NAME} -n openshift-gitops
```

Delete the ManagedClusterSetBinding and ManagedClusterSet:

```bash
oc delete managedclustersetbinding ${CLUSTERSET_NAME} -n openshift-gitops
oc delete managedclusterset ${CLUSTERSET_NAME}
```

Detach the managed clusters:

```bash
oc delete managedcluster ${PRIMARY_CLUSTER_NAME}
oc delete managedcluster ${DR_CLUSTER_NAME}
```

Delete the DNS record:

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"DELETE\",
      \"ResourceRecordSet\": {
        \"Name\": \"${CUSTOM_DOMAIN}\",
        \"Type\": \"A\",
        \"TTL\": 30,
        \"ResourceRecords\": [{\"Value\": \"${PRIMARY_IP}\"}]
      }
    }]
  }"
```
