---
date: '2023-04-02'
title: Create ROSA Cluster(STS) using OCM Terraform Provider
tags: ["AWS", "ROSA", "TERRAFORM"]
---

*Author: Kumudu Herath*

This guide shows how to create a Public or Private Link STS ROSA cluster, the required operator IAM roles and the oidc provider using Red Hat [OCM Terraform Provider](https://github.com/terraform-redhat/terraform-provider-ocm). This guide also provides examples of creating other necessary components like AWS VPC, Azure App Registration for Azure AD IDP provider and Azure AD IDP for ROSA Cluster. These additional component creations can be enabled using terraform variables. The goal of this guide is to show how to create a ROSA STS cluster and how to add additional terraform modules to extend cluster provisioning using terraform automation. 

> This guide extends the official OCM ROSA Cluster TF privisioning example. Detail info can be found [here](https://github.com/terraform-redhat/terraform-provider-ocm/tree/main/examples/create_rosa_cluster/create_rosa_sts_cluster/classic_sts/cluster)

## Prerequisites

* Install [Terraform](https://www.terraform.io/downloads.html)
* OCM authentication [token](https://console.redhat.com/openshift/token)
* Install and configure `aws` cli
* Red Hat AWS Account ID for [STS Trust policies](https://docs.openshift.com/rosa/rosa_architecture/rosa-sts-about-iam-resources.html)

### Environment Setup

Variables can be passed to terraform using either Environment variables or using the terraform.tfvars file, which is placed in the directory where the terraform command executes. 

Following example shows how to configure common terraform environment variables.
   ```bash
   export TF_VAR_token="OCM TOKEN Value"
   export TF_VAR_url="https://api.openshift.com"
   export TF_LOG="DEBUG"
   export TF_LOG_PATH="logs/terraform.log"
   ```

### Usage
Following examples show how to create the terraform.tfvars file for Public and Private link ROSA STS clusters.

## Sample terraform.tfvars file for the Public ROSA STS Cluster
```
token="OCM TOKEN Value"
url="https://api.openshift.com"
redhat_aws_account_id="REDHAT AWS ACCOUNT ID"
# Module selection
create_vpc=false
create_aad_app=false
create_idp_aad=false
create_account_roles=false
#ROSA Cluster Info
account_role_prefix="ManagedOpenShift"
operator_role_prefix="mobbtf"
cluster_name="mobbtf-01"
multi_az=true
#AWS Info
aws_region="us-east-2"
availability_zones = ["us-east-2a","us-east-2b","us-east-2c"]
#Private Link Cluster
enable_private_link=false
additional_tags={
     Terraform = "true"
     TFEnvironment = "dev"
     TFOwner = "mobb@redhat.com"
     ROSAClusterName="mobbtf-01"
   }
#Azure AD app reg Info
aad_tenant_id="AZURE_Tenant_id"
```

## Sample terraform.tfvars file for the Private Link ROSA STS Cluster
```
token="OCM TOKEN Value"
url="https://api.openshift.com"
redhat_aws_account_id="REDHAT AWS ACCOUNT ID"
# Module selection
create_vpc=true
create_aad_app=false
create_idp_aad=false
create_account_roles=false
#ROSA Cluster Info
account_role_prefix="ManagedOpenShift"
operator_role_prefix="mobbtf"
cluster_name="mobbtf-01"
multi_az=true
#AWS Info
aws_region="us-east-2"
availability_zones = ["us-east-2a","us-east-2b","us-east-2c"]
#Private Link Cluster Info. Enable create_vpc to create new AWS VPC
enable_private_link=true
vpc_cidr_block="10.66.0.0/16"
private_subnet_cidrs=["10.66.1.0/24", "10.66.2.0/24", "10.66.3.0/24"]
public_subnet_cidrs=["10.66.101.0/24", "10.66.102.0/24", "10.66.103.0/24"]
additional_tags={
     Terraform = "true"
     TFEnvironment = "dev"
     TFOwner = "mobb@redhat.com"
     ROSAClusterName="mobbtf-01"
   }
#Azure AD app reg Info
aad_tenant_id="AZURE_Tenant_id"
```

## Deploy

1. Download this repo

    ```bash
    git clone https://github.com/rh-mobb/terraform_ocm_rosa_sts.git
    cd terraform_ocm_rosa_sts
    ```

1. Create terraform.tfvars as above, then run

    ```bash
    terraform init
    terraform plan
    terraform apply
    ```

## Cleanup

1. To destroy resources

    ```bash
    terraform destroy
    ```