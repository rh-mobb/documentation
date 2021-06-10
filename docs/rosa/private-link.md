# Creating a ROSA cluster with Private Link enabled

## Create VPC and Subnets

Pick one of the following options

### Option 1 - VPC with a private subnet and AWS Site-to-Site VPN access.

### Option 2 - VPC with public and private subnets (NAT)

1. Create a VPC

    ```
    VPC_ID=`aws ec2 create-vpc --cidr-block 10.0.0.0/16 | jq -r .Vpc.VpcId`
    ```

1. Create a Public Subnet

    ```bash
    PUBLIC_SUBNET=`aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.128.0/17 | jq -r .Subnet.SubnetId`
    ```

1. Create a Private Subnet

    ```bash
    PRIVATE_SUBNET=`aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.0.0/17 | jq -r .Subnet.SubnetId`
    ```

1. Create an Internet Gateway and Route Table

    ```bash
    I_GW=`aws ec2 create-internet-gateway | jq -r .InternetGateway.InternetGatewayId`
    aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $I_GW | jq .
    ```

1. Create a Route Table

    ```bash
    R_TABLE=`aws ec2 create-route-table --vpc-id $VPC_ID | jq -r .RouteTable.RouteTableId`

    aws ec2 create-route --route-table-id $R_TABLE --destination-cidr-block 0.0.0.0/0 --gateway-id $I_GW | jq .

    aws ec2 describe-route-tables --route-table-id $R_TABLE | jq .

    aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET --route-table-id $R_TABLE | jq .
    ```

1. Create Network ACLs

    ```bash
    ACL=`aws ec2 create-network-acl --vpc-id $VPC_ID | jq -r .NetworkAcl.NetworkAclId`

    aws ec2 create-network-acl-entry --network-acl-id $ACL \
      --ingress --rule-number 100 --protocol tcp \
      --port-range From=80,To=80 --cidr-block 0.0.0.0/0 \
      --rule-action allow | jq .

    aws ec2 create-network-acl-entry --network-acl-id $ACL \
      --ingress --rule-number 200 --protocol tcp \
      --port-range From=443,To=443 --cidr-block 0.0.0.0/0 \
      --rule-action allow | jq .

    aws ec2 create-network-acl-entry --network-acl-id $ACL \
      --ingress --rule-number 300 --protocol tcp \
      --port-range From=22,To=22 --cidr-block 0.0.0.0/0 \
      --rule-action allow | jq .

    aws ec2 create-network-acl-entry --network-acl-id $ACL \
      --egress --rule-number 400 --protocol -1 \
      --port-range From=0,To=65535 --cidr-block 0.0.0.0/0 \
      --rule-action allow | jq .

    aws ec2 create-network-acl-entry --network-acl-id $ACL \
      --ingress --rule-number 500 --protocol -1 \
      --port-range From=1024,To=65535 --cidr-block 0.0.0.0/0 \
      --rule-action allow | jq .
    ```





### Option 3 - VPC with public and private subnets and AWS Site-to-Site VPN access


1. Create ROSA cluster

    ```bash
    rosa create cluster --private-link --cluster-name=private-test \
    --machine-cidr=10.0.0.0/16 \
    --subnet-ids=$PRIVATE_SUBNET
    ```