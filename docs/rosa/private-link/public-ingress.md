# Adding a Public Ingress endpoint to a ROSA Private-Link Cluster

The is an example guide for creating a public ingress endpoint for a ROSA Private-Link cluster. Be aware of the security implications of creating a public subnet in your ROSA VPC this way.

![architecture diagram showing privatelink with public ingress](./images/arch-pl-ingress.png)

## Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
* [Rosa CLI](https://github.com/openshift/rosa/releases/tag/v1.0.8) v1.0.8
* [jq](https://stedolan.github.io/jq/download/)
* [A ROSA PL cluster](./README.md)

## Getting Started

### Set some environment variables

1. Set the following environment variables, changing them to suit your cluster.

   ```bash
   export ROSA_CLUSTER_NAME=private-link
   # this should be a free CIDR inside your VPC
   export PUBLIC_CIDR=10.0.2.0/24
   export AWS_PAGER=""
   export EMAIL=username.taken@gmail.com
   export DOMAIN=public.aws.mobb.ninja
   export SCRATCH_DIR=/tmp/scratch
   mkdir -p $SCRATCH_DIR
   ```

### Create a public subnet

> If you followed the above instructions to create the ROSA Private-Link cluster, you should already have a public subnet in your VPC. You can skip this step.

1. Get a Private Subnet ID from the cluster.

   ```bash
   PRIVATE_SUBNET_ID=$(rosa describe cluster -c $ROSA_CLUSTER_NAME -o json \
      | jq -r '.aws.subnet_ids[0]')
   echo $PRIVATE_SUBNET_ID
   ```

1. Get the VPC ID from the subnet ID.

   ```bash
    VPC_ID=$(aws ec2 describe-subnets --subnet-ids $PRIVATE_SUBNET_ID \
      --query 'Subnets[0].VpcId' --output text)
    echo $VPC_ID
   ```

1. Get the Cluster Tag from the subnet

   ```bash
   TAG=$(aws ec2 describe-subnets --subnet-ids $PRIVATE_SUBNET_ID \
      --query 'Subnets[0].Tags[?Value == `shared`]' | jq -r '.[0].Key')
   echo $TAG
   ```

1. Create a public subnet

   ```bash
   PUBLIC_SUBNET=`aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $PUBLIC_CIDR \
     --query 'Subnet.SubnetId' --output text`
   echo $PUBLIC_SUBNET
   ```

1. Tag the public subnet for the cluster

   ```bash
   aws ec2 create-tags --resources $PUBLIC_SUBNET \
      --tags Key=Name,Value=$ROSA_CLUSTER_NAME-public \
      Key=$TAG,Value="shared" Key=kubernetes.io/role/elb,Value="true"
   ```

### Create a Custom Domain

1. Create TLS Key Pair for custom domain using certbot:

    > Skip this if you already have a key pair.

    ```bash
    certbot certonly --manual \
      --preferred-challenges=dns \
      --email $EMAIL \
      --server https://acme-v02.api.letsencrypt.org/directory \
      --agree-tos \
      --config-dir "$SCRATCH_DIR/config" \
      --work-dir "$SCRATCH_DIR/work" \
      --logs-dir "$SCRATCH_DIR/logs" \
      -d "*.$DOMAIN"
    ```

1. Create TLS secret for custom domain:

    > Note use your own keypair paths if not using certbot.

   ```bash
   CERTS=/tmp/scratch/config/live/$DOMAIN
   oc new-project my-custom-route
   oc create secret tls acme-tls --cert=$CERTS/fullchain.pem --key=$CERTS/privkey.pem
   ```

1. Create Custom Domain resource:

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: managed.openshift.io/v1alpha1
   kind: CustomDomain
   metadata:
     name: acme
   spec:
     domain: $DOMAIN
     certificate:
       name: acme-tls
       namespace: my-custom-route
   EOF
   ```

1. Wait for the domain to be ready:

   ```bash
   watch oc get customdomains
   ```

1. Once its ready grab the CLB name:

   ```bash
   CDO_NAME=acme
   CLB_NAME=$(oc get svc -n openshift-ingress -o jsonpath='{range .items[?(@.metadata.labels.ingresscontroller\.operator\.openshift\.io\/owning-ingresscontroller=="'$CDO_NAME'")]}{.status.loadBalancer.ingress[].hostname}{"\n"}{end}')
   echo $CLB_NAME
   ```

1. Create a CNAME in your DNS provider for *.<$DOMAIN> that points at the CLB NAME from the above command.

### Deploy a public application

1. Create a new project

   ```bash
   oc new-project my-public-app
   ```

1. Create a new application

   ```bash
   oc new-app --docker-image=docker.io/openshift/hello-openshift
   ```

1. Create a route for the application

   ```bash
   oc create route edge --service=hello-openshift hello-openshift-tls \
     --hostname hello.$DOMAIN
   ```

1. Check that you can access the application:

   ```bash
   curl https://hello.$DOMAIN
   ```

1. You should see the output

   ```
   Hello OpenShift!
   ```
