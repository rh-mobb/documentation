---
date: '2025-07-02'
title: Accessing the ROSA HCP API Server from a Different AWS Account
tags: ["AWS", "ROSA", "HCP"]
authors:
  - Yuhki Hanada 
---

## Introduction                         

You can create a ROSA HCP cluster in one AWS account and configure it to allow accesss from a different AWS account using `oc` command.
Here, I walk through the actual AWS setup.

![pic1](./images/pic1.png)
Note: AWS environments vary, so consider this as one possible setup.


## Prerequisites

Assume a ROSA HCP cluster has been already deployed in AWS Account-A, and the following AWS resources are available.
I used ROSA HCP 4.19.0 when writing this article. 
![pic2](./images/pic2.png)

## Setup on AWS Account‑B

This section covers steps in AWS Account-B 
![pic3](./images/pic3.png)


#### Prepare necessary tools on  Bastion-B 

1. On the EC2 bastion instance (bastion-B), install required tools

    ```bash
    curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/rosa-linux.tar.gz
    tar -zxf rosa-linux.tar.gz 
    sudo mv ./rosa /usr/local/bin/
    rosa download oc
    tar -xzf openshift-client-linux.tar.gz 
    sudo mv ./oc /usr/local/bin
    sudo mv ./kubectl /usr/local/bin
    ```

1. Verify the installation

    ```bash
    oc version
    ```
    (Note: cluster connection is not yet possible.)

1. Create an IAM Policy

    Create a policy file in json ( vpce-policy.json)

    ```bash
    cat > vpce-policy.json <<EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "VisualEditor0",
          "Effect": "Allow",
          "Action": [
            "vpce:*",
            "ec2:CreateVpcEndpointServiceConfiguration",
            "ec2:CreateVpcEndpoint",
            "ec2:CreateVpcEndpointConnectionNotification"
          ],
          "Resource": "*"
        }
      ]
    }
    EOF
    ```

1. Create an IAM Policy from the json file

    ```bash
    IAM_POLICY_ARN=$(aws iam create-policy \
      --policy-name ROSAHcpVPCEndpointPolicy \
      --policy-document file://vpce-policy.json \
      --query 'Policy.Arn' \
      --output text)
    ```

#### Create an IAM Role

1. Get your current IAMUser ARN

      ```bash
      IAMUSER_ARN=$(aws sts get-caller-identity \
        --query "Arn" \
        --output text)
      ```

1. Create a trust relationship file (trust-policy.json)

    ```bash
    cat > trust-policy.json <<EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "AWS": "$IAMUSER_ARN"
          },
          "Action": "sts:AssumeRole"
        }
      ]
    }
    EOF
    ```

1. Create an IAM Role

    ```bash
    IAM_ROLE_ARN=$(aws iam create-role \
      --role-name ROSAHcpVPCEndpointRole \
      --assume-role-policy-document file://trust-policy.json \
      --query 'Role.Arn' \
      --output text)
    echo $IAM_ROLE_ARN  # e.g. arn:aws:iam::822827512345:role/ROSAHcpVPCEndpointRole
    ```

1. Attach the IAM Policy to the IAM Role

    ```
    aws iam attach-role-policy \
      --role-name ROSAHcpVPCEndpointRole \
      --policy-arn $IAM_POLICY_ARN
    ```

#### Configure AWS CLI to Assume the IAM Role

1. Add a new profile in `~/.aws/config` to assume the IAM Role created in the previous step.

    ```
    [default]
    region = <AWS Region>

    [profile myprofile]
    role_arn = <IAM_ROLE_ARN>
    source_profile = default
    region = <AWS Region>

    ```


## Setup on AWS Account‑A

Switch to AWS Account-A, where the ROSA cluster resides
![AWS Account A](./images/pic4.png)

   

#### Register the IAM Role with ROSA

1. Run On Bastion-A (or any rosa-enabled host) to set some environmental variables.

    ```bash
    CLUSTER_NAME=$(rosa list clusters -o json | jq -r '.[0].name')
    IAM_ROLE_ARN=<role ARN from Account-B>
    rosa edit cluster -c $CLUSTER_NAME --additional-allowed-principals $IAM_ROLE_ARN
    rosa describe cluster -c $CLUSTER_NAME | grep "Additional Principals:"
    ```

1. Get the VPC Endpoint Service Name for the ROSA hosted controlplane.

    ```bash
    aws ec2 describe-vpc-endpoints \
      --query "VpcEndpoints[*].[VpcEndpointId, ServiceName]" \
      --output table
    ```
   ( Note: The service name is like `com.amazonaws.vpce.<Your AWS region>.vpce-svc-....`)


1. Fetch the API URL for ROSA Cluster

    ```bash
    rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.api.url'
    ```
    Expect something like: `https://api.rosahcp.<id>.openshiftapps.com:443`


## Back to AWS Account‑B
Continue in Account-B 
![aws account B](./images/pic3.png)
      

#### Create a VPC Endpoint

1. Set some environment variables

    ```bash
    SERVICE_NAME=<from Account-A>
    INSTANCE_ID=<bastion-B EC2 ID>
    SUBNET_ID=$(aws ec2 describe-instances …)
    SUBNET_CIDR=$(aws ec2 describe-subnets …)
    VPC_ID=$(…)
    ```

1. Make sure the variables are set

    ```bash
    echo "VPC_ID=$VPC_ID, SERVICE_NAME=$SERVICE_NAME, SUBNET_ID=$SUBNET_ID, SUBNET_CIDR=$SUBNET_CIDR"
    ```

1. Create a security group for the VPC Endpoint

    ```bash
    SEC_GROUP_ID=$(aws ec2 create-security-group \
      --group-name MyVPCEndpointSG \
      --description "Security Group for VPC Endpoint" \
      --vpc-id $VPC_ID \
      --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=MyVPCEndpointSG}]' \
      --query 'GroupId' \
      --output text)
    ```

1. Allow inbound traffic from the subnet

    ```bash
    aws ec2 authorize-security-group-ingress \
      --group-id $SEC_GROUP_ID \
      --protocol tcp \
      --port 443 \
      --cidr $SUBNET_CIDR
    ```
    (Note: You can customize the rule depending your need. This is just an example.) 

1. Create an interface endpoint, using the `myprofile` role

    ```bash
    ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
      --vpc-id $VPC_ID \
      --service-name $SERVICE_NAME \
      --vpc-endpoint-type Interface \
      --subnet-ids $SUBNET_ID \
      --security-group-ids $SEC_GROUP_ID \
      --query 'VpcEndpoint.VpcEndpointId' \
      --output text \
      --profile myprofile)
    ```
    (Note: You run the command with `--profile myprofile` to assume the IAM Role you created in the previous step)

    If there are no errors, the VPC endpoint will be created. The request to connect the hosted control plane VPC service endpoint will be automatically accepted if the IAM role is configured correctly.
![aws account B](./images/pic5.png)

#### Create a Private DNS Zone in Route 53

1. Fetch the VPC endpoint DNS name

    ```bash
    ENDPOINT_DNS=$(aws ec2 describe-vpc-endpoints \
      --vpc-endpoint-ids $ENDPOINT_ID \
      --query 'VpcEndpoints[0].DnsEntries[0].DnsName' \
      --output text)
    ```

1. Extract the domain from the API URL

    ```bash
    API_URL=<ROSA API URL>
    DOMAIN=$(echo $API_URL | cut -d '/' -f3 | sed 's/^api\.//;s/:.*//')
    ```

1. Set the AWS region of the AWS account-B

    ```bash
    REGION=<AWS Region of AWS account-B>
    ```

1. Make sure the variables are set before proceeding

    ```bash
    echo "DOMAIN=$DOMAIN, REGION=$REGION, VPC_ID=$VPC_ID"
    ```

1. Create a Route 53 private hosted zone

    ```bash
    HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
      --name $DOMAIN \
      --vpc VPCRegion=$REGION,VPCId=$VPC_ID \
      --caller-reference $(date +%s) \
      --hosted-zone-config PrivateZone=true \
      --query 'HostedZone.Id' \
      --output text | cut -d'/' -f3)
    ```

1. Create DNS records

    ```bash
    cat > record.json <<EOF
    {
      "Changes": [
        {
          "Action": "CREATE",
          "ResourceRecordSet": {
            "Name": "api.$DOMAIN",
            "Type": "CNAME",
            "TTL": 300,
            "ResourceRecords": [ { "Value": "$ENDPOINT_DNS" } ]
          }
        },
        {
          "Action": "CREATE",
          "ResourceRecordSet": {
            "Name": "oauth.$DOMAIN",
            "Type": "CNAME",
            "TTL": 300,
            "ResourceRecords": [ { "Value": "$ENDPOINT_DNS" } ]
          }
        }
      ]
    }
    EOF

    aws route53 change-resource-record-sets \
      --hosted-zone-id $HOSTED_ZONE_ID \
      --change-batch file://record.json
    ```
    The DNS records for `api.<DOMAIN>` and `oauth.<DOMAIN>` are resovled to the VPC endpoint, and the traffic is routed to the Hosted Ccontrolplane managed by Red Hat SRE.


## Verify Connection
1. Test access from bastion-B to the hosted controlplane

    ```
    oc login $API_URL --username cluster-admin --password <password>
    ```


