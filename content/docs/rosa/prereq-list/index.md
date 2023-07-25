---
date: '2023-07-27'
title: Prerequisites Checklist to Deploy ROSA Cluster with STS 
tags: ["ROSA", "STS"]
authors:
  - Byron Miller
  - Connor Wooley
  - Diana Sari
---

# Prerequisites Checklist to Deploy ROSA Cluster with STS 

## Background
This is a quick checklist of prerequisites needed to spin up a classic [Red Hat OpenShift Service on AWS (ROSA)](https://developers.redhat.com/products/red-hat-openshift-service-on-aws/overview) cluster with [STS](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html). Note that this is a high level checklist and your implementation may vary. 

## Generic Prerequisites
Before proceeding futher, please refer to the official documentation [here](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-aws-prereqs.html#rosa-aws-prereqs_rosa-sts-aws-prereqs).

- AWS account:
    - You would need the following details:
        - AWS IAM User
        - AWS Access Key ID
        - AWS Secret Access Key
- AWS CLI (`aws`):
    - Install from [here](https://aws.amazon.com/cli/) if you have not already.
    - Configure the CLI:
        - Enter `aws configure` in the terminal.
        - Enter the AWS Access Key ID and press enter.
        - Enter the AWS Secret Access Key and press enter.
        - Enter the default region you want to deploy into.
        - Enter the output format you want (“table” or “json”). 
        - Verify the output by running `aws sts get-caller-identity`.
        - Ensure that the service role for ELB already exists by running `aws iam get-role --role-name "AWSServiceRoleForElasticLoadBalancing"`
            - If it does not exist, run `aws iam create-service-linked-role --aws-service-name "elasticloadbalancing.amazonaws.com"`
- Red Hat account:
    - Create one [here](https://console.redhat.com/) if you have not already.
- ROSA CLI (`rosa`): 
    - Enable ROSA from your AWS account [here](https://console.aws.amazon.com/rosa/) if you have not already.
    - Install the CLI from [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-installing-rosa.html) or from the OpenShift console [here](https://console.redhat.com/openshift/downloads#tool-rosa).
    - Enter `rosa login` in a terminal, and this will prompt you to go to the [token page](https://console.redhat.com/openshift/token/rosa) via the console.
    - Log in with your Red Hat account credentials.
    - Click the "Load token" button.
    - Copy the token and paste it back into the CLI prompt and press enter.
        - Alternatively, you can copy the full `rosa login --token=abc...` command and paste that in the terminal.
    - Verify your credentials by running `rosa whoami`.
    - Ensure you have sufficient quota by running `rosa verify quota`.
        - Please refer [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html#rosa-aws-policy-provisioned_prerequisites) for more details on AWS services provisioned for ROSA cluster. 
        - Please refer [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-required-aws-service-quotas.html#rosa-required-aws-service-quotas) for more details on AWS services quota. 
- OpenShift CLI (`oc`):
    - Install from [here](https://docs.openshift.com/container-platform/4.13/cli_reference/openshift_cli/getting-started-cli.html) or from the OpenShift console [here](https://console.redhat.com/openshift/downloads#tool-oc).
    - Verify that the OpenShift CLI has been installed correctly by running `rosa verify openshift-client`.

Once you have the above prerequisites installed and enabled, let's proceed to the next steps.


## SCP Prerequisites
In this section, we will discuss about the minimum set of effective permissions for [service control policy (SCP)](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html). 

Ensure that your organization's SCP does not restrict any of these [required permissions](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html#rosa-minimum-scp_prerequisites).


## Networking Prerequisites
Next, let's talk about the prerequisites needed from networking standpoint.

- Firewall
    - Configure your firewall to allow access to the domains and ports listed [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html#osd-aws-privatelink-firewall-prerequisites_prerequisites)
- Custom DNS
- 


## SCP Prerequisites
Ensure that your organization's [service control policy (SCP)](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html) has the minimum set of effective permissions as detailed [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html#rosa-minimum-scp_prerequisites).

- Also ensure that your organization's SCP are not more restrictive than the ones listed in the links above. 


## Networking Prerequisites
Next, let's talk about the prerequisites needed from networking standpoint.

- Firewall
    - Configure your firewall to allow access to the domains and ports listed [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html#osd-aws-privatelink-firewall-prerequisites_prerequisites)
- Custom DNS
    - If you want to use custom DNS, then ROSA installer must be able to use VPC DNS with default DHCP options so it can resolve hosts locally. 
        - To do so, run `aws ec2 describe-dhcp-options` and see if the VPC is using VPC Resolver.
        - Otherwise, the upstream DNS will need to forward the cluster scope to this VPC so the cluster can resolve internal IPs/services.

## PrivateLink Prerequisites
If you would like to deploy a PrivateLink cluster, then be sure to deploy the cluster in the pre-existing VPC (BYO VPC) and please refer [here](https://docs.openshift.com/container-platform/4.13/installing/installing_aws/installing-aws-vpc.html) for more details and below in high level:

- Create a public and private subnet for each AZ that your cluster uses.
    - Alternatively, implement transit gateway for internet/egress with appropriate routes.
- The VPC's CIDR block must contain the `Networking.MachineCIDR` range, which is the IP address for cluster machines. 
    - The subnet CIDR blocks must belong to the machine CIDR that you specify.
- The VPC must have a public internet gateway attached to it and for each AZ:
    - The public subnet requires a route to the internet gateway.
    - The public subnet requires a NAT gateway with an EIP address.
    - The private subnet requires a route to the NAT gateway in public subnet.
- The VPC must not use the `kubernetes.io/cluster/.*: owned`, `Name`, and `openshift.io/cluster` tags.
- Set both `enableDnsHostnames` and `enableDnsSupport` to `true`.
    - That way, the cluster can use the Route 53 zones that are attached to the VPC to resolve cluster’s internal DNS records.
    - If you prefer to use your own Route 53 hosted private zone, you must associate the existing hosted zone with your VPC prior to installing a cluster. 
        - You can define your hosted zone using the `platform.aws.hostedZone` field in the `install-config.yaml` file.
- Ensure that your VPCs do not have overlapping CIDRs.
- Verify route tables by running `aws ec2 describe-route-tables --filters "Name=vpc-id,Values=<vpc-id>"`. 
    - Ensure that the cluster can egress either via NAT gateway in public subnet or via transit gateway.
    - And ensure whatever UDR you would like to follow is set up.

## ROSA Prerequisites without STS 
Note that we do not discuss about the prerequisites for a classic ROSA cluster without STS in this article. And thus, if that is your preferred scenario, please refer to the official documentation [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-aws-prereqs.html).