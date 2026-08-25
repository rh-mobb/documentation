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

- ArgoCD deploys the application to both clusters simultaneously via an ApplicationSet
- ACM monitors cluster health via klusterlet heartbeats
- A Placement resource detects when a cluster becomes unreachable
- During failover, only DNS needs to be switched to point to the healthy cluster
- The application is already running on the DR cluster, so there is no deployment delay

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
* A Route 53 hosted zone for the custom domain (optional, for DNS-based failover)

## Environment Variables

The following variables carry over from the [DR infrastructure guide](/experts/rosa/rosa-dr-infra/): `PRIMARY_CLUSTER_NAME`, `DR_CLUSTER_NAME`, `PRIMARY_REGION`, `DR_REGION`, `APP_BUCKET_PRIMARY`, `APP_BUCKET_DR`, `APP_S3_ROLE_ARN_PRIMARY`, `APP_S3_ROLE_ARN_DR`, `PRIMARY_EFS`, `DR_EFS`, `AWS_ACCOUNT_ID`. Set the additional variables needed for this guide:

```bash
export CLUSTER_ACM=<your-acm-cluster-name>
export NAMESPACE=acm-demo
export CUSTOM_DOMAIN=<your-custom-domain>
export HOSTED_ZONE_ID=<your-route53-hosted-zone-id>
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
NAME       HUB ACCEPTED   MANAGED CLUSTER URLS                  JOINED   AVAILABLE   AGE
kmc-east   true           https://api.kmc-east...                True     True        2m
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
NAME            HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
kmc-east        true           https://api...          True     True        5m
kmc-west        true           https://api...          True     True        2m
local-cluster   true           https://api...          True     True        30m
```

## Create a ManagedClusterSet

Group the regional clusters into a ManagedClusterSet so they can be referenced as a single pool for placement decisions.

Create the ManagedClusterSet:

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: dr-clusters
EOF
```

Add both clusters to the set and mark the primary cluster as active:

```bash
oc label managedcluster ${PRIMARY_CLUSTER_NAME} \
  cluster.open-cluster-management.io/clusterset=dr-clusters \
  --overwrite

oc label managedcluster ${DR_CLUSTER_NAME} \
  cluster.open-cluster-management.io/clusterset=dr-clusters \
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

## Bind the ManagedClusterSet to GitOps

Create a ManagedClusterSetBinding in the `openshift-gitops` namespace to allow ArgoCD to use the cluster set:

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: dr-clusters
  namespace: openshift-gitops
spec:
  clusterSet: dr-clusters
EOF
```

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

Create a Placement to select all clusters in the DR cluster set. This is used by the GitOpsCluster to register both clusters as ArgoCD deployment targets:

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: all-dr-clusters
  namespace: openshift-gitops
spec:
  clusterSets:
    - dr-clusters
EOF
```

Create the GitOpsCluster resource:

```bash
cat << EOF | oc apply -f -
apiVersion: apps.open-cluster-management.io/v1beta1
kind: GitOpsCluster
metadata:
  name: gitops-cluster
  namespace: openshift-gitops
spec:
  argoServer:
    cluster: local-cluster
    argoNamespace: openshift-gitops
  placementRef:
    kind: Placement
    apiVersion: cluster.open-cluster-management.io/v1beta1
    name: all-dr-clusters
    namespace: openshift-gitops
EOF
```

Verify the clusters appear as ArgoCD cluster secrets:

```bash
oc get secrets -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster
```

You should see secrets for both managed clusters. The `application-manager` addon copies ManagedCluster labels to the cluster secrets, including the `acm-dr-active` label that the ApplicationSet uses to select the active cluster.

## Configure ACM Placement for Failover

Create the Placement that monitors cluster health. This Placement selects exactly one cluster from the `dr-clusters` set. The `Steady` prioritizer keeps the selection on the current cluster unless it becomes unreachable. The tolerations allow 30 seconds after a cluster is tainted as unreachable before the placement moves.

```bash
cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: acm-demo-placement
  namespace: openshift-gitops
spec:
  clusterSets:
    - dr-clusters
  numberOfClusters: 1
  prioritizerPolicy:
    mode: Exact
    configurations:
      - scoreCoordinate:
          type: BuiltIn
          builtIn: Steady
        weight: 3
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
      tolerationSeconds: 30
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
      tolerationSeconds: 30
EOF
```

This Placement is used for health monitoring. To see which cluster ACM considers healthy:

```bash
oc get placementdecision -n openshift-gitops \
  -l cluster.open-cluster-management.io/placement=acm-demo-placement \
  -o jsonpath='{.items[0].status.decisions[0].clusterName}'
```

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

## Create the ArgoCD ApplicationSet

The ApplicationSet uses a merge generator that combines two sources:

- **clusters**: reads ArgoCD cluster secrets, selecting all clusters in the `dr-clusters` ManagedClusterSet so the application is deployed to both clusters
- **list**: provides per-cluster configuration (region, S3 bucket, IRSA role ARN, EFS file system ID)

The merge generator joins them by cluster `name`. Because the application is deployed to both clusters, failover only requires switching DNS to the DR cluster.

The YAML is built in segments to cleanly embed the multi-line PEM certificate and key. The first heredoc writes everything up to `certificate: |`, then `sed` appends the indented PEM content directly from the cert files, and a final heredoc closes the YAML.

Create the ApplicationSet:

```bash
cat > /tmp/appset.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: acm-demo
  namespace: openshift-gitops
spec:
  goTemplate: true
  generators:
    - merge:
        mergeKeys:
          - name
        generators:
          - clusters:
              selector:
                matchLabels:
                  cluster.open-cluster-management.io/clusterset: dr-clusters
          - list:
              elements:
                - name: ${PRIMARY_CLUSTER_NAME}
                  clusterRegion: ${PRIMARY_REGION}
                  s3Bucket: ${APP_BUCKET_PRIMARY}
                  s3RoleArn: ${APP_S3_ROLE_ARN_PRIMARY}
                  efsId: ${PRIMARY_EFS}
                - name: ${DR_CLUSTER_NAME}
                  clusterRegion: ${DR_REGION}
                  s3Bucket: ${APP_BUCKET_DR}
                  s3RoleArn: ${APP_S3_ROLE_ARN_DR}
                  efsId: ${DR_EFS}
  template:
    metadata:
      name: acm-demo-{{.name}}
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

cat >> /tmp/appset.yaml << 'EOF'
      destination:
        server: "{{.server}}"
        namespace: acm-demo
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

Verify the Application was created and is syncing:

```bash
watch "oc get applications.argoproj.io -n openshift-gitops"
```

Wait until both applications show `Synced` and `Healthy`:

```
NAME                 SYNC STATUS   HEALTH STATUS
acm-demo-kmc-east1   Synced        Healthy
acm-demo-kmc-west2   Synced        Healthy
```

## Prepare DR Cluster for EFS Data Continuity

When ArgoCD deploys the application to the DR cluster, the Helm chart dynamically provisions new EFS access points for each PVC. These new access points create fresh, empty subdirectories -- the replicated data from the primary EFS lives under different paths. To ensure the DR application sees the replicated data, pre-create static PersistentVolumes on the DR cluster that point to the original data paths.

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
  name: dr-shared-flight-data
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
  name: dr-flight-data-0
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
  name: dr-flight-data-1
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
**Why static provisioning?** When the EFS CSI driver dynamically provisions a PVC, it creates a new access point with a unique subdirectory (e.g., `/acm-demo/pvc-xyz789`). The replicated data from the primary lives under the original subdirectory (e.g., `/acm-demo/pvc-abc123`). A dynamically provisioned PVC on the DR side would mount an empty directory. Static PVs with `claimRef` pre-binding ensure the DR PVCs mount the replicated data paths. The `claimRef` reserves each PV so only the named PVC can bind to it.
{{< /alert >}}

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

Watch for ACM to detect the failure. With the tuned lease duration (10s) and toleration (30s), detection takes approximately 40 seconds:

```bash
watch -n5 "echo '=== Cluster Health ===' && \
  oc get managedcluster ${PRIMARY_CLUSTER_NAME} \
    -o jsonpath='Available: {.status.conditions[?(@.type==\"ManagedClusterConditionAvailable\")].status}' && \
  echo '' && echo '' && echo '=== Placement Decision ===' && \
  oc get placementdecision -n openshift-gitops \
    -l cluster.open-cluster-management.io/placement=acm-demo-placement \
    -o jsonpath='{.items[0].status.decisions[0].clusterName}'"
```

Wait until `Available` changes from `True` to `Unknown` and the PlacementDecision switches to the DR cluster.

Because the application is already deployed to both clusters, no ArgoCD changes are needed. The DR cluster's application is already `Synced` and `Healthy`. You can verify in the ArgoCD UI that the primary cluster's application shows `Degraded` while the DR cluster's application remains `Healthy`.

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

Failing back is a manual process. The Steady prioritizer in the health-monitoring Placement keeps the selection on the DR cluster even after the primary recovers, preventing unnecessary flip-flopping.

{{< alert >}}
**Do not fail traffic back to the primary cluster until data written in the DR region has been reconciled.**

During failover, the DR EFS file system and DR S3 bucket become independent writable data stores. Writes made in the DR region are not automatically copied back to the primary region.

- **EFS:** The primary resumes using its original EFS, which does not contain writes made to the DR EFS during failover. Re-establishing replication (primary to DR) below will overwrite the DR EFS with the primary's data. In a production environment, copy or merge DR EFS data back to the primary before this step.
- **S3:** S3 Cross-Region Replication is one-directional (primary to DR). Objects written to the DR bucket during failover are not replicated back to the primary bucket (the primary bucket will return 404 for those objects). To preserve DR-written data, set up reverse replication (DR to primary) or manually sync with `aws s3 sync` before re-establishing normal replication.

For this demonstration, if no DR-side data needs to be preserved, you can restart the primary workers and re-establish primary-to-DR replication as shown below.
{{< /alert >}}

Start the primary worker instances and re-enable auto-repair:

```bash
PRIMARY_INSTANCE_IDS=($(aws ec2 describe-instances --region ${PRIMARY_REGION} \
  --filters "Name=tag:Name,Values=*${PRIMARY_CLUSTER_NAME}*worker*" \
            "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text))

aws ec2 start-instances \
  --instance-ids "${PRIMARY_INSTANCE_IDS[@]}" \
  --region $PRIMARY_REGION

for MP in $(rosa list machinepools -c $PRIMARY_CLUSTER_NAME -o json | jq -r '.[].id'); do
  rosa edit machinepool $MP --cluster $PRIMARY_CLUSTER_NAME --autorepair=true
done
```

Wait for the primary cluster to rejoin ACM. This typically takes 2-3 minutes as the klusterlet pods restart and begin sending heartbeats:

```bash
watch "oc get managedcluster ${PRIMARY_CLUSTER_NAME} \
  -o jsonpath='Available: {.status.conditions[?(@.type==\"ManagedClusterConditionAvailable\")].status}'"
```

Wait until it shows `True`.

Verify that the primary cluster's ArgoCD application has returned to `Healthy`:

```bash
watch "oc get applications.argoproj.io -n openshift-gitops"
```

Wait until `acm-demo-${PRIMARY_CLUSTER_NAME}` shows `Synced` and `Healthy`.

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
| Placement toleration expires | T+40s |
| ACM detects cluster is unhealthy | T+40s |
| DNS switch (manual) | T+45s |
| Traffic reaches DR cluster | T+75s (30s TTL) |

> **Note:** Because the application is already running on both clusters, failover requires only a DNS switch. There is no ArgoCD deployment delay. For production environments, consider using Route 53 health checks with DNS failover routing to automate the DNS switch entirely.

## Production Considerations

- **Resource overhead:** The application runs on both clusters simultaneously. For resource-intensive applications, consider whether the cost of running on both clusters is acceptable. The trade-off is faster failover (DNS-only, no deployment delay) versus higher steady-state resource consumption.
- **EFS path mapping:** Record and maintain the PVC-to-EFS access point path mapping as part of your DR runbook. In a real disaster, the primary cluster API might not be available to query. Update this mapping whenever PVCs are recreated.
- **Data reconciliation before failback:** Both EFS and S3 replication are one-directional (primary to DR). Data written during failover must be manually synced or merged back to the primary before re-establishing replication. See the [Disaster Recovery with OADP on ROSA HCP](/experts/rosa/oadp-efs-s3/) guide for detailed failback data reconciliation steps.
- **ACM hub availability:** The ACM hub is a single point of failure for failover detection. In production, deploy the hub with high availability or consider an active-passive hub configuration.
- **DNS automation:** Replace the manual DNS switch with Route 53 health checks and failover routing policies for fully automated DR.
- **Lease duration tuning:** The 10-second lease used in this guide is aggressive. For production, balance detection speed against the risk of false positives from transient network issues. A 60-second lease is a reasonable starting point.
- **EFS mount targets:** Ensure the DR cluster has EFS mount targets in all worker subnets before a disaster occurs. Creating mount targets during a failover adds delay to the recovery process.

## Cleanup

Delete the ApplicationSet:

```bash
oc delete applicationset acm-demo -n openshift-gitops
```

Delete the Placements and GitOpsCluster:

```bash
oc delete gitopscluster gitops-cluster -n openshift-gitops
oc delete placement acm-demo-placement -n openshift-gitops
oc delete placement all-dr-clusters -n openshift-gitops
```

Delete the ManagedClusterSetBinding and ManagedClusterSet:

```bash
oc delete managedclustersetbinding dr-clusters -n openshift-gitops
oc delete managedclusterset dr-clusters
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
