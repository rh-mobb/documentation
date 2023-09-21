---
date: '2021-06-10'
title: ROSA Prerequisites
weight: 1
tags: ["AWS", "ROSA", "Quickstarts"]
authors:
  - Steve Mirman
  - Paul Czarkowski
---

This document contains a set of pre-requisites that must be run once before you can create your first ROSA cluster.

## Prerequisites

### AWS

an AWS account with the [AWS ROSA Prerequisites](https://console.aws.amazon.com/rosa/home?#/get-started) met.

![AWS console rosa requisites](/experts/images/rosa-aws-pre.png)

### AWS CLI

**MacOS**

> See [AWS Docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-mac.html) for alternative install options.

1. Install AWS CLI using the macOS command line

    ```bash
    curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
    sudo installer -pkg AWSCLIV2.pkg -target /
    ```

**Linux**

> See [AWS Docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html) for alternative install options.

1. Install AWS CLI using the Linux command line

    ```bash
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    ```

**Windows**

> See [AWS Docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-windows.html) for alternative install options.

1. Install AWS CLI using the Windows command line

    ```bash
    C:\> msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
    ```

**Docker**

> See [AWS Docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-docker.html) for alternative install options.

1. To run the AWS CLI version 2 Docker image, use the docker run command.

    ```bash
    docker run --rm -it amazon/aws-cli command
    ```

### Prepare AWS Account for OpenShift

1. Configure the AWS CLI by running the following command

    ```bash
    aws configure
    ```

2. You will be required to enter an `AWS Access Key ID` and an `AWS Secret Access Key` along with a default region name and output format

    ```bash
    % aws configure
    AWS Access Key ID []:
    AWS Secret Access Key []:
    Default region name [us-east-2]:
    Default output format [json]:
    ```
    The `AWS Access Key ID` and `AWS Secret Access Key` values can be obtained by logging in to the AWS console and creating an **Access Key** in the **Security Credentials** section of the IAM dashboard for your user

3. Validate your credentials

    ```bash
    aws sts get-caller-identity
    ```

    You should receive output similar to the following
    ```
    {
      "UserId": <your ID>,
      "Account": <your account>,
      "Arn": <your arn>
    }
    ```

4. If this is a brand new AWS account that has never had a AWS Load Balancer installed in it, you should run the following

    ```bash
    aws iam create-service-linked-role --aws-service-name \
    "elasticloadbalancing.amazonaws.com"
    ```

### Get a Red Hat Offline Access Token

1. Log into cloud.redhat.com

2. Browse to https://cloud.redhat.com/openshift/token/rosa

3. Copy the **Offline Access Token** and save it for the next step


### Set up the OpenShift CLI (oc)

1. Download the OS specific OpenShift CLI from [Red Hat](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/)

2. Unzip the downloaded file on your local machine

3. Place the extracted `oc` executable in your OS path or local directory


### Set up the ROSA CLI

1. Download the OS specific ROSA CLI from [Red Hat](https://www.openshift.com/products/amazon-openshift/download)

2. Unzip the downloaded file on your local machine

3. Place the extracted `rosa` and `kubectl` executables in your OS path or local directory

4. Log in to ROSA

  ```bash
  rosa login
  ```

  You will be prompted to enter in the **Red Hat Offline Access Token** you retrieved earlier and should receive the following message

  ```
  Logged in as <email address> on 'https://api.openshift.com'
  ```

1. Verify that ROSA has the minimal quota

  ```bash
  rosa verify quota
  ```

  > Expected output: `AWS quota ok`

### Associate your AWS account with your Red Hat account

To perform ROSA cluster provisioning tasks, you must create ocm-role and user-role IAM resources in your AWS account and link them to your Red Hat organization.

1. Create the ocm-role which the OpenShift Cluster Manager (OCM) will use to be able to administer and Create ROSA clusters. If this has already been done for your OCM Organization, you can skip to creating the user-role.

    > **Tip** If you have multiple AWS accounts that you want to associate with your Red Hat Organization, you can use the `--profile` option to specify the AWS profile you would like to associate.

    ```bash
    rosa create ocm-role --mode auto --yes
    ```

1. Create the User Role that allows OCM to verify that users creating a cluster have access to the current AWS account.

    > **Tip** If you have multiple AWS accounts that you want to associate with your Red Hat Organization, you can use the `--profile` option to specify the AWS profile you would like to associate.

    ```bash
    rosa create user-role --mode auto --yes
    ```

1. Create the ROSA Account Roles which give the ROSA installer, and machines permissions to perform actions in your account.

    ```bash
    rosa create account-roles --mode auto --yes
    ```


## Conclusion

You are now ready to create your first cluster.  Browse back to the page that directed you here.

