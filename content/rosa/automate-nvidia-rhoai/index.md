---
date: '2025-07-15'
title: Deploy ROSA + Nvidia GPU + RHOAI with Automation
tags: ["AWS", "ROSA", "GPU", "RHOAI"]
authors:
  - Kevin Collins
---

Getting Red Hat OpenShift AI up and running with NVIDIA GPUs on a Red Hat OpenShift Service on AWS (ROSA) cluster can involve a series of detailed steps, from installing various operators to managing dependencies. While manageable, this process can be time-consuming when you're eager to start leveraging OpenShift AI for your projects.

This guide and its accompanying Git repository are designed to streamline your setup significantly. We focus on getting you productive faster by using Terraform to deploy a ROSA cluster with GPUs from the start. From there, Ansible scripts take over, automating the deployment and configuration of all necessary operators for both NVIDIA GPUs and Red Hat OpenShift AI. This means less manual configuration for you and more time spent on what matters: innovating with AI.

## Prerequisites

* terraform
* git
* ansible cli

## Create a Red Hat Hybrid Cloud Console Service Account

Please refer to this [guide](https://docs.redhat.com/en/documentation/red_hat_hybrid_cloud_console/1-latest/html/creating_and_managing_service_accounts/proc-ciam-svc-acct-overview-creating-service-acct#proc-ciam-svc-acct-create-creating-service-acct) to create a service account to be used to create the cluster.

>Note: Make sure to add the service account to a group that has 'OCM cluster provisioner' access.  Refer to this [guide](https://docs.redhat.com/en/documentation/red_hat_hybrid_cloud_console/1-latest/html/creating_and_managing_service_accounts/proc-ciam-svc-acct-overview-creating-service-acct#proc-ciam-svc-acct-rbac-creating-service-acct) on adding a service account to a group.


## Set Environment Variables

Set and adjust the following variables to meet your requirements

```bash
export TF_VAR_client_secret="OCM Service Account Client Secret"
export TF_VAR_client_id="OCM Service Account Client ID"
export TF_VAR_cluster_name="rosa-rhoai"
export TF_VAR_ocp_version=4.19.2
export TF_VAR_private=false
export TF_VAR_compute_machine_type=m5.8xlarge
export TF_VAR_gpu_machine_type=g5.4xlarge
export TF_VAR_admin_password=<admin password>
export TF_VAR_developer_password=<developer password>
export TF_VAR_hosted_control_plane=true
export TF_VAR_multi_az=true
export TF_VAR_region=<AWS Region>
```

## Create the ROSA cluster

The ROSA cluster will be created with the following:

* A second machine pool with Nvidia GPU worker nodes
* Deploys Node Feature Discovery (NFD) Operator
* Deploys NVIDIA GPU Operator
* Deploys OpenShift Serverless Operator
* Deploys Service Mesh Operator
* Deploys Authorino Operator
* Deploys and Configures Red Hat OpenShift AI
* Deploys and Configures Accelerator Profile


### Clone the git repository

```bash
git clone https://github.com/rh-mobb/terraform-rosa-rhoai
```

### Run terraform to deploy

```bash
terraform init && \
  terraform plan -out tf.plan && \
  terraform apply tf.plan
```

