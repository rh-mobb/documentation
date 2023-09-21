---
date: '2021-10-04'
title: Extending ROSA STS to include authentication with AWS Services
tags: ["AWS", "ROSA", "STS"]
authors:
  - Connor Wooley
---

In this example we will deploy the Amazon Ingress Controller that uses ALBs, and configure it to use STS authentication.

## Deployment

### Configure STS

1. Make sure your cluster has the pod identity webhook

    ```bash
    kubectl get mutatingwebhookconfigurations.admissionregistration.k8s.io pod-identity-webhook
    ```

1. Download the IAM Policy for the AWS Load Balancer Hooks

    ```bash
    wget https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.2.0/docs/install/iam_policy.json
    ```

1. Create AWS Role with inline policy

    ```bash
    aws iam create-role \
      --role-name AWSLoadBalancerController --query Policy.Arn --output text
   ```



1. Create AWS Policy and Service Account

    ```bash
    POLICY_ARN=$(aws iam create-policy --policy-name "AWSLoadBalancerControllerIAMPolicy" --policy-document file://iam_policy.json --query Policy.Arn --output text)
    echo $POLICY_ARN
    ```

1. Create service account

    > Note I had issues with the policy, and for now just gave this user admin
      creds. Need to revisit and figure out.

    ```
    SA_ARN=$(aws iam create-user --user-name aws-lb-controller --permissions-boundary=$POLICY_ARN --query User.Arn --output text)
    ```

1. Create access key

    ```
    ACCESS_KEY=$(aws iam create-access-key --user-name aws-lb-controller)
    ```

1. Attach policy to user

    ```bash

1. Paste the `AccessKeyId` and `SecretAccessKey` into values.yaml

1. tag your public subnet with ``

1. Create a namespace for the controller

    ```bash
    kubectl create ns aws-load-balancer-controller
    ```
<!--
1. Create a service account for the controller

    ```bash
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    sts.amazonaws.com/role-arn: "${IAM_ARN}"
    eks.amazonaws.com/role-arn: "${IAM_ARN}"
    eks.amazonaws.com/audience: sts.amazonaws.com
  name: aws-load-balancer-controller
  namespace: aws-load-balancer-controller
EOF
    ```
-->
1. Apply CRDs

    ```bash
    kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller//crds?ref=master"
    ```

1. Add the helm repo and install the controller (install [helm3](https://github.com/helm/helm/releases/tag/v3.5.4) if not already)

    ```bash
    helm repo add eks https://aws.github.io/eks-charts
    helm install -n aws-load-balancer-controller \
      aws-load-balancer-controller eks/aws-load-balancer-controller \
      --values=./helm/values.yaml --create-namespace
    ```


## Deploy Sample Application


```bash
oc new-project demo
oc new-app https://github.com/sclorg/django-ex.git
kubectl -n demo patch service django-ex -p '{"spec":{"type":"NodePort"}}'
```

```bash
kubectl apply -f ingress.yaml
```