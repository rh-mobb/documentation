# Creating a ROSA cluster in STS mode with custom KMS key

**Byron Miller**

*Last updated 4/21/2022*

> **Tip** Official Documentation [ROSA STS with custom KMS key](https://docs.openshift.com/rosa/rosa_getting_started/rosa-sts-creating-a-cluster-with-customizations.html#rosa-sts-creating-cluster-customizations_rosa-sts-creating-a-cluster-with-customizations)

This guide will walk you through installing ROSA (Red Hat OpenShift on AWS) with a customer provided KMS Key that will be used to encrypt both the root volumes of nodes as well as PV Claims for mounted EBS claims.

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [Rosa CLI](https://github.com/openshift/rosa/releases/tag/v1.1.11) v1.1.11
* OpenShift CLI - `rosa download openshift-client`


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
   ```json
   {
     "UserId": <your ID>,
     "Account": <your account>,
     "Arn": <your arn>
   }
   ```

    You will need to save the account ID for adding it to your KMS key to define installer role, so take note.

4. If this is a brand new AWS account that has never had a AWS Load Balancer installed in it, you should run the following

   ```bash
   aws iam create-service-linked-role --aws-service-name \
   "elasticloadbalancing.amazonaws.com"
   ```

## Create KMS Key

I can't presume to know what your KMS key is, so we'll walk through the AWS console and grab a key to demonstrate.

1. Create custom KMS key (or use existing key)

   ```bash
   aws kms create-key --region us-east-2 --description "Custom Encryption Key"
   ```

   You will need to save the ARN output of this custom key for further steps

   ```bash
   KMS_ARN="arn:aws:kms:us-east-2:<insert accountid>:key/6b79db67-3bbb-435c-8352-7fa20b7d6518"
   ```

1. Save the key output

   ```bash
   aws kms get-key-policy --key-id $KMS_ARN --policy-name default --output text > kms-key-policy.json
   ```

1. Add the installer role to your key

   Modify kms key to add installer role

   ```bash
   vim kms-key-policy.json
   ```

   ```json
   {
       "Version": "2012-10-17",
       "Id": "key-default-1",
       "Statement": [
           {
               "Sid": "Enable IAM User Permissions",
               "Effect": "Allow",
               "Principal": {
                   "AWS": [ 
                       "arn:aws:iam::<insert accountid>:role/ManagedOpenShift-Installer-Role"
                       ]
               },
               "Action": "kms:*",
               "Resource": "*"
           }
       ]
   }
   ```

1. Apply modified KMS key

   ```bash
   aws kms put-key-policy --key-id $KMS_ARN \ 
   --policy file://kms-key-policy.json \ 
   --policy-name default
   ```

## Create ROSA Cluster

1. Make you your ROSA CLI version is correct (v1.1.11 or higher)

   ```bash
   rosa version
   ```

1. Create the IAM Account Roles

    > If you have already installed account-roles into your aws account, you can skip this step.

   ```bash
   rosa create account-roles --mode auto -y
   ```

1. Set Environment Variables
   
   ```bash
   ROSA_CLUSTER_NAME=poc-kmskey
   KMS_ARN="arn:aws:kms:us-east-2:<insert accountid>:key/6b79db67-3bbb-435c-8352-7fa20b7d6518"
   ```

2. Run the rosa cli to create your cluster


   ```bash
   rosa create cluster --cluster-name $ROSA_CLUSTER_NAME --sts \
   --region us-east-2 --compute-nodes 2 --machine-cidr 10.0.0.0/16 \
   --service-cidr 172.30.0.0/16 --pod-cidr 10.128.0.0/14 --host-prefix 23 \
   --kms-key-arn $KMS_ARN
   ```

1. Create the Operator Roles

   ```bash
   rosa create operator-roles -c $ROSA_CLUSTER_NAME --mode auto --yes
   ```

2. Create the OIDC provider.

   ```bash
   rosa create oidc-provider -c $ROSA_CLUSTER_NAME --mode auto --yes
   ```

3. Validate The cluster is now installing

    The State should have moved beyond `pending` and show `installing` or `ready`.

   ```bash
   watch "rosa describe cluster -c $ROSA_CLUSTER_NAME"
   ```

4. Watch the install logs

   ```bash
   rosa logs install -c $ROSA_CLUSTER_NAME --watch --tail 10
   ```

## Validate the cluster

Once the cluster has finished installing we can validate we can access it

1. Create an Admin user

   ```bash
   rosa create admin -c $ROSA_CLUSTER_NAME
   ```
   Run the resulting login statement from output. May take 2-3 minutes before authentication is fully synced

2. Verify PV Claims

   ```bash
   oc get pv
   ```

   Output: 
   ```bash
   NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM
                                       STORAGECLASS       REASON   AGE
   pvc-00dac374-a45e-43fa-a313-ae0491e8edf1   10Gi       RWO            Delete           Bound    openshift-monitoring/alertmanager-data-alertmanager-main-1   gp2-customer-kms            26m
   pvc-7d211496-4ddf-4200-921c-1404b754afa5   10Gi       RWO            Delete           Bound    openshift-monitoring/alertmanager-data-alertmanager-main-0   gp2-customer-kms            26m
   pvc-b5243cef-ec30-4e5c-a348-aeb8136a908c   100Gi      RWO            Delete           Bound    openshift-monitoring/prometheus-data-prometheus-k8s-0        gp2-customer-kms            26m
   pvc-ec60c1cf-72cf-4ac6-ab12-8e9e5afdc15f   100Gi      RWO            Delete           Bound    openshift-monitoring/prometheus-data-prometheus-k8s-1        gp2-customer-kms            26m
   ```
You should see the storage class show gp2-customer-kms which shows the pv claims encrypted by customer provided key.

## Cleanup

1. Delete the ROSA cluster

   ```bash
   rosa delete cluster -c $ROSA_CLUSTER_NAME
   ```

1. Clean up the STS roles

    Once the cluster is deleted we can delete the STS roles.

   ```bash
   rosa delete operator-roles -c $ROSA_CLUSTER_NAME --yes --mode auto
   rosa delete oidc-provider -c $ROSA_CLUSTER_NAME  --yes --mode auto
   ```
