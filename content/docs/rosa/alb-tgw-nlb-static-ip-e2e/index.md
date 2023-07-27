date: '2023-07-26'
title: Securely Exposing apps to the Internet with ALB, TGW, and NLB with fixed IP
tags: ["ROSA", "AWS", "Private Link"]
authors:
  - Mohsen Houshamnd
  - Paul Czarkowski
---

This Git repository demonstrates exposing an HTTPS endpoint on ROSA privatelink cluster to the internet, using ALB, TGW, and NLB with fixed IP addresses. 
This repository demonstrates how to utilize a privatelink ROSA (Red Hat OpenShift on AWS) cluster to securely expose an application with end-to-end encryption. The provided architecture serves as a sample for application exposure. The deployment incorporates an Ingress/Egress VPC to route traffic to the cluster, which is deployed within a private VPC.

![architecture diagram showing privatelink with TGW](./images/rosa_alb_tgw_nlb_e2e.png)

### Prerequisites

- A privatelink ROSA cluster
- [ROSA CLI](https://github.com/openshift/rosa) - Download the latest release
- oc CLI `bash rosa download openshift-client`
- [jq](https://jqlang.github.io/jq/download/)

Clone the repository
```bash
git clone https://github.com/houshym/rosa-ossm-e2e-encryption
```

### Deploy AWS Load Balancer Operator (ALBO)

Use this [mobb.ninja](https://mobb.ninja/docs/rosa/aws-load-balancer-operator/) to install ALB operator on ROSA cluster or use the following snippet or run the  [script](./alb-operator/deploy-awslbo.sh)

```bash
#!/bin/sh
set +e
export ROSA_CLUSTER_NAME=$(oc get infrastructure cluster -o=jsonpath="{.status.infrastructureName}"  | sed 's/-[a-z0-9]\{5\}$//')
export REGION=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.aws.region}")
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed  's|^https://||')
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME=$(oc get infrastructure cluster -o=jsonpath="{.status.infrastructureName}")
echo "Cluster: ${ROSA_CLUSTER_NAME}, Region: ${REGION}, OIDC Endpoint: ${OIDC_ENDPOINT}, AWS Account ID: ${AWS_ACCOUNT_ID}"
TRUST_POLICY=$(<alb-operator/trust-policy.json)
SUBSTITUTED_POLICY=$(echo "$TRUST_POLICY" | envsubst)
echo "Trust Policy $SUBSTITUTED_POLICY"

if ! ROLE_ARN=$(aws iam get-role --role-name "${ROSA_CLUSTER_NAME}-alb-operator" --query Role.Arn --output text 2>/dev/null); then
  ROLE_ARN=$(aws iam create-role --role-name "${ROSA_CLUSTER_NAME}-alb-operator" --assume-role-policy-document "$SUBSTITUTED_POLICY" --query Role.Arn --output text)
fi
echo "Role ARN: $ROLE_ARN"
# Create the policy if it doesn't exist
EXISTING_POLICY_ARN=$(aws --region "$REGION" --output text iam list-policies --query "Policies[?PolicyName=='aws-load-balancer-operator-policy'].Arn" --output text)
if [ -z "$EXISTING_POLICY_ARN" ]; then
  # Create the policy if it doesn't exist
  POLICY_ARN=$(aws --region "$REGION" --query Policy.Arn --output text iam create-policy --policy-name aws-load-balancer-operator-policy --policy-document "file://alb-operator/load-balancer-operator-policy.json")
else
  POLICY_ARN="$EXISTING_POLICY_ARN"
fi
echo "Policy ARN: $POLICY_ARN"
aws iam attach-role-policy --role-name "${ROSA_CLUSTER_NAME}-alb-operator" \
  --policy-arn $POLICY_ARN
# tag cluster vpc for aws load balancer operator
export ROSA_CLUSTER_SUBNET=$(rosa describe cluster -c $ROSA_CLUSTER_NAME -o json | jq -r '.aws.subnet_ids[0]')
export ROSA_CLUSTER_VPC_ID=$(aws ec2 describe-subnets --subnet-ids $ROSA_CLUSTER_SUBNET --query 'Subnets[0].VpcId' --output text)
echo "ROSA cluster VPC ID $ROSA_CLUSTER_VPC_ID"
aws ec2 create-tags --resources ${ROSA_CLUSTER_VPC_ID} \
  --tags Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned \
  --region ${REGION}

# Fetch all subnets of the VPC
export ROSA_CLUSTER_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$ROSA_CLUSTER_VPC_ID" --query 'Subnets[*].SubnetId' --output text)

# Loop through each subnet and add the tag
for subnet in $ROSA_CLUSTER_SUBNETS; do
    aws ec2 create-tags --resources $ROSA_CLUSTER_SUBNETS --tags Key=kubernetes.io/role/internal-elb,Value=1
done

cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: aws-load-balancer-operator
EOF

cat << EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aws-load-balancer-operator
  namespace: aws-load-balancer-operator
stringData:
  credentials: |
    [default]
    role_arn = $ROLE_ARN
    web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF



cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: aws-load-balancer-operator
  namespace: aws-load-balancer-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: aws-load-balancer-operator
  namespace: aws-load-balancer-operator
spec:
  channel: stable-v1.0
  installPlanApproval: Automatic
  name: aws-load-balancer-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: aws-load-balancer-operator.v1.0.0
EOF
```

 **Note:** If you have a cluster-wide proxy, you must run the following snippet or uncomment the "Configuring egress proxy for AWS Load Balancer Operator" section in the [deploy-awslbo.sh](./alb-operator/deploy-awslbo.sh)

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
oc apply -f echo-server/echo-server.yaml
```

### Check SSL termination

#### Check termination at NodePort 

get the nodes' IP address and istio-ingress service ports

 **Note:** If you don't get a response, check the security group and be sure that port 3000-32767 is allowed 

```bash
export WORKER_IP_ADDRESS=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | head -n 1)
echo "Worker IP Address $WORKER_IP_ADDRESS"
export NODE_PORT=$(oc get svc -n echo-server http-https-echo -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
echo "Ingress service NodePort $NODE_PORT"
```

Check application endpoint

```bash
curl -v -k --resolve secured-echo-server.com:$NODE_PORT:$WORKER_IP_ADDRESS  https://secured-echo-server.com:$NODE_PORT/productpage 
```

#### Check TLS termination at the NLB layer

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

1. Define a TG 
 
    ```bash
    export ING_EGRESS_VPC_ID=vpc-0344775b9177ec7d5
    export ING_EGRESS_PUB_SUB_1=subnet-0123d00f20e9d4c4b
    export ING_EGRESS_PUB_SUB_2=subnet-06130b9f97821d8d8
    export ECHO_SERVER_CERT_ARN=arn:aws:acm:us-east-2:660250927410:certificate/ddae6fbd-a540-4619-939f-9e20ff9b765e 
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

3. Create an ALB in the ingress/egress VPC and set the TG.

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





