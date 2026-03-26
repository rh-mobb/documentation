---
date: '2026-03-26'
title: ROSA HCP Quickstart
weight: 1
authors:
  - Kevin Collins
  - Deepika Ranganathan
tags: ["ROSA HCP", "Quickstarts"]
---
{{% alert state="info" %}}This guide has been validated on **OpenShift 4.20**. Operator CRD names, API versions, and console paths may differ on other versions.{{% /alert %}}
A Quickstart guide to deploying a RedHat Openshift Cluster on AWS. 

## Prerequisites

* Install [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* Install [ROSA CLI](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cli_tools/rosa-cli#rosa-get-started-cli)
* AWS Virtual private cloud (VPC) 
* Account-wide roles
* An OIDC configuration
* Operator roles

Refer [ROSA prerequisite checklist](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/prepare_your_environment/rosa-cloud-expert-prereq-checklist) for more information on permissions and quota requirements. 

### AWS CLI

1. Confirm the AWS CLI is installed.
   
    ```bash
    aws --version
    ```
    
1. Verify the CLI can authenticate to your account (prints account ID, ARN, and user ID when successful).
   
    ```bash
    aws sts get-caller-identity
    ```
    
### ROSA CLI

1. Confirm the ROSA CLI is installed.

    ```bash
    rosa version
    ```

   {{% alert state="info" %}} use ROSA CLI **1.2.48 or later** if you plan to run `rosa create network` for VPC creation.{{% /alert %}}
 
2. Authenticate the CLI with your Red Hat account so subsequent commands can reach OpenShift Cluster Manager and create AWS resources in your account on your behalf.

    ```bash
    rosa login --use-auth-code
    ```
    
### Create AWS VPC network

1. Create a VPC for ROSA cluster. The following command automates the deployment of a ROSA compliant VPC and subnets via a managed CloudFormation template, eliminating manual resource configuration.
    
    ```bash
    rosa create network --param Name=quickstart-stack --param AvailabilityZoneCount=1 --param VpcCidr=10.0.0.0/16
    ```

    {{% alert state="info" %}} Define `--param AvailabilityZoneCount=3` for multi AZ deployment.{{% /alert %}}
   
2. When the command finishes, copy the **public** and **private** subnet IDs from the printed resource summary into a comma-separated variable.

    ```bash
    export SUBNET_IDS=<public_subnet_id>,<private_subnet_id>
    ```

### Create account-wide roles

ROSA utilizes account-wide IAM roles to establish a centralized, reusable set of permissions that grant the Red Hat SRE team the specific authorizations needed to manage and support cluster infrastructure across your entire AWS account without requiring unique credentials for every individual cluster.

1. Set Environment variables

    ```bash
    export ACCOUNT_ROLES_PREFIX=<your_account_roles_prefix>
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    ```

1. Create the hosted-control-plane account roles in automatic mode.

    ```bash
    rosa create account-roles \
      --mode auto \
      --hosted-cp \
      --prefix "${ACCOUNT_ROLES_PREFIX}" \
      --yes

    export INSTALLER_ROLE_ARN=$(aws iam get-role --role-name "${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Installer-Role" --query 'Role.Arn' --output text)
    export SUPPORT_ROLE_ARN=$(aws iam get-role --role-name "${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Support-Role" --query 'Role.Arn' --output text)
    export WORKER_ROLE_ARN=$(aws iam get-role --role-name "${ACCOUNT_ROLES_PREFIX}-HCP-ROSA-Worker-Role" --query 'Role.Arn' --output text)
    ```

### Create the OIDC configuration

OIDC configuration establishes a secure, identity-based trust relationship between your AWS account and the OpenShift cluster, enabling internal components to authenticate directly with AWS IAM using short-lived tokens instead of static, long-term access keys.

1. Create OIDC config  
  ```bash
  export OIDC_ID=$(rosa create oidc-config --mode auto --yes -o json | jq -r '.id')
  ```

### Create operator roles

ROSA HCP Operator roles provide cluster-specific, fine-grained IAM permissions that allow internal OpenShift components to securely interact with AWS resources via OIDC-based authentication, ensuring each service has only the exact authorizations required for its specific function.

1. Create operator role

```bash
export OPERATOR_ROLES_PREFIX=<your_operator_roles_prefix>
    
rosa create operator-roles --hosted-cp \
      --mode auto \
      --prefix="${OPERATOR_ROLES_PREFIX}" \
      --oidc-config-id="${OIDC_ID}" \
      --installer-role-arn $INSTALLER_ROLE_ARN \
      --yes
```
    
### Cluster Creation

1. Create a ROSA HCP cluster 

```bash
export CLUSTER_NAME=<cluster_name>

rosa create cluster --cluster-name="${CLUSTER_NAME}" --mode=auto \
      --hosted-cp --operator-roles-prefix="${OPERATOR_ROLES_PREFIX}" \
      --oidc-config-id="${OIDC_ID}" --subnet-ids="${SUBNET_IDS}" \
      --role-arn="$INSTALLER_ROLE_ARN" \
      --support-role-arn="$SUPPORT_ROLE_ARN" \
      --worker-iam-role-arn="$WORKER_ROLE_ARN" \
      --yes
```
2. Check the status of your cluster.

```bash
rosa describe cluster --cluster="${CLUSTER_NAME}"
```

### Delete the cluster

When you no longer need the environment, remove the cluster to stop incurring charges.

```bash
rosa delete cluster --cluster="${CLUSTER_NAME}"
```
## Additional Resources
- [ROSA Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4)
- [Create Cluster via Terraform](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_clusters/creating-a-red-hat-openshift-service-on-aws-cluster-with-terraform)
