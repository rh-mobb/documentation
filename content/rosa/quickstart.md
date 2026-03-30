---
date: '2026-03-26'
title: Red Hat OpenShift Service on AWS (ROSA) Quickstart
weight: 1
authors:
  - Kevin Collins
  - Deepika Ranganathan
  - Michael McNeill
tags: ["ROSA HCP", "Quickstarts"]
---
{{% alert state="info" %}}This guide has been validated on **OpenShift 4.20**. Operator CRD names, API versions, and console paths may differ on other versions.{{% /alert %}}

Follow this guide to quickly create a Red Hat OpenShift Service on AWS (ROSA) cluster using the ROSA command-line interface (CLI), grant user access, deploy your first application, and learn how to revoke user access and delete your cluster.

## Prerequisites

* A Red Hat account.
* An AWS account.
* Install the latest [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and log in to your AWS account.
* Install the latest [ROSA CLI](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cli_tools/rosa-cli#rosa-get-started-cli).
* You must have the required service quotas set for Amazon EC2, Amazon VPC, Amazon EBS, and Elastic Load Balancing.

Refer to the [prerequisite checklist for deploying](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/prepare_your_environment/rosa-cloud-expert-prereq-checklist) for more information on permissions and quota requirements. 

### Enable the ROSA Service

To create a ROSA cluster, you must enable the ROSA service in the AWS ROSA console. The AWS ROSA console verifies if your AWS account has the necessary AWS Marketplace permissions, service quotas, and the Elastic Load Balancing (ELB) service-linked role named `AWSServiceRoleForElasticLoadBalancing`. If any of these prerequisites are missing, the console provides guidance on how to configure your account to meet them.

1. Navigate to the [AWS Management Console's ROSA landing page](https://console.aws.amazon.com/rosa).
2. Select **Get started**.
3. On the "Verify ROSA prerequisites" page, select **I agree to share my contact information with Red Hat**.
4. Select **Enable ROSA**.

### CLI Validation

1. Verify that the AWS CLI is successfully authenticated to your account:
   
    ```bash
    aws sts get-caller-identity
    ```

    *Example output:*
    ```json
    {
        "UserId": "AIDASAMPLEUSERID",
        "Account": "123456789012",
        "Arn": "arn:aws:iam::123456789012:user/DevAdmin"
    }
    ```
 
2. Log in to the ROSA CLI with your Red Hat account:

    ```bash
    rosa login --use-auth-code
    ```

    This command opens a new browser window to authenticate with the OpenShift Cluster Manager. Once your login is successful, you will receive a success message in your web browser and a confirmation in your terminal.

    *Example terminal output:*
    ```text
    I: Token received successfully
    I: Logged in as 'user@example.com' on '[https://api.openshift.com](https://api.openshift.com)'
    I: To switch accounts, logout from [https://sso.redhat.com](https://sso.redhat.com) and run `rosa logout` before attempting to login again
    ```

## Create the required IAM roles and OpenID Connect configuration

Before creating a ROSA with Hosted Control Planes (HCP) cluster, you must create the necessary IAM roles, policies, and the OpenID Connect (OIDC) configuration. For more information about IAM roles and policies for ROSA with HCP, see the [AWS managed policies for ROSA](https://docs.aws.amazon.com/rosa/latest/userguide/security-iam-awsmanpol.html).

This procedure uses the auto mode of the ROSA CLI to automatically create the IAM roles and OIDC configuration necessary for cluster creation.

### Create account IAM roles

ROSA utilizes account-wide IAM roles to establish a centralized, reusable set of permissions required for Red Hat Site Reliability Engineering (SRE) technical support, cluster installation, and control plane and compute functionality.

1. Create the ROSA account roles:

    {{% alert state="info" %}}By default, account roles use the `ManagedOpenShift` prefix. If you prefer to change this, run the following command, replacing `<account-roles-prefix>` with your desired prefix: 
    `export ACCOUNT_ROLES_PREFIX=<account-roles-prefix>`
    {{% /alert %}}

    ```bash
    rosa create account-roles \
      --mode auto \
      --hosted-cp \
      --prefix "${ACCOUNT_ROLES_PREFIX:-ManagedOpenShift}" \
      --yes

    export INSTALLER_ROLE_ARN=$(aws iam get-role --role-name "${ACCOUNT_ROLES_PREFIX:-ManagedOpenShift}-HCP-ROSA-Installer-Role" --query 'Role.Arn' --output text)
    export SUPPORT_ROLE_ARN=$(aws iam get-role --role-name "${ACCOUNT_ROLES_PREFIX:-ManagedOpenShift}-HCP-ROSA-Support-Role" --query 'Role.Arn' --output text)
    export WORKER_ROLE_ARN=$(aws iam get-role --role-name "${ACCOUNT_ROLES_PREFIX:-ManagedOpenShift}-HCP-ROSA-Worker-Role" --query 'Role.Arn' --output text)
    ```

### Create the OIDC configuration

The AWS Security Token Service (STS) is an AWS service that grants temporary, limited-privilege credentials for accessing AWS resources. Unlike permanent IAM credentials that can last indefinitely, STS issues credentials that automatically expire after a set time, reducing the risk of unauthorized access. ROSA uses a Red Hat-managed OIDC configuration to establish a secure, identity-based trust relationship between your AWS account and the ROSA cluster.

1. Create the OIDC configuration:
    ```bash
    export OIDC_ID=$(rosa create oidc-config --mode auto --yes -o json | jq -r '.id')
    ```

    {{% alert state="info" %}}By default, ROSA creates a Red Hat-managed OIDC provider for federation. If you prefer to use a customer-hosted OIDC provider, please see the [Red Hat documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/rosa-hcp-about-iam-resources#rosa-byo-odic-overview_rosa-sts-about-iam-resources).{{% /alert %}}

### Create operator roles

Operator roles are used to obtain the temporary permissions required to carry out cluster operations, such as managing back-end storage, cloud ingress controllers, and external access to a cluster. 

When you create operator roles, AWS Managed Policies are automatically attached to them. ROSA always uses the latest version of these managed policies, meaning you do not need to manage or schedule upgrades for them. 

1. Create the operator roles:

    ```bash
    export OPERATOR_ROLES_PREFIX=<operator-roles-prefix>
        
    rosa create operator-roles --hosted-cp \
        --mode auto \
        --prefix="${OPERATOR_ROLES_PREFIX}" \
        --oidc-config-id="${OIDC_ID}" \
        --installer-role-arn="${INSTALLER_ROLE_ARN}" \
        --yes
    ```

    {{% alert state="info" %}}Replace `<operator-roles-prefix>` with your preferred prefix for the created AWS IAM roles.{{% /alert %}}

### Create the AWS VPC network

{{% alert state="info" %}}This example uses the ROSA CLI to create a cluster network and associated resources. You may opt to create your VPC using your preferred method.{{% /alert %}}

1. Using the ROSA CLI, the following command automates the deployment of a ROSA-compliant VPC and subnets via a managed CloudFormation template, eliminating the need for manual resource configuration:
    
    ```bash
    rosa create network --param Name=quickstart-stack --param AvailabilityZoneCount=1 --param VpcCidr=10.0.0.0/16
    ```

    {{% alert state="info" %}}Define `--param AvailabilityZoneCount=3` for a multi-AZ deployment.{{% /alert %}}
   
2. When the command finishes, copy the **public** and **private** subnet IDs from the printed resource summary into a comma-separated variable:

    ```bash
    export SUBNET_IDS=<public_subnet_id>,<private_subnet_id>
    ```
    
### Cluster Creation

1. Create a ROSA cluster using the configuration provided above:

    ```bash
    export CLUSTER_NAME=<cluster_name>

    rosa create cluster --cluster-name="${CLUSTER_NAME}" --mode=auto \
        --hosted-cp --operator-roles-prefix="${OPERATOR_ROLES_PREFIX}" \
        --oidc-config-id="${OIDC_ID}" --subnet-ids="${SUBNET_IDS}" \
        --role-arn="${INSTALLER_ROLE_ARN}" \
        --support-role-arn="${SUPPORT_ROLE_ARN}" \
        --worker-iam-role-arn="${WORKER_ROLE_ARN}" \
        --create-admin-user \
        --yes
    ```

    {{% alert state="info" %}}Replace `<cluster-name>` with your preferred cluster name.{{% /alert %}}

2. Check the status of your cluster:

    ```bash
    rosa describe cluster --cluster="${CLUSTER_NAME}"
    ```

3. Once the cluster is ready, retrieve the console URL:

    ```bash
    rosa describe cluster --cluster="${CLUSTER_NAME}" --output json | jq -r '.console.url'
    ```

4. Use the console URL and the generated `cluster-admin` credentials to log into OpenShift via a web browser.

### Delete the cluster

When you no longer need the environment, remove the cluster to stop incurring charges:

```bash
rosa delete cluster --cluster="${CLUSTER_NAME}"
```