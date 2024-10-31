---
date: '2024-10-29'
title: Securely exposing an application on a private ROSA cluser with an AWS Network Load Balancer - Jump Host
tags: ["AWS", "ROSA"]
authors:
  - Kevin Collins
---
## Continuation of [Securely exposing an application on a private ROSA cluser with an AWS Network Load Balancer](/experts/rosa/hcp-private-nlb/)

These instructions go through setting up a jump host to connect to the private rosa cluster.

> Note: the guide assumes you have set envirionment variables as described in the parent guide.


### Create a **jumphost** instance using the AWS CLI

Create an additional Security Group for the jumphost

```bash
TAG_SG="$ROSA_CLUSTER_NAME-jumphost-sg"

aws ec2 create-security-group --group-name ${ROSA_CLUSTER_NAME}-jumphost-sg --description ${ROSA_CLUSTER_NAME}-jumphost-sg --vpc-id ${ROSA_VPC_ID} --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$TAG_SG}]"
```

Grab the Security Group Id generated in the previous step

```bash
PublicSecurityGroupId=$(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=${ROSA_CLUSTER_NAME}-jumphost-sg" | jq -r '.SecurityGroups[0].GroupId')

echo $PublicSecurityGroupId
```

Add a rule to Allow the ssh into the Public Security Group

```bash
aws ec2 authorize-security-group-ingress --group-id $PublicSecurityGroupId --protocol tcp --port 22 --cidr 0.0.0.0/0
```

(Optional) Create a Key Pair for your jumphost if your have not a previous one

```bash
aws ec2 create-key-pair --key-name $ROSA_CLUSTER_NAME-key --query 'KeyMaterial' --output text > PATH/TO/YOUR_KEY.pem
    
chmod 400 PATH/TO/YOUR_KEY.pem
```

Define an AMI_ID to be used for your jump host

```bash
AMI_ID="ami-0022f774911c1d690"
```

> This AMI_ID corresponds an Amazon Linux within the us-east-1 region and could be not available in your region. [Find your AMI ID](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/finding-an-ami.html) and use the proper ID.

Launch an ec2 instance for your jumphost using the parameters defined in early steps:

```bash
TAG_VM="$ROSA_CLUSTER_NAME-jumphost-vm"

aws ec2 run-instances --image-id $AMI_ID --count 1 --instance-type t2.micro --key-name $ROSA_CLUSTER_NAME-key --security-group-ids $PublicSecurityGroupId --subnet-id $JUMP_HOST_SUBNET --associate-public-ip-address --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG_VM}]"
```

> This instance will be associated with a Public IP directly.

- Wait until the ec2 instance is in Running state, grab the Public IP associated to the instance and check the if the ssh port and:

```bash
IpPublicBastion=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$TAG_VM" | jq -r '.Reservations[0].Instances[0].PublicIpAddress')

echo $IpPublicBastion

nc -vz $IpPublicBastion 22
```
    
### Test the jumphost connectivity to the cluster

Open a new terminal tab and set the IpPublicBastion environment variable.  Through the rest of the tutorial, use the SSH session you are going to open to run all 'oc' commands.   The AWS CLI commands will need to various environment variables to be set.

```bash
ssh -i <YOUR PEM FILE> ec2-user@$IpPublicBastion
```

While in the EC2 instance, create and install the oc cli

```bash
mkdir bin
if ! which oc > /dev/null; then
    curl -Ls https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.15/openshift-client-linux.tar.gz | tar xzf -

    install oc ~/bin
    install kubectl ~/bin
fi
```
