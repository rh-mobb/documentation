date: '2023-07-31'
title: Securely Exposing apps to the Internet with ALB, TGW, and NLB with fixed IP
tags: ["ROSA", "AWS", "Private Link","ALB", "NLB", "TGW"]
authors:
  - Mohsen Houshamnd
  - Paul Czarkowski
---

This Git repository demonstrates exposing an HTTPS endpoint on ROSA privatelink cluster to the internet, using ALB, TGW, and NLB with fixed IP addresses. 
This repository demonstrates how to utilize a privatelink ROSA (Red Hat OpenShift on AWS) cluster to securely expose an application with end-to-end encryption. The provided architecture serves as a sample for application exposure. The deployment incorporates an Ingress/Egress VPC to route traffic to the cluster, which is deployed within a private VPC.

![architecture diagram showing privatelink with TGW](./images/rosa_alb_tgw_nlb_e2e.png)

### Prerequisites

- A multi-az privatelink ROSA cluster
- [ROSA CLI](https://github.com/openshift/rosa) - Download the latest release
- oc CLI `bash rosa download openshift-client`
- [jq](https://jqlang.github.io/jq/download/)

Clone the repository

```bash
git clone https://github.com/rh-mobb/examples.git
cd examples
```

### Deploy AWS Load Balancer Operator (ALBO)

Use this [mobb.ninja](https://mobb.ninja/docs/rosa/aws-load-balancer-operator/) to install ALB operator on ROSA cluster or run the script `./rosa/aws-load-balancer-operator/deploy-aws-lbo.sh`

```bash
./rosa/aws-load-balancer-operator/deploy-aws-lbo.sh
```

 **Note:** If you have a cluster-wide proxy, you must run the following snippet or uncomment the "Configuring egress proxy for AWS Load Balancer Operator" section in the script `./rosa/aws-load-balancer-operator/deploy-aws-lbo.sh`

```bash
 oc -n aws-load-balancer-operator create configmap trusted-ca
 oc -n aws-load-balancer-operator label cm trusted-ca config.openshift.io/inject-trusted-cabundle=true
 oc -n aws-load-balancer-operator patch subscription aws-load-balancer-operator --type='merge' -p '{"spec":{"config":{"env":[{"name":"TRUSTED_CA_CONFIGMAP_NAME","value":"trusted-ca"}],"volumes":[{"name":"trusted-ca","configMap":{"name":"trusted-ca"}}],"volumeMounts":[{"name":"trusted-ca","mountPath":"/etc/pki/tls/certs/albo-tls-ca-bundle.crt","subPath":"ca-bundle.crt"}]}}}'
 oc -n aws-load-balancer-operator exec deploy/aws-load-balancer-operator-controller-manager -c manager -- bash -c "ls -l /etc/pki/tls/certs/albo-tls-ca-bundle.crt; printenv TRUSTED_CA_CONFIGMAP_NAME"
 oc -n aws-load-balancer-operator rollout restart deployment/aws-load-balancer-operator-controller-manager
```

Create AWS Load Balancer Controller

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

we use echo-server application to show an end to end encryption

```bash
oc new-project echo-server
oc apply -f ./apps/echo-server/echo-server.yaml
```

### Check TLS at the NLB layer

```bash
export NLB_URL=$(oc get svc -n ech-server http-https-echo -ojsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "NLB's FQDN:  $NLB_URL"
export NLB_IP=$(dig +short $NLB_URL | head -1)
echo "NLP IP address $NLB_IP"
```
Check application  endpoint

```bash
 curl -v -k --resolve secured-echo-server.com:443:$NLB_IP https://secured-echo-server.com:443/productpage
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

