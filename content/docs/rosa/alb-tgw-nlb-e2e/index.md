---
date: '2023-07-31'
title: Securely Exposing apps to the Internet with ALB, TGW, and NLB with fixed IP
tags: ["ROSA", "AWS", "Private Link","ALB", "NLB", "TGW"]
authors:
  - Mohsen Houshamnd
  - Paul Czarkowski
---

It's not uncommon to want a private-link ROSA cluster but to also allow some traffic to come into the cluster from another VPC, often across a Transit Gateway. This can often satisfy security needs of traffic passing through an inspection point (like a WAF) or other DMZ use cases.

This guide demonstrates setting up an NLB with static IP addresses (Using the AWS LoadBalancer Operator) which can then be used as a target for an ALB in another VPC.

This can be utilized as a starting point for building your own architecture to securely expose applications on a Private Link cluster.

> The deployment incorporates an Ingress/Egress VPC to route traffic to the cluster, which is deployed within a private VPC.

![architecture diagram showing privatelink with TGW](./images/rosa_alb_tgw_nlb_e2e.png)

### Prerequisites

- A multi-az privatelink ROSA cluster
- [ROSA CLI](https://github.com/openshift/rosa) - Download the latest release
- oc CLI `rosa download openshift-client`
- [jq](https://jqlang.github.io/jq/download/)

1. Clone the MOBB examples registry that contains scripts and tools to help deploy this.

    ```bash
    git clone https://github.com/rh-mobb/examples.git mobb-examples
    cd mobb-examples
    ```

1. Set some environment variables (substitute the values inside `<>`)

    ```bash
    export CLUSTER_NAME=<your rosa cluster name>
    export REGION=$(rosa describe cluster -c ${CLUSTER_NAME} \
      -o json | jq -r '.region.id')
    export SUBNETS=$(rosa describe cluster -c ${CLUSTER_NAME} \
      -o json | jq -r '.aws.subnet_ids[]' | xargs)
    ```

### Deploy AWS Load Balancer Operator (ALBO)

1. Run `rosa/aws-load-balancer-operator/deploy-aws-lbo.sh` to install the ALB operator on your ROSA cluster.

    > This script creates the IAM and OCP resources necessary for the ALBO, See the following [guide](https://mobb.ninja/docs/rosa/aws-load-balancer-operator/) for a walkthrough of those resources.

    > Note: If you have a cluster-wide proxy, run `export HAS_PROXY=true` before running the command.

    ```bash
    ./rosa/aws-load-balancer-operator/deploy-aws-lbo.sh
    ```

1. With the ALBO deployed, we can use it to create an AWS Load Balancer Controller resource.

    ```bash
    cat << EOF | oc apply -f -
    apiVersion: networking.olm.openshift.io/v1
    kind: AWSLoadBalancerController
    metadata:
      name: cluster
    spec:
      credentials:
        name: aws-load-balancer-operator
    EOF
    ```

### Deploy application

#### Static IPs for NLB

The application will be requesting an NLB with static IPs, in order to do that you need to find a spare IP from each of your ROSA subnets.

1. Run the following command to get your subnets

    ```bash
    aws ec2 describe-subnets --region ${REGION} \
      --subnet-ids $(echo "${SUBNETS}") \
      --query 'Subnets[*].CidrBlock' --output text
    ```

    ```
    10.0.16.0/22    10.0.12.0/22    10.0.20.0/22
    ```

1. Pick a an unused IP address from each of these CIDRs (you may need to use the AWS console to do this, although its a good bet a high IP in each CIDR is free).

    > In this example we'll use `10.0.16.200`, `10.0.12.200`, and `10.0.20.200`.

1. Edit the file `./apps/echo-server/echo-server.yaml` and find the line that contains the text `service.beta.kubernetes.io/aws-load-balancer-private-ipv4-addresses`.  Replace the example IPs with the ones you picked above.

1. Create a project to run the echo server application in

    ```bash
    oc new-project echo-server
    ```

1. Deploy the echo server application

    ```bash
    oc apply -f ./apps/echo-server/echo-server.yaml
    ```

1. Wait until the deployment is running

    ```bash
    oc rollout status deployment/http-https-echo
    ```

1. Wait until the service has a Load Balancer attached

    > Hint: the `EXTERNAL-IP` field should contain a DNS record, if not, wait a minute and run this command again.

    ```bash
    oc get service
    ```

    ```
    NAME              TYPE           CLUSTER-IP     EXTERNAL-IP
        PORT(S)                         AGE
    http-https-echo   LoadBalancer   172.30.52.80   k8s-echoserv-httphttp-12c646e3a6-58ae04e547de7af0.elb.us-east-1.amazonaws.com   8080:30127/TCP,8443:32553/TCP   24s
    ```

1. Get the URL of the NLB

    ```bash
    export NLB_URL=$(oc get svc -n echo-server http-https-echo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    echo "NLB's FQDN: $NLB_URL"
    ```

1. Check you can access the endpoint

    > Note: The NLB inherits the security group of its targets, which in this case means you need to access it from inside the subnets that the ROSA worker nodes are in.  We do this by running the command through `oc debug`

    ```bash
    NODE=$(oc get nodes -l 'node-role.kubernetes.io/worker=' \
      -o name | head -1)
    oc debug $NODE -- curl -s -v -k https://$NLB_URL
    ```

    The output should include a JSON blob that looks something like this.  If it stalls out, you might just need to wait a while for the NLB to finish provisioning.

    ```
    {
      "path": "/",
      "headers": {
        "host": "k8s-echoserv-httphttp-6fa3dbaa74-c7eab484590da975.elb.us-east-1.amazonaws.com",
        "user-agent": "curl/7.61.1",
        "accept": "*/*"
      },
      "method": "GET",
    ```

### Create an ALB in the public subnet

We need to create an ALB in the ingress/egress VPC. To do this, we first need to create a Target Group (TG) within this VPC and then associate this TG with the ALB's targets. To create the TG, we require the IP addresses of the NLB.

1. Define a Target Group

    ```bash
    export ING_EGRESS_VPC_ID=<vpc-id>
    export ING_EGRESS_PUB_SUB_1=<public subnet-id 1>
    export ING_EGRESS_PUB_SUB_2=<public subnet-id 2>
    export BOOKINFO_CERT_ARN=<certificate arn>
    export TG_ARN=$(aws elbv2 create-target-group --name nlb-e2e-tg --protocol HTTPS --port 443 --vpc-id $ING_EGRESS_VPC_ID --target-type ip --health-check-protocol HTTP --health-check-port 15021 --health-check-path /healthz/ready --query 'TargetGroups[0].TargetGroupArn' --output text)
    ```

1. Fetch NLB IP addresses

    ```bash
    export NLB_FQDN=$(oc get svc -n ossm istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    echo "The external IP address of istio-ingressgateway is: $NLB_FQDN"
    # Fetch the load balancer ARN
    export NLB_ARN=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='$NLB_FQDN'].LoadBalancerArn" --output text)
    echo "NLB arn: $NLB_ARN"
    export NLB_INFO=$(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN --output json )
    export NLB_PRV_IP_1=$(echo "$NLB_INFO" | jq -r '.LoadBalancers[0].AvailabilityZones[0].LoadBalancerAddresses[0].PrivateIPv4Address')
    export NLB_PRV_IP_2=$(echo "$NLB_INFO" | jq -r '.LoadBalancers[0].AvailabilityZones[1].LoadBalancerAddresses[0].PrivateIPv4Address')
    export NLB_PRV_IP_3=$(echo "$NLB_INFO" | jq -r '.LoadBalancers[0].AvailabilityZones[2].LoadBalancerAddresses[0].PrivateIPv4Address')
    echo "Private IP 1: $NLB_PRV_IP_1"
    echo "Private IP 2: $NLB_PRV_IP_2"
    echo "Private IP 3: $NLB_PRV_IP_3"
    ```

2. Register NLB IP addresses in the Target Group

    ```bash
    aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$NLB_PRV_IP_1,Port=443,AvailabilityZone=all Id=$NLB_PRV_IP_2,Port=443,AvailabilityZone=all Id=$NLB_PRV_IP_3,Port=443,AvailabilityZone=all
    ```

3. Create an ALB in the ingress/egress VPC and set the Target Group.

   You need to find your ingress/egress VPC ID, public subnet ID, and certificate ARN to create the ALB.

   4.1. Create a security group for ALB

    ```bash
    ALB_SG_ID=$(aws ec2 create-security-group --group-name secured-echo-server \
        --vpc-id $ING_EGRESS_VPC_ID \
        --description "allow traffic from the internet" \
        --query 'GroupId' \
        --output text)
    ```
   4.2. Allow traffic from the internet

    ```bash
    aws ec2 authorize-security-group-ingress \
       --group-id $ALB_SG_ID \
       --protocol tcp \
       --port 443 \
       --cidr 0.0.0.0/0
    ```
   4.3 Create ALB

    ```bash
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name secured-echo-alb \
        --subnets $ING_EGRESS_PUB_SUB_1 $ING_EGRESS_PUB_SUB_2 \
        --security-groups $ALB_SG_ID \
        --scheme internet-facing \
        --type application \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)
    ```

   4.4 Create Listener

    ```bash
    aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTPS \
    --port 443 \
    --certificates CertificateArn=$ECHO_SERVER_CERT_ARN \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN
    ```

### Check application endpoint

Fetch ALB's URL and generate traffic

    ```bash
    ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)
    
    curl -k  https://$ALB_DNS
    ```

