---
date: "2023-01-06"
title: "VPC and Subnet IP Address Considerations with ROSA"
tags: ["rosa","vpc", "subnet"]
authors:
   - Thatcher Hubbard
---

# VPC and Subnet IP Address Considerations with ROSA

ROSA clusters can be built to be highly available using the fundamental capability that underlies most HA configurations on AWS: Availability Zones. By spreading the resources of a cluster across three separate (but regionally co-located) datacenters, ROSA users can ensure the cluster continues to run even if an entire AWS AZ goes down.

This capability comes with a few challenges and considerations around IP addressing that this article will attempt to explain and provide options and best practices around.

## ROSA and network CIDRs

Configuring a ROSA cluster requires the provision of three non-overlapping CIDR ranges, as is typical for any Kubernetes installation:

1. The Machine CIDR range (the range that node IP addresses are assigned from)
1. The Service CIDR range (the range that OpenShift will assign Service IPs from)
1. The Pod CIDR range (the range that OpenShift will assign Pod IPs from)

The Service and Pod CIDR ranges are typically safe to overlap with other clusters because they are used exclusively for intra-cluster communication, however they should never conflict with other non-OCP resources on your network, while they're non-routable, if they overlap with another service elsewhere on the network, they may not be able to route to that service (as the traffic will think it should stay local).

For most users, the Machine CIDR range should be unique across all environments and be assigned out of some kind of IPAM scheme.

It's also notable that while the ROSA installer requires the *specification* of the Machine CIDR range at install time, the cluster itself does nothing to configure the *assignment* or *routing* associated with that range, that is all handled by the underlying VPC resources on AWS.

Typically, the Machine CIDR range will either be the same as or a subset of the CIDR range for the VPC the cluster is being built in. 

## Subnetting

Because AWS subnets cannot span more than a single AZ, and subnetting is based on splitting up larger networks into multiples of the number '2', a lot of the habits formed around managing networks in a datacenter environment can lead to poor utilization of the IP address space.

Let's start with an example. ACME industries (has to be ACME right?), wants to build a ROSA cluster in the AWS `us-east-1` region, and they want it to be HA. The team that will operate the cluster goes to their network engineering group and requests a CIDR block for this use as dictated by ACME policy and best practice. The network engineering group assigns the block `10.0.0.0/22` in their IPAM system and the team goes forth to provision AWS resources.

ROSA clusters need to reside in a VPC with both public and private subnets, so the conventional wisdom for an HA config would dictate this VPC contain at least six subnets, three private and three public, which would traditionally be accomplished by splitting the assigned CIDR range up like so:

|Subnet address	|Netmask	        |Addresses	                |Useable IPs	                |Hosts  |
|---------------|-------------------|---------------------------|-------------------------------|-------|
|10.0.0.0/25	|255.255.255.128	|10.0.0.0 - 10.0.0.127	    |10.0.0.1 - 10.0.0.126	        |126	|
|10.0.0.128/25	|255.255.255.128	|10.0.0.128 - 10.0.0.255	|10.0.0.129 - 10.0.0.254	    |126	|
|10.0.1.0/25	|255.255.255.128	|10.0.1.0 - 10.0.1.127	    |10.0.1.1 - 10.0.1.126	        |126	|
|10.0.1.128/25	|255.255.255.128	|10.0.1.128 - 10.0.1.255	|10.0.1.129 - 10.0.1.254	    |126	|
|10.0.2.0/25	|255.255.255.128	|10.0.2.0 - 10.0.2.127	    |10.0.2.1 - 10.0.2.126	        |126	|
|10.0.2.128/25	|255.255.255.128	|10.0.2.128 - 10.0.2.255	|10.0.2.129 - 10.0.2.254	    |126	|
|10.0.3.0/25	|255.255.255.128	|10.0.3.0 - 10.0.3.127	    |10.0.3.1 - 10.0.3.126	        |126	|
|10.0.3.128/25	|255.255.255.128	|10.0.3.128 - 10.0.3.255	|10.0.3.129 - 10.0.3.254	    |126	|

This presents a couple of issues. 

First, there are only six subnets required by this ROSA cluster. This cluster doesn't rely on any AWS-native services that require their own subnets (e.g., RDS), so the `10.0.3.0/24` block (the last two lines) would go un-utilized.

Second, the need for IP address space on public subnets is limited, ACME only intends on running a couple of public ALBs in front of the cluster, which will be built so it's default Ingress is private.

Neither of these issues are necessarily problematic if a ROSA user has a sufficiently large private IP address space from which to assign CIDR blocks from. But many users have a need to build AWS infrastructure that can coexist with existing infrastructure in on-premises datacenters or even other cloud providers. It's also common for the team that owns the ROSA cluster(s) to not have direct control over CIDR block assignment and need to engineer their address space for best utilization.

## AWS VPC Capabilities

The first option to help with address range utilization is to leverage the AWS VPC capability to [assign more than a single CIDR range to the VPC](https://docs.aws.amazon.com/vpc/latest/userguide/how-it-works.html#vpc-ip-addressing). By default, VPCs can have up to 5 separate, *non-contiguous* IPv4 ranges assigned, and that quota can be adjusted upward (though making this common practice would not be recommended). Keep in mind that the minimal *subnet* size is `/28`, which is also the minimal VPC CIDR size, meaning that a VPC with a `/28` CIDR could only have a single subnet.

Using the example above, the VPC could be configured with these CIDR ranges:

1. `10.0.0.0/23` -> Covers the first four subnets
1. `10.0.2.0/24` -> Covers the next two

This would leave the `10.0.3.0/24` range to be assigned somewhere else. When the time came to build the ROSA cluster, the Machine CIDR value would be anything that's inclusive of the configured ranges, the smallest being `10.0.0.0/22`. This CIDR includes the `10.0.3.0/24` range, but because ROSA only uses the Machine CIDR range for cluster admission control and all address assignment and routing are done at the AWS Subnet level, this doesn't cause any problems.

> A good tool to help with the task of planning subnet sizes is the [Visual Subnet Calculator](https://www.davidc.net/sites/default/subnets/subnets.html)

## Different CIDR range sizes

The example directly above helps with not leaving chunks of address space unused, but doesn't address the typical question of smaller public subnet sizes vs. the private subnets. The same capability can be used to address it though. Using the same starting CIDR range:

1. The first three `/25` subnets are used for the private subnets.
1. The fourth `10.0.1.128/25` subnet is chopped up into 4 `/27` subnets with 30 assignable IPs each:
    - `10.0.1.128/27`
    - `10.0.1.160/27`
    - `10.0.1.192/27`
    - `10.0.1.224/27`

This example still provides 126 assignable IPs on each private subnet as the above examples do, but fits the entire VPC inside a `/23` instead of a `/22`. It still leaves a `/27` unused, but this could be split into two `/28` subnets in the future for use with something like RDS.

## Additional Considerations

AWS' VPC provides a lot of capability to work around IP addressing limitations, but it's a good idea to temper this with consideration for administrative and operational overhead.

1. In terms of CIDR ranges that get applied to VPCs, keep in mind that assigning multiple non-contiguous ranges to a VPC may make routing configuration from a non-AWS location (e.g., an owned datacenter) difficult to manage. It could also prevent features like route summarization from being used to their fullest effect.

1. Amazon RDS requires dedicated subnets for database instances, and it requires a minimum of 2 for any VPC that will host RDS instances. Leaving space in a VPC CIDR range for these is a good idea if there's any possibility RDS will need to be hosted in the VPC.

1. Amazon Local Zones have different requirements and limitations vs. standard AZs. Notably, they are not HA (e.g., a ROSA MachinePool in a Local Zone isn't redundant), and they also have a minimum subnet size of `/24`. Like RDS, it may make sense to try to assign or leave IP address space capacity for Local Zone utilization if there's any chance they might be needed in the future.

1. VPC CIDR ranges can be modified after creation (e.g. add another range) but it can't interfere with any existing subnet range configuration, which can make modifying an existing range (e.g. making the subnet mask smaller) require the destruction of the subnet(s) affected before the VPC can be reconfigured.

1. One VPC = One ROSA Cluster is considered best practice. It's technically possible to build multiple clusters inside of a VPC, but not recommended.





