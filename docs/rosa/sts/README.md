# Creating a ROSA cluster in STS mode

**Paul Czarkowski**

*06/12/2021*

STS allows us to deploy ROSA without needing a ROSA admin account, instead it uses roles and policies with Amazon STS (secure token service) to gain access to the AWS resources needed to install and operate the cluster.

This is a summary of the [official docs](https://docs.openshift.com/rosa/rosa_getting_started/rosa-sts-getting-started-workflow.html) that can be used as a line by line install guide.

> Note that some commands (OIDC for STS) will be hard coded to US-EAST-1, do not be tempted to change these to use $region instead or you will fail installation.

> Note as the roles created for STS in this guide have a common name (see the `ccoctl` command further down) only one cluster will be installable in a given AWS account.  You'll need to modify the name and resulting role bindings to deploy more than one cluster.

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [Rosa CLI](https://github.com/openshift/rosa/releases/tag/v1.0.8) v1.0.8
* OpenShift CLI - `rosa download openshift-client`
* [jq](https://stedolan.github.io/jq/download/)
* Cloud Credential Operator CLI

    ```bash
    git clone https://github.com/openshift/cloud-credential-operator.git
    cd cloud-credential-operator/cmd/ccoctl
    go build .
    mv ccoctl /usr/local/bin/ccoctl
    ccoctl --help
    ```

### Prepare local environment

1. clone down this repository

    ```bash
    git clone https://github.com/rh-mobb/documentation.git
    cd documentation/docs/rosa/sts
    ```

1. set some environment variables

    ```bash
    export version=4.7.11 \
           name=<cluster name> \
           aws_account_id=`aws sts get-caller-identity --query Account --output text` \
           region=us-east-2 \
           AWS_PAGER=""
    ```

### Prepare AWS and Red Hat accounts

If this is your first time deploying ROSA you need to do some preparation as described [here](../../quickstart-rosa.md#Prerequisites). Stop just before running `rosa init` we don't need to do that for STS mode.

## Creating IAM and OIDC roles for STS

> Review the roles in the `./roles` directory, they will be the roles that ROSA can assume to perform installation / day 2 operations.

### Installer access role and policy

This role is used to manage the installation and deletion of clusters that use STS.


1. Create the role

    ```bash
    aws iam create-role \
    --role-name ManagedOpenShift-IAM-Role \
      --assume-role-policy-document \
      file://roles/ManagedOpenShift_IAM_Role.json
    ```

2. Attach the policy to the role

    ```bash
    aws iam put-role-policy \
      --role-name ManagedOpenShift-IAM-Role \
      --policy-name ManagedOpenShift-IAM-Role-Policy \
      --policy-document \
      file://roles/ManagedOpenShift_IAM_Role_Policy.json
    ```

### Control plane node instance profile role

1. Create the role

    ```bash
    aws iam create-role \
      --role-name ManagedOpenShift-ControlPlane-Role \
      --assume-role-policy-document \
      file://roles/ManagedOpenShift_ControlPlane_Role.json
    ```

2. Attach the policy to the role

    ```bash
    aws iam put-role-policy \
      --role-name ManagedOpenShift-ControlPlane-Role \
      --policy-name ManagedOpenShift-ControlPlane-Role-Policy \
      --policy-document \
      file://roles/ManagedOpenShift_ControlPlane_Role_Policy.json
    ```

### Worker node instance profile role

1. Create the role

    ```bash
    aws iam create-role \
      --role-name ManagedOpenShift-Worker-Role \
      --assume-role-policy-document \
      file://roles/ManagedOpenShift_Worker_Role.json
    ```

1. Attach the policy to the role

    ```bash
    aws iam put-role-policy \
      --role-name ManagedOpenShift-Worker-Role \
      --policy-name ManagedOpenShift-Worker-Role-Policy \
      --policy-document \
      file://roles/ManagedOpenShift_Worker_Role_Policy.json
    ```

### STS support role

The STS support role is designed to give Red Hat site reliability engineering (SRE) read-only access to support a given cluster and troubleshoot issues.

1. Create the Role

    ```bash
    aws iam create-role \
      --role-name ManagedOpenShift-Support-Role \
      --assume-role-policy-document file://roles/RH_Support_Role.json
    ```

1. Attach the policy to the role

    ```bash
    aws iam create-policy \
      --policy-name ManagedOpenShift-Support-Access \
      --policy-document file://roles/RH_Support_Policy.json

    policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='ManagedOpenShift-Support-Access'].Arn" --output text)

    aws iam attach-role-policy \
      --role-name ManagedOpenShift-Support-Role \
      --policy-arn $policy_arn
    ```

## Deploy ROSA cluster

> Note, the role ARNs are truncated to 64chars to suit the AWS limits on ARNs. If you change them, you also need to change the script that creates the roles further down.

1. Run the rosa cli to create your cluster

    ```bash
    rosa create cluster --cluster-name ${name} \
      --region ${region} --version ${version} \
      --role-arn arn:aws:iam::${aws_account_id}:role/ManagedOpenShift-IAM-Role \
      --support-role-arn arn:aws:iam::${aws_account_id}:role/ManagedOpenShift-Support-Role \
      --master-iam-role arn:aws:iam::${aws_account_id}:role/ManagedOpenShift-ControlPlane-Role \
      --worker-iam-role arn:aws:iam::${aws_account_id}:role/ManagedOpenShift-Worker-Role \
      --operator-iam-roles aws-cloud-credentials,openshift-machine-api,arn:aws:iam::${aws_account_id}:role/ManagedOpenShift-openshift-machine-api-aws-cloud-credentials \
      --operator-iam-roles cloud-credential-operator-iam-ro-creds,openshift-cloud-credential-operator,arn:aws:iam::${aws_account_id}:role/ManagedOpenShift-openshift-cloud-credential-operator-cloud-crede \
      --operator-iam-roles installer-cloud-credentials,openshift-image-registry,arn:aws:iam::${aws_account_id}:role/ManagedOpenShift-openshift-image-registry-installer-cloud-creden \
      --operator-iam-roles cloud-credentials,openshift-ingress-operator,arn:aws:iam::${aws_account_id}:role/ManagedOpenShift-openshift-ingress-operator-cloud-credentials \
      --operator-iam-roles ebs-cloud-credentials,openshift-cluster-csi-drivers,arn:aws:iam::${aws_account_id}:role/ManagedOpenShift-openshift-cluster-csi-drivers-ebs-cloud-credent
  ```

1. Wait for cluster status to change to pending

    ```bash
    while ! \
    rosa describe cluster -c $name | grep "Waiting for OIDC"; \
    do sleep 1; done
    ```

1. Create the OIDC provider.

    ```bash
    cluster_id=$(rosa describe cluster -c $name | grep "^ID:" | awk '{ print $2}')

    thumbprint=$(openssl s_client -servername \
      rh-oidc.s3.us-east-1.amazonaws.com/${cluster_id} \
      -showcerts -connect rh-oidc.s3.us-east-1.amazonaws.com:443 \
      </dev/null 2>&1| openssl x509 -fingerprint -noout | tail -n1 \
      | sed 's/SHA1 Fingerprint=//' | sed 's/://g')

    aws iam create-open-id-connect-provider \
    --url "https://rh-oidc.s3.us-east-1.amazonaws.com/${cluster_id}" \
    --client-id-list openshift sts.amazonaws.com \
    --thumbprint-list "${thumbprint}"
    ```

1. Generate permissions for OIDC-access-based roles

    ```bash
    mkdir -p credrequests

    oc adm release extract \
      quay.io/openshift-release-dev/ocp-release:${version:0:3}.0-x86_64 \
      --credentials-requests \
      --cloud=aws \
      --to credrequests

    cat credrequests/0000*.yaml > credrequests/${version:0:3}.yaml

    rm -f credrequests/0000*.yaml
    ```

1. Prepare the IAM roles

    ```bash
    mkdir -p iam_assets

    cd iam_assets

    ccoctl aws create-iam-roles \
      --credentials-requests-dir ../credrequests/ \
      --identity-provider-arn "arn:aws:iam::${aws_account_id}:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/${cluster_id}" \
      --name ManagedOpenShift \
      --region ${region} \
      --dry-run

    cd ..
    ```

1. Apply the IAM roles

    ```bash
    ./apply-roles.sh
    ```

1. Validate The cluster is now Installing

    The State should have moved beyond `pending` and show `installing` or `ready`.

    ```bash
    rosa describe cluster -c $name | grep State
    ```

1. Watch the install logs

    ```bash
    rosa logs install -c $name --watch
    ```

## Validate the cluster

Once the cluster has finished installing we can validate we can access it

1. Create an Admin user

    ```bash
    rosa create admin -c $cluster
    ```

1. Wait a few moments and run the `oc login` command it provides.

## Cleanup

1. Delete the ROSA cluster

    ```bash
    rosa delete cluster -c $cluster
    ```

1. Watch the logs and wait until the cluster is deleted

    ```bash
    rosa logs uninstall -c $cluster --watch
    ```

1. Clean up the STS roles

    ```bash
    ./clean-roles.sh
    ```

1. delete the OIDC connect provider

    ```bash
    oidc_arn=$(aws iam list-open-id-connect-providers | \
      grep $cluster_id | awk -F ": " '{ print $2 }' | \
      sed 's/"//g')

    aws iam delete-open-id-connect-provider \
      --open-id-connect-provider-arn=$oidc_arn
    ```

1. Cleanup the rest of the roles and policies

    Instructions to come, for now use the AWS Console.

    The rest of the Roles and Policies can be used for other ROSA clusters, so only delete them if you do not have (or plan to install) other ROSA clusters.



