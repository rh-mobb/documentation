---
date: '2024-05-20'
title: Deploying a ROSA HCP cluster with Terraform
tags: ["ROSA", "terraform", "hcp"]
authors:
  - Paul Czarkowski
---

This guide will walk you through deploying a ROSA cluster using Terraform.  This is a great way to get started with ROSA and to automate the deployment of your clusters.

{{< readfile file="/content/rosa/terraform/tf-prereqs.md" markdown="true" >}}

## HCP ROSA Cluster

1. Clone down the terraform repository

    ```bash
    git clone --depth=1 https://github.com/rh-mobb/terraform-rosa.git
    cd terraform-rosa
    ```

1. Save some environment variables

    > Note: You may want to customize some of these settings to match your needs. see the `variables.tf` file for options.

    ```bash
    export TF_VAR_token="$(jq -r .refresh_token ~/.config/ocm/ocm.json)"
    export TF_VAR_cluster_name="$(whoami)-hcp"
    export TF_VAR_admin_password='Passw0rd12345!'
    export TF_VAR_developer_password=''
    export TF_VAR_private=false
    export TF_VAR_ocp_version=4.15.11
    export TF_VAR_hosted_control_plane=true
    export TF_VAR_multi_az=true
    ```

3. Create a Plan and Apply it

    ```bash
    terraform init

    terraform plan -out tf.plan

    terraform apply tf.plan

    ```

    If everything goes to plan, after about 20 minutes you should have a cluster available to use.

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
    oc login $(terraform output -raw cluster_api_url) \
            --username admin --password $TF_VAR_admin_password

    ```
