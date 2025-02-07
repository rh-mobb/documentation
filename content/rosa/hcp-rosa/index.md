---
date: '2025-02-07'
title: Deploying ROSA Hosted Control Plane
tags: ["AWS", "ROSA","ROSA HCP" "STS"]
weight: 1
aliases: ["/experts/quickstart-rosa-hcp.md"]

authors:
  - Nerav Doshi
---


{{% alert state="info" %}}**Tip** The official documentation for installing a ROSA cluster in STS mode can be found [here](https://docs.openshift.com/rosa/rosa_getting_started_sts/rosa-sts-getting-started-workflow.html).{{% /alert %}}

Quick Introduction by Ryan Niksch (AWS) and Shaozen Ding (Red Hat) on [YouTube](https://youtu.be/R1T0yk9l6Ys)

<iframe width="560" height="315" src="https://www.youtube.com/embed/R1T0yk9l6Ys" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>

STS allows us to deploy ROSA without needing a ROSA admin account, instead it uses roles and policies with Amazon STS (secure token service) to gain access to the AWS resources needed to install and operate the cluster.

This is a summary of the [official docs](https://docs.openshift.com/rosa/rosa_getting_started/rosa-sts-getting-started-workflow.html) that can be used as a line by line install guide.

In this section we will deploy a ROSA cluster using Hosted Control Planes (HCP).

ROSA HCP introduces the ability to separate the control plane from the data plane (worker nodes). This new deployment model for ROSA involves hosting the control plane within a Red Hat-managed AWS account, rather than within your own AWS account. As a result, you no longer need to manage and pay for the infrastructure associated with the control plane in your AWS environment, leading to reduced costs for your AWS resources. Additionally, the control plane is dedicated to a single OpenShift cluster, ensuring high availability and resilience for your workloads.. See the documentation for more about [Hosted Control Planes.](https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-sts-creating-a-cluster-quickly.html)

## Prerequisites

**If this is your first time deploying ROSA you need to do some preparation as described for deploying ROSA using STS [here](https://docs.openshift.com/rosa/rosa_planning/rosa-cloud-expert-prereq-checklist.html).**

To create a ROSA with HCP cluster, you must have the following items:

  - A configured virtual private cloud (VPC). You can create a VPC using [Terraform template or manually](https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-sts-creating-a-cluster-quickly.html#rosa-hcp-creating-vpc)

  - Configure [Account-wide roles](https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-sts-creating-a-cluster-quickly.html#rosa-sts-creating-account-wide-sts-roles-and-policies_rosa-hcp-sts-creating-a-cluster-quickly) using [AWS managed policies](https://docs.aws.amazon.com/rosa/latest/userguide/security-iam-awsmanpol.html). Setting account-wide policies for ROSA with AWS managed policies ensures that your OpenShift clusters are secure, consistent, and cost-effective.

  - Create an [OpenID Connect(OIDC) configuration](https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-sts-creating-a-cluster-quickly.html#rosa-sts-byo-oidc_rosa-hcp-sts-creating-a-cluster-quickly). When using a ROSA with HCP cluster, you must create the OIDC configuration prior to creating your cluster. This configuration is registered to be used with OpenShift Cluster Manager.

  - Create [Operator roles](https://docs.openshift.com/rosa/rosa_hcp/rosa-hcp-sts-creating-a-cluster-quickly.html#rosa-operator-config_rosa-hcp-sts-creating-a-cluster-quickly). Operator roles are essential for the creation and management of a ROSA HCP cluster because they ensure that the necessary permissions are granted to OpenShift Operators, which are responsible for automating the deployment, configuration, and management of OpenShift components and AWS resources

**Once completing those steps you can continue below.**

## Deploy ROSA cluster

1. Make you your ROSA CLI version is correct (v1.2.45 or higher)

    ```bash
    rosa version
    ```

1. Run the rosa cli to create your cluster

    > Note there are many configurable installation options that you can view using `rosa create cluster -h`. The following will create a cluster with all of the default options.

    ```bash
    rosa create cluster --sts --mode=auto \
    --cluster-name <cluster_name> \
    --hosted-cp \
    --operator-roles-prefix <operator-role-prefix> \
    --oidc-config-id <ID-of-OIDC-configuration> \
    --subnet-ids <public-subnet-id>,<private-subnet-id>
    ```

1. Watch the install logs

    ```bash
    rosa logs install -c <cluster name> --watch --tail 10
    ```

1. Check Status of the cluster
 
    ```bash
    rosa describe cluster --cluster <cluster name>
    ```

## Validate the cluster

Once the cluster has finished installing we can validate we can access it

1. Create an Admin user

    ```bash
    rosa create admin -c <cluster name>
    ```

1. Wait a few moments and run the `oc login` command it provides. If it fails, or if you get a warning about TLS certificates, wait a few minutes and try again.

1. Run `oc whoami --show-console`, browse to the provided URL and log in using the credentials provided above.

## Cleanup

1. Delete the ROSA cluster

    ```bash
    rosa delete cluster -c <cluster name>
    ```

1. Clean up the STS roles

    Once the cluster has been deleted we can delete the STS roles.

    **Tip** You can get the correct commands with the ID filled in from the output of the previous step.

    ```bash
    rosa delete operator-roles -c <id> --yes --mode auto
    rosa delete oidc-provider -c <id>  --yes --mode auto
    ```
