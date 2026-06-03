---
date: '2026-03-21'
title: Configure Node Pool Scale-to-Zero on ROSA HCP
tags: ["ROSA", "ROSA HCP"]
authors:
  - Kevin Ye
---

ROSA HCP supports setting `min_replicas=0` on node pools with autoscaling enabled. This allows the cluster autoscaler to scale worker nodes down to zero when no workloads require them, and scale back up automatically when pods are scheduled. This is useful for cost optimization on development, testing, or burst-capacity node pools.

In this guide, you will:

- Create a node pool configured to scale to zero
- Deploy a test workload to trigger scale-up from zero
- Observe automatic scale-down after the workload is removed
- Learn how to troubleshoot common scale-down blockers

{{% alert state="info" %}}
Scale-to-zero is only available on **ROSA HCP** clusters. It is not supported on ROSA Classic.
{{% /alert %}}

{{% alert state="danger" %}}
ROSA HCP currently requires a minimum of **2 non-tainted worker nodes** per cluster at all times. The OCM API enforces this by requiring the sum of `min_replica` across all non-tainted node pools to be at least 2. You cannot scale all node pools to zero. Scale-to-zero is intended for **additional workload pools** (e.g. burst capacity, dev/test), while your base pools maintain the minimum worker capacity for system pods (ingress, monitoring, registry). See [Minimum Replica Constraint](#minimum-replica-constraint) for details.
{{% /alert %}}

## Prerequisites

* A [ROSA HCP cluster](../terraform/hcp) running OpenShift 4.x
* `oc` CLI logged in to the cluster
* `rosa` CLI logged in (`rosa login`)
* `ocm` CLI logged in (`ocm login`)
* `jq` installed

## Set Up Environment Variables

1. Set the cluster name and retrieve the cluster ID.

    ```bash
    export CLUSTER_NAME=<your-cluster-name>
    export CLUSTER_ID=$(rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.id')
    ```

1. List the available subnets and choose one for the node pool.

    ```bash
    rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.aws.subnet_ids[]'
    ```

    Set the subnet ID for the availability zone you want the node pool in:

    ```bash
    export SUBNET_ID=<your-chosen-subnet-id>
    ```

## Create a Node Pool with Scale-to-Zero

Scale-to-zero cannot be configured via the ROSA CLI or the Red Hat console today. You must use the OCM API or Terraform.

### Option A: OCM API

1. Create a new node pool with `min_replica=0`.

    ```bash
    ocm post /api/clusters_mgmt/v1/clusters/$CLUSTER_ID/node_pools <<EOF
    {
      "id": "zero-pool",
      "aws_node_pool": {
        "instance_type": "m5.xlarge"
      },
      "subnet": "$SUBNET_ID",
      "auto_repair": true,
      "autoscaling": {
        "min_replica": 0,
        "max_replica": 2
      },
      "labels": {
        "workload": "scale-test"
      },
      "taints": [
        {
          "key": "workload",
          "value": "scale-test",
          "effect": "NoSchedule"
        }
      ]
    }
    EOF
    ```

    {{% alert state="info" %}}The OCM API uses singular `min_replica` / `max_replica` for HCP node pools. The taint prevents system pods from landing on this node pool, which avoids scale-down blockers (explained in [Troubleshooting](#troubleshooting)).
    {{% /alert %}}

1. Verify the node pool was created and has 0 current replicas.

    ```bash
    ocm get /api/clusters_mgmt/v1/clusters/$CLUSTER_ID/node_pools/zero-pool \
      | jq '{id, autoscaling, status}'
    ```

    You should see:

    ```json
    {
      "id": "zero-pool",
      "autoscaling": {
        "min_replica": 0,
        "max_replica": 2
      },
      "status": {
        "current_replicas": 0
      }
    }
    ```

### Option B: Terraform

1. Create a `main.tf` file with the following content.

    ```hcl
    resource "rhcs_hcp_machine_pool" "zero_pool" {
      cluster   = var.cluster_id
      name      = "zero-pool"
      subnet_id = var.subnet_id

      aws_node_pool = {
        instance_type = "m5.xlarge"
      }

      autoscaling = {
        enabled      = true
        min_replicas = 0
        max_replicas = 2
      }

      labels = {
        workload = "scale-test"
      }

      taints = [
        {
          key           = "workload"
          value         = "scale-test"
          schedule_type = "NoSchedule"
        }
      ]

      auto_repair = true
    }
    ```

    {{% alert state="info" %}}
    The Terraform RHCS provider uses plural `min_replicas` / `max_replicas`.
    {{% /alert %}}

1. Apply the configuration.

    ```bash
    terraform init && terraform apply
    ```

### Enable Scale-to-Zero on an Existing Node Pool

You can also enable scale-to-zero on an existing node pool by patching it via the OCM API:

```bash
ocm patch /api/clusters_mgmt/v1/clusters/$CLUSTER_ID/node_pools/<pool-id> <<'EOF'
{
  "autoscaling": {
    "min_replica": 0,
    "max_replica": 2
  }
}
EOF
```

{{% alert state="info" %}}
This will only be accepted if the [minimum replica constraint](#minimum-replica-constraint) is still satisfied after the change.
{{% /alert %}}

## Deploy a Test Workload to Trigger Scale-Up

With the node pool at 0 nodes, deploy a workload that targets it. The cluster autoscaler will detect unschedulable pods and provision a new node.

1. Create a test namespace.

    ```bash
    oc new-project scale-test
    ```

1. Deploy an application with a `nodeSelector` and `tolerations` matching the node pool.

    ```bash
    cat <<'EOF' | oc apply -f -
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: scale-test-app
      namespace: scale-test
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: scale-test-app
      template:
        metadata:
          labels:
            app: scale-test-app
        spec:
          nodeSelector:
            workload: scale-test
          tolerations:
            - key: workload
              value: scale-test
              effect: NoSchedule
          containers:
            - name: hello
              image: registry.access.redhat.com/ubi9/ubi-minimal:latest
              command: ["sleep", "infinity"]
              resources:
                requests:
                  cpu: "500m"
                  memory: "512Mi"
                limits:
                  cpu: "1"
                  memory: "1Gi"
    EOF
    ```

1. Watch the pods. They will initially be `Pending` because no nodes match the selector.

    ```bash
    oc get pods -n scale-test -w
    ```

    You should see:

    ```
    NAME                             READY   STATUS    RESTARTS   AGE
    scale-test-app-xxxxxxxxx-xxxxx   0/1     Pending   0          10s
    scale-test-app-xxxxxxxxx-xxxxx   0/1     Pending   0          10s
    ```

1. Check the cluster autoscaler status to confirm scale-up has been triggered.

    ```bash
    oc get configmap cluster-autoscaler-status -n kube-system \
      -o jsonpath='{.data.status}' | grep -A2 'scaleUp'
    ```

    You should see:

    ```
    scaleUp:
      status: InProgress
    ```

    You can also check cluster events for the scale-up trigger:

    ```bash
    oc get events -A --field-selector reason=TriggeredScaleUp --sort-by='.lastTimestamp'
    ```

    You should see an event like:

    ```
    NAMESPACE   ...   TriggeredScaleUp   pod/scale-test-app-xxxxx   pod triggered scale-up:
    [{<node-pool-machine-deployment> 0->1 (max: 2)}]
    ```

1. In a separate terminal, watch for the new node to appear.

    ```bash
    watch -n 10 'oc get nodes -l workload=scale-test'
    ```

    After a few minutes, you should see a new node become `Ready` and the pods transition to `Running`.

    ```
    NAME                                          STATUS   ROLES    AGE   VERSION
    ip-10-x-x-x.region.compute.internal           Ready    worker   1m    v1.x.x
    ```

1. Confirm the pods are running on the new node.

    ```bash
    oc get pods -n scale-test -o wide
    ```

## Observe Scale-Down to Zero

When the workload is removed, the cluster autoscaler will detect the node as idle and eventually remove it.

1. Delete the test deployment.

    ```bash
    oc delete deployment scale-test-app -n scale-test
    ```

1. Watch the node being removed.

    ```bash
    watch -n 10 'oc get nodes -l workload=scale-test'
    ```

    The scale-down process has two phases:

    | Phase | Duration | Description |
    |---|---|---|
    | Idle assessment | ~15 minutes | Autoscaler continuously observes the node as unneeded before triggering removal |
    | Drain + removal | ~2 minutes | Pod eviction, node drain, and EC2 instance termination |

    The total time from workload deletion to node removal is typically **~17 minutes**.

    {{% alert state="info" %}}This was verified by deleting a workload from a node that had been running for over 15 minutes (ensuring any `delay_after_add` cooldown had fully expired). The ~15-minute idle assessment is a ROSA HCP platform-managed default and cannot be changed by the user.
    {{% /alert %}}

1. Verify the node pool has scaled back to 0.

    ```bash
    rosa describe machinepool -c $CLUSTER_NAME zero-pool
    ```

## Cluster Autoscaler Configuration

1. View the current autoscaler configuration.

    ```bash
    ocm get /api/clusters_mgmt/v1/clusters/$CLUSTER_ID/autoscaler | jq .
    ```

1. On ROSA HCP, the scale-down behavior uses platform-managed defaults:

    | Parameter | Observed Default | Description |
    |---|---|---|
    | Idle assessment | ~15 minutes | How long a node must be continuously idle before removal is triggered |
    | Drain + removal | ~2 minutes | Time to evict pods and terminate the EC2 instance |

    {{% alert state="warning" %}}On ROSA HCP, the `scale_down` parameters (such as `unneeded_time`, `delay_after_add`, `utilization_threshold`) **cannot be customized**. The OCM API rejects `scale_down` configuration changes with `"Attribute 'scale_down' is not allowed"`. These settings are only configurable on ROSA Classic clusters.
    {{% /alert %}}

## Minimum Replica Constraint

The OCM API enforces that the **sum of `min_replica` across all non-tainted node pools must be at least 2**. This guarantees that system pods (ingress, monitoring, image registry) always have worker nodes available.

For example, given a cluster with three non-tainted pools (`compute-0`, `compute-1`, `compute-2`) each at `min_replica=1`:

1. Setting `compute-0` to `min_replica=0` **succeeds** — the remaining pools still guarantee 2 replicas (1+1=2).

    ```bash
    ocm patch /api/clusters_mgmt/v1/clusters/$CLUSTER_ID/node_pools/compute-0 <<'EOF'
    {
      "autoscaling": { "min_replica": 0, "max_replica": 2 }
    }
    EOF
    ```

    ```json
    {
      "kind": "NodePool",
      "id": "compute-0",
      "autoscaling": { "min_replica": 0, "max_replica": 2 }
    }
    ```

1. Setting `compute-1` to `min_replica=0` **fails** — only `compute-2` at `min_replica=1` would remain, which is less than 2.

    ```bash
    ocm patch /api/clusters_mgmt/v1/clusters/$CLUSTER_ID/node_pools/compute-1 <<'EOF'
    {
      "autoscaling": { "min_replica": 0, "max_replica": 2 }
    }
    EOF
    ```

    ```json
    {
      "kind": "Error",
      "id": "400",
      "code": "CLUSTERS-MGMT-400",
      "reason": "We need to have at least 2 replicas without taints across all the node pools."
    }
    ```

**Key points:**

- Tainted node pools (e.g. pools with `NoSchedule` taints) are **excluded** from the count — system pods cannot schedule on them.
- The constraint checks the sum of `min_replica` values, not the current number of running nodes.
- You can set as many **tainted** pools to `min_replica=0` as you want — only non-tainted pools are subject to this rule.

| Pool Config | Non-tainted min_replica sum | Accepted? |
|---|---|---|
| 3 pools at min=1 | 3 | Yes |
| 1 pool at min=0, 2 pools at min=1 | 2 | Yes |
| 2 pools at min=0, 1 pool at min=1 | 1 | **No** |
| 3 pools at min=0 | 0 | **No** |

## Troubleshooting

### Check Why a Node Is Not Scaling Down

1. Check the cluster autoscaler status.

    ```bash
    oc get configmap cluster-autoscaler-status -n kube-system \
      -o jsonpath='{.data.status}' | head -20
    ```

    Look for `ScaleDown` status:
    - **`CandidatesPresent`** — the autoscaler has identified nodes to scale down and is waiting out the idle timer.
    - **`NoCandidates`** — something is preventing scale-down. Investigate further below.

1. Check for pods with `safe-to-evict=false` annotation, which blocks scale-down.

    ```bash
    oc get pods -A -o json | jq -r '
      .items[] |
      select(.metadata.annotations["cluster-autoscaler.kubernetes.io/safe-to-evict"] == "false") |
      "\(.spec.nodeName): \(.metadata.namespace)/\(.metadata.name)"
    '
    ```

    If any pods appear, they are preventing the autoscaler from draining their node. Common culprits include operators like OpenShift Pipelines (Tekton), which sets this annotation on its controller pods.

    To override the annotation on a specific pod:

    ```bash
    oc annotate pod <pod-name> -n <namespace> \
      cluster-autoscaler.kubernetes.io/safe-to-evict=true --overwrite
    ```

    {{% alert state="warning" %}}If the pod is managed by an operator, the annotation will be reset when the pod is recreated. Consider uninstalling the operator or configuring it to not set this annotation.
    {{% /alert %}}

### System Pods and PodDisruptionBudgets

System pods with PodDisruptionBudgets (PDBs) such as `router-default`, `image-registry`, and `alertmanager` generally **do not block** scale-down. The autoscaler respects PDBs during its simulation and will proceed if the pods can be safely rescheduled to other nodes.

### Anti-Affinity Cascade Locks

If you have multiple node pools that can scale to zero and many system pods with hard pod anti-affinity rules (`requiredDuringSchedulingIgnoredDuringExecution`), a circular dependency can form. When nodes scale down, evicted system pods land on remaining nodes — including workload-designated pools — and their anti-affinity rules can prevent further scale-down.

To avoid this:

- **Use taints and tolerations** on workload pools to prevent system pods from landing on them (as shown in this guide).
- **Keep at least one general-purpose pool** with `min_replicas >= 1` that is large enough to host all system pods.
- **The [minimum replica constraint](#minimum-replica-constraint) still applies** — ensure your non-tainted pools still guarantee at least 2 replicas.

## Cleanup

1. Delete the test namespace.

    ```bash
    oc delete project scale-test
    ```

1. Delete the node pool.

    Using OCM API:

    ```bash
    ocm delete /api/clusters_mgmt/v1/clusters/$CLUSTER_ID/node_pools/zero-pool
    ```

    Or using Terraform:

    ```bash
    terraform destroy
    ```

## References

- [Red Hat KB: Scale-to-Zero for ROSA HCP Node Pools](https://access.redhat.com/articles/7136402)
- [OpenShift Cluster Autoscaler Documentation](https://docs.openshift.com/container-platform/latest/machine_management/applying-autoscaling.html)
