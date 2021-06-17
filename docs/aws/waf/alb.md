# This is a POC of ROSA with a AWS WAF service

**This is not endorsed or supported in any way by Red Hat, YMMV**

[Here](https://iamondemand.com/blog/elb-vs-alb-vs-nlb-choosing-the-best-aws-load-balancer-for-your-needs/)'s a good overview of AWS LB types and what they support

## Problem Statement

1. Operator requires WAF (Web Application Firewall) in front of their workloads running on OpenShift (ROSA)

1. Operator does not want WAF running on OpenShift to ensure that OCP resources do not experience Denial of Service through handling the WAF

## Proposed Solution

> Loosely based off EKS instructions here - https://aws.amazon.com/premiumsupport/knowledge-center/eks-alb-ingress-aws-waf/

1. Deploy secondary Ingress solution (+TLS +DNS) that uses an AWS ALB

    * **Todo** Configure TLS + DNS for that Ingress (Lets Encrypt + WildCard DNS)

![](./alb.drawio.png)

## Deployment

Create a new public ROSA cluster called `waf-demo` and make sure to set it to be multi-AZ enabled.

### AWS Load Balancer Controller

AWS Load Balancer controller manages the following AWS resources

Application Load Balancers to satisfy Kubernetes ingress objects
Network Load Balancers in IP mode to satisfy Kubernetes service objects of type LoadBalancer with NLB IP mode annotation

1. Create AWS Policy and Service Account

    ```bash
    POLICY_ARN=$(aws iam create-policy --policy-name "AWSLoadBalancerControllerIAMPolicy" --policy-document file://iam-policy.json --query Policy.Arn --output text)
    echo $POLICY_ARN
    ```

1. Create service account

    ```bash
    aws iam create-user --user-name aws-lb-controller  --query User.Arn --output text
    ```

1. Attach policy to user

    ```bash
    aws iam attach-user-policy --user-name aws-lb-controller --policy-arn ${POLICY_ARN}
    ```

1. Create access key and save the output (Paste the `AccessKeyId` and `SecretAccessKey` into `values.yaml`)

    ```bash
    aws iam create-access-key --user-name aws-lb-controller
    ```

1. Modify the VPC ID and cluster name in the `values.yaml` with the output from *(replace `poc-waf` with your cluster name)*:

    ```bash
    aws ec2 describe-vpcs --output json --filters Name=tag-value,Values="poc-waf*" | jq . | grep VpcId
    ```

1. Modify the subnet list in `ingress.yaml` with the output from: *(replace `poc-waf` with your cluster name)*

    ```bash
    aws ec2 describe-subnets --output json \
      --filters Name=tag-value,Values="poc-waf-*public*" \
      | jq -r | grep SubnetId
    ```

1. Add tags to those subnets (change the subnet ids in the resources line)

    ```bash
      aws ec2 create-tags \
        --resources subnet-0fd57669a80eb7596 subnet-0aa9967e8767d792f subnet-0982bb73ca67d61de \
        --tags Key=kubernetes.io/role/elb,Value=   Key=kubernetes.io/cluster/poc-waf,Value=shared
    ```
1. Create a namespace for the controller

    ```bash
    kubectl create ns aws-load-balancer-controller
    ```

1. Apply CRDs

    ```bash
    kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"
    ```

1. Add the helm repo and install the controller (install [helm3](https://github.com/helm/helm/releases/tag/v3.5.4) if not already)

    ```bash
    helm repo add eks https://aws.github.io/eks-charts
    helm install -n aws-load-balancer-controller \
      aws-load-balancer-controller eks/aws-load-balancer-controller \
      --values=values.yaml --create-namespace
    ```


### Deploy Sample Application

1. Create a new application in OpenShift

    ```bash
    oc new-project demo
    oc new-app https://github.com/sclorg/django-ex.git
    kubectl -n demo patch service django-ex -p '{"spec":{"type":"NodePort"}}'
    ```

1. Create an Ingress to trigger an ALB

    ```bash
    kubectl apply -f ingress.yaml
    ```

1. Check the logs of the ALB controller

    ```
    kubectl logs -f deployment/aws-load-balancer-controller
    ```

1. use the second address from the ingress to browse to the app

    ```
    kubectl -n demo get ingress
    ```

    ```bash
    curl -s --header "Host: foo.bar" k8s-demo-djangoex-49f31c1921-782305710.us-east-2.elb.amazonaws.com | head
    ```

### WAF time

1. Create a WAF rule here https://console.aws.amazon.com/wafv2/homev2/web-acls/new and use the Core and SQL Injection rules. (make sure region matches us-east-2)

1. View your WAF

    ```bash
    aws wafv2 list-web-acls --scope REGIONAL --region us-east-2 | jq .
    ```

1. set the waf annotation to match the ARN provided above (and uncomment it) then re-apply the ingress

    ```bash
    kubectl apply -f ingress.yaml
    ```

1. test the app still works

    ```bash
    curl -s --header "Host: foo.bar" --location "k8s-demo-djangoex-49f31c1921-782305710.us-east-2.elb.amazonaws.com"
    ```

1. test the WAF denies a bad request

    *You should get a **403 Forbidden** error*

    ```bash
    curl -X POST http://k8s-demo-djangoex-49f31c1921-782305710.us-east-2.elb.amazonaws.com -F "user='<script><alert>Hello></alert></script>'"
    ```