---
date: '2023-07-27'
title: Prerequisites Checklist to Deploy ROSA Cluster with STS 
tags: ["ROSA", "STS"]
authors:
  - Byron Miller
  - Connor Wooley
  - Diana Sari
---

## Background
This is a quick checklist of prerequisites needed to spin up a classic [Red Hat OpenShift Service on AWS (ROSA)](https://developers.redhat.com/products/red-hat-openshift-service-on-aws/overview) cluster with [STS](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp.html). Note that this is a high level checklist and your implementation may vary. 

Before running the installation process, make sure that you deploy this from a machine that has access to:
- The API services for the cloud to which you provision.
- Access to `api.openshift.com` and `sso.redhat.com`. 
- The hosts on the network that you provision.
- The internet to obtain installation media.

In addition, please refer to the official documentation [here](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-aws-prereqs.html#rosa-aws-prereqs_rosa-sts-aws-prereqs) for more details of the prerequisites in general.

## Accounts and CLIs Prerequisites
First, let's discuss about the accounts and CLIs you would need to install to deploy the cluster.

### AWS account:
  - You would need the following details:
      - AWS IAM User
      - AWS Access Key ID
      - AWS Secret Access Key
  - Ensure that you have the right permissions as detailed [here](https://docs.aws.amazon.com/ROSA/latest/userguide/security-iam-awsmanpol.html) and [here](https://docs.openshift.com/rosa/rosa_architecture/rosa-sts-about-iam-resources.html)
  - Please also refer [here](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-aws-prereqs.html#rosa-account_rosa-sts-aws-prereqs) for more details. 

### AWS CLI (`aws`):
  - Install from [here](https://aws.amazon.com/cli/) if you have not already.
  - Configure the CLI:
      1. Enter `aws configure` in the terminal.
      2. Enter the AWS Access Key ID and press enter.
      3. Enter the AWS Secret Access Key and press enter.
      4. Enter the default region you want to deploy into.
      5. Enter the output format you want (“table” or “json”). 
      6. Verify the output by running `aws sts get-caller-identity`.
      7. Ensure that the service role for ELB already exists by running `aws iam get-role --role-name "AWSServiceRoleForElasticLoadBalancing"`
          - If it does not exist, run `aws iam create-service-linked-role --aws-service-name "elasticloadbalancing.amazonaws.com"`

### Red Hat account:
  - Create one [here](https://console.redhat.com/) if you have not already.

### ROSA CLI (`rosa`): 
  - Enable ROSA from your AWS account [here](https://console.aws.amazon.com/rosa/) if you have not already.
  - Install the CLI from [here](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa_getting_started_iam/rosa-installing-rosa.html) or from the OpenShift console [here](https://console.redhat.com/openshift/downloads#tool-rosa).
  - Enter `rosa login` in a terminal, and this will prompt you to go to the [token page](https://console.redhat.com/openshift/token/rosa) via the console.
  - Log in with your Red Hat account credentials.
  - Click the "Load token" button.
  - Copy the token and paste it back into the CLI prompt and press enter.
      - Alternatively, you can copy the full `rosa login --token=abc...` command and paste that in the terminal.
  - Verify your credentials by running `rosa whoami`.
  - Ensure you have sufficient quota by running `rosa verify quota`.
      - Please refer [here](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-aws-prereqs.html#rosa-aws-policy-provisioned_rosa-sts-aws-prereqs) for more details on AWS services provisioned for ROSA cluster. 
      - Please refer [here](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-required-aws-service-quotas.html) for more details on AWS services quota. 

### OpenShift CLI (`oc`):
  - Install from [here](https://docs.openshift.com/container-platform/4.13/cli_reference/openshift_cli/getting-started-cli.html) or from the OpenShift console [here](https://console.redhat.com/openshift/downloads#tool-oc).
  - Verify that the OpenShift CLI has been installed correctly by running `rosa verify openshift-client`.

Once you have the above prerequisites installed and enabled, let's proceed to the next steps.


## SCP Prerequisites
It is a best practice for the ROSA cluster to be hosted in an AWS account within an AWS Organizational Unit. A [service control policy (SCP)](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html) is created and applied to the AWS Organizational Unit that manages what services the AWS sub-accounts are permitted to access. 

- Ensure that your organization's SCP are not more restrictive than the roles and policies required by the cluster.

- Ensure that your SCP is configured to allow the required `aws-marketplace:Subscribe` permission when you choose `Enable ROSA` from the console, and please refer [here](https://docs.aws.amazon.com/ROSA/latest/userguide/troubleshoot-rosa-enablement.html#error-aws-orgs-scp-denies-permissions) for more details.

- When you create a ROSA cluster using AWS STS, an associated AWS OpenID Connect (OIDC) identity provider is created as well. 
    - This OIDC provider configuration relies on a public key that is located in the `us-east-1` AWS region. 
    - Customers with AWS SCPs must allow the use of the `us-east-1` AWS region, even if these clusters are deployed in a different region.


## Networking Prerequisites
Next, let's talk about the prerequisites needed from networking standpoint.

### Firewall
  - Configure your firewall to allow access to the domains and ports listed [here](https://docs.openshift.com/rosa/rosa_planning/rosa-sts-aws-prereqs.html#osd-aws-privatelink-firewall-prerequisites_rosa-sts-aws-prereqs)

### Custom DNS
  - If you want to use custom DNS, then ROSA installer must be able to use VPC DNS with default DHCP options so it can resolve hosts locally. 
      - To do so, run `aws ec2 describe-dhcp-options` and see if the VPC is using VPC Resolver.
      - Otherwise, the upstream DNS will need to forward the cluster scope to this VPC so the cluster can resolve internal IPs/services.

## PrivateLink Prerequisites
If you would like to deploy a PrivateLink cluster, then be sure to deploy the cluster in the pre-existing VPC (BYO VPC) and please refer [here](https://docs.openshift.com/container-platform/4.13/installing/installing_aws/installing-aws-vpc.html) for more details and below in high level:

- Create a public and private subnet for each AZ that your cluster uses.
    - Alternatively, implement transit gateway for internet/egress with appropriate routes.
- The VPC's CIDR block must contain the `Networking.MachineCIDR` range, which is the IP address for cluster machines. 
    - The subnet CIDR blocks must belong to the machine CIDR that you specify.
- Set both `enableDnsHostnames` and `enableDnsSupport` to `true`.
    - That way, the cluster can use the Route 53 zones that are attached to the VPC to resolve cluster’s internal DNS records.
- Verify route tables by running `aws ec2 describe-route-tables --filters "Name=vpc-id,Values=<vpc-id>"` 
    - Ensure that the cluster can egress either via NAT gateway in public subnet or via transit gateway.
    - And ensure whatever UDR you would like to follow is set up.
- Select `Configure a cluster-wide proxy` in the `Network configuration` page to enable an HTTP or HTTPS proxy to deny direct access to the internet from your cluster. Please refer [here](https://access.redhat.com/documentation/en-us/red_hat_openshift_service_on_aws/4/html/networking/configuring-a-cluster-wide-proxy) for more details.   

Note that you can also install a nonPrivateLink ROSA cluster in a pre-existing VPC. 

