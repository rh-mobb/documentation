# Creating a ROSA cluster with Private Link enabled

## Create VPC and Subnets

The following instructions use the AWS CLI to create the necessary networking to deploy a Private Link ROSA cluster into a Single AZ and are intended to be a guide. Ideally you would use an Automation tool like Ansible or Terraform to manage your VPCs.

### Option 1 - VPC with a private subnet and AWS Site-to-Site VPN access.

Todo

### Option 2 - VPC with public and private subnets and AWS Site-to-Site VPN access

ToDo

### Option 3 - VPC with public and private subnets (NAT)

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

1. Create a NAT Gateway

    ```bash
    EIP=`aws ec2 allocate-address --domain vpc | jq -r .AllocationId`
    NAT_GW=`aws ec2 create-nat-gateway --subnet-id $PUBLIC_SUBNET \
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

<!--  These need more testing before using, the default ACLs are permissive and will work.

1. Create Network ACLs

    ```bash
    ACL=`aws ec2 create-network-acl --vpc-id $VPC_ID | jq -r .NetworkAcl.NetworkAclId`

    aws ec2 delete-network-acl-entry --network-acl-id $ACL \
      --rule-number 100

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

## Deploy ROSA

1. Create ROSA cluster

    ```bash
    rosa create cluster --private-link --cluster-name=private-test \
    --machine-cidr=10.0.0.0/16 \
    --subnet-ids=$PRIVATE_SUBNET
    ```

## Test Connectivity

1. Create an Instance to use as a jump host

    I just did this via GUI, will come back to it and add cli

1. Create a ROSA admin user

    ```
    rosa create admin -c private-test
    ```

1. update /etc/hosts to point the domains to localhost

    ```
    127.0.0.1 api.private-test.3d1n.p1.openshiftapps.com
    127.0.0.1 console-openshift-console.apps.private-test.3d1n.p1.openshiftapps.com
    127.0.0.1 oauth-openshift.apps.private-test.3d1n.p1.openshiftapps.com
    ```


1. SSH to that instance (use the appropriate hostnames and IP)

    ```bash
      sudo ssh -i ./temp-instance.pem \
      -L 6443:api.private-test.3d1n.p1.openshiftapps.com:6443 \
      -L 443:console-openshift-console.apps.private-test.3d1n.p1.openshiftapps.com:443 \
      -L 80:console-openshift-console.apps.private-test.3d1n.p1.openshiftapps.com:80 \
       ec2-user@18.118.23.167
    ```

1. Log into the cluster using oc (from the create admin command above)

    ```bash
    oc login https://api.private-test.3d1n.p1.openshiftapps.com:6443 --username cluster-admin --password GQSGJ-daqfN-8QNY3-tS9gU
Login successful
    ```

1. Check that you can access the Console by opening the console url in your browser.