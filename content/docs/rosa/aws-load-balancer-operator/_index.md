---
date: '2023-01-03T22:07:08.574151'
title: AWS Load Balancer Operator On ROSA
aliases: ['/docs/rosa/alb-sts']
tags: ["AWS", "ROSA"]
---

Author **Shaozhen Ding**, **Paul Czarkowski**

*last edited: 04/26/2023*

[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/) is a controller to help manage Elastic Load Balancers for a Kubernetes cluster.

* It satisfies Kubernetes [Ingress resources](https://kubernetes.io/docs/concepts/services-networking/ingress/) by provisioning [Application Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html).
* It satisfies Kubernetes [Service resources](https://kubernetes.io/docs/concepts/services-networking/service/) by provisioning [Network Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/introduction.html).

Compared with default AWS In Tree Provider, this controller is actively developed with advanced annotations for both [ALB](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.2/guide/ingress/annotations/) and [NLB](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.2/guide/service/annotations/#lb-type). Some advanced usecases are:

* Using native kubernetes ingress with ALB
* Integrate ALB with WAF
* Specify NLB source IP ranges
* Specify NLB internal IP address

[AWS Load Balancer Operator](https://github.com/openshift/aws-load-balancer-operator) is used to used to install, manage and configure an instance of aws-load-balancer-controller in a OpenShift cluster.

## Prerequisites

* [A multi AZ ROSA cluster deployed with STS](/docs/rosa/sts/)
* AWS CLI
* OC CLI

## Environment

1. Prepare the environment variables

   ```bash
   export AWS_PAGER=""
   export ROSA_CLUSTER_NAME=$(oc get infrastructure cluster -o=jsonpath="{.status.infrastructureName}"  | sed 's/-[a-z0-9]\{5\}$//')
   export REGION=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.aws.region}")
   export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed  's|^https://||')
   export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
   export SCRATCH="/tmp/${ROSA_CLUSTER_NAME}/alb-operator"
   mkdir -p ${SCRATCH}
   echo "Cluster: ${ROSA_CLUSTER_NAME}, Region: ${REGION}, OIDC Endpoint: ${OIDC_ENDPOINT}, AWS Account ID: ${AWS_ACCOUNT_ID}"
   ```

## AWS VPC / Subnets

> Note: This section only applies to BYO VPC clusters, if you let ROSA create your VPCs you can skip to the following [Installation](#installation) section.

1. Set Variables describing your VPC and Subnets:

   ```bash
   export VPC_ID=<vpc-id>
   export PUBLIC_SUBNET_IDS=<public-subnets>
   export PRIVATE_SUBNET_IDS=<private-subnets>
   export CLUSTER_NAME=$(oc get infrastructure cluster -o=jsonpath="{.status.infrastructureName}")
   ```

1. Tag VPC with the cluster name

   ```bash
   aws ec2 create-tags --resources ${VPC_ID} --tags Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned --region ${REGION}
   ```

1. Add tags to Public Subnets

   ```bash
   aws ec2 create-tags \
     --resources ${PUBLIC_SUBNET_IDS} \
     --tags Key=kubernetes.io/role/elb,Value='' \
     --region ${REGION}
   ```

1. Add tags to Private Subnets

   ```bash
   aws ec2 create-tags \
     --resources "${PRIVATE_SUBNET_IDS}" \
     --tags Key=kubernetes.io/role/internal-elb,Value='' \
     --region ${REGION}
   ```

## Installation

1. Create Policy for the aws load balancer controller

   > **Note**: Policy is from [AWS Load Balancer Controller Policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.4/docs/install/iam_policy.json) plus subnet create tags permission (required by the operator)

   ```bash
   oc new-project aws-load-balancer-operator
   POLICY_ARN=$(aws iam list-policies --query \
     "Policies[?PolicyName=='aws-load-balancer-operator-policy'].{ARN:Arn}" \
     --output text)
   if [[ -z "${POLICY_ARN}" ]]; then
     wget -O "${SCRATCH}/load-balancer-operator-policy.json" \
       https://raw.githubusercontent.com/rh-mobb/documentation/main/content/docs/rosa/aws-load-balancer-operator/load-balancer-operator-policy.json
     POLICY_ARN=$(aws --region "$REGION" --query Policy.Arn \
     --output text iam create-policy \
     --policy-name aws-load-balancer-operator-policy \
     --policy-document "file://${SCRATCH}/load-balancer-operator-policy.json")
   fi
   echo $POLICY_ARN
   ```

1. Create trust policy for ALB Operator

   ```bash
   cat <<EOF > "${SCRATCH}/trust-policy.json"
   {
     "Version": "2012-10-17",
     "Statement": [
     {
     "Effect": "Allow",
     "Condition": {
       "StringEquals" : {
         "${OIDC_ENDPOINT}:sub": ["system:serviceaccount:aws-load-balancer-operator:aws-load-balancer-operator-controller-manager", "system:serviceaccount:aws-load-balancer-operator:aws-load-balancer-controller-cluster"]
       }
     },
     "Principal": {
       "Federated": "arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/${OIDC_ENDPOINT}"
     },
     "Action": "sts:AssumeRoleWithWebIdentity"
     }
     ]
   }
   EOF
   ```

1. Create Role for ALB Operator

   ```bash
   ROLE_ARN=$(aws iam create-role --role-name "${ROSA_CLUSTER_NAME}-alb-operator" \
   --assume-role-policy-document "file://${SCRATCH}/trust-policy.json" \
   --query Role.Arn --output text)
   echo $ROLE_ARN

   aws iam attach-role-policy --role-name "${ROSA_CLUSTER_NAME}-alb-operator" \
     --policy-arn $POLICY_ARN
   ```

1. Create secret for ALB Operator

   ```bash
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
   ```

1. Install Red Hat AWS Load Balancer Operator

   ```bash
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

1. Install Red Hat AWS Load Balancer Controller

   > Note: If you get an error here wait a minute and try again, it likely means the Operator hasn't completed installing yet.

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

1. Check the Operator and Controller pods are both running

   ```bash
   oc -n aws-load-balancer-operator get pods
   ```

   You should see the following, if not wait a moment and retry.

   ```
   NAME                                                             READY   STATUS    RESTARTS   AGE
   aws-load-balancer-controller-cluster-6ddf658785-pdp5d            1/1     Running   0          99s
   aws-load-balancer-operator-controller-manager-577d9ffcb9-w6zqn   2/2     Running   0          2m4s
   ```

## Validate the deployment with Echo Server application

1. Deploy Echo Server Ingress with ALB

   ```bash
   oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-namespace.yaml
   oc adm policy add-scc-to-user anyuid system:serviceaccount:echoserver:default
   oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-deployment.yaml
   oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-service.yaml
   oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-ingress.yaml
   ```

1. Curl the ALB ingress endpoint to verify the echoserver pod is accessible

   ```
   INGRESS=$(oc -n echoserver get ingress echoserver \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   curl -sH "Host: echoserver.example.com" \
     "http://${INGRESS}" | grep Hostname
   ```

   ```
   Hostname: echoserver-7757d5ff4d-ftvf2
   ```

1. Deploy Echo Server NLB Load Balancer

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: v1
   kind: Service
   metadata:
     name: echoserver-nlb
     namespace: echoserver
     annotations:
       service.beta.kubernetes.io/aws-load-balancer-type: external
       service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
       service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
   spec:
     ports:
       - port: 80
         targetPort: 8080
         protocol: TCP
     type: LoadBalancer
     selector:
       app: echoserver
   EOF
   ```

1. Test the NLB endpoint

   ```bash
   NLB=$(oc -n echoserver get service echoserver-nlb \
     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   curl -s "http://${NLB}" | grep Hostname
   ```

   ```
   Hostname: echoserver-7757d5ff4d-ftvf2
   ```

## Clean Up

1. Delete the Operator and the AWS Roles

   ```bash
   oc delete subscription aws-load-balancer-operator -n aws-load-balancer-operator
   aws iam detach-role-policy \
     --role-name "${ROSA_CLUSTER_NAME}-alb-operator" \
     --policy-arn $POLICY_ARN
   aws iam delete-role \
     --role-name "${ROSA_CLUSTER_NAME}-alb-operator"
   ```

1. If you wish to delete the policy you can run

   ```bash
   aws iam delete-policy --policy-arn $POLICY_ARN
   ```
