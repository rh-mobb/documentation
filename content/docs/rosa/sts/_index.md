---
date: '2022-09-14T22:07:08.604151'
title: Deploying ROSA in STS mode
tags: ["AWS", "ROSA", "STS"]
---
**Paul Czarkowski**

*Last updated 03/29/2023*

> **Tip** The official documentation for installing a ROSA cluster in STS mode can be found [here](https://docs.openshift.com/rosa/rosa_getting_started_sts/rosa-sts-getting-started-workflow.html).


Quick Introduction by Ryan Niksch (AWS) and Shaozen Ding (Red Hat) on [YouTube](https://youtu.be/R1T0yk9l6Ys)

<iframe width="560" height="315" src="https://www.youtube.com/embed/R1T0yk9l6Ys" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>

STS allows us to deploy ROSA without needing a ROSA admin account, instead it uses roles and policies with Amazon STS (secure token service) to gain access to the AWS resources needed to install and operate the cluster.

This is a summary of the [official docs](https://docs.openshift.com/rosa/rosa_getting_started/rosa-sts-getting-started-workflow.html) that can be used as a line by line install guide and later used as a basis for automation in your [favorite automation tool](https://github.com/ansible/ansible).

> Note that some commands (OIDC for STS) will be hard coded to US-EAST-1, do not be tempted to change these to use $REGION instead or you will fail installation.

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [Rosa CLI](https://github.com/openshift/rosa/releases/tag/v1.2.2) v1.2.2
* OpenShift CLI (run `rosa download openshift-client`)
* [jq](https://stedolan.github.io/jq/download/)

### Prepare local environment

1. set some environment variables

    ```bash
    export VERSION=4.11.31 \
           ROSA_CLUSTER_NAME=mycluster \
           AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text` \
           REGION=us-east-2 \
           AWS_PAGER=""
    ```

### Prepare AWS and Red Hat accounts

1. If this is your first time deploying ROSA you need to do some preparation as described [here](../../quickstart-rosa.md#Prerequisites). Stop just before running `rosa init` we don't need to do that for STS mode.


1. If this is a brand new AWS account that has never had a AWS Load Balancer installed in it, you should run the following

    ```bash
    aws iam create-service-linked-role --aws-service-name \
    "elasticloadbalancing.amazonaws.com"
    ```

1. Associate your AWS account

   To perform ROSA cluster provisioning tasks, you must create ocm-role and user-role IAM resources in your AWS account and link them to your Red Hat organization.

   <br>
   <b>Create the OCM Role</b><br>
   The first role you will create is the ocm-role which the OpenShift Cluster Manager (OCM) will use to be able to administer and Create ROSA clusters. If this has already been done for your OCM Organization, you can skip to creating the user-role.

   If you haven't already created the ocm-role, you can create and link the role with one command.
   ```bash
   rosa create ocm-role
   ```
   > **Tip** If you have multiple AWS accounts that you want to associate with your Red Hat Organization, you can use the `--profile` option to specify the AWS profile you would like to associate.


   > **Tip** You can get your OCM role arn from AWS IAM:
   ```bash
   aws iam list-roles | grep OCM
   ```

   <br>
   <b>Create the User Role</b><br>
   The second is the user-role that allows OCM to verify that users creating a cluster have access to the current AWS account.

   If you haven't already created the user-role, you can create and link the role with one command.

   ```bash
   rosa create user-role
   ```
   > **Tip** If you have multiple AWS accounts that you want to associate with your Red Hat Organization, you can use the `--profile` option to specify the AWS profile you would like to associate.

   <br>
   If you have already created the user-role, you can just link the user-role to your Red Hat organization.

   ```bash
   rosa link user-role --role-arn <arn>
   ```

   > **Tip** You can get your user-role arn by running the ROSA cli command: `rosa whoami`. Look for the `AWS ARN:` field.
   <br>

## Deploy ROSA cluster

1. Make you your ROSA CLI version is correct (v1.2.2 or higher)

    ```bash
    rosa version
    ```
1. Run the rosa cli to create your cluster

    > You can run the command as provided in the ouput of the previous step to deploy in interactive mode.

    > Add any other arguments to this command to suit your cluster. for example `--private-link` and `--subnet-ids=subnet-12345678,subnet-87654321`.

    ```bash
    rosa create cluster --sts --cluster-name ${ROSA_CLUSTER_NAME} \
      --region ${REGION} --version ${VERSION} --mode auto -y
    ```

1. Validate The cluster is now installing

    The State should have moved beyond `pending` and show `installing` or `ready`.

    ```bash
    watch "rosa describe cluster -c $ROSA_CLUSTER_NAME"
    ```
    **Tip** Newer versions of MacOS do not include a `watch` command. One can be installed using a package manager such as [Homebrew](https://brew.sh/). 

1. Watch the install logs

    ```bash
    rosa logs install -c $ROSA_CLUSTER_NAME --watch --tail 10
    ```

## Validate the cluster

Once the cluster has finished installing we can validate we can access it

1. Create an Admin user

    ```bash
    rosa create admin -c $ROSA_CLUSTER_NAME
    ```

1. Wait a few moments and run the `oc login` command it provides.

## Cleanup

1. Delete the ROSA cluster

    ```bash
    rosa delete cluster -c $ROSA_CLUSTER_NAME
    ```
1. Clean up the STS roles

    Once the cluster has been deleted we can delete the STS roles.

    **Tip** You can get the correct commands with the ID filled in from the output of the previous step.

    ```bash
    rosa delete operator-roles -c <id> --yes --mode auto
    rosa delete oidc-provider -c <id>  --yes --mode auto
    ```
