---
date: '2026-06-11'
title: Getting Started with Red Hat Build of Karpenter (AutoNode) on ROSA
tags: ["ROSA HCP"]
authors:
  - Kevin Collins
  - Kumudu Herath
validated_version: "4.22"
---

Red Hat build of Karpenter (AutoNode) brings workload-aware, just-in-time node provisioning to Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Planes. Instead of managing static machine pools with pre-defined instance types, Karpenter evaluates the exact CPU, memory, and scheduling constraints of pending pods and provisions the optimal EC2 instance automatically — then consolidates underutilized nodes when they are no longer needed.

This guide walks through enabling AutoNode on a ROSA HCP cluster, configuring a NodePool and EC2NodeClass, and exploring use cases including right-sizing, Spot optimization, and consolidation.

## Prerequisites

* A ROSA HCP cluster running OpenShift 4.22 or later with AutoNode enabled
* `oc` CLI authenticated to the cluster
* `rosa` CLI configured
* AWS CLI configured

## Set Environment Variables

Set your cluster name once and reuse it throughout the guide:

```bash
export CLUSTER_NAME=<your-cluster-name>
export AWS_REGION=us-east-1
```

## Deploy a Karpenter-Enabled ROSA Cluster

### Option 1 — Automated (Recommended)

Use the [terraform-rosa](https://github.com/rh-mobb/terraform-rosa) Terraform module to deploy a fully configured ROSA HCP cluster with AutoNode enabled in a single command. Set `karpenter = true` alongside your cluster variables and Terraform handles the IAM role, trust policy, cluster wiring, and default NodePool/EC2NodeClass automatically.

```bash
git clone https://github.com/rh-mobb/terraform-rosa.git
cd terraform-rosa
```

Set the required environment variables:

```bash
export TF_VAR_client_id="<OCM service account client ID>"
export TF_VAR_client_secret="<OCM service account client secret>"
export TF_VAR_admin_password="<admin password>"
export TF_VAR_developer_password="<developer password>"
```

Create a `tfvars` file:

```hcl
cluster_name         = "my-karpenter-cluster"
ocp_version          = "4.22.0"
hosted_control_plane = true
private              = false
multi_az             = true
replicas             = 3
karpenter            = true
```

Deploy:

```bash
terraform init
terraform plan -var-file=my-cluster.tfvars -out=my-cluster.plan
terraform apply my-cluster.plan
```

Terraform will create the cluster, configure the Karpenter IAM role, and apply the default `OpenshiftEC2NodeClass` and `NodePool` automatically.

### Option 2 — Manual

Follow the [official Red Hat documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html-single/cluster_administration/index#rosa-nodes-autonode-managing) to:

1. Create the Karpenter IAM policy and role
2. Tag the cluster security group with `karpenter.sh/discovery`
3. Enable AutoNode via `rosa edit cluster --autonode=enabled --autonode-iam-role-arn=<role_arn>`

## Verify AutoNode is Active

```bash
rosa describe cluster -c $CLUSTER_NAME | grep -A3 "AutoNode"
```

Expected output:
```
AutoNode:
  IAM Role ARN: arn:aws:iam::<ACCOUNT_ID>:role/<cluster-name>-karpenter
```

Log in and confirm the Karpenter CRDs are installed:

```bash
oc login <API_URL> --username admin --password <PASSWORD>

# Confirm ROSA-specific CRDs are present
oc get crd | grep karpenter

# Karpenter runs in the hosted control plane — no pods on your worker nodes
oc get pods -A | grep karpenter
# Expected: no output
```

## Configure NodePool and EC2NodeClass

ROSA uses `OpenshiftEC2NodeClass` instead of the upstream `EC2NodeClass`. ROSA automatically manages subnet and security group selectors via `karpenter.sh/discovery` tags — no manual configuration is needed in the spec.

> **Note:** If you deployed via `terraform-rosa` with `karpenter = true`, these resources are already applied. Skip to [Use Case 1](#use-case-1--basic-scale-up).

Apply the `OpenshiftEC2NodeClass`:

```bash
cat <<EOF | oc apply -f -
apiVersion: karpenter.hypershift.openshift.io/v1
kind: OpenshiftEC2NodeClass
metadata:
  name: default
spec: {}
EOF
```

Apply the `NodePool`:

```bash
cat <<EOF | oc apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        autonode: "true"
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
EOF
```

Verify both resources are ready:

```bash
oc get openshiftec2nodeclass,nodepool
```

Expected output:
```
NAME                               READY
openshiftec2nodeclass.karpenter.hypershift.openshift.io/default   True

NAME                                    NODECLASS   NODES   READY   AGE
nodepool.karpenter.sh/default           default     0       True    30s
```

`NODES: 0` is correct — Karpenter provisions nodes on demand when pods are pending.

## Create the Test Namespace

All workloads run in a dedicated namespace:

```bash
oc new-project karpenter-test
```

---

## Use Case 1 — Basic Scale-Up

Deploy a workload that exceeds current capacity and watch Karpenter provision a right-sized node automatically.

```bash
# Check nodes before starting
oc get nodes

# Check nodes before starting
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-scaleup
  namespace: karpenter-test
spec:
  replicas: 10
  selector:
    matchLabels:
      app: karpenter-scaleup
  template:
    metadata:
      labels:
        app: karpenter-scaleup
    spec:
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: "1"
            memory: "1Gi"
          limits:
            cpu: "1"
            memory: "1Gi"
EOF
```

Watch Karpenter respond:

```bash
# Terminal 1 — watch pods
watch oc get pods -n karpenter-test

# Terminal 2 — watch nodes
watch oc get nodes -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type
```

**What to observe:**
1. Pods enter `Pending` state — no capacity available on existing nodes
2. Within ~30 seconds, Karpenter detects pending pods and creates a `NodeClaim`
3. A new node joins the cluster (~2–4 minutes)
4. All pods schedule and move to `Running`

```bash
# Show the instance Karpenter selected
oc get nodes -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type

# Show the NodeClaim Karpenter created
oc get nodeclaim -o wide
```

Karpenter evaluated the total pending resource requests (10 × 1 CPU / 1Gi) and provisioned a single right-sized instance through bin-packing rather than multiple smaller nodes.

---

## Use Case 2 — Instance Type Flexibility (Right-Sizing)

Show how Karpenter selects different instance families for memory-heavy vs CPU-heavy workloads.

> **Important:** Resource requests must be large enough that workloads cannot efficiently share a single node. Karpenter always optimizes for cost — small requests will be bin-packed onto one large instance instead of provisioning specialized nodes. `topologySpreadConstraints` forces pods to spread across separate nodes.

Deploy a memory-heavy workload (12Gi per pod → drives `r`-family selection):

```bash
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: memory-intensive
  namespace: karpenter-test
spec:
  replicas: 5
  selector:
    matchLabels:
      app: memory-intensive
  template:
    metadata:
      labels:
        app: memory-intensive
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: memory-intensive
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: "500m"
            memory: "12Gi"
EOF
```

Deploy a CPU-heavy workload (6 CPU per pod → drives `c`-family selection):

```bash
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cpu-intensive
  namespace: karpenter-test
spec:
  replicas: 5
  selector:
    matchLabels:
      app: cpu-intensive
  template:
    metadata:
      labels:
        app: cpu-intensive
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: cpu-intensive
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: "6"
            memory: "1Gi"
EOF
```

After nodes provision (~3–4 minutes):

```bash
oc get nodes -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type
```

The memory workload lands on `r`-family instances; the CPU workload lands on `c`-family instances — no manual node group configuration required.

---

## Use Case 3 — Spot Instance Optimization

Show cost savings through automatic Spot instance usage.

```bash
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spot-workload
  namespace: karpenter-test
spec:
  replicas: 20
  selector:
    matchLabels:
      app: spot-workload
  template:
    metadata:
      labels:
        app: spot-workload
    spec:
      tolerations:
      - key: "karpenter.sh/interruption"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["spot"]
EOF

# Verify Spot instances are being used
oc get nodes -L karpenter.sh/capacity-type | grep spot
```

Spot instances can deliver 60–90% cost savings vs On-Demand. Karpenter monitors EC2 Spot markets across instance types and Availability Zones to find the cheapest available capacity, with automatic fallback to On-Demand when Spot is unavailable.

---

## Use Case 4 — Consolidation (Scale Down)

Show Karpenter automatically reclaiming unused capacity.

```bash
# Scale down all workloads
oc scale deployment karpenter-scaleup --replicas=2 -n karpenter-test
oc scale deployment memory-intensive --replicas=1 -n karpenter-test
oc scale deployment cpu-intensive --replicas=1 -n karpenter-test
oc scale deployment spot-workload --replicas=2 -n karpenter-test

# Watch nodes consolidate
watch oc get nodes
```

Within ~60 seconds Karpenter identifies underutilized nodes, cordons and drains them, reschedules remaining pods onto fewer nodes, and terminates the unused EC2 instances.

---

## Use Case 5 — Coexistence with Machine Pools



Karpenter-managed nodes and existing ROSA machine pool nodes run side by side in the same cluster. You can use node selectors and affinity rules to direct specific workloads to either provisioner. This enables a gradual migration — existing workloads stay on managed machine pools while new workloads adopt Karpenter at your own pace.

### View existing machine pools

```bash
rosa list machinepools -c $CLUSTER_NAME
```

### Optionally enable Cluster Autoscaler on a machine pool

To compare Karpenter with traditional Cluster Autoscaler scaling, enable autoscaling on an existing machine pool:

```bash
# Get machine pool name
MACHINE_POOL=$(rosa list machinepools -c $CLUSTER_NAME -o json | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

# Enable autoscaling on the machine pool (min 2, max 6 replicas)
rosa edit machinepool $MACHINE_POOL \
  --cluster $CLUSTER_NAME \
  --enable-autoscaling \
  --min-replicas 1 \
  --max-replicas 3
```

Verify autoscaling is enabled:

```bash
rosa describe machinepool $MACHINE_POOL -c $CLUSTER_NAME | grep -A3 "Autoscaling"
```

### Deploy a workload targeting Karpenter nodes

Karpenter-provisioned nodes carry the `autonode: "true"` label from the NodePool template. Use a `nodeSelector` to direct workloads exclusively to these nodes:

```bash
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: karpenter-only
  namespace: karpenter-test
spec:
  replicas: 5
  selector:
    matchLabels:
      app: karpenter-only
  template:
    metadata:
      labels:
        app: karpenter-only
    spec:
      nodeSelector:
        autonode: "true"
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
EOF
```

### Deploy a workload targeting machine pool nodes only

Use node affinity to ensure the workload never schedules on Karpenter-managed nodes. The replica count and CPU request are sized to exceed the available capacity of the existing machine pool nodes, which forces the Cluster Autoscaler to provision additional machine pool nodes:

```bash
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: machinepool-only
  namespace: karpenter-test
spec:
  replicas: 15
  selector:
    matchLabels:
      app: machinepool-only
  template:
    metadata:
      labels:
        app: machinepool-only
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: autonode
                operator: DoesNotExist
      containers:
      - name: app
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: "2"
            memory: "1Gi"
EOF
```

### Verify the Cluster Autoscaler scaled the machine pool

Watch for new nodes and confirm they came from the machine pool (no `autonode` label) rather than Karpenter:

```bash
# Watch nodes join — machine pool nodes will NOT have an autonode label
watch oc get nodes -L autonode,node.kubernetes.io/instance-type,karpenter.sh/capacity-type
```

Once new nodes appear, verify the pods scheduled correctly:

```bash
# Show which nodes each workload landed on
oc get pods -n karpenter-test -o wide | grep machinepool-only

# Confirm machine pool nodes have no autonode label
oc get nodes -L autonode | grep -v "autonode"
```


Confirm the machine pool replica count increased:

```bash
rosa describe machinepool $MACHINE_POOL -c $CLUSTER_NAME | grep -A5 "Autoscaling\|Replicas"
```

**What to observe:** Pods targeting machine pool nodes go `Pending` because existing nodes are full. The Cluster Autoscaler detects the unschedulable pods, scales the machine pool up, and the new nodes carry standard machine pool labels — no `autonode` label, no `karpenter.sh/nodepool` label. This confirms the two provisioners are operating independently on the same cluster.

### Verify workload placement side by side

```bash
oc get nodes -L autonode,node.kubernetes.io/instance-type,karpenter.sh/capacity-type
```

Expected result — two distinct groups of nodes:

| Node | `autonode` | Instance Type | Capacity Type | Provisioner |
|---|---|---|---|---|
| `ip-10-x-x-x` | `true` | `c7i-flex.2xlarge` | `spot` | Karpenter |
| `ip-10-x-x-x` | *(none)* | `m5.xlarge` | *(none)* | Cluster Autoscaler |

Pods from `karpenter-only` will appear on nodes with `autonode=true`; pods from `machinepool-only` will appear on machine pool nodes with no `autonode` label.

---

## Cleanup

```bash
# Delete all workloads
oc delete namespace karpenter-test


# Verify Karpenter nodes are removed
watch oc get nodes
```

After the namespace is deleted, both provisioners will reclaim their nodes automatically. Karpenter terminates its nodes within ~30 seconds of the workloads being removed (based on the `consolidateAfter: 30s` setting in the NodePool). The Cluster Autoscaler will scale the machine pool back down to its minimum replica count within a few minutes once the nodes are no longer needed.

---

## Summary

| Capability | What It Shows | Business Value |
|---|---|---|
| **Right-sizing** | CPU vs memory workloads get different instance families | No over-provisioning; pay only for what you need |
| **Spot optimization** | Batch workloads automatically use Spot | 60–90% cost reduction for fault-tolerant workloads |
| **Consolidation** | Scale down → nodes disappear in ~60s | No stranded capacity; cluster continuously optimizes |
| **Zero overhead** | No Karpenter pods in `oc get pods -A` | Hosted control plane takes the operational burden |
| **Coexistence** | Machine pool + Karpenter nodes side by side | Gradual migration, no big-bang cutover required |
| **400+ instance types** | `oc get nodes -L node.kubernetes.io/instance-type` shows variety | No manual node group configuration per instance type |

## Additional Resources

* [Red Hat build of Karpenter documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html-single/cluster_administration/index#rosa-nodes-autonode-managing)
* [terraform-rosa — Automated ROSA cluster deployment with Karpenter](https://github.com/rh-mobb/terraform-rosa)
* [Karpenter upstream project](https://karpenter.sh)
