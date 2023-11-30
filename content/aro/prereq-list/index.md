---
date: '2023-11-30'
title: Prerequisites Checklist to Deploy ARO Cluster
tags: ["ARO"]
authors:
  - Ricardo Macedo Martins
---

Before deploying an ARO cluster, ensure you meet the following prerequisites:

## Setup Tools

- **Install Azure CLI**: Essential for managing Azure resources. Refer to the [oficial documentation](https://learn.microsoft.com/cli/azure/install-azure-cli)

## Verify Resources

- **Core Quota**: [Confirm availability of at least 40 cores](https://learn.microsoft.com/azure/quotas/per-vm-quota-requests) to create and run an OpenShift Cluster.

## Permissions

- **RBAC Settings**:
  - Ensure you have **Contributor** and **User Access Administrator** roles on the cluster resource group.
  - Assign **Network Contributor** role on the virtual network, if using a separate resource group.
  - For stricter security policies, [create a custom role](https://learn.microsoft.com/azure/role-based-access-control/custom-roles) with necessary permissions. [Reference link](https://docs.openshift.com/container-platform/4.14/installing/installing_azure/installing-azure-account.html#minimum-required-permissions-ipi-azure_installing-azure-account).
- **Microsoft Entra (Former Azure AD)**:
  - Have a member user of the tenant or a guest with **Application administrator** role for the tooling to create an application and service principal on your behalf for the cluster.
- **Terraform**: If you plan to use Terraform for the deployment of the cluster, [see here](https://github.com/rh-mobb/terraform-aro-permissions) the required permissions.

## Azure Integration

- **Resource Provider**:
  - Register the `Microsoft.RedHatOpenshift` resource provider. [Reference link](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-providers-and-types#register-resource-provider).
- **Red Hat Integration**:
  - Obtain a [Red Hat pull secret](https://console.redhat.com/openshift/install/azure/aro-provisioned) (Recommended for access to additional content like Operators and Container Registries).

## Domain Configuration 

This step is optional since you can use the built-in domain. 

- **Custom Domain**:
  - Post-cluster creation, configure two DNS A records for the specified domain:
    - `api` pointing to the API server IP.
    - `*.apps` pointing to the ingress IP.
  - Retrieve IP addresses using: `az aro show -n -g --query '{"api":apiserverProfile.ip, "ingress":ingressProfiles[0].ip}'`.
  - Access OpenShift console via `https://console-openshift-console.apps.example.com` (instead of the built-in domain https://console-openshift-console.apps.<random>.<location>.aroapp.io)
  - If using custom DNS, set up a [custom CA for your ingress controller](https://docs.openshift.com/container-platform/4.6/security/certificates/replacing-default-ingress-certificate.html) and [API server](https://docs.openshift.com/container-platform/4.6/security/certificates/api-server.html).

## Network Configuration

- **Virtual Network**:
  - Create or provide a VNet with two subnets for master and worker nodes.
  - Ensure Pod and Service Network CIDRs do not overlap with other network ranges. [Reference link.](https://learn.microsoft.com/azure/openshift/concepts-networking#networking-for-azure-red-hat-openshift)
- **Outbound Traffic**:
  - Default deployment is with `outboundType: LoadBalancer`, meaning that a Public IP is associated with the Load Balancer for the cluster egress connectivity.
  - To restrict Internet Egress, set `--outbound-type` to `UserDefinedRouting`.
  - Consider use a Firewall solution from your choice or Azure native solutions like Azure Firewall or NAT Gateway for enhanced security. [Reference link](https://learn.microsoft.com/azure/openshift/howto-create-private-cluster-4x#create-a-private-cluster-without-a-public-ip-address).

## Cluster Creation

- **Egress Lockdown**:
  - Note that ARO clusters do not require Internet connectivity. Learn about [Egress Lockdown](https://learn.microsoft.com/azure/openshift/concepts-egress-lockdown).
  - All of the required connections for an ARO cluster are proxied through the service, see the [list of endpoints here](https://learn.microsoft.com/azure/openshift/howto-restrict-egress#endpoints-proxied-through-the-aro-service).
- **Create the Cluster**:
  - Proceed to [create your ARO cluster](/aro/private-cluster/) once all prerequisites are met.

For a detailed step-by-step guide on creating your ARO cluster, refer to the official [ARO documentation](https://learn.microsoft.com/en-us/azure/openshift/).
