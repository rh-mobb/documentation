# Creating a ROSA cluster with Private Link enabled

## Create VPC and Subnets

Pick one of the following options

### Option 1 - VPC with a private subnet and AWS Site-to-Site VPN access.

### Option 2 - VPC with public and private subnets (NAT)

1. Create a VPC

    ```
    VPC_ID=`aws ec2 create-vpc --cidr-block 10.0.0.0/16 | jq -r .Vpc.VpcId`

    aws ec2 create-tags --resources $VPC_ID \
      --tags Key=Name,Value=rosa-private-link | jq .

    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames | jq .
    ```

1. Create a Public Subnet

    ```bash
    PUBLIC_SUBNET=`aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.128.0/17 | jq -r .Subnet.SubnetId`

    aws ec2 create-tags --resources $PUBLIC_SUBNET \
      --tags Key=Name,Value=rosa-private-link-public | jq .

    aws ec2 modify-subnet-attribute --subnet-id $PUBLIC_SUBNET --map-public-ip-on-launch | jq .
    ```

1. Create a Private Subnet

    ```bash
    PRIVATE_SUBNET=`aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.0.0/17 | jq -r .Subnet.SubnetId`

    aws ec2 create-tags --resources $PRIVATE_SUBNET \
      --tags Key=Name,Value=rosa-private-link-private | jq .
    ```

1. Create an Internet Gateway

    ```bash
    I_GW=`aws ec2 create-internet-gateway | jq -r .InternetGateway.InternetGatewayId`
    aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $I_GW | jq .

    aws ec2 create-tags --resources $I_GW \
      --tags Key=Name,Value=rosa-private-link | jq .
    ```

1. Create a Route Table for the Public subnet

    ```bash
    R_TABLE_I=`aws ec2 create-route-table --vpc-id $VPC_ID | jq -r .RouteTable.RouteTableId`

    while ! aws ec2 describe-route-tables --route-table-id $R_TABLE_I \
      | jq .; do sleep 1; done

    aws ec2 create-route --route-table-id $R_TABLE_I --destination-cidr-block 0.0.0.0/0 --gateway-id $I_GW | jq .

    aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET --route-table-id $R_TABLE_I | jq .

    aws ec2 create-tags --resources $R_TABLE_I \
      --tags Key=Name,Value=rosa-private-link-public | jq .
    ```

1. Create a NAT Gateway

    ```bash
    EIP=`aws ec2 allocate-address --domain vpc | jq -r .AllocationId`
    NAT_GW=`aws ec2 create-nat-gateway --subnet-id $PRIVATE_SUBNET \
      --allocation-id $EIP | jq -r .NatGateway.NatGatewayId`

1. Create a Route Table for the Private subnet

    ```bash
    R_TABLE_NAT=`aws ec2 create-route-table --vpc-id $VPC_ID | jq -r .RouteTable.RouteTableId`

    while ! aws ec2 describe-route-tables --route-table-id $R_TABLE_NAT \
      | jq .; do sleep 1; done

    aws ec2 create-route --route-table-id $R_TABLE_NAT --destination-cidr-block 0.0.0.0/0 --gateway-id $NAT_GW | jq .

    aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET --route-table-id $R_TABLE_NAT | jq .

    aws ec2 create-tags --resources $R_TABLE_NAT $EIP \
      --tags Key=Name,Value=rosa-private-link-private | jq .
    ```
<!--
1. Create Network ACLs

    ```bash
    ACL=`aws ec2 describe-network-acls --filters \
      "Name=association.subnet-id,Values=$PRIVATE_SUBNET" \
      | jq -r ".NetworkAcls[0].Associations[0].NetworkAclId"`

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
-->




### Option 3 - VPC with public and private subnets and AWS Site-to-Site VPN access


1. Create ROSA cluster

    ```bash
    rosa create cluster --private-link --cluster-name=private-test \
    --subnet-ids=$PRIVATE_SUBNET
    ```