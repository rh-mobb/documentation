# Using AWS Load Balancer Operator On Red Hat OpenShift on AWS with STS

Author **Shaozhen Ding**

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
* Tag the VPC (If this is a bring your own VPC)

  ```
  CLUSTER_NAME=$(oc get infrastructure cluster -o=jsonpath="{.status.infrastructureName}")
  aws ec2 create-tags --resources VPC_ID --tags Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned 
  ```

## Installation

* Prepare the environment variables

```bash
export ROSA_CLUSTER_NAME=USE_YOUR_ROSA_CLUSTER_NAME
export REGION=THE_REGION
export ROSA_CLUSTER_ID=$(rosa describe cluster -c $ROSA_CLUSTER_NAME --output json | jq -r .id)
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o json | jq .spec.serviceAccountIssuer)
export AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text`
```

* Create Role and Policy for the aws load balancer controller

**notes**: Policy is from [AWS Load Balancer Controller Policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.4/docs/install/iam_policy.json) plus subnet create tags permission (required by the operator)


```bash
oc new-project aws-load-balancer-operator
wget https://raw.githubusercontent.com/rh-mobb/documentation/main/docs/rosa/aws-load-balancer-operator/load-balancer-operator-policy.json
POLICY_ARN=$(aws --region "$REGION" --query Policy.Arn \
--output text iam create-policy \
--policy-name aws-load-balancer-operator-policy \
--policy-document file://load-balancer-operator-policy.json)
echo $POLICY_ARN

cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
  {
  "Effect": "Allow",
  "Condition": {
    "StringEquals" : {
      "rh-oidc.s3.us-east-1.amazonaws.com/${ROSA_CLUSTER_ID}:sub": ["system:serviceaccount:aws-load-balancer-operator:aws-load-balancer-operator-controller-manager", "system:serviceaccount:aws-load-balancer-operator:aws-load-balancer-controller-cluster"]
    }
  },
  "Principal": {
    "Federated": "arn:aws:iam::$AWS_ACCOUNT_ID:oidc-provider/rh-oidc.s3.us-east-1.amazonaws.com/$ROSA_CLUSTER_ID"
  },
  "Action": "sts:AssumeRoleWithWebIdentity"
  }
  ]
}
EOF

ROLE_ARN=$(aws iam create-role --role-name aws-load-balancer-operator-role \
--assume-role-policy-document file://trust-policy.json \
--query Role.Arn --output text)
echo $ROLE_ARN

aws iam attach-role-policy --role-name aws-load-balancer-operator-role --policy-arn $POLICY_ARN

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

* Install Red Hat AWS Load Balancer Operator

```bash
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: aws-load-balancer-operator
  namespace: aws-load-balancer-operator
spec:
  targetNamespaces:
    - aws-load-balancer-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: aws-load-balancer-operator
  namespace: aws-load-balancer-operator
spec:
  channel: stable-v0
  installPlanApproval: Automatic
  name: aws-load-balancer-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: aws-load-balancer-operator.v0.2.0
EOF
```

* Install Red Hat AWS Load Balancer Controller CRD

```bash
cat << EOF | oc apply -f -
apiVersion: networking.olm.openshift.io/v1alpha1
kind: AWSLoadBalancerController
metadata:
  name: cluster
spec:
  credentials:
    name: aws-load-balancer-operator
EOF
```

* Tag ROSA AWS Subnets

    * Tag all the rosa private subnets with kubernetes.io/role/internal-elb = 1
    * Tag all the rosa public subnets with kubernetes.io/role/elb = 1

## Validate the deployment with Echo Server application

### Deploy Echo Server Ingress with ALB

```bash
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-namespace.yaml
oc adm policy add-scc-to-user anyuid system:serviceaccount:echoserver:default
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-deployment.yaml
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-service.yaml
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-ingress.yaml

oc get ingress -n echoserver
NAME         CLASS   HOSTS   ADDRESS                                                                  PORTS   AGE
echoserver   alb     *       k8s-echoserv-echoserv-384bcaf98e-798185250.us-east-2.elb.amazonaws.com   80      24s

curl -vvv -H "HOST: echoserver.example.com" http://k8s-echoserv-echoserv-384bcaf98e-798185250.us-east-2.elb.amazonaws.com
```

### Deploy Echo Server NLB Load Balancer

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

oc get service -n echoserver
NAME             TYPE           CLUSTER-IP      EXTERNAL-IP                                                                     PORT(S)        AGE
echoserver       NodePort       172.30.153.66   <none>                                                                          80:31296/TCP   48m
echoserver-nlb   LoadBalancer   172.30.53.223   k8s-echoserv-echoserv-d036437ed4-94d8073cee7e077c.elb.us-east-2.amazonaws.com   80:31957/TCP   4m12s
```

## Clean Up

* oc delete subscription aws-load-balancer-operator -n aws-load-balancer-operator
* aws iam detach-role-policy --role-name aws-load-balancer-operator-role --policy-arn $POLICY_ARN
* aws iam delete-role --role-name aws-load-balancer-operator-role
* aws iam delete-policy --policy-arn $POLICY_ARN