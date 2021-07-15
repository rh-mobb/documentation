# Creating a ROSA cluster with Private Link enabled (custom VPC) and STS

**Steve Mirman**

*07/12/2021*

> This is a combination of the [private-link](../private-link) and [sts](../sts) setup documents to show the full picture

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [Rosa CLI](https://github.com/openshift/rosa/releases/tag/v1.0.8) v1.0.8
* [jq](https://stedolan.github.io/jq/download/)

## Create the AWS Virtual Private Cloud (VPC) and Subnets

For this scenario, we will be using a newly created VPC with both public and private subnets.  All of the cluster resources will reside in the private subnet. The plublic subnet will be used for traffic to the Internet (egress)

1. Set a Cluster name

    ```
    ROSA_CLUSTER_NAME=pl-sts-cluster
    ```

1. Create a VPC for use by ROSA

    - Create the VPC and return the ID as `VPC_ID`
      ```
       VPC_ID=`aws ec2 create-vpc --cidr-block 10.0.0.0/16 | jq -r .Vpc.VpcId`
      ```
    - Tag the newly created VPC with the cluster name
      ```bash
        aws ec2 create-tags --resources $VPC_ID \
        --tags Key=Name,Value=$ROSA_CLUSTER_NAME | jq .
      ```
    - Configure the VPC to allow DNS hostnames for their public IP addresses
      ```bash
        aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames | jq .
      ```
    - The new VPC should be visible in the AWS console

      ![Newly created VPC](./images/sts-pl1.png)

1. Create a Public Subnet to allow egress traffic to the Internet

    - Create the public subnet in the VPC CIDR block range and return the ID as `PUBLIC_SUBNET`
      ```bash
      PUBLIC_SUBNET=`aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.128.0/17 | jq -r .Subnet.SubnetId`
      ```

    - Tag the public subnet with the cluster name
      ```bash
      aws ec2 create-tags --resources $PUBLIC_SUBNET \
      --tags Key=Name,Value=$ROSA_CLUSTER_NAME-public | jq .
      ```

1. Create a Private Subnet for the cluster

    - Create the private subnet in the VPC CIDR block range and return the ID as `PRIVATE_SUBNET`
      ```bash
      PRIVATE_SUBNET=`aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.0.0/17 | jq -r .Subnet.SubnetId`
      ```
    
    - Tag the private subnet with the cluster name
      ```bash
      aws ec2 create-tags --resources $PRIVATE_SUBNET \
      --tags Key=Name,Value=$ROSA_CLUSTER_NAME-private | jq .
      ```

    - Both subnets should now be visible in the AWS console

      ![Newly created subnets](./images/sts-pl2.png)

1. Create an Internet Gateway for NAT egress traffic

      - Create the Internet Gateway and return the ID as `I_GW`
        ```
        I_GW=`aws ec2 create-internet-gateway | jq -r .InternetGateway.InternetGatewayId`
        ```
      
      - Attach the new Internet Gateway to the VPC
        ```bash
        aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $I_GW | jq .
        ```

      - Tag the Internet Gateway with the cluster name
        ```bash
        aws ec2 create-tags --resources $I_GW \
        --tags Key=Name,Value=$ROSA_CLUSTER_NAME | jq .
        ```
 
      - The new Internet Gateway should be created and attached to your VPC

        ![Newly created Internet Gateway](./images/sts-pl3.png)

1. Create a Route Table for NAT egress traffic

      - Create the Route Table and return the ID as `R_TABLE`
        ```bash
        R_TABLE=`aws ec2 create-route-table --vpc-id $VPC_ID | jq -r .RouteTable.RouteTableId`
        ```

      - Create a route with no IP limitations (0.0.0.0/0) to the Internet Gateway
        ```bash
        aws ec2 create-route --route-table-id $R_TABLE --destination-cidr-block 0.0.0.0/0 --gateway-id $I_GW | jq .
        ```

      - Verify the route table settings
        ```bash
          aws ec2 describe-route-tables --route-table-id $R_TABLE | jq .
        ```
        > Example output![Sample Route Table output](./images/sts-pl4.png)

      - Associate the Route Table with the Public subnet
        ```bash
          aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET --route-table-id $R_TABLE | jq .
        ```
        > Example output![Route Table association output](./images/sts-pl5.png)

      - Tag the Route Table with the cluster name
        ```bash
          aws ec2 create-tags --resources $R_TABLE \
          --tags Key=Name,Value=$ROSA_CLUSTER_NAME | jq .
        ```

1. Create a NAT Gateway for the Private network

      - Allocate and elastic IP address and return the ID as `EIP`
        ```bash
          EIP=`aws ec2 allocate-address --domain vpc | jq -r .AllocationId`
        ```

      - Create a new NAT Gateway in the Public subnet with the new Elastic IP address and return the ID as `NAT_GW`
        ```bash
          NAT_GW=`aws ec2 create-nat-gateway --subnet-id $PUBLIC_SUBNET \
          --allocation-id $EIP | jq -r .NatGateway.NatGatewayId`
        ```
      - Tag the Elastic IP with the cluster name
        ```bash
          aws ec2 create-tags --resources $EIP --resources $NAT_GW \
          --tags Key=Name,Value=$ROSA_CLUSTER_NAME | jq .
        ```

      - The new NAT Gateway should be created and associated with your VPC

        ![Newly created Internet Gateway](./images/sts-pl6.png)

1. Create a Route Table for the Private subnet to the NAT Gateway

      - Create a Route Table in the VPC and return the ID as `R_TABLE_NAT`
        ```bash
          R_TABLE_NAT=`aws ec2 create-route-table --vpc-id $VPC_ID | jq -r .RouteTable.RouteTableId`
        ```

      - Loop through a Route Table check until it is created
        ```bash
          while ! aws ec2 describe-route-tables --route-table-id $R_TABLE_NAT \
          | jq .; do sleep 1; done
        ```
        > Example output! <br>
        
          ![Route Table check output](./images/sts-pl7.png)

      - Create a route in the new Route Table for all addresses to the NAT Gateway
        ```bash
          aws ec2 create-route --route-table-id $R_TABLE_NAT --destination-cidr-block 0.0.0.0/0 --gateway-id $NAT_GW | jq .
        ```

      - Associate the Route Table with the Private subnet
        ```bash
          aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET --route-table-id $R_TABLE_NAT | jq .
        ```
      
      - Tag the Route Table with the cluster name
        ```bash
          aws ec2 create-tags --resources $R_TABLE_NAT $EIP \
          --tags Key=Name,Value=$ROSA_CLUSTER_NAME-private | jq .
        ```


## Configure the AWS Security Token Service (STS) for use with ROSA

The AWS Security Token Service (STS) allows us to deploy ROSA without needing a ROSA admin account, instead it uses roles and policies to gain access to the AWS resources needed to install and operate the cluster.

This is a summary of the [official OpenShift docs](https://docs.openshift.com/rosa/rosa_getting_started/rosa-sts-getting-started-workflow.html) that can be used as a line by line install guide.

> Note that some commands (OIDC for STS) will be hard coded to US-EAST-1, do not be tempted to change these to use $region instead or you will fail installation.

> Note as the roles created for STS in this guide have a common name (see the `ccoctl` command further down) only one cluster will be installable in a given AWS account.  You'll need to modify the name and resulting role bindings to deploy more than one cluster.

### Prerequisites

- Cloud Credential Operator CLI

    ```
    git clone https://github.com/openshift/cloud-credential-operator.git -b release-4.3
    cd cloud-credential-operator/cmd/ccoctl
    go build .
    mv ccoctl /usr/local/bin/ccoctl
    ccoctl --help
    ```

### Local script and variable configuration

We have provided a number of scripts, variables, and JSON configuration files to simplify the STS configuration process.  
1. Clone the following repository and `cd` into the root directory

    ```
    git clone https://github.com/rh-mobb/documentation.git
    cd documentation/docs/rosa/sts
    ```

1. Configure the following environment variables, adjusting for `name`, `version` and `region` as necessary

    ```bash
    export version=4.7.19 \
           ROSA_CLUSTER_NAME=pl-sts-cluster \
           aws_account_id=`aws sts get-caller-identity --query Account --output text` \
           region=us-east-2 \
           AWS_PAGER=""
    ```

### Prepare AWS and Red Hat accounts

> If this is your first time deploying ROSA you need to do some preparation as described [here](../../quickstart-rosa.md#Prerequisites).  Stop prior to running `rosa init`, as that is not required for STS mode.

## Creating IAM and OIDC roles for STS

Review the JSON Role files in the `./roles` directory.  Once configured, ROSA will be able to assume them to perform installation / day 2 operations.
```
ManagedOpenShift_ControlPlane_Role.json
ManagedOpenShift_ControlPlane_Role_Policy.json
ManagedOpenShift_IAM_Role.json
ManagedOpenShift_IAM_Role_Policy.json
ManagedOpenShift_Worker_Role.json
ManagedOpenShift_Worker_Role_Policy.json
RH_Support_Policy.json
RH_Support_Role.json
```

### Configure the installer access role and policy

This role is used to manage the installation and deletion of clusters that use STS.

1. Create the role, changing the `role-name` if required

    ```bash
    aws iam create-role \
    --role-name ManagedOpenShift-IAM-Role \
      --assume-role-policy-document \
      file://roles/ManagedOpenShift_IAM_Role.json
    ```

2. Attach the policy to the role, changing the `policy-name` if required

    ```bash
    aws iam put-role-policy \
      --role-name ManagedOpenShift-IAM-Role \
      --policy-name ManagedOpenShift-IAM-Role-Policy \
      --policy-document \
      file://roles/ManagedOpenShift_IAM_Role_Policy.json
    ```

### Control plane node instance profile role

1. Create the role, changing the `role-name` if required

    ```bash
    aws iam create-role \
      --role-name ManagedOpenShift-ControlPlane-Role \
      --assume-role-policy-document \
      file://roles/ManagedOpenShift_ControlPlane_Role.json
    ```

2. Attach the policy to the role, changing the `policy-name` if required

    ```bash
    aws iam put-role-policy \
      --role-name ManagedOpenShift-ControlPlane-Role \
      --policy-name ManagedOpenShift-ControlPlane-Role-Policy \
      --policy-document \
      file://roles/ManagedOpenShift_ControlPlane_Role_Policy.json
    ```

### Worker node instance profile role

1. Create the role, changing the `role-name` if required

    ```bash
    aws iam create-role \
      --role-name ManagedOpenShift-Worker-Role \
      --assume-role-policy-document \
      file://roles/ManagedOpenShift_Worker_Role.json
    ```

1. Attach the policy to the role, changing the `policy-name` if required

    ```bash
    aws iam put-role-policy \
      --role-name ManagedOpenShift-Worker-Role \
      --policy-name ManagedOpenShift-Worker-Role-Policy \
      --policy-document \
      file://roles/ManagedOpenShift_Worker_Role_Policy.json
    ```

### STS support role

The STS support role is designed to give Red Hat site reliability engineering (SRE) read-only access to support a given cluster and troubleshoot issues.

1. Create the role, changing the `role-name` if required

    ```bash
    aws iam create-role \
      --role-name ManagedOpenShift-Support-Role \
      --assume-role-policy-document file://roles/RH_Support_Role.json
    ```

1. Create the support policy, changing the `policy-name` if required

    ```bash
    aws iam create-policy \
      --policy-name ManagedOpenShift-Support-Access \
      --policy-document file://roles/RH_Support_Policy.json
    ```

1. List the support policy ARN, saving it as `policy_arn`

    ```
    policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='ManagedOpenShift-Support-Access'].Arn" --output text)
    ```

1. Attach the policy to the support role, changing the `policy-name` if required

    ```bash   
    aws iam attach-role-policy \
      --role-name ManagedOpenShift-Support-Role \
      --policy-arn $policy_arn
    ```

## Deploy ROSA cluster

> Note, the role ARNs are truncated to 64 CHAR to suit the AWS limits on ARNs. If you change them, you also need to change the script that creates the roles further down.

1. Run the rosa cli to create your cluster

    ```bash
    rosa create cluster --private-link --machine-cidr=10.0.0.0/16 \
      --subnet-ids=$PRIVATE_SUBNET --cluster-name ${ROSA_CLUSTER_NAME} \
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

    > Confirm the Private Link set up
    ![Route Table check output](./images/sts-pl8.png)

1. Wait for cluster status to change to pending

    ```bash
    while ! \
    rosa describe cluster -c $ROSA_CLUSTER_NAME | grep "Waiting for OIDC"; \
    do sleep 1; done
    ```

    > Proceed when `pending` message appears
    ![Route Table check output](./images/sts-pl9.png)


1. Create the OIDC provider.

    - Obtain the cluster ID and store as `cluster_id`
      ```bash
      cluster_id=$(rosa describe cluster -c $ROSA_CLUSTER_NAME | grep "^ID:" | awk '{ print $2}')
      ```

    - Store the ssl thumbprint as `thumbprint`
      ```bash
      thumbprint=$(openssl s_client -servername \
      rh-oidc.s3.us-east-1.amazonaws.com/${cluster_id} \
      -showcerts -connect rh-oidc.s3.us-east-1.amazonaws.com:443 \
      </dev/null 2>&1| openssl x509 -fingerprint -noout | tail -n1 \
      | sed 's/SHA1 Fingerprint=//' | sed 's/://g')
      ```

    - Create the OID provider
      ```bash
        aws iam create-open-id-connect-provider \
        --url "https://rh-oidc.s3.us-east-1.amazonaws.com/${cluster_id}" \
        --client-id-list openshift sts.amazonaws.com \
        --thumbprint-list "${thumbprint}"
      ```

1. Generate permissions for OIDC-access-based roles

    - Create a local directory for YAML files
      ```bash
        mkdir -p credrequests
      ```

    - Extract credentials to the `credrequests` directory
      ```bash
        oc adm release extract \
        quay.io/openshift-release-dev/ocp-release:${version:0:3}.0-x86_64 \
        --credentials-requests \
        --cloud=aws \
        --to credrequests
      ```

    - Combine the YAML files into a single file 
      ```bash
        cat credrequests/0000*.yaml > credrequests/${version:0:3}.yaml
      ```

    - Remove the individual YAML files 
      ```bash
      rm -f credrequests/0000*.yaml
      ```

1. Prepare the IAM roles

    - Create a local directory and `cd` into it
      ```
      mkdir -p iam_assets
      cd iam_assets
      ```

    - Use the Cloud Credential Operator CLI (CCOCTL) to create local JSON and YAML files
      ```bash
      ccoctl aws create-iam-roles \
      --credentials-requests-dir ../credrequests/ \
      --identity-provider-arn "arn:aws:iam::${aws_account_id}:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/${cluster_id}" \
      --name ManagedOpenShift \
      --region ${region} \
      --dry-run
      ```

    - Switch back to the `sts` directory
      ```
      cd ..
      ```

1. Apply the IAM roles

    ```bash
    ./apply-roles.sh
    ```

1. Validate The cluster is now Installing

    > The State should have moved beyond `pending` and show `installing` or `ready`.
    
    ```bash
    rosa describe cluster -c $ROSA_CLUSTER_NAME | grep State
    ```
    ![Route Table check output](./images/sts-pl10.png)

    > The installation process could take 30-40 minutes

1. Watch the install logs

    ```bash
    rosa logs install -c $ROSA_CLUSTER_NAME --watch
    ```

## Validate the cluster

Once the cluster has finished installing it is time to validate.  Validation when using Private Link requires the use of a **jump host**.

1. Create a **jump host** instance through the AWS Console

    - Navigate to the EC2 console and launch a new instance
    
    - Select the AMI for your instance, if you don't have a standard, the Amazon Linux 2 AMI works just fine
    ![AMI instance](./images/sts-pl11.png)

    - Choose your instance type, the t2.micro/free tier is sufficient for our needs, and click **Next: Configure Instance Details**

    - Change the **Network** settings to setup this host inside your _private-link_ VPC  
       ![network](./images/sts-pl12.png)

    - Change the **Subnet** setting to use the _private-link-public_ subnet  
      ![subnet](./images/sts-pl13.png)

    - Change **Auto-assign Public IP** to _Enable_  
      ![Public IP](./images/sts-pl14.png)

    - Default settings for **Storage** and **Tags** are fine.  Make the following changes in the  **6. Configure Security Group** tab (either by clicking through the screens or selecting from the top bar)
      - If you already have a security group created to allow access from your computer to AWS, choose **Select an existing security group** and choose that group from the list, otherwise, select **Create a new security group** and continue.

      - To allow access only from your current public IP, change the **Source** heading to use _My IP_  
      ![Access from public IP](./images/sts-pl15.png)

    - Click **Review and Launch**, verify all settings are correct, and follow the standard AWS instructions for finalizing the setup and selecting/creating the security keys.

    - Once launched, open the instance summary for the jump host instance and note the public IP address.


1. Create a ROSA admin user and save the login command for use later

    ```
    rosa create admin -c $ROSA_CLUSTER_NAME
    ```

1. Note the DNS name of your private cluster, use the `rosa describe` command if needed

    ```
    rosa describe cluster -c $ROSA_CLUSTER_NAME
    ```

1. update /etc/hosts to point the openshift domains to localhost. Use the DNS of your openshift cluster as described in the previous step in place of `$YOUR_OPENSHIFT_DNS` below

    ```
    127.0.0.1 api.$YOUR_OPENSHIFT_DNS
    127.0.0.1 console-openshift-console.apps.$YOUR_OPENSHIFT_DNS
    127.0.0.1 oauth-openshift.apps.$YOUR_OPENSHIFT_DNS
    ```


1. SSH to that instance, tunneling traffic for the appropriate hostnames. Be sure to use your new/existing private key, the OpenShift DNS for `$YOUR_OPENSHIFT_DNS` and your jump host IP for `$YOUR_EC2_IP`

    ```bash
      sudo ssh -i PATH/TO/YOUR_KEY.pem \
      -L 6443:api.$YOUR_OPENSHIFT_DNS:6443 \
      -L 443:console-openshift-console.apps.$YOUR_OPENSHIFT_DNS:443 \
      -L 80:console-openshift-console.apps.$YOUR_OPENSHIFT_DNS:80 \
       ec2-user@$YOUR_EC2_IP
    ```
    ![EC2 login](./images/sts-pl16.png)

1. From your EC2 jump instances, download the OC CLI and install it locally
    - Download the OC CLI for Linux
      ```
      wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/  openshift-client-linux.tar.gz
      ```
    - Unzip and untar the binary
      ```
        gunzip openshift-client-linux.tar.gz
        tar -xvf openshift-client-linux.tar
      ```

1. log into the cluster using oc login command from the create admin command above. ex.

    ```bash
    ./oc login https://api.$YOUR_OPENSHIFT_DNS.p1.openshiftapps.com:6443 --username cluster-admin --password $YOUR_OPENSHIFT_PWD
    ```
    ![oc login](./images/sts-pl17.png)

1. Check that you can access the Console by opening the console url in your browser.
  ![oc login](./images/sts-pl18.png)

## Cleanup

1. Delete ROSA

    ```bash
    rosa delete cluster -c $ROSA_CLUSTER_NAME -y
    ```

1. Watch the logs and wait until the cluster is deleted

    ```bash
    rosa logs uninstall -c $ROSA_CLUSTER_NAME --watch
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

1. Delete AWS resources

    ```bash
    aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW | jq .
    aws ec2 release-address --allocation-id=$EIP | jq .
    aws ec2 detach-internet-gateway --vpc-id $VPC_ID \
      --internet-gateway-id $I_GW | jq .
    aws ec2 delete-subnet --subnet-id=$PRIVATE_SUBNET | jq .
    aws ec2 delete-subnet --subnet-id=$PUBLIC_SUBNET | jq .
    aws ec2 delete-route-table --route-table-id=$R_TABLE | jq .
    aws ec2 delete-route-table --route-table-id=$R_TABLE_NAT | jq .
    aws ec2 delete-vpc --vpc-id=$VPC_ID | jq .
    ```

