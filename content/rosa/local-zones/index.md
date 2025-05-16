---
date: '2025-03-31'
title: Using local-zones in ROSA Classic
tags: ["AWS", "ROSA", "local zones"]
authors:
  - Daniel Penagos
  - David Gomez
---

This guide walks through setting up a local-zone in an existing ROSA Classic cluster. Use this approach when you have latency requirements that can be reduced when using a local zone. Since you are not using the default ingress, you will not be able to use the router strategy the cluster has. 

## Prerequisites

* A ROSA classic cluster deployed with STS in a region that has local zones(BYO VPC)
* [Install and execute the installation guide for AWS LoadBalancer Operator](https://cloud.redhat.com/experts/rosa/aws-load-balancer-operator/)
* AWS CLI
* watch
* [Identify the local zone to be used](https://aws.amazon.com/about-aws/global-infrastructure/localzones/features/)
* [Enable the local zone in the account](https://docs.redhat.com/en/documentation/openshift_container_platform/4.12/html/installing_on_aws/installing-aws-localzone#installation-aws-add-local-zone-locations_installing-aws-localzone)
* The VPC must have enough space to create the Local Zone Subnet. In this example, we create two subnets, one public and one private.  

## Set up environment

Create environment variables. We assume the CIDR is a valid subnet for the localzone. 

```bash
export AWS_DEFAULT_REGION=us-east-1
export ROSA_CLUSTER_NAME=my-cluster
export VPC_ID=place-your-vpc-identifier (eg. vpc-0123456789abcdefg)
export R_TABLE_NAT=place-your-existing-route-table-id-for-existing-private-subnet (eg. rtb-0123456789abcdefg)
export R_TABLE_PUBLIC=place-your-existing-route-table-id-for-public-subnets (eg. rtb-0123456789abcdefg)
export LZ_PRIVATE_CIDR=define-the-private-subnet-cidr-for-localzone (eg. 10.0.4.0/24)
export LZ_PUBLIC_CIDR=define-the-public-subnet-cidr-for-localzone (eg. 10.0.5.0/24)
export LOCAL_ZONE_ID=define-the-localzone-id (eg. us-east-1-scl-1a | us-east-1-mia-2a )
export SCRATCH_DIR=/tmp/scratch
export INFRA_ID=$(rosa describe cluster -c ${ROSA_CLUSTER_NAME} | grep -i "Infra ID:" | awk '{print $NF}')
export LZ_MACHINEPOOL_NAME=lz-machinepool
export LZ_LABEL=lz-miami
export INSTANCE_TYPE=define-your-preferred-instance-type (eg. r6i.xlarge)


```

## AWS Networking Preparation

1. Tag the vpc.

    ```bash
    aws ec2 create-tags --resources $VPC_ID --tags Key=kubernetes.io/cluster/${INFRA_ID},Value=owned
    ```

1. Create private and public subnets in the local zone.

    ```bash
    PRIVATE_SUBNET_LZ=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $LZ_PRIVATE_CIDR --availability-zone $LOCAL_ZONE_ID | jq -r .Subnet.SubnetId)
    aws ec2 create-tags --resources $PRIVATE_SUBNET_LZ --tags Key=Name,Value=$ROSA_CLUSTER_NAME-private-lz
    aws ec2 create-tags --resources $PRIVATE_SUBNET_LZ --tags Key=kubernetes.io/role/internal-elb,Value=''

    PUBLIC_SUBNET_LZ=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $LZ_PUBLIC_CIDR --availability-zone $LOCAL_ZONE_ID | jq -r .Subnet.SubnetId)
    aws ec2 create-tags --resources $PUBLIC_SUBNET_LZ --tags Key=Name,Value=$ROSA_CLUSTER_NAME-public-lz
    aws ec2 create-tags --resources $PUBLIC_SUBNET_LZ --tags Key=kubernetes.io/role/elb,Value=''
    ```


1. Associate the new private subnet in the route table.

    ```bash
    aws ec2 associate-route-table --subnet-id $PRIVATE_SUBNET_LZ --route-table-id $R_TABLE_NAT
    ```

1. Associate the new public subnet in the route table.

    ```bash
    aws ec2 associate-route-table --subnet-id $PUBLIC_SUBNET_LZ --route-table-id $R_TABLE_PUBLIC
    ```

1. Tag the private subnet in the local zone with the cluster infra id.

    ```bash
    aws ec2 create-tags --resources $PRIVATE_SUBNET_LZ --tags Key=kubernetes.io/cluster/$INFRA_ID,Value=shared
    ```

## Cluster Preparation (30 min)

Patch the cluster network operator MTU.

```bash
oc patch network.operator.openshift.io/cluster --type=merge --patch "{\"spec\":{\"migration\":{\"mtu\":{\"network\":{\"from\":$(oc get network.config.openshift.io/cluster --output=jsonpath={.status.clusterNetworkMTU}),\"to\":1200},\"machine\":{\"to\":9001}}}}}"
```

```bash
watch oc get mcp
```

{{% alert state="warning" %}}  **Note:** It takes more than 1 minute to start the rollout. Wait for the configuration untill everything is `UPDATED=True`, `UPDATING=False`, `DEGRADED=False`. It could take several minutes(aprox. 20) until the configuration is applied to all nodes. {{% /alert %}} 

```bash
oc patch network.operator.openshift.io/cluster --type=merge --patch '{"spec":{"migration":null,"defaultNetwork":{"ovnKubernetesConfig":{"mtu":1200}}}}' 
```

```bash
oc get mcp
```

{{% alert state="warning" %}}  **Note:** Again, it takes more than 1 minute to start the rollout. Wait for the configuration untill everything is `UPDATED=True`, `UPDATING=False`, `DEGRADED=False`. It could take several minutes(aprox. 20) until the configuration is applied to all nodes. {{% /alert %}} 


## Create and configure ROSA in the localzone

Create the machinepool in the localzone and wait until the nodes are available in the list. This could take several minutes. 

```bash
rosa create machinepool --cluster $ROSA_CLUSTER_NAME --name $LZ_MACHINEPOOL_NAME --subnet $PRIVATE_SUBNET_LZ --replicas 2 --instance-type $INSTANCE_TYPE
watch oc get machines -n openshift-machine-api 
```

{{% alert state="warning" %}}  **Note:** Wait for the machines to be up and running before continuing with the next steps. It could take several minutes. (7-15 min. depending on the localzone). {{% /alert %}} 

Label the machinepool so the applications will be installed on the local zone nodes only.

```bash
rosa edit machinepool --labels test=$LZ_LABEL --cluster $ROSA_CLUSTER_NAME $LZ_MACHINEPOOL_NAME
rosa edit machinepool --labels test=normal --cluster $ROSA_CLUSTER_NAME worker
```

## Test. 

To test, we create the deployment, applying the match labels, so the pods will run on the local zone nodes. 

```bash
oc adm policy add-scc-to-user anyuid system:serviceaccount:echoserver:default

cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echoserver
  namespace: echoserver
spec:
  selector:
    matchLabels:
      app: echoserver
  replicas: 1
  template:
    metadata:
      labels:
        app: echoserver
    spec:
      nodeSelector:
        test: ${LZ_LABEL}
      containers:
      - image: k8s.gcr.io/e2e-test-images/echoserver:2.5
        imagePullPolicy: Always
        name: echoserver
        ports:
        - containerPort: 8080
EOF
```

Validate the deploy is running on a Node in the Local Zone.

```bash
oc get nodes --selector=test=${LZ_LABEL}
oc get pods -n echoserver -o wide
```

Deploy the echo load balancer in the private subnet in the local zone.

```bash
cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echoserverprivate
  namespace: echoserver
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/tags: Environment=dev,Team=test
    service.beta.kubernetes.io/aws-load-balancer-subnets: $PRIVATE_SUBNET_LZ
    alb.ingress.kubernetes.io/subnets: $PRIVATE_SUBNET_LZ
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Exact
            backend:
              service:
                name: echoserver
                port:
                  number: 80
EOF
```


Deploy the echo load balancer in the public subnet in the local zone. (Optional) 
{{% alert state="warning" %}}  **NOTE**: For perdurable environments, the recommendation is not to expose the cluster directly in the Internet. This step is executed in this guide for testing latency from the internet. {{% /alert %}} 

```bash
cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echoserverpublic
  namespace: echoserver
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/tags: Environment=dev,Team=test
    service.beta.kubernetes.io/aws-load-balancer-subnets: $PUBLIC_SUBNET_LZ
    alb.ingress.kubernetes.io/subnets: $PUBLIC_SUBNET_LZ
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Exact
            backend:
              service:
                name: echoserver
                port:
                  number: 80
EOF
```


Curl the ALB ingress endpoint to verify the echoserver pod is accessible.
```
INGRESS=$(oc -n echoserver get ingress echoserverpublic -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
nmap --packet-trace -p 80 ${INGRESS}
```
``` {linenos=inline hl_lines=[24] style=friendly}
Starting Nmap 7.95 ( https://nmap.org ) at 2025-04-08 15:19 -05
CONN (0.0288s) TCP localhost > 161.193.5.86:80 => Operation now in progress
CONN (0.0288s) TCP localhost > 161.193.5.86:443 => Operation now in progress
CONN (0.1050s) TCP localhost > 161.193.5.86:80 => Connected
NSOCK INFO [0.1060s] nsock_iod_new2(): nsock_iod_new (IOD #1)
NSOCK INFO [0.1060s] nsock_connect_udp(): UDP connection requested to 8.8.4.4:53 (IOD #1) EID 8
NSOCK INFO [0.1060s] nsock_read(): Read request from IOD #1 [8.8.4.4:53] (timeout: -1ms) EID 18
NSOCK INFO [0.1060s] nsock_iod_new2(): nsock_iod_new (IOD #2)
NSOCK INFO [0.1060s] nsock_connect_udp(): UDP connection requested to 8.8.8.8:53 (IOD #2) EID 24
NSOCK INFO [0.1060s] nsock_read(): Read request from IOD #2 [8.8.8.8:53] (timeout: -1ms) EID 34
NSOCK INFO [0.1060s] nsock_write(): Write request for 43 bytes to IOD #1 EID 43 [8.8.4.4:53]
NSOCK INFO [0.1060s] nsock_trace_handler_callback(): Callback: CONNECT SUCCESS for EID 8 [8.8.4.4:53]
NSOCK INFO [0.1060s] nsock_trace_handler_callback(): Callback: WRITE SUCCESS for EID 43 [8.8.4.4:53]
NSOCK INFO [0.1060s] nsock_trace_handler_callback(): Callback: CONNECT SUCCESS for EID 24 [8.8.8.8:53]
NSOCK INFO [0.2200s] nsock_trace_handler_callback(): Callback: READ SUCCESS for EID 18 [8.8.4.4:53] (97 bytes)
NSOCK INFO [0.2200s] nsock_read(): Read request from IOD #1 [8.8.4.4:53] (timeout: -1ms) EID 50
NSOCK INFO [0.2200s] nsock_iod_delete(): nsock_iod_delete (IOD #1)
NSOCK INFO [0.2200s] nevent_delete(): nevent_delete on event #50 (type READ)
NSOCK INFO [0.2200s] nsock_iod_delete(): nsock_iod_delete (IOD #2)
NSOCK INFO [0.2200s] nevent_delete(): nevent_delete on event #34 (type READ)
CONN (0.2206s) TCP localhost > 161.193.5.86:80 => Operation now in progress
CONN (0.2937s) TCP localhost > 161.193.5.86:80 => Connected
Nmap scan report for k8s-echoserv-echoserv-0538388a96-1833561578.us-east-1.elb.amazonaws.com (161.193.5.86)
Host is up (0.014s latency).
Other addresses for k8s-echoserv-echoserv-0538388a96-1833561578.us-east-1.elb.amazonaws.com (not scanned): 161.193.10.125
rDNS record for 161.193.5.86: ec2-161-193-5-86.compute-1.amazonaws.com

PORT   STATE SERVICE
80/tcp open  http

Nmap done: 1 IP address (1 host up) scanned in 0.29 seconds
```

