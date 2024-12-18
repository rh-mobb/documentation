---
date: '2024-07-05'
title: Creating a ROSA cluster in AWS GovCloud
tags: ["AWS", "ROSA", "GovCloud"]
authors:
  - Andy Krohg
---
This guide outlines the procedure for creating a ROSA cluster in AWS GovCloud. There are some key differences between the ROSA offerings in AWS GovCloud and AWS Commercial. They’re outlined in detail in the AWS documentation [here](https://docs.aws.amazon.com/govcloud-us/latest/UserGuide/govcloud-rosa.html#govcloud-diffs), but a few requirements in GovCloud that are worth highlighting:

* Only ROSA Classic is supported (not Hosted Control Plane)
* STS mode is required
* PrivateLink is required
* FIPS mode is required

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [Rosa CLI](https://github.com/openshift/rosa/releases/tag/v1.2.39) v1.2.39
* [jq](https://stedolan.github.io/jq/download/)
* [terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
* [sshuttle](https://github.com/sshuttle/sshuttle?tab=readme-ov-file#obtaining-sshuttle)

## Create VPC and Subnets

In this guide, we’ll use Terraform to create a VPC to house our cluster, and we’ll opt for a Single-AZ configuration for simplicity. We’ll also create an EC2 jumphost to aid in accessing our cluster once it comes up. Before running it, you’ll need to ensure your AWS CLI is authenticated to a **government** region in AWS (`us-gov-west-1` or `us-gov-east-1`).

Clone the terraform git repository and `cd` into it:
```bash
git clone https://github.com/openshift/rosa-govcloud-quickstart
cd rosa-govcloud-quickstart
```

Create an SSH key pair to use for a jumphost:
```bash
ssh-keygen -f jumphost-key -q -N ""
```

Initialize and apply resources with terraform:
```bash
terraform init
terraform apply
```

Terraform will output a pre-wired command to create your ROSA cluster. We’re not ready to run it just yet, but it should look something like this:
```bash
rosa create cluster --cluster-name rosa-gc-demo --mode auto --sts \
  --machine-cidr 10.0.0.0/17 --service-cidr 172.30.0.0/16 \
  --pod-cidr 10.128.0.0/14 --host-prefix 23 --yes \
  --private-link --subnet-ids subnet-03b5943cfb7921b85
```

## Login to the FedRAMP Hybrid Cloud Console
ROSA GovCloud is a [FedRAMP High Service](https://marketplace.fedramp.gov/products/FR2102031769), so we cannot leverage the OpenShift Cluster Manager hosted at https://console.redhat.com since it does not reside within the FedRAMP boundary. Instead, we’ll utilize the FedRAMP Hybrid Cloud Console hosted at https://console.openshiftusgov.com, which requires a separate account from your usual Red Hat login. If you already have an account, login to the console and proceed with the guide. If you don’t, either contact your organization’s administrator to ask for an invite, or otherwise create a new account using our sign-up form at https://console.redhat.com/openshift/create/rosa/govcloud.

## Deploy ROSA

Authenticate with your ROSA CLI using the login command obtained [here](https://console.openshiftusgov.com/openshift/create/rosa/getstarted). Then create your cluster using the prewired `terraform` command from a previous step. If you lost it, you can output it again by running:

```bash
terraform output next_steps
```

## Test Connectivity

Set an environment variable for the cluster name you chose, e.g.:
```bash
ROSA_CLUSTER_NAME=my-gc-cluster
```

Create a ROSA admin user and make note of the generated credentials:
```bash
rosa create admin -c $ROSA_CLUSTER_NAME
```

Then create a VPN tunnel to the jumphost our terraform created earlier using the pre-wired `sshuttle` command. It should look something like this:
```bash
sshuttle --ssh-cmd 'ssh -i jumphost-key' --dns -NHr ec2-user@15.200.235.209 10.0.0.0/16
```

You should now be able to login to the console in your web browser with the credentials for your admin user and the URL:
```bash
rosa describe cluster -c $ROSA_CLUSTER_NAME -o json | jq -r .console.url
```

## Cleanup

Delete the ROSA cluster and destroy terraform assets:
```bash
rosa delete cluster -c $ROSA_CLUSTER_NAME
terraform destroy
```
