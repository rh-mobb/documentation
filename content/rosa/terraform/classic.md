---
date: '2024-05-20'
title: Deploying a ROSA Classic cluster with Terraform
tags: ["ROSA", "terraform"]
authors:
  - Paul Czarkowski
---

This guide will walk you through deploying a ROSA cluster using Terraform.  This is a great way to get started with ROSA and to automate the deployment of your clusters.

{{< readfile file="/content/rosa/terraform/tf-prereqs.md" markdown="true" >}}

## ROSA Classic Cluster

### Setup Using a Direct Git Clone

You can run Terraform by cloning the desired module repository directly:

1. Clone down the terraform repository

    ```bash
    git clone --depth=1 https://github.com/rh-mobb/terraform-rosa.git
    cd terraform-rosa
    ```

1. Save some environment variables

    > Note: You may want to customize some of these settings to match your needs. see the `variables.tf` file for options.

    ```bash
    export TF_VAR_token="$(jq -r .refresh_token ~/.config/ocm/ocm.json)"
    export TF_VAR_cluster_name="$(whoami)"
    export TF_VAR_admin_password='Passw0rd12345!'
    export TF_VAR_developer_password=''
    export TF_VAR_private=false
    export TF_VAR_ocp_version=4.15.11
    export TF_VAR_hosted_control_plane=false
    export TF_VAR_multi_az=false
    ```

### Setup Using a Module Repository

Alternatively, instead of directly cloning, you can use an upstream Git repository which hosts Terraform 
code as a module instead.  This is often preferred when there are many consumers of an opinionated automation 
methodology.  Additionally, this does not require any git updates as the versions and sources are specified
directly in the Terraform code:

1. Create the Terraform file which consumes the module:

    > **NOTE:** you may also use the `TF_VAR_` variables to pass variables to your new `main.tf` file as referenced
    > above.  In the below scenario. the `token` variable is the only one we are passing directly.  All others are set
    > in our `main.tf` file.

    ```bash
    mkdir -p rosa
    cd rosa
    cat <<EOF > main.tf
    variable "token" {
      type      = string
      sensitive = true
    }

    variable "admin_password" {
      type      = string
      sensitive = true
    }

    variable "cluster_name" {}

    module "rosa" {
      source = "git::https://github.com/rh-mobb/terraform-rosa.git?ref=v0.0.5"

      private              = false
      multi_az             = false
      cluster_name         = var.cluster_name
      ocp_version          = "4.15.11"
      token                = var.token
      admin_password       = var.admin_password
      developer_password   = ""
      pod_cidr             = "10.128.0.0/14"
      service_cidr         = "172.30.0.0/16"
      hosted_control_plane = false
      replicas             = 2
      max_replicas         = 4

      tags = {
        "owner" = "me"
      }
    }

    output "rosa" {
      value = module.rosa
    }
    EOF
    ```

1. Save some environment variables

    > Note: You may want to customize some of these settings to match your needs. see the `variables.tf` file for options.

    ```bash
    export TF_VAR_token="$(jq -r .refresh_token ~/.config/ocm/ocm.json)"
    export TF_VAR_admin_password='Passw0rd12345!'
    export TF_VAR_cluster_name="$(whoami)"
    ```

### Deploy and Login

Regardless of whether you use the [direct clone method](#setup-using-a-direct-git-clone) or you
[consume an upstream module](#setup-using-a-module-repository), the next steps are identical

1. Create a Plan and Apply it

    ```bash
    terraform init

    terraform plan -out tf.plan

    terraform apply tf.plan

    ```

    If everything goes to plan, after about 45 minutes you should have a cluster available to use.

    ```
    Apply complete! Resources: 0 added, 0 changed, 0 destroyed.

    Outputs:

    cluster_api_url = "https://api.pczarkow-virt.nga3.p3.openshiftapps.com:443"
    oidc_config_id = "2b607a5ufsjc51g41ul07k5vj12v7ivb"
    oidc_endpoint_url = "2b607a5ufsjc51g41ul07k5vj12v7ivb"
    private_subnet_azs = tolist([
      "us-east-1a",
    ])
    private_subnet_ids = tolist([
      "subnet-09adee841dd979fdb",
    ])
    public_subnet_azs = tolist([
      "us-east-1a",
    ])
    public_subnet_ids = tolist([
      "subnet-0dca7ed3cddf65d87",
    ])
    vpc_id = "vpc-0df19c93b93721ada"
    ```

1. Log into OpenShift

    ```bash
    oc login $(rosa describe cluster -c $TF_VAR_cluster_name -o json | jq -r '.api.url') \
            --username admin --password $TF_VAR_admin_password
    ```
