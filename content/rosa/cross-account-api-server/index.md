---
date: '2025-07-02'
title: Accessing the ROSA HCP API Server from a Different AWS Account
tags: ["AWS", "ROSA", "HCP"]
authors:
  - Andy Repton
---

The Amazon Web Services Elastic File System (AWS EFS) is a Network File System (NFS) that can be provisioned on Red Hat OpenShift Service on AWS clusters. With the release of OpenShift 4.10 the EFS CSI Driver is now GA and available.

This is a guide to enable cross-account EFS mounting on ROSA.

> Important: Cross Account EFS is considered an advanced topic, and this article makes various assumptions as to knowledge of AWS terms and techniques across VPCs, Networking, IAM permissions and more.

## Prerequisites

* One AWS Account containing a Red Hat OpenShift on AWS (ROSA) 4.16 or later cluster, in a VPC
* One AWS Account containing (or which will contain) the EFS filesystem, containing a VPC
* The OC CLI
* The AWS CLI
* `jq` command
* `watch` command


1. Introduction                         

You can create a ROSA HCP cluster in one AWS account and configure it so that you can run oc commands from a different AWS account. Although this setup is documented, detailed steps for AWS-side configuration are not provided. Here, I walk through the actual AWS setup.

Note: AWS environments vary, so consider this as one possible setup.


1. Prerequisites

Assume ROSA is already deployed in Account-A, and the following AWS resources are available: (diagram omitted)
   

1. Setup on AWS Account‑B

This section covers steps in AWS Account-B: (diagram omitted)


1.1 Prepare Bastion-B Tools
On the EC2 bastion instance (bastion-B), install the required tools:

```bash
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/rosa/latest/rosa-linux.tar.gz
tar -zxf rosa-linux.tar.gz 
sudo mv ./rosa /usr/local/bin/
rosa download oc
tar -xzf openshift-client-linux.tar.gz 
sudo mv ./oc /usr/local/bin
sudo mv ./kubectl /usr/local/bin
```


Verify installation:
```bash
oc version
```
(Note: cluster connection is not yet possible.)


3.2 Prepare IAM Role and Policy
3.2.1 Create IAM Policy
Create vpce-policy.json:

```bash
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
```

Apply it:
```bash
IAM_POLICY_ARN=$(aws iam create-policy \
  --policy-name ROSAHcpVPCEndpointPolicy \
  --policy-document file://vpce-policy.json \
  --query 'Policy.Arn' \
  --output text)
```

3.2.2 Create IAM Role
Get your current IAM user ARN:
```bash
IAMUSER_ARN=$(aws sts get-caller-identity \
  --query "Arn" \
  --output text)
```

Create trust relationship file (trust-policy.json):
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

Create the role:
```bash
IAM_ROLE_ARN=$(aws iam create-role \
  --role-name ROSAHcpVPCEndpointRole \
  --assume-role-policy-document file://trust-policy.json \
  --query 'Role.Arn' \
  --output text)
echo $IAM_ROLE_ARN  # e.g. arn:aws:iam::822827512345:role/ROSAHcpVPCEndpointRole
```

Attach the policy:
```
aws iam attach-role-policy \
  --role-name ROSAHcpVPCEndpointRole \
  --policy-arn $IAM_POLICY_ARN
```

3.3 Configure AWS CLI to Assume the IAM Role
Add a new profile in `~/.aws/config` to assume the role:
```
[default]
region = <AWS Region>

[profile myprofile]
role_arn = <IAM_ROLE_ARN>
source_profile = default
region = <AWS Region>

```


4. Setup on AWS Account‑A
Switch to Account-A, where the ROSA cluster resides: (diagram omitted)

4.1 Register IAM Role with ROSA
On Bastion-A (or any rosa-enabled host):
```bash
CLUSTER_NAME=$(rosa list clusters -o json | jq -r '.[0].name')
IAM_ROLE_ARN=<role ARN from Account-B>
rosa edit cluster -c $CLUSTER_NAME --additional-allowed-principals $IAM_ROLE_ARN
rosa describe cluster -c $CLUSTER_NAME | grep "Additional Principals:"
```

4.2 Get VPC Endpoint Service Name
```bash
aws ec2 describe-vpc-endpoints \
  --query "VpcEndpoints[*].[VpcEndpointId, ServiceName]" \
  --output table
```
Note the service name for the Hosted Control Plane endpoint, e.g., com.amazonaws.vpce.ap-northeast-1.vpce-svc-....




4.3 Fetch API URL for ROSA Cluster
```bash
rosa describe cluster -c $CLUSTER_NAME -o json | jq -r '.api.url'
```
Expect something like:` https://api.rosahcp.<id>.openshiftapps.com:443`


5. Back to AWS Account‑B
Continue in Account-B: (diagram omitted)

5.1 Create VPC Endpoint
Set variables:
```bash
SERVICE_NAME=<from Account-A>
INSTANCE_ID=<bastion-B EC2 ID>
SUBNET_ID=$(aws ec2 describe-instances …)
SUBNET_CIDR=$(aws ec2 describe-subnets …)
VPC_ID=$(…)
```

Verify:
```bash
echo "VPC_ID=$VPC_ID, SERVICE_NAME=$SERVICE_NAME, SUBNET_ID=$SUBNET_ID, SUBNET_CIDR=$SUBNET_CIDR"
```

Create security group:
```bash
SEC_GROUP_ID=$(aws ec2 create-security-group \
  --group-name MyVPCEndpointSG \
  --description "Security Group for VPC Endpoint" \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=MyVPCEndpointSG}]' \
  --query 'GroupId' \
  --output text)
```

Allow inbound from subnet:
```bash
aws ec2 authorize-security-group-ingress \
  --group-id $SEC_GROUP_ID \
  --protocol tcp \
  --port 443 \
  --cidr $SUBNET_CIDR
```

Create the interface endpoint, using the `myprofile` role:
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


If no error, the endpoint is created.

5.2 Configure Private DNS Zone in Route 53
Fetch the endpoint DNS name:

```bash
ENDPOINT_DNS=$(aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids $ENDPOINT_ID \
  --query 'VpcEndpoints[0].DnsEntries[0].DnsName' \
  --output text)
```

Extract domain from API URL:
```bash
API_URL=<ROSA API URL>
DOMAIN=$(echo $API_URL | cut -d '/' -f3 | sed 's/^api\.//;s/:.*//')
```

Set the region:

```bash
REGION=<AWS Region>
```

Check:
```bash
echo "DOMAIN=$DOMAIN, REGION=$REGION, VPC_ID=$VPC_ID"
```

Create Route 53 private hosted zone:
```bash
HOSTED_ZONE_ID=$(aws route53 create-hosted-zone \
  --name $DOMAIN \
  --vpc VPCRegion=$REGION,VPCId=$VPC_ID \
  --caller-reference $(date +%s) \
  --hosted-zone-config PrivateZone=true \
  --query 'HostedZone.Id' \
  --output text | cut -d'/' -f3)
```
Create DNS records:
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
This ensures DNS resolution of `api.<DOMAIN>` and `oauth.<DOMAIN>` points to the VPC endpoint and routes traffic to the Hosted Control Plane.

6. Verify Connection
Test access from bastion-B:
```
oc login $API_URL --username cluster-admin --password <password>
```

1. Summary
You have now:

Set up tools on bastion-B in Account-B.
Created IAM role/policy allowing Account-B to call AWS on ROSA’s behalf.
Registered that role with the ROSA cluster in Account-A.
Created an interface VPC endpoint and private DNS in Account-B.
Verified oc access from Account-B into ROSA.













