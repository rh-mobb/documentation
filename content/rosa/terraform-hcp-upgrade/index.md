---
date: '2026-08-05'
title: Upgrading a ROSA HCP cluster with Terraform
tags: ["ROSA", "ROSA HCP", "Terraform"]
authors:
  - Suresh Gaikwad
validated_version: "4.22"
---

Learn how to upgrade Red Hat OpenShift Service on AWS (ROSA) Hosted Control Plane (HCP) clusters with the supported Terraform RHCS provider and the `terraform-redhat/rosa-hcp` module. Upgrade the control plane first, then additional machine pools, then the default installer worker pools. Do not change channel and version in the same apply.

This is a practical day-2 guide for z-stream and y-stream upgrades with the official RHCS Terraform stack. For cluster creation, see [Deploying a ROSA HCP cluster with Terraform](/experts/rosa/terraform/hcp/).

## Why this matters

On ROSA Hosted Control Plane, the control plane and machine pools upgrade independently. The OpenShift version on a machine pool must never exceed the control plane version, and you cannot upgrade both to the same target in one Terraform apply. Teams that only bump `openshift_version` and run a full `terraform apply` often hit empty "available upgrades" lists on pools, or leave the installer-created `workers-*` pools behind while additional pools move forward.

This article follows the supported Terraform path:

* Provider: [`terraform-redhat/rhcs`](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest)
* Module: [`terraform-redhat/rosa-hcp/rhcs`](https://registry.terraform.io/modules/terraform-redhat/rosa-hcp/rhcs/latest) (and its `rosa-cluster-hcp` / `machine-pool` submodules)
* Official guides: [Upgrading HCP with Terraform](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs/guides/upgrading-hcp-cluster), [Default / worker machine pool](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs/guides/worker-machine-pool), [ROSA HCP upgrading](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/upgrading/rosa-hcp-upgrading)

## Three upgrade surfaces

| Surface | What it is | Typical Terraform resource | How to upgrade |
|--------|------------|----------------------------|--------------|
| Control plane (CP) | Hosted control plane version | `rhcs_cluster_rosa_hcp` (module `rosa-cluster-hcp`) | Change `version` / `openshift_version`, apply CP only |
| Additional machine pools | Pools you declared in Terraform after create | `rhcs_hcp_machine_pool` (module `machine-pool`) | Change each pool's `version` (or shared variable), apply after CP |
| Default machine pools | Installer-created pools (HCP: usually `workers-0`, `workers-1`, ... per AZ) | Not managed until you import them | Import into `rhcs_hcp_machine_pool`, then set `version` |

Pools may lag the control plane by up to two minor (y-stream) versions.

## Before you upgrade

### Prerequisites

* A ROSA HCP cluster managed with Terraform (`terraform-redhat/rosa-hcp` or equivalent `rhcs_cluster_rosa_hcp` / `rhcs_hcp_machine_pool` resources)
* `rosa` CLI logged in
* `terraform` CLI with access to the same state used to create the cluster

### Confirm a supported path

1. List available upgrades for the cluster and for each machine pool:

    ```bash
    rosa list upgrade --cluster <cluster_name>
    rosa list upgrade --cluster <cluster_name> --machinepool <pool_name>
    ```

    {{% alert state="info" %}}If a machine pool shows no available upgrades (`[]`) while the CP target exists, the control plane has not finished moving to a version that unlocks that pool upgrade. Wait for the CP, then retry.{{% /alert %}}

### Z-stream vs y-stream

* **Z-stream** (for example `4.21.15` to `4.21.27`): bump version only. `upgrade_acknowledgements_for` is usually not required.
* **Y-stream** (for example `4.21.z` to `4.22.z`): set channel (for example `stable-4.22`) and `upgrade_acknowledgements_for = "4.22"`, but not in the same API request as the version bump (see below).

### Acknowledge only after you validate

Setting `upgrade_acknowledgements_for` means you accept the administrative agreements for that minor upgrade. Before you set it:

* Review OpenShift / ROSA release notes and [life cycle](https://access.redhat.com/support/policy/updates/openshift) for the target y-stream
* Check API deprecations and removed APIs (operators, CRDs, GitOps manifests)
* Confirm workloads and operators support the target version

{{% alert state="warning" %}}Do not leave `upgrade_acknowledgements_for` permanently set as a standing default for every apply. Add it for the upgrade that needs it.{{% /alert %}}

## Part 1: Upgrade the control plane only

With the rosa-hcp root module (or an equivalent that wraps `modules/rosa-cluster-hcp`), target the cluster module so machine pools are not updated in the same apply.

### Z-stream example

1. Set the target version:

    ```hcl
    openshift_version = "4.21.27"
    ```

1. Apply only the cluster module:

    ```bash
    terraform apply -target='module.rosa_cluster_hcp'
    # If you call the cluster resource directly:
    # terraform apply -target='rhcs_cluster_rosa_hcp.rosa_hcp_cluster'
    ```

1. Wait until the control plane is ready:

    ```bash
    rosa describe cluster -c <cluster_name>   # OpenShift Version / State
    # or Terraform output for current_version, if exposed
    ```

### Y-stream: channel and version cannot change together

The OCM API returns:

```text
Cannot change channel and version simultaneously
```

if you update both in one request. Use two control-plane applies.

1. **Apply A: channel only** (keep the current CP version):

    ```hcl
    openshift_version            = "4.21.27"      # current CP version
    channel                      = "stable-4.22"
    upgrade_acknowledgements_for = "4.22"
    ```

    ```bash
    terraform apply -target='module.rosa_cluster_hcp'
    ```

1. **Apply B: version** (channel already `stable-4.22`):

    ```hcl
    openshift_version            = "4.22.8"       # from rosa list upgrade
    channel                      = "stable-4.22"
    upgrade_acknowledgements_for = "4.22"
    ```

    ```bash
    terraform apply -target='module.rosa_cluster_hcp'
    ```

{{% alert state="info" %}}Do not set `channel` and `version_channel_group` / `channel_group` together. Pick one channel model per the RHCS provider docs.{{% /alert %}}

## Part 2: Upgrade additional machine pools

Additional pools are the ones you created with the machine-pool submodule (or `rhcs_hcp_machine_pool` resources) after cluster create, for example GPU, metal, or extra compute pools.

After the control plane is on the target version:

1. Set each pool's `openshift_version` / `version` to the same target (or use a shared variable the module passes through).
1. For y-stream, set `upgrade_acknowledgements_for` on the pool if the provider requires it (same minor acknowledgement pattern as the cluster).
1. Apply pools only (or a full apply now that CP is done):

    ```bash
    terraform apply -target='module.rhcs_hcp_machine_pool'
    # Direct resource example:
    # terraform apply -target='rhcs_hcp_machine_pool.gpu'
    ```

1. Verify:

    ```bash
    rosa list machinepool -c <cluster_name>
    rosa describe machinepool -c <cluster_name> <pool_name>
    rosa list upgrade -c <cluster_name> --machinepool <pool_name>
    ```

You want pool **VERSION** to match the CP (or show a scheduled upgrade), and eventually "no available upgrades" once caught up.

## Part 3: Default machine pools

### What the official module does (and does not)

When you create a ROSA cluster with Terraform, a default worker machine pool is created by the installer so the cluster can become ready. After create, cluster attributes such as `compute_machine_type` / replicas on `rhcs_cluster_rosa_hcp` no longer drive day-2 pool changes.

Per the [RHCS worker machine pool guide](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs/guides/worker-machine-pool):

* You must import a machine pool resource that points at the default pool before you can change or delete it via Terraform.
* Classic docs often refer to a pool named `worker`.
* On ROSA HCP multi-AZ, you typically get one pool per AZ: `workers-0`, `workers-1`, `workers-2`, and so on, not a single `worker` name. Magic import for the name `worker` does not cover those HCP pools; use explicit `terraform import` for each.

Until you import them, bumping `openshift_version` on the cluster and on additional pools will not upgrade default `workers-*` pools. That is expected, not a Terraform bug.

### Manual steps (supported RHCS pattern)

1. List pools and note subnet / replicas / instance type:

    ```bash
    rosa list machinepool -c <cluster_name>
    rosa describe machinepool -c <cluster_name> workers-0
    ```

1. Declare `rhcs_hcp_machine_pool` resources that match live settings (names and `subnet_id` are immutable after create):

    ```hcl
    # Example for one AZ; repeat for workers-1, workers-2, ...
    resource "rhcs_hcp_machine_pool" "workers_0" {
      cluster   = <cluster_id>
      name      = "workers-0"
      replicas  = 1
      subnet_id = "<subnet-from-describe>"

      aws_node_pool = {
        instance_type = "m6a.xlarge"   # match current
        # Prefer matching live settings; some installer attrs (e.g. tags)
        # may need lifecycle ignore_changes after import
      }

      auto_repair                  = true
      version                      = var.openshift_version
      upgrade_acknowledgements_for = var.upgrade_acknowledgements_for
      ignore_deletion_error        = true
    }
    ```

1. If the provider rejects updates to installer `aws_node_pool` fields (for example tags changing from null), add:

    ```hcl
    lifecycle {
      ignore_changes = [
        aws_node_pool,
        # optionally replicas if you scale only via rosa CLI
      ]
    }
    ```

    so Terraform can still manage **version** without fighting create-time node-pool attributes.

1. Import into state (HCP import id is `cluster_id,machine_pool_id`):

    ```bash
    CLUSTER_ID=$(terraform output -raw cluster_id)   # or rosa describe cluster

    terraform import 'rhcs_hcp_machine_pool.workers_0' "${CLUSTER_ID},workers-0"
    terraform import 'rhcs_hcp_machine_pool.workers_1' "${CLUSTER_ID},workers-1"
    terraform import 'rhcs_hcp_machine_pool.workers_2' "${CLUSTER_ID},workers-2"
    ```

1. Align config with `terraform plan` until you only see intended changes (usually `version`).

1. Upgrade default pools after the CP is on the target version:

    ```bash
    terraform apply -target='rhcs_hcp_machine_pool.workers_0' \
      -target='rhcs_hcp_machine_pool.workers_1' \
      -target='rhcs_hcp_machine_pool.workers_2'
    ```

1. Confirm:

    ```bash
    rosa list machinepool -c <cluster_name>
    rosa describe machinepool -c <cluster_name> workers-0
    # Look for Version / Scheduled upgrade
    ```

### Destroy / day-2 safety tips

* ROSA requires at least one machine pool; deleting the last pool is rejected by the API. Use `ignore_deletion_error = true` when the cluster and pools are destroyed in the same root module.
* To stop managing default pools in Terraform without deleting them in AWS/OCM: `terraform state rm` the resources, then remove them from configuration. Setting a "manage default pools" flag to false while resources remain in config will plan a destroy.

## Recommended upgrade sequence

```text
[ ] rosa list upgrade: pick target version
[ ] Review release notes / API deprecations (y-stream)
[ ] CP: channel-only apply if y-stream (keep current version)
[ ] CP: version apply (-target cluster module)
[ ] Wait until CP current version == target
[ ] Additional pools: set version, terraform apply (-target machine pools)
[ ] Default workers-*: import once (if not already), then apply version
[ ] rosa list machinepool: all pools at target (or scheduled)
```

## Common errors

| Error / symptom | Meaning | Fix |
|-----------------|---------|-----|
| Pool: desired version not in available upgrades `[]` | CP not yet on a version that unlocks that pool upgrade, or CP+pools applied together | Finish CP upgrade; wait; apply pools second |
| `Cannot change channel and version simultaneously` | Channel and version in one update | Two CP applies: channel, then version |
| Missing upgrade acknowledgements | Y-stream requires admin ack | Set `upgrade_acknowledgements_for` to the target minor (for example `"4.22"`) after validating APIs |
| Default `workers-*` still on old version | Not imported / not in Terraform | Import `rhcs_hcp_machine_pool` for each pool, then set `version` |
| `Attribute aws_node_pool.tags cannot be changed` | Installer pool attrs are sticky | `lifecycle.ignore_changes` on `aws_node_pool`; manage version only |

## References

* [Upgrade ROSA HCP cluster or machine pool (RHCS Terraform)](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs/guides/upgrading-hcp-cluster)
* [Default machine pool / import guide (RHCS Terraform)](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs/guides/worker-machine-pool)
* [`rhcs_hcp_machine_pool` resource](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs/resources/hcp_machine_pool)
* [`rhcs_cluster_rosa_hcp` resource](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs/resources/cluster_rosa_hcp)
* [ROSA HCP upgrading (Red Hat docs)](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/upgrading/rosa-hcp-upgrading)
* Module: [terraform-redhat/rosa-hcp/rhcs](https://registry.terraform.io/modules/terraform-redhat/rosa-hcp/rhcs/latest)
