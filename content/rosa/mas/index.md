---
date: '2024-08-26'
title: Maximo Application Suite on ROSA ( Red Hat OpenShift on AWS )
tags: ["ROSA", "AWS", "MAS"]
authors:
  - Kevin Collins
---

IBM Maximo Application Suite (MAS) is a set of applications for asset monitoring, management, predictive maintenance and reliability planning.  When combined with Red Hat OpenShift on AWS ( ROSA ), this frees up your Maximo and operations team to focus on what is important to them ( Maximo ) rather than having to worry about managing and building clusters.

This document outlines how to get quickly get started with ROSA and installing Maximo all through automation.


## Prerequisites
* a ROSA Cluster (see [Deploying ROSA with Terraform](/experts/rosa/terraform-install/))
* oc cli
* aws cli
* ansible cli
* a Maximo License Key
<br>

> Note: You must log into your ROSA cluster via your oc cli before going through the following steps.

## Prepare the Environment

> Note: This guide re-uses environment variables from the [Deploying a ROSA HCP cluster with Terraform](/experts/rosa/terraform/hcp/) guide. If you have an existing cluster, you'll need to set them appropriately for the cluster.

1. Run this these commands to set some environment variables to use throughout (Terraform commands need to be run in the directory you ran Terraform)
<br>

<b>Maximo environment variables.</b>
    
You do need both an IBM entitlement key and a Maximo license ID and file.  These can be obtained from IBM.</b>

```bash
export IBM_ENTITLEMENT_KEY=XYZ
export MAS_CONFIG_DIR=~/tmp/masconfig
export DRO_CONTACT_EMAIL=name@company.com
export DRO_CONTACT_FIRSTNAME=First
export DRO_CONTACT_LASTNAME=Last
export MAS_INSTANCE_ID=inst1
export SLS_LICENSE_ID=
export SLS_LICENSE_FILE=
export PROMETHEUS_ALERTMGR_STORAGE_CLASS=gp3-csi
export PROMETHEUS_STORAGE_CLASS=efs-sc
export PROMETHEUS_USERWORKLOAD_STORAGE_CLASS=efs-sc
export GRAFANA_INSTANCE_STORAGE_CLASS=efs-sc
export MONGODB_STORAGE_CLASS=gp3-csi
export UDS_STORAGE_CLASS=efs-sc
mkdir -p $MAS_CONFIG_DIR
```

<br>

<b>OpenShift Environment Variables </b>

```bash
export CLUSTER=${TF_VAR_CLUSTER}
export REGION=$(rosa describe cluster -c ${CLUSTER} -o json | jq -r '.region.id')
export OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster -o json \
| jq -r .spec.serviceAccountIssuer| sed -e "s/^https:\/\///")
export AWS_PAGER=""
INGRESS_SECRET_NAME=$(oc get secret -n openshift-ingress -o json | jq -r '.items[] | select(.metadata.name|contains("ingress")) | .metadata.name')

az aro list --query \
    "[?name=='$CLUSTER'].{ ResourceGroup:resourceGroup,Location:location}" \
    -o tsv | read -r RESOURCEGROUP LOCATION
```
  
## Prepare the Storage Accounts for MAS
The first step is to add AWS EFS to our cluster.  The following guide covers the minimum instructions to add EFS for Maximo, a complete guide on adding EFS to ROSA is [here](https://cloud.redhat.com/experts/rosa/aws-efs/)

In order to use the AWS EFS CSI Driver we need to create IAM roles and policies that can be attached to the Operator.

1. Create an IAM Policy

   ```bash
   cat << EOF > $MAS_CONFIG_DIR/efs-policy.json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "elasticfilesystem:DescribeAccessPoints",
           "elasticfilesystem:DescribeFileSystems",
           "elasticfilesystem:DescribeMountTargets",
           "elasticfilesystem:TagResource",
           "ec2:DescribeAvailabilityZones"
         ],
         "Resource": "*"
       },
       {
         "Effect": "Allow",
         "Action": [
           "elasticfilesystem:CreateAccessPoint"
         ],
         "Resource": "*",
         "Condition": {
           "StringLike": {
             "aws:RequestTag/efs.csi.aws.com/cluster": "true"
           }
         }
       },
       {
         "Effect": "Allow",
         "Action": "elasticfilesystem:DeleteAccessPoint",
         "Resource": "*",
         "Condition": {
           "StringEquals": {
             "aws:ResourceTag/efs.csi.aws.com/cluster": "true"
           }
         }
       }
     ]
   }
   EOF
   ```


1. Create the Policy

   > This creates a named policy for the cluster, you could use a generic policy for multiple clusters to keep things simpler.

   ```bash
   POLICY=$(aws iam create-policy --policy-name "${CLUSTER}-rosa-efs-csi" \
      --policy-document file://$MAS_CONFIG_DIR/efs-policy.json \
      --query 'Policy.Arn' --output text) || \
      POLICY=$(aws iam list-policies \
      --query 'Policies[?PolicyName==`rosa-efs-csi`].Arn' \
      --output text)
   echo $POLICY
   ```

1. Create a Trust Policy

   ```bash
   cat <<EOF > $MAS_CONFIG_DIR/TrustPolicy.json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "${OIDC_PROVIDER}:sub": [
               "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-operator",
               "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-controller-sa"
             ]
           }
         }
       }
     ]
   }
   EOF
   ```

1. Create Role for the EFS CSI Driver Operator

   ```bash
   ROLE=$(aws iam create-role \
     --role-name "${CLUSTER}-aws-efs-csi-operator" \
     --assume-role-policy-document file://$MAS_CONFIG_DIR/TrustPolicy.json \
     --query "Role.Arn" --output text)
   echo $ROLE
   ```

1. Attach the Policies to the Role

   ```bash
   aws iam attach-role-policy \
      --role-name "${CLUSTER}-aws-efs-csi-operator" \
      --policy-arn $POLICY
   ```

### Deploy the AWS EFS Operator

1. Create a Secret to tell the AWS EFS Operator which IAM role to request.

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: v1
   kind: Secret
   metadata:
    name: aws-efs-cloud-credentials
    namespace: openshift-cluster-csi-drivers
   stringData:
     credentials: |-
       [default]
       role_arn = $ROLE
       web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
   EOF
   ```

1. Install the EFS Operator

   ```bash
   cat <<EOF | oc create -f -
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     generateName: openshift-cluster-csi-drivers-
     namespace: openshift-cluster-csi-drivers
   ---
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     labels:
       operators.coreos.com/aws-efs-csi-driver-operator.openshift-cluster-csi-drivers: ""
     name: aws-efs-csi-driver-operator
     namespace: openshift-cluster-csi-drivers
   spec:
     channel: stable
     installPlanApproval: Automatic
     name: aws-efs-csi-driver-operator
     source: redhat-operators
     sourceNamespace: openshift-marketplace
   EOF
   ```

1. Wait until the Operator is running

   ```bash
   watch oc get deployment aws-efs-csi-driver-operator -n openshift-cluster-csi-drivers
   ```

1. Install the AWS EFS CSI Driver

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: operator.openshift.io/v1
   kind: ClusterCSIDriver
   metadata:
       name: efs.csi.aws.com
   spec:
     managementState: Managed
   EOF
   ```

1. Wait until the CSI driver is running

   ```bash
   watch oc get daemonset aws-efs-csi-driver-node -n openshift-cluster-csi-drivers
   ```

### Prepare an AWS EFS Volume for dynamic provisioning

1. Run this set of commands to update the VPC to allow EFS access

   ```bash
   NODE=$(oc get nodes --selector=node-role.kubernetes.io/worker \
     -o jsonpath='{.items[0].metadata.name}')
   VPC=$(aws ec2 describe-instances \
     --filters "Name=private-dns-name,Values=$NODE" \
     --query 'Reservations[*].Instances[*].{VpcId:VpcId}' \
     --region $REGION \
     | jq -r '.[0][0].VpcId')
   CIDR=$(aws ec2 describe-vpcs \
     --filters "Name=vpc-id,Values=$VPC" \
     --query 'Vpcs[*].CidrBlock' \
     --region $REGION \
     | jq -r '.[0]')
   SG=$(aws ec2 describe-instances --filters \
     "Name=private-dns-name,Values=$NODE" \
     --query 'Reservations[*].Instances[*].{SecurityGroups:SecurityGroups}' \
     --region $REGION \
     | jq -r '.[0][0].SecurityGroups[0].GroupId')
   echo "CIDR - $CIDR,  SG - $SG"
   ```

1. Assuming the CIDR and SG are correct, update the security group

   ```bash
   aws ec2 authorize-security-group-ingress \
    --group-id $SG \
    --protocol tcp \
    --port 2049 \
    --region $REGION \
    --cidr $CIDR | jq .
   ```

> At this point you can create either a single Zone EFS filesystem, or a Region wide EFS filesystem

### Creating a region-wide EFS

1. Create a region-wide EFS File System

   ```bash
   EFS=$(aws efs create-file-system --creation-token efs-token-1 \
      --region ${REGION} \
      --encrypted | jq -r '.FileSystemId')
   echo $EFS
   ```

1. Configure a region-wide Mount Target for EFS (this will create a mount point in each subnet of your VPC by default)

   ```bash
   for SUBNET in $(aws ec2 describe-subnets \
     --filters Name=vpc-id,Values=$VPC Name='tag:kubernetes.io/role/internal-elb',Values='*' \
     --query 'Subnets[*].{SubnetId:SubnetId}' \
     --region $REGION \
     | jq -r '.[].SubnetId'); do \
       MOUNT_TARGET=$(aws efs create-mount-target --file-system-id $EFS \
          --subnet-id $SUBNET --security-groups $SG \
          --region $REGION \
          | jq -r '.MountTargetId'); \
       echo $MOUNT_TARGET; \
    done
   ```

### Create a storage class for EFS
1. Create a Storage Class for the EFS volume

   ```bash
   cat <<EOF | oc apply -f -
   kind: StorageClass
   apiVersion: storage.k8s.io/v1
   metadata:
     name: efs-sc
   provisioner: efs.csi.aws.com
   parameters:
     provisioningMode: efs-ap
     fileSystemId: $EFS
     directoryPerms: "700"
     gidRangeStart: "1000"
     gidRangeEnd: "2000"
     basePath: "/dynamic_provisioning"
   EOF
   ```






1. Change the default storage class

```bash
  oc patch storageclass managed-csi -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

1. Create an Azure Premium Disk for Maximo

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: managed-premium
      annotations: 
        storageclass.kubernetes.io/is-default-class: 'true'
    provisioner: kubernetes.io/azure-disk
    parameters:
      kind: Managed
      storageaccounttype: Premium_LRS
    reclaimPolicy: Delete
    allowVolumeExpansion: true
    volumeBiningMode: WaitForFirstConsumer
    EOF
    ```

1. Create an Azure Premium File Storage for Maximo

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: azurefiles-premium
    provisioner: file.csi.azure.com
    parameters:
      protocol: nfs
      networkEndpointType: privateEndpoint
      location: $LOCATION
      resourceGroup: $RESOURCEGROUP
      skuName: Premium:LRS
    reclaimPolicy: Retain
    allowVolumeExpansion: true
    volumeBiningMode: Immediate
    EOF
    ```

## Install IBM Maximo Application Suite with Ansible

IBM has provided an ansible playbook to automate the installation of Maximo and all the required dependencies making it very easy and repeatable to get started with Maximo.

Click [here](https://ibm-mas.github.io/ansible-devops/playbooks/oneclick-core) to learn more about the OneClick Install of Maximo.

1. Install the Maximo Ansible collection

```bash
ansible-galaxy collection install ibm.mas_devops
```

1. Run the Ansible playbook
```bash
ansible-playbook ibm.mas_devops.oneclick_core
```

And that's it!! ... it will take about 90 minutes for the installation to complete follow along the ansible log messages if you like.

You can also open the OpenShift web console and view the projects and resources the playbook is creating.

![MAS Projects](images/mas-projects.jpg)

When the playbook finishes, you will see the following showing the installation is complete along with the MAS Admin Dashboard with username and password to use.

![MAS Installation](images/mas-finish.png)

Open the MAS Dashboard URL in your browser and log in with the given username and password.

![MAS Admin](images/mas-admin.png)

> Note: If you are using the default aroapp.io domain that comes with ARO, the URL will show it's insecure due to an untrusted CA.
For a production level Maximo installation with ARO, the cluster should be created with a [custom domain](https://cloud.redhat.com/experts/aro/cert-manager/) where you control the certificates.  Follow these [directions](https://www.ibm.com/docs/en/mas-cd/continuous-delivery?topic=management-manual-certificate) from IBM in manually appling the certificates for MAS.

If you see a blue spinning circle from the admin page like this:
![MAS Blue Circle](images/mas-blue-circle.png)

In the browswer, change admin to api and hit enter.
For example: change https://admin.inst1.apps.mobb.eastus.aroapp.io/ to
https://api.inst1.apps.mobb.eastus.aroapp.io/

This will return a message like the following:
![MAS API](images/mas-api.png)

Try to load the admin screen and this time it should work.

## Install Maximo Applications ( Optional )

Optionally install Maximo applications you would like to use.  In this example, we will install IT and Asset Configuration Manager.

On the Admin page, click on Catalog and then under applications click on Manage.
![MAS Manage](images/mas-manage.png)

Select both IT and Asset Configuration Manager and then clikc on Continue.
![MAS Componenets](images/mas-it-asset.png)

Keep the defaults and click on Subscribe to channel.  Note that this can take 10+ minutes.
![MAS Subscribe](images/mas-subscribe.png)

Once you see thate Manage is ready to be activated, click on Activate
![MAS Activate](images/mas-activate.png)

Finally, click on Start activation on the next screen.  Note that this step can take several hours.
![MAS Start Activation](images/mas-start-activation.png)










