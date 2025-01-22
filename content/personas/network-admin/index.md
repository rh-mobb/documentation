---
date: '2025-01-22'
title: I'm a Network Admin who's been asked to support ARO/ROSA
aliases: ['/personas/network-admin']
tags: ["ROSA", "OSD", "ARO"]
authors:
  - Thatcher Hubbard
---

# Managed OpenShift Networking Requirements

There are requirements specific to each cloud platform that will be covered below, but all managed OCP products require an underlying network infrastructure. This outline is intended to be a quick overview, with links to specific documents and example where appropriate. Red Hat also has cloud services specialists (Managed OpenShift Black Belts) that your account team can get you in touch with to help with anything not covered here.

- First and foremost, a VPC (AWS and GCP) or VNet (Azure) that will host the VMs that the managed service builds will be required. OpenShift has varying outbound connectivity requirements depending on the underlying cloud provider, but in general, it doesn't care *how* the traffic gets out, just that is has a route. 

- The VPC/VNet will always use private addressing and there is never a requirement for the individual nodes to have a public IP address.

- Each managed OpenShift cluster will **require** dedicated subnets inside that VPC. Best practice is to only build a single cluster in each VPC, but there is no technical prohibition against building multiples as long as they're on distinct sets of subnets.

- The size (CIDR range) of the VPC/VNet is determined primarily by how many VMs will need to be built on it, with some further allowance for private service endpoints and/or load balancer IPs. Each VM gets a single IP. 

- The IP range of your OpenShift cluster should not conflict with ranges in use on-premises or in other environments unless there's no chance the cluster or a workload deployed on it would ever need to reach those ranges.

- Intra-cluster communication uses an overlay network with two distinct IP ranges. These should not conflict with the VNet/VPC CIDR nor any in-use ranges in other environments, but they can be the same for each and every cluster you build as they are purely for internal traffic. Some customers like to carve these ranges out in their IPAM. They are also typically larger than the underlying VNet/VPC CIDR range because there are many more of them in-use at any given time.

- OpenShift will need an existing VNet/VPC to be in place and some specific parameters about it (CIDR range, VNet Ids, Subnet Ids,etc.) at the time the cluster is provisioned.

- OpenShift *can* be built with either a public or private management endpoint (OpenShift API) but outside of a PoC environment, a private endpoint is always recommended.

- Private clusters can still host public-facing workloads through a variety of cloud provider mechanisms (e.g., Azure FrontDoor, AWS CloudFront, etc.) and this is the recommended pattern.

- OpenShift will require access to the cloud provider DNS service at a VM level, but there are a variety of ways to control where it directs requests (e.g., a workload resolving a DNS name for an on-premises database server). DNS hosting for inbound traffic aside from managed endpoints like the API and the web GUI can live wherever you need it to.

## Specific Questions

1. "We direct all traffic into and out of our cloud enrivonments through a firewall, can ARO/ROSA/OSD support that?" - Yes, with the caveat that if the firewall is a transparent proxy, the CA it serves may need to be provided at the time of cluster install. In general, managed OpenShift routes as much of the managed service traffic as possible via private endpoints, so often this is more a question of supporting layered products that Red Hat provides that run on top of OCP.

1. "We use Terraform/ARM/CloudFormation/scripts to build our network environments"