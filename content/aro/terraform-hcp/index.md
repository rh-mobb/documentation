---
date: '2026-03-28'
title: Deploying ARO HCP with Terraform
weight: 2
tags: ["ARO", "ARO HCP", "Terraform", "Quickstarts"]
authors:
  - Paul Czarkowski
validated_version: "4.22"
---

**Azure Red Hat OpenShift with hosted control planes (ARO HCP)** runs the OpenShift control plane as a fully managed service in a Microsoft-managed subscription, separate from your worker nodes. For product overview, comparison with classic ARO, and benefits, read **[Azure Red Hat OpenShift with hosted control planes now available in public preview](https://techcommunity.microsoft.com/blog/appsonazureblog/azure-red-hat-openshift-with-hosted-control-planes-now-available-in-public-previ/4555997)** (Microsoft).

This guide covers a **public cluster** deployment (`clusters/public`): public API and ingress. For private API or ingress, use [`clusters/private`](https://github.com/rh-mobb/validated-pattern-aro-hcp/tree/main/clusters/private) and the [private cluster steps](https://rh-mobb.github.io/validated-pattern-aro-hcp/getting-started/quick-start/#private-cluster-profile) in the reference docs.

{{% alert state="warning" header="Public preview" %}}
ARO HCP is in [public preview](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster), not GA. APIs, regions, quotas, and supported features may change before GA.

**Classic ARO** (control plane in your subscription) remains fully supported and is the default GA path today: [ARO Quickstart](/experts/aro/quickstart/) or [Deploying ARO using Terraform](/experts/aro/terraform-install/).

**Technical reference (Microsoft Learn):** [Introduction](https://learn.microsoft.com/en-us/azure/openshift/intro-openshift) · [Quickstart](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster) · [Connect](https://learn.microsoft.com/en-us/azure/openshift/connect-hosted-control-planes-cluster) · [Red Hat announcement](https://www.redhat.com/en/blog/azure-red-hat-openshift-hosted-control-planes-now-available-public-preview)
{{% /alert %}}

## Terraform reference

[validated-pattern-aro-hcp](https://github.com/rh-mobb/validated-pattern-aro-hcp) is a Terraform implementation maintained by [Red Hat Cloud Experts](https://cloud.redhat.com/experts/) for production-style deployments: least-privilege managed identities and RBAC, Entra external OIDC, optional OpenShift GitOps bootstrap, and Makefile wrappers for credentials and teardown. Reference docs: [rh-mobb.github.io/validated-pattern-aro-hcp](https://rh-mobb.github.io/validated-pattern-aro-hcp/).

Microsoft's CLI and Bicep quickstarts remain the product source of truth for ARO HCP behavior and limits. Use this repo when you want a Terraform path you can fork and adapt.

## Guide overview

Work through these sections in order:

1. **[Prerequisites](#prerequisites)**: Azure subscription, clone the reference repo, install tooling, and confirm permissions.
2. **[Plan your deployment](#plan-your-deployment)**: Choose cluster settings and edit `terraform.tfvars` **before** apply. Most values are permanent.
3. **[Deploy the cluster](#deploy-the-cluster)**: Create a cluster profile and run Terraform.
4. **[Connect and configure](#connect-and-configure)**: After the cluster reaches `Succeeded`, request credentials, configure Entra console login, and verify.

## Architecture overview

You provision resources in your **customer subscription** and connect them to the **hosted control plane** in a Microsoft-managed subscription via a **delegated VNet integration subnet**. Product architecture: [Introduction to Azure Red Hat OpenShift](https://learn.microsoft.com/en-us/azure/openshift/intro-openshift).

{{< mermaid >}}
graph LR
    subgraph MS["Microsoft-managed subscription"]
        direction TB
        MSNOTE["Operated by Microsoft and Red Hat SREs"]
        subgraph HCP["Hosted control plane"]
            direction TB
            API[API server]
            ETCD[(etcd)]
            SCHED[Scheduler]
            CTRL[Controllers]
            ROUTE["OAuth, Ignition, Router"]
        end
    end

    subgraph LINK["VNet integration"]
        direction LR
        NICA[NIC]
        VINT["Delegated VNet\nintegration subnet"]
        NICB[NIC]
    end

    subgraph CS["Customer subscription"]
        direction TB
        CSNOTE["Your applications, your VNet"]
        subgraph VNET["Customer VNet"]
            direction TB
            WORK[Worker subnet]
            subgraph POOL["Node pool(s)"]
                direction TB
                W1[Worker node] --- P1[Pods]
                W2[Worker node] --- P2[Pods]
            end
        end
    end

    HCP --> NICA
    NICA --- VINT --- NICB
    NICB --> WORK
    WORK --> POOL
{{< /mermaid >}}

Conceptual deployment topology. Minimum footprint: two worker nodes.

## Prerequisites

Meet Microsoft's prerequisites first. Source: [Prepare your environment](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster#prepare-your-environment).

### Azure subscription

| Requirement | Notes |
|-------------|-------|
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | Version **2.67.0 or later** (`az --version`) |
| [ARO HCP CLI extension](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster#aro-hcp-cli-extension) | Required for `az aro hcp` commands (installed by `make setup` in the reference repo) |
| **Contributor + User Access Administrator**, or **Owner** | On the resource group or subscription where you create the cluster ([Permissions](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster#permissions)) |
| **Resource providers registered** | `Microsoft.RedHatOpenShift`, `Microsoft.Compute`, `Microsoft.Storage`, `Microsoft.Authorization` ([Register resource providers](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster#register-resource-providers)) |
| **Compute quota** | Microsoft documents **at least 20 cores** in your subscription ([Resource quota](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster#resource-quota)). Verify quota for your chosen [supported worker VM size](https://learn.microsoft.com/en-us/azure/openshift/support-policies-v4#worker-nodes) in your region |
| **Supported region** | [Preview regions](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration#choose-the-cluster-region): `australiaeast`, `brazilsouth`, `canadacentral`, `centralindia`, `eastus2`, `switzerlandnorth`, `uksouth`, `westeurope` |

Register providers (if needed):

```bash
az provider register --namespace Microsoft.RedHatOpenShift --wait
az provider register --namespace Microsoft.Compute --wait
az provider register --namespace Microsoft.Storage --wait
az provider register --namespace Microsoft.Authorization --wait
```

Check quota (adjust the VM family for your node pool SKU):

```bash
LOCATION=eastus2
az vm list-usage -l "$LOCATION" \
  --query "[?contains(name.value, 'standardDSv5Family')]" -o table
```

{{% alert state="warning" header="Quota vs. reference defaults" %}}
Microsoft's **20-core** requirement is subscription quota, not the worker vCPU count in `terraform.tfvars`. The [default quickstart](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster) uses two `Standard_D8s_v3` workers; the reference defaults to two `Standard_D4s_v6` workers. Pick a supported size and replica count that fit your workload and quota.
{{% /alert %}}

### External authentication (plan ahead)

ARO HCP uses **external OIDC authentication**. Unlike classic ARO, the built-in OpenShift OAuth server is not available ([Authentication model](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration#authentication-model)).

The reference repo creates the Entra app registration during Terraform apply when `enable_external_auth = true` (the default). The account running `apply` still needs Entra directory rights to create app registrations, not just Azure subscription RBAC. **After** the cluster is ready, apply the console OAuth secret in [Connect and configure](#connect-and-configure). See [External auth with Entra ID](https://rh-mobb.github.io/validated-pattern-aro-hcp/guides/external-auth-entra-id/) if that step fails.

### Get the reference repository

Clone the repo and install the `az aro hcp` CLI extension before planning or deploying:

```bash
git clone https://github.com/rh-mobb/validated-pattern-aro-hcp.git
cd validated-pattern-aro-hcp
make setup    # installs az aro hcp extension
```

### Operator tooling

| Tool | Minimum | When you need it |
|------|---------|------------------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.9 | Deploy step |
| `jq` | any recent | Helper scripts in the reference repo |
| [`oc`](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/cli_tools/openshift-cli-oc) | Match cluster version | After cluster create ([request admin credentials](https://learn.microsoft.com/en-us/azure/openshift/connect-hosted-control-planes-cluster)) |

### Red Hat pull secret (optional)

{{% alert state="info" %}}Optional for cluster create in the reference repo, but useful for OperatorHub and `registry.redhat.io` if you run the optional GitOps bootstrap later.{{% /alert %}}

1. Browse to <https://console.redhat.com/openshift/install/azure/aro-provisioned>
2. Download the pull secret (for example to `~/Downloads/pull-secret.txt`).
3. Restrict permissions: `chmod 600 ~/Downloads/pull-secret.txt`. Never commit this file.

## Plan your deployment

Microsoft Learn organizes ARO HCP planning into three topics. Each maps to keys in `clusters/<name>/terraform.tfvars`. **Most settings are permanent:** changing them after create requires deleting and recreating the cluster.

{{% alert state="info" %}}
Complete this section before you run `make cluster.<name>.apply`. Official Microsoft articles are the source of truth for trade-offs; the tables below show how those decisions appear in the Terraform reference.
{{% /alert %}}

### Cluster profile

This guide uses [`clusters/public`](https://github.com/rh-mobb/validated-pattern-aro-hcp/blob/main/clusters/public/terraform.tfvars). Copy it to `clusters/my-cluster` (or your chosen name); each profile has its own `terraform.tfvars` and state under `clusters/<name>/`.

Other committed profiles in the repo include [`clusters/private`](https://github.com/rh-mobb/validated-pattern-aro-hcp/tree/main/clusters/private) and [`clusters/aro-virt`](https://github.com/rh-mobb/validated-pattern-aro-hcp/tree/main/clusters/aro-virt). See the [reference docs](https://rh-mobb.github.io/validated-pattern-aro-hcp/) for those paths.

Full variable definitions: [`terraform/variables.tf`](https://github.com/rh-mobb/validated-pattern-aro-hcp/blob/main/terraform/variables.tf).

### Permanent cluster settings

Official guide: [Choose your permanent cluster settings](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration) (preview).

| Official decision | `terraform.tfvars` key | Default (reference) | Notes |
|-------------------|----------------------|---------------------|-------|
| Cluster region | `location` | `uksouth` | Must be a [preview region](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration#choose-the-cluster-region) |
| Cluster name | `cluster_name` | (required) | Prefixes RG, VNet, identities, and subnets unless overridden |
| OpenShift version stream | `cluster_version` | `4.22` | `X.Y` stream; `plan` fails if not enabled in `location` |
| Update channel | `cluster_channel` | `stable` | e.g. `stable`, `fast` |
| API server visibility | `api_visibility` | `Public` | This guide keeps `Public` ([other options](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration#choose-the-api-server-visibility)) |
| Default ingress visibility | `ingress_visibility` | `Public` | This guide keeps `Public` ([other options](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration#choose-the-default-ingress-type)) |
| etcd KMS Key Vault visibility | `vault_visibility` | `Public` | `Public` or `Private` for customer Key Vault |
| Internal image registry | `cluster_image_registry_state` | `Enabled` | `Enabled` or `Disabled` (create-time only) |
| Outbound connectivity | `outbound_type` | `LoadBalancer` | [Load Balancer only](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration#outbound-connectivity-model) |
| Red Hat pull secret | `pull_secret_path` | `../tmp/pull-secret.txt` in examples | Written to Key Vault; never commit the file |
| Entra OIDC | `enable_external_auth` | `true` | Terraform creates the Entra app at apply time; console secret is applied after cluster create |
| Extra OIDC redirect URIs | `oidc_web_redirects` | RHOAI callback by default | Reference repo only |

**Fixed in reference Terraform (not exposed as variables today):**

| Official decision | Reference behavior |
|-------------------|-------------------|
| CNI plugin | `OVNKubernetes` only ([default quickstart](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster)) |
| DNS base domain | Service-generated (`dns = {}`) |
| FIPS mode | Not exposed yet; use the [official CLI/Bicep path](https://learn.microsoft.com/en-us/azure/openshift/howto-create-custom-hosted-cluster) if required |

Example:

```hcl
location         = "eastus2"
cluster_name     = "my-cluster"
cluster_version  = "4.22"
cluster_channel  = "stable"

api_visibility     = "Public"
ingress_visibility = "Public"
vault_visibility   = "Public"

cluster_image_registry_state = "Enabled"
outbound_type                = "LoadBalancer"

pull_secret_path     = "../tmp/pull-secret.txt"
enable_external_auth = true
```

### Cluster network and node pools

Official guide: [Plan your cluster network](https://learn.microsoft.com/en-us/azure/openshift/howto-plan-cluster-network) (preview).

| Official topic | `terraform.tfvars` key | Default | Notes |
|----------------|----------------------|---------|-------|
| Machine (VNet) CIDR | `address_prefix` | `10.0.0.0/16` | Must cover all worker, integration, and optional pool subnets |
| Worker subnet | `subnet_prefix` | `10.0.0.0/24` | Default node pool unless `node_pools.<name>.subnet_id` is set |
| VNet integration subnet | `vnet_integration_subnet_prefix` | `10.0.1.0/24` | Minimum `/29` ([subnet requirements](https://learn.microsoft.com/en-us/azure/openshift/howto-plan-cluster-network#subnet-requirements)) |
| Service CIDR | `service_cidr` | `172.30.0.0/16` | Must not overlap VNet or pod CIDR |
| Pod CIDR | `pod_cidr` | `10.128.0.0/14` | Must not overlap VNet or service CIDR |
| Host prefix | `host_prefix` | `23` | `/23` per node from pod CIDR |
| Resource naming | `vnet_name`, `subnet_name`, etc. | derived from `cluster_name` | Override when integrating with existing names |
| Node pools | `node_pools` | `np-1`: 2 × `Standard_D4s_v6`, zone `1` | VM size, replicas, zones, autoscaling, taints, labels |
| Node pool patch | `node_pool_version`, `node_pool_channel` | `4.22.12`, `stable` | Align with control plane patch in the same channel |

The reference repo creates the NSG and rules from [Required network security group traffic](https://learn.microsoft.com/en-us/azure/openshift/howto-plan-cluster-network#required-network-security-group-traffic).

Example:

```hcl
address_prefix                 = "10.0.0.0/16"
subnet_prefix                  = "10.0.0.0/24"
vnet_integration_subnet_prefix = "10.0.1.0/24"
pod_cidr                       = "10.128.0.0/14"
service_cidr                   = "172.30.0.0/16"
host_prefix                    = 23

node_pool_version = "4.22.12"
node_pool_channel = "stable"

node_pools = {
  np-1 = {
    vm_size           = "Standard_D4s_v6"
    replicas          = 2
    availability_zone = "1"
  }
}
```

### Managed identities and RBAC

Official guide: [Required managed identities and role assignments](https://learn.microsoft.com/en-us/azure/openshift/concepts-managed-identities) (preview).

Microsoft documents **13 user-assigned managed identities** and their role assignments. You do not declare them in `terraform.tfvars`; the reference `modules/identities` creates them during apply.

| Responsibility | Microsoft docs | Reference repo |
|----------------|----------------|-------------------|
| Deployer RBAC | Contributor + User Access Administrator or Owner | Same; needed to create role assignments during apply |
| Managed identities | Create before cluster create | `modules/identities` in Terraform |
| External OIDC | Required for user authentication | `enable_external_auth = true`; console secret applied post-create |
| etcd customer-managed key | Key Vault, KMS key, KMS identity ([encryption strategy](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration#choose-the-cluster-encryption-strategy)) | `modules/network`; `vault_visibility` for Key Vault access |

To customize beyond the reference module, fork [validated-pattern-aro-hcp](https://github.com/rh-mobb/validated-pattern-aro-hcp) or follow [Create an ARO with hosted control planes cluster](https://learn.microsoft.com/en-us/azure/openshift/howto-create-custom-hosted-cluster).

## Deploy the cluster

From the cloned `validated-pattern-aro-hcp` directory:

### 1. Create a cluster profile

Copy the public example (see [Cluster profile](#cluster-profile)):

```bash
cp -r clusters/public clusters/my-cluster
```

### 2. Edit `terraform.tfvars`

Apply the decisions from [Plan your deployment](#plan-your-deployment). At minimum, set `location`, `cluster_name`, and `cluster_version`.

Optional: list OpenShift versions enabled in your region before `plan`, and align `cluster_version` and `node_pool_version` in `terraform.tfvars`:

```bash
make cluster.my-cluster.versions
```

`plan` fails fast if `cluster_version` is not enabled in `location`.

If you use a pull secret:

```bash
mkdir -p tmp
cp ~/Downloads/pull-secret.txt tmp/pull-secret.txt
```

Check for environment variables that override tfvars:

```bash
env | grep '^TF_VAR_' || true
```

Unset or align any `TF_VAR_*` values before apply.

### 3. Initialize, plan, and apply

```bash
make cluster.my-cluster.init
make cluster.my-cluster.plan
make cluster.my-cluster.apply
```

Wait until the cluster reaches `provisioningState: Succeeded` before continuing.

```bash
az aro hcp cluster show -g <resource_group> -n <cluster_name> --query provisioningState
```

## Connect and configure

Run these steps **after** the cluster is ready. Administrative credentials expire after [24 hours](https://learn.microsoft.com/en-us/azure/openshift/connect-hosted-control-planes-cluster#connect-to-the-cluster); re-run `kubeconfig` when they expire.

### 1. Request admin credentials

```bash
make cluster.my-cluster.kubeconfig
```

This wraps `az aro hcp cluster request-credential --admin` and writes kubeconfig to `.kube/config`.

### 2. Configure Entra console login

```bash
make cluster.my-cluster.external-auth
```

This applies the console OAuth secret for the Entra app Terraform created during apply. If this step fails with Entra permission errors, see [External auth with Entra ID](https://rh-mobb.github.io/validated-pattern-aro-hcp/guides/external-auth-entra-id/).

### 3. Verify

```bash
oc get co console
oc get clusterversion
```

The console URL from `az aro hcp cluster show` should return HTTP 200 after external-auth completes.

### 4. Optional GitOps bootstrap

Optional operators (OpenShift GitOps, Web Terminal, Compliance Operator, External Secrets):

```bash
make cluster.my-cluster.bootstrap
```

See [GitOps bootstrap](https://rh-mobb.github.io/validated-pattern-aro-hcp/guides/gitops/) in the reference repo.

## Teardown

{{% alert state="danger" %}}Do not run `terraform destroy` alone. The last node pool cannot be deleted independently ([OCPBUGS-86702](https://issues.redhat.com/browse/OCPBUGS-86702)). Use the Makefile `destroy` target.{{% /alert %}}

```bash
make cluster.my-cluster.external-auth-delete
make cluster.my-cluster.destroy
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Cluster create permission error | Insufficient RBAC | Verify [Contributor + User Access Administrator or Owner](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster#permissions). See [managed identities](https://learn.microsoft.com/en-us/azure/openshift/concepts-managed-identities) |
| Console 503 / degraded `console` CO | Console OAuth secret not applied | Run `make cluster.<name>.external-auth` after cluster is ready |
| Credential POST 404 | Cluster not ready | Wait for `provisioningState: Succeeded` |
| Admin kubeconfig expired | [24-hour TTL](https://learn.microsoft.com/en-us/azure/openshift/connect-hosted-control-planes-cluster#connect-to-the-cluster) | `make cluster.<name>.kubeconfig` again |
| Last node pool delete 409 | OCPBUGS-86702 | `make cluster.<name>.destroy` only |
| `az ad app create` insufficient privileges | User app registration disabled in tenant | Application Developer or Cloud Application Administrator role |

Extended troubleshooting: [reference README](https://github.com/rh-mobb/validated-pattern-aro-hcp#troubleshooting).

## Related guides

### Official documentation (Microsoft and Red Hat)

| Topic | Link |
|-------|------|
| Architecture overview | [Introduction to Azure Red Hat OpenShift](https://learn.microsoft.com/en-us/azure/openshift/intro-openshift) |
| Standard vs hosted control planes | [Compare architectures](https://learn.microsoft.com/en-us/azure/openshift/concepts-classic-hosted-control-planes-comparison) |
| Permanent cluster settings | [Choose your permanent cluster settings](https://learn.microsoft.com/en-us/azure/openshift/howto-choose-cluster-configuration) |
| Network planning | [Plan your cluster network](https://learn.microsoft.com/en-us/azure/openshift/howto-plan-cluster-network) |
| Managed identities and RBAC | [Required managed identities and role assignments](https://learn.microsoft.com/en-us/azure/openshift/concepts-managed-identities) |
| Create a cluster (CLI/Bicep) | [Create an ARO with hosted control planes cluster](https://learn.microsoft.com/en-us/azure/openshift/howto-create-custom-hosted-cluster) |
| Create a cluster (defaults quickstart) | [Quickstart: default hosted cluster](https://learn.microsoft.com/en-us/azure/openshift/quickstart-create-default-hosted-cluster) |
| Connect to a cluster | [Connect to an ARO with hosted control planes cluster](https://learn.microsoft.com/en-us/azure/openshift/connect-hosted-control-planes-cluster) |
| Delete a cluster | [Delete an ARO with hosted control planes cluster](https://learn.microsoft.com/en-us/azure/openshift/delete-hosted-control-planes-cluster) |

### Red Hat Cloud Experts reference (Terraform)

| Topic | Link |
|-------|------|
| Reference docs (full site) | [rh-mobb.github.io/validated-pattern-aro-hcp](https://rh-mobb.github.io/validated-pattern-aro-hcp/) |
| Private cluster profile | [Quick start (private cluster)](https://rh-mobb.github.io/validated-pattern-aro-hcp/getting-started/quick-start/#private-cluster-profile) |
| Account prerequisites and RBAC matrix | [Account prerequisites](https://rh-mobb.github.io/validated-pattern-aro-hcp/prerequisites/account/) |
| External auth (Entra ID) | [External auth guide](https://rh-mobb.github.io/validated-pattern-aro-hcp/guides/external-auth-entra-id/) |
| OpenShift Virtualization full stack | [Virt stack](https://rh-mobb.github.io/validated-pattern-aro-hcp/guides/virt-stack/) |
| Classic ARO quickstart | [ARO Quickstart](/experts/aro/quickstart/) |
| Classic ARO Terraform | [Deploying ARO using Terraform](/experts/aro/terraform-install/) |
| ROSA HCP Terraform (AWS) | [Deploying a ROSA HCP cluster with Terraform](/experts/rosa/terraform/hcp/) |
