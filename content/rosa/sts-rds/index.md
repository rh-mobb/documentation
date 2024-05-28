---
date: '2023-07-24'
title: Connect to RDS database with STS from ROSA
tags: ["AWS", "ROSA", "RDS", "STS"]
aliases: ["/docs/rosa/using-sts-with-aws-services"]
authors:
  - Florian Jacquin
---

The Amazon Web Services Relational Database Service (AWS RDS) can be consumed from Red Hat OpenShift Service on AWS (ROSA) and authenticate to DB with Security Token Service (STS).

This is a guide to quickly connect to RDS Database (Postgres engine) from ROSA.

## Amazon Web Services Relational Database Service

Amazon Web Services Relational Database Service (AWS RDS) is a distributed relational database service by Amazon Web Services. 
It is designed to simplify setup, operation, and scaling of a relational database for use in applications.
It supports differents database engines such as Amazon Aurora, MySQL, MariaDB, Oracle, Microsoft SQL Server, and PostgreSQL.

In our example we will use PostgreSQL as engine.

## Prerequisites

* A Red Hat OpenShift on AWS (ROSA) 4.12 cluster
* The OC CLI
* The AWS CLI
* `jq` command

## Set up environment

1. Export value of your cluster name (`rosa list cluster`)
   ```bash
   export CLUSTER_NAME=<your_cluster_name>    
   ```

2. Export list of environements variables from your cluster
   ```bash
   export AWS_REGION=$(rosa describe cluster -c ${CLUSTER_NAME} -o json | jq -r .region.id)
   export OIDC_PROVIDER=$(rosa describe cluster -c ${CLUSTER_NAME} -o json \
    | jq -r .aws.sts.oidc_endpoint_url | sed -e 's/^https:\/\///')
   export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   export SCRATCH_DIR=/tmp/scratch
   export AWS_PAGER=""
   export PSQL_PASSWORD=$(openssl rand -base64 12)
   export NODE=$(oc get nodes --selector=node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].metadata.name}')
   export VPC_ROSA=$(aws ec2 describe-instances \
    --filters "Name=private-dns-name,Values=$NODE" \
    --query 'Reservations[*].Instances[*].{VpcId:VpcId}' \
    --region $AWS_REGION \
    | jq -r '.[0][0].VpcId')
   export ROSA_IP_OUT=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ROSA}" --region ${AWS_REGION} \
    | jq -r .NatGateways[].NatGatewayAddresses[].PublicIp)
   mkdir -p $SCRATCH_DIR
   ```
## Create database network

1. VPC + Subnets

   ```bash
   VPC_DB=$(aws ec2 create-vpc --cidr-block 10.23.0.0/16 --region ${AWS_REGION} | jq -r .Vpc.VpcId)
   aws ec2 modify-vpc-attribute --vpc-id ${VPC_DB} --enable-dns-hostnames "{\"Value\":true}"
   aws ec2 modify-vpc-attribute --vpc-id ${VPC_DB} --enable-dns-support "{\"Value\":true}"
   SUBNET_A=$(aws ec2 create-subnet --vpc-id ${VPC_DB} --cidr-block 10.23.1.0/24 --availability-zone ${AWS_REGION}a | jq -r .Subnet.SubnetId)
   SUBNET_B=$(aws ec2 create-subnet --vpc-id ${VPC_DB} --cidr-block 10.23.2.0/24 --availability-zone ${AWS_REGION}b | jq -r .Subnet.SubnetId) 
   SUBNET_C=$(aws ec2 create-subnet --vpc-id ${VPC_DB} --cidr-block 10.23.3.0/24 --availability-zone ${AWS_REGION}c | jq -r .Subnet.SubnetId)
   ```
2. Internet Gateway

   ```bash
   IGW=$(aws ec2 create-internet-gateway --region ${AWS_REGION} | jq -r .InternetGateway.InternetGatewayId)
   aws ec2 attach-internet-gateway --vpc-id ${VPC_DB} --internet-gateway-id ${IGW}
   RT_ID=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=${VPC_DB} --region ${AWS_REGION}  | jq -r .RouteTables[].RouteTableId)
   aws ec2 create-route --route-table-id ${RT_ID} --destination-cidr-block 0.0.0.0/0 --gateway-id ${IGW} --region ${AWS_REGION}
   ```

3. DB Subnet group

   ```bash
   aws rds create-db-subnet-group --db-subnet-group-name db-group-${CLUSTER_NAME} \
      --db-subnet-group-description "DB Subnet group for testing RDS" \
      --subnet-ids ${SUBNET_A} ${SUBNET_B} ${SUBNET_C} \
      --region ${AWS_REGION}
   ```
## Create RDS Database

1. Create DB with aws cli 

   ```bash
   RDS_DB="$(aws rds create-db-instance \
       --db-instance-identifier psql-${CLUSTER_NAME} \
       --db-instance-class db.t3.micro \
       --engine postgres \
       --master-user-password ${PSQL_PASSWORD} \
       --allocated-storage 20 \
       --master-username postgres \
       --region ${AWS_REGION} \
       --db-subnet-group-name db-group-${CLUSTER_NAME} \
       --enable-iam-database-authentication \
       --publicly-accessible \
       --region ${AWS_REGION} \
       | jq -c '.DBInstance | { "DbiResourceId": .DbiResourceId, "VpcSecurityGroups": .VpcSecurityGroups[].VpcSecurityGroupId }')"
   echo $RDS_DB
   ```

2. Authorize ROSA cluster to connect to DB

   ```bash
   aws ec2 authorize-security-group-ingress \
    --group-id $(echo $RDS_DB | jq -r .VpcSecurityGroups) \
    --protocol tcp \
    --port 5432 \
    --cidr ${ROSA_IP_OUT}/32 \
    --region ${AWS_REGION}
   ```

## IAM Permissions 

1. Build the RDS access Policy

   ```bash
   cat <<EOF > $SCRATCH_DIR/rds-policy.json
   {
       "Version": "2012-10-17",
       "Statement": [
           {
               "Effect": "Allow",
               "Action": [
                   "rds-db:connect"
               ],
               "Resource": [
                   "arn:aws:rds-db:${AWS_REGION}:${AWS_ACCOUNT_ID}:dbuser:$(echo ${RDS_DB} | jq -r .DbiResourceId)/iamuser"
               ]
           }
       ]
   }
   EOF
   ```

2. Create the RDS Access Policy

   > This creates a named policy for the cluster, you could use a generic policy for multiple clusters to keep things simpler.

   ```bash
   POLICY=$(aws iam create-policy --policy-name "${CLUSTER_NAME}-rosa-rds-policy" \
      --policy-document file://$SCRATCH_DIR/rds-policy.json \
      --query 'Policy.Arn' --output text)
   echo $POLICY
   ```

3. Build Trust Policy

   ```bash
   cat <<EOF > $SCRATCH_DIR/trust-policy.json
   {
       "Version": "2012-10-17",
       "Statement": [
           {
               "Effect": "Allow",
               "Principal": {
                   "Federated": "arn:aws:iam::$(aws sts get-caller-identity --query 'Account' --output text):oidc-provider/${OIDC_PROVIDER}" 
               },
               "Action": "sts:AssumeRoleWithWebIdentity",
               "Condition": {
                   "StringEquals": {
                       "${OIDC_PROVIDER}:sub": "system:serviceaccount:rds-sts-app:default" 
                   }
               }
           }
       ]
   }
   EOF
   ```

4. Create Role for accessing database

   ```bash
   ROLE=$(aws iam create-role \
     --role-name "${CLUSTER_NAME}-rosa-rds-access" \
     --assume-role-policy-document file://$SCRATCH_DIR/trust-policy.json \
     --query "Role.Arn" --output text)
   echo $ROLE
   ```

5. Attach the Policies to the Role

   ```bash
   aws iam attach-role-policy \
      --role-name "${CLUSTER_NAME}-rosa-rds-access" \
      --policy-arn $POLICY
   ```

## Test STS

1. Create new project

   ```bash
   oc new-project rds-sts-app
   ```

1. Check that STS is working properly
   ```bash
   curl -s -H "Accept: application/json" "https://sts.amazonaws.com/\
   ?Action=AssumeRoleWithWebIdentity\
   &DurationSeconds=3600\
   &RoleSessionName=test\
   &RoleArn=${ROLE}\
   &WebIdentityToken=$(oc create token default --audience openshift --duration 60m)\
   &Version=2011-06-15" | jq
   ```

## Prepare/Populate Database

1. Create a Pod for connecting to DB with postgres user

   ```bash
   DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier psql-${CLUSTER_NAME} --query 'DBInstances[*].[Endpoint.Address]' --output text --region ${AWS_REGION})
   oc run -it --tty --rm --image registry.redhat.io/rhel8/postgresql-15 prep-db --env PGPASSWORD=${PSQL_PASSWORD} --env DB_ENDPOINT=${DB_ENDPOINT} -- /bin/sh
   ```
   
2. Download dataset IPrange / Country (in the prompt of `oc run`)

   ```bash
   curl -O -L https://github.com/sapics/ip-location-db/raw/main/geolite2-country/geolite2-country-ipv4.csv
   sed -i 's/\,/\-/' geolite2-country-ipv4.csv
   ```

2. Connect to DB, create user, DB and populate it (in the prompt of `oc run`)
   ```bash
   psql -h ${DB_ENDPOINT}
   CREATE USER iamuser WITH LOGIN; 
   GRANT rds_iam TO iamuser;
   CREATE DATABASE iamdb;
   \c iamdb
   CREATE EXTENSION if not exists ip4r;
   CREATE TABLE if not exists ref_ip_blocks
   (
     iprange iprange,
     geoname varchar
   
   );
   \copy ref_ip_blocks FROM 'geolite2-country-ipv4.csv' DELIMITER ',' CSV;
   CREATE INDEX ref_ip_blocks_ip4r_idx on ref_ip_blocks using gist(iprange);
   GRANT SELECT ON TABLE ref_ip_blocks TO iamuser;
   quit
   exit
   ```

## Connection with IAM

1. Create pod to access with a IAM user this time
   ```bash
   oc run -it --tty --rm --image registry.redhat.io/rhel8/postgresql-15 iamdb-connect \
     --env PGSSLMODE=require \
     --env PGPASSWORD=$(aws rds generate-db-auth-token --hostname $DB_ENDPOINT --port 5432 --region ${AWS_REGION} --username iamuser) \
     --env DB_ENDPOINT=${DB_ENDPOINT} \
    -- /bin/sh
   ```

2. Test request

   ```bash
   psql -h ${DB_ENDPOINT} -U iamuser -d iamdb
   SELECT iprange,geoname FROM ref_ip_blocks where iprange >>= '104.123.30.45'::ip4r;
   quit
   exit
   ```

## Deploy app

1. Create new-app

   ```bash
   oc new-app -e DB_ENDPOINT=${DB_ENDPOINT} \
    -e DB_PORT=5432 \
    -e AWS_REGION=${AWS_REGION} \
    -e DB_USER=iamuser \
    -e DB_NAME=iamdb \
    --strategy=docker https://github.com/fjcloud/ip-finder-api.git
   ```

2. Add secrets to deployment

   ```bash
   oc apply -f - <<EOF
   apiVersion: v1
   kind: Secret
   metadata:
     name: aws-creds
   type: Opaque 
   stringData: 
     credentials: |
       [default]
       role_arn = ${ROLE}
       web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
   EOF
   
   oc patch deployment ip-finder-api --type=merge -p '{"spec":{"template":{"spec":{"volumes":[{"name":"bound-sa-token","projected":{"sources":[{"serviceAccountToken":{"audience":"openshift","expirationSeconds":3600,"path":"token"}}]}},{"name":"aws-creds","secret":{"secretName":"aws-creds"}}]}}}}'
   
   
   oc patch deployment ip-finder-api --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts", "value": [{"name":"bound-sa-token","readOnly":true,"mountPath":"/var/run/secrets/openshift/serviceaccount"},{"name":"aws-creds","mountPath":"/opt/app-root/src/.aws"}]}]'
   
   ```

3. Expose APP

   ```bash
   oc expose service ip-finder-api
   oc patch route ip-finder-api --patch '{"spec":{"tls":{"termination":"edge","insecureEdgeTerminationPolicy":"Redirect"}}}'
   ```

4. Test app

   ```bash
   curl https://$(oc get route ip-finder-api -o jsonpath='{.spec.host}')
   ```

   > Expected output
   ```bash
   {
    "your_ip": X.X.X.X",
    "countrycode": "FR"
   }
   ```
## Cleanup


1. Delete resources

   ```bash
   oc delete ns rds-sts-app
   aws rds delete-db-instance --db-instance-identifier psql-${CLUSTER_NAME} --region ${AWS_REGION} --skip-final-snapshot
   aws ec2 detach-internet-gateway --vpc-id ${VPC_DB} --internet-gateway-id ${IGW}
   aws ec2 delete-internet-gateway --internet-gateway-id ${IGW} --region ${AWS_REGION}
   aws ec2 delete-subnet --subnet-id ${SUBNET_A} --region ${AWS_REGION}
   aws ec2 delete-subnet --subnet-id ${SUBNET_B} --region ${AWS_REGION}
   aws ec2 delete-subnet --subnet-id ${SUBNET_C} --region ${AWS_REGION}
   aws ec2 delete-vpc --vpc-id ${VPC_DB} --region ${AWS_REGION}
   aws rds delete-db-subnet-group --db-subnet-group-name db-group-${CLUSTER_NAME}
   ```

2. Detach the Policies to the Role

   ```bash
   aws iam detach-role-policy \
      --role-name "${CLUSTER_NAME}-rosa-rds-access" \
      --policy-arn $POLICY
   ```

3. Delete the Role

   ```bash
   aws iam delete-role --role-name \
      ${CLUSTER_NAME}-rosa-rds-access
   ```

4. Delete the Policy

   ```bash
   aws iam delete-policy --policy-arn \
      $POLICY
   ```
