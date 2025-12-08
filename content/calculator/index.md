---
title: "OpenShift Network Calculator"
description: "Calculate network sizing for your OpenShift cluster"

date: '2025-12-05T0:00:00.0000'
tags: ["OSD", "Google", "ROSA", "ARO"]
authors:
  - Paul Czarkowski
---

## Overview

The OpenShift Network Calculator helps you determine the network requirements for your OpenShift cluster, specifically designed for clusters using the **OVN-Kubernetes** Container Network Interface (CNI). This tool calculates the number of pods, services, and nodes your network configuration can support, and identifies potential network conflicts with OVN-Kubernetes reserved networks.

Proper network planning is critical when deploying OpenShift clusters, as incorrect CIDR ranges can lead to IP address exhaustion, network conflicts, or connectivity issues. This calculator is particularly useful when planning deployments for:

- **ROSA** (Red Hat OpenShift Service on AWS)
- **ARO** (Azure Red Hat OpenShift)
- **OSD** (OpenShift Dedicated)
- **Self-managed OpenShift** clusters

## Understanding Network Parameters

Before using the calculator, it's important to understand what each network parameter means:

### Host Prefix

The **Host Prefix** (also called the subnet prefix length) determines how many IP addresses are allocated to each individual node in your cluster. This value splits the Cluster Network (Pod CIDR) into subnets, with each node receiving its own subnet.

- **Default value**: `23` (provides 512 IP addresses per node)
- **Range**: 1-32
- **Common values**:
  - `/23` = 512 IPs per node (suitable for most workloads)
  - `/22` = 1,024 IPs per node (for high pod density)
  - `/24` = 256 IPs per node (for smaller clusters)

### Cluster Network (Pod CIDR)

The **Cluster Network** (also called Pod CIDR) is the IP address range from which pod IP addresses are allocated. This is the primary network used by your workloads.

- **ROSA default**: `10.128.0.0/14`
- **ARO default**: `10.128.0.0/14`
- This network is used exclusively for intra-cluster pod communication

### Service Network (Service CIDR)

The **Service Network** is the IP address range used by Kubernetes Services. Each Service gets a virtual IP from this range.

- **ROSA default**: `172.30.0.0/16`
- **ARO default**: `172.30.0.0/16`
- This provides 65,536 service IP addresses

### Machine Network (Machine CIDR)

The **Machine Network** is the IP address range used by the underlying infrastructure (nodes, load balancers, etc.). This typically corresponds to your VPC or virtual network CIDR.

- **ROSA default**: `10.0.0.0/16`
- **ARO default**: Varies (typically `10.0.0.0/16` or similar)
- This should match or be a subset of your cloud provider's VPC CIDR

## OVN-Kubernetes Reserved Networks

OVN-Kubernetes uses two reserved network ranges that **must not overlap** with your cluster, service, or machine networks:

- **Join Switch**: `100.64.0.0/16`
- **Transit Switch**: `100.88.0.0/16`

The calculator automatically checks for conflicts with these reserved ranges and will alert you if any overlap is detected.

## Using the Calculator

1. **Enter your network parameters** - The calculator is pre-populated with ROSA default values, but you can modify them to match your specific requirements.

2. **Click Calculate** - The calculator will:
   - Validate your input values
   - Calculate the number of pods, services, and nodes supported
   - Determine pods per node (accounting for OVN-Kubernetes reserved IPs)
   - Check for network conflicts

3. **Review the results** - Pay special attention to:
   - **Network Conflict**: Should be "No" - if it shows "Yes", you need to adjust your CIDR ranges
   - **Nodes (Want)**: The number of nodes your configuration can support
   - **Nodes (Have)**: The number of nodes available in your machine network
   - **Pods per Node**: The actual usable pods per node (after OVN reservations)

## Important Considerations

### Network Overlap

- **Pod and Service CIDRs** can overlap between clusters if they're isolated, but should never conflict with other non-OpenShift resources on your network
- **Machine CIDR** should be unique across all environments and follow your organization's IPAM scheme
- The Machine CIDR must not overlap with OVN reserved networks (`100.64.0.0/16` and `100.88.0.0/16`)

### Pod Density

OVN-Kubernetes reserves 3 IP addresses per node for internal networking. The calculator accounts for this when calculating pods per node.

### Multi-AZ Deployments

For highly available clusters spanning multiple availability zones, ensure your Machine CIDR is large enough to accommodate nodes across all zones. Each availability zone requires its own subnet within your VPC.

### Scaling Considerations

When planning your network:
- Consider future growth - choose CIDR ranges that allow for cluster expansion
- Account for autoscaling - ensure you have enough IP space for maximum node count
- Plan for multiple clusters - if deploying multiple clusters, ensure their networks don't overlap

## Calculator

{{< network-calculator >}}

## Additional Resources

- [ROSA Network CIDR Documentation]({{< relref "/rosa/ip-addressing-and-subnets" >}})
- [OpenShift Networking Documentation](https://docs.openshift.com/container-platform/latest/networking/understanding-networking.html)
- [OVN-Kubernetes Architecture](https://docs.openshift.com/container-platform/latest/networking/ovn_kubernetes_network_provider/about-ovn-kubernetes.html)
