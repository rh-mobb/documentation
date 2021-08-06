# Creating a ROSA cluster in STS mode

**Paul Czarkowski**

*08/6/2021*

STS allows us to deploy ROSA without needing a ROSA admin account, instead it uses roles and policies with Amazon STS (secure token service) to gain access to the AWS resources needed to install and operate the cluster.

This is a summary of the [official docs](https://docs.openshift.com/rosa/rosa_getting_started/rosa-sts-getting-started-workflow.html) that can be used as a line by line install guide and later used as a basis for automation in your [favorite automation tool](https://github.com/ansible/ansible).

> Note that some commands (OIDC for STS) will be hard coded to US-EAST-1, do not be tempted to change these to use $REGION instead or you will fail installation.

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [Rosa CLI](https://github.com/openshift/rosa/releases/tag/v1.1.0) v1.1.0
* OpenShift CLI - `rosa download openshift-client`
* [jq](https://stedolan.github.io/jq/download/)

### Prepare local environment

1. clone down this repository

    ```bash
    git clone https://github.com/rh-mobb/documentation.git
    cd documentation/docs/rosa/sts
    ```

1. set some environment variables

    ```bash
    export VERSION=4.8.2 \
           ROSA_CLUSTER_NAME=mycluster \
           AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text` \
           REGION=us-east-2 \
           AWS_PAGER=""
    ```

### Prepare AWS and Red Hat accounts

If this is your first time deploying ROSA you need to do some preparation as described [here](../../quickstart-rosa.md#Prerequisites). Stop just before running `rosa init` we don't need to do that for STS mode.

## Deploy ROSA cluster

> Note, the role ARNs are truncated to 64chars to suit the AWS limits on ARNs. If you change them, you also need to change the script that creates the roles further down.

1. Make you your ROSA CLI version is correct (v1.1.0 or higher)

    ```bash
    rosa version
    ```

1. Create the IAM Account Roles

    ```
    rosa create account-roles --mode auto --version "${VERSION%.*}" -y
    ```

1. Run the rosa cli to create your cluster

    > You can run the command as provided in the ouput of the previous step to deploy in interactive mode.

    > Add any other arguments to this command to suit your cluster. for example `--private-link` and `--subnet-ids=subnet-12345678,subnet-87654321`.

    ```bash
    rosa create cluster --cluster-name ${ROSA_CLUSTER_NAME} \
      --region ${REGION} --version ${VERSION} \
      --support-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/ManagedOpenShift-Support-Role \
        --role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/ManagedOpenShift-Installer-Role \
        --master-iam-role arn:aws:iam::${AWS_ACCOUNT_ID}:role/ManagedOpenShift-ControlPlane-Role \
        --worker-iam-role arn:aws:iam::${AWS_ACCOUNT_ID}:role/ManagedOpenShift-Worker-Role
    ```

1. Wait for cluster status to change to pending

    ```bash
    while ! \
    rosa describe cluster -c $ROSA_CLUSTER_NAME | grep "Waiting for OIDC"; \
    do echo -n .; sleep 1; done
    ```

1. Create the Operator Roles

    ```bash
    rosa create operator-roles -c $ROSA_CLUSTER_NAME --mode auto --yes
    ```

1. Create the OIDC provider.

    ```bash
    rosa create oidc-provider -c $ROSA_CLUSTER_NAME --mode auto --yes
    ```

1. Validate The cluster is now installing

    The State should have moved beyond `pending` and show `installing` or `ready`.

    ```bash
    watch "rosa describe cluster -c $ROSA_CLUSTER_NAME"
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

1. Wait a few moments and run the `oc login` command it provides.

## Cleanup

1. Delete the ROSA cluster

    ```bash
    rosa delete cluster -c $ROSA_CLUSTER_NAME
    ```

1. Watch the logs and wait until the cluster is deleted

    ```bash
    rosa logs uninstall -c $ROSA_CLUSTER_NAME --watch
    ```

1. Clean up the STS roles

**TBD**

1. Cleanup the rest of the roles and policies

    Instructions to come, for now use the AWS Console.

    The rest of the Roles and Policies can be used for other ROSA clusters, so only delete them if you do not have (or plan to install) other ROSA clusters.



