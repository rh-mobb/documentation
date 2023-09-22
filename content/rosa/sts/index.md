---
date: '2022-05-27'
title: Deploying ROSA in STS mode
tags: ["AWS", "ROSA", "STS"]
weight: 1
aliases: ["/experts/quickstart-rosa.md"]

authors:
  - Paul Czarkowski
  - Michael Ducy
---

> **Tip** The official documentation for installing a ROSA cluster in STS mode can be found [here](https://docs.openshift.com/rosa/rosa_getting_started_sts/rosa-sts-getting-started-workflow.html).


Quick Introduction by Ryan Niksch (AWS) and Shaozen Ding (Red Hat) on [YouTube](https://youtu.be/R1T0yk9l6Ys)

<iframe width="560" height="315" src="https://www.youtube.com/embed/R1T0yk9l6Ys" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>

STS allows us to deploy ROSA without needing a ROSA admin account, instead it uses roles and policies with Amazon STS (secure token service) to gain access to the AWS resources needed to install and operate the cluster.

This is a summary of the [official docs](https://docs.openshift.com/rosa/rosa_getting_started/rosa-sts-getting-started-workflow.html) that can be used as a line by line install guide and later used as a basis for automation in your [favorite automation tool](https://github.com/ansible/ansible).

## Prerequisites

**If this is your first time deploying ROSA you need to do some preparation as described [here](./prereqs).**

**Once completing those steps you can continue below.**

## Deploy ROSA cluster

1. set some environment variables

    ```bash
    export ROSA_CLUSTER_NAME=mycluster
    export AWS_ACCOUNT_ID=`aws sts get-caller-identity \
      --query Account --output text`
    export REGION=us-east-2
    export AWS_PAGER=""
    ```

1. Make you your ROSA CLI version is correct (v1.2.25 or higher)

    ```bash
    rosa version
    ```

1. Run the rosa cli to create your cluster

    > Note there are many configurable installation options that you can view using `rosa create cluster -h`. The following will create a cluster with all of the default options.

    ```bash
    rosa create cluster --sts --cluster-name ${ROSA_CLUSTER_NAME} \
      --region ${REGION} --mode auto --yes
    ```

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

1. Wait a few moments and run the `oc login` command it provides. If it fails, or if you get a warning about TLS certificates, wait a few minutes and try again.

1. Run `oc whoami --show-console`, browse to the provided URL and log in using the credentials provided above.

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
