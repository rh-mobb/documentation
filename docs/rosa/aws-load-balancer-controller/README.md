# Using AWS Load Balancer Controller On Red Hat OpenShift on AWS with STS

Author **Shaozhen Ding**

[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.4/) is a controller to help manage Elastic Load Balancers for a Kubernetes cluster.

* It satisfies Kubernetes [Ingress resources](https://kubernetes.io/docs/concepts/services-networking/ingress/) by provisioning [Application Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html).
* It satisfies Kubernetes [Service resources](https://kubernetes.io/docs/concepts/services-networking/service/) by provisioning [Network Load Balancers](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/introduction.html).

Compared with default AWS In Tree Provider, this controller is actively developed with advanced annotations for both [ALB](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.2/guide/ingress/annotations/) and [NLB](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.2/guide/service/annotations/#lb-type). Some advanced usecases are:

* Using native kubernetes ingress with ALB
* Integrate ALB with WAF
* Specify NLB source IP ranges
* Specify NLB internal IP address

## Prerequisites

* [A ROSA cluster deployed with STS](/docs/rosa/sts/)
* Helm 3
* AWS CLI
* OC

## Installation

* Prepare the environment variables

```bash
export ROSA_CLUSTER_NAME=USE_YOUR_ROSA_CLUSTER_NAME
export VPC_ID=USER_YOUR_ROSA_VPC_ID
export ROSA_CLUSTER_ID=$(rosa describe cluster -c $ROSA_CLUSTER_NAME --output json | jq -r .id)
export REGION=us-east-2
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster -o json | jq .spec.serviceAccountIssuer)
export AWS_ACCOUNT_ID=`aws sts get-caller-identity --query Account --output text`
```

* Install Red Hat Cert Manager Operator

```bash
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: openshift-operators
spec:
  channel: tech-preview
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: openshift-cert-manager.v1.7.1
EOF
```

* Create Role and Policy for the aws load balancer controller

```
oc new-project aws-load-balancer-controller
wget https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.4/docs/install/iam_policy.json
POLICY_ARN=$(aws --region "$REGION" --query Policy.Arn \
--output text iam create-policy \
--policy-name aws-load-balancer-controller-policy \
--policy-document file://iam_policy.json)
echo $POLICY_ARN

cat <<EOF > trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
  {
  "Effect": "Allow",
  "Condition": {
    "StringEquals" : {
      "rh-oidc.s3.us-east-1.amazonaws.com/${ROSA_CLUSTER_ID}:sub": ["system:serviceaccount:aws-load-balancer-controller:aws-load-balancer-controller"]
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

ROLE_ARN=$(aws iam create-role --role-name aws-load-balancer-controller-role \
--assume-role-policy-document file://trust-policy.json \
--query Role.Arn --output text)
echo $ROLE_ARN

aws iam attach-role-policy --role-name aws-load-balancer-controller-role --policy-arn $POLICY_ARN
```


* Prepare aws load balancer controller service account

```
oc create sa aws-load-balancer-controller
oc adm policy add-scc-to-user nonroot system:serviceaccount:aws-load-balancer-controller:aws-load-balancer-controller
oc annotate -n aws-load-balancer-controller serviceaccount aws-load-balancer-controller \
   eks.amazonaws.com/role-arn=$ROLE_ARN
```

* Deploy aws load balancer controller helm chart

```   
helm repo add eks https://aws.github.io/eks-charts
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')

cat <<EOF > values.yaml
clusterName: ${CLUSTER_NAME}
vpcId: ${VPC_ID}
region: ${REGION}
serviceAccount:
  create: false
  name: aws-load-balancer-controller
EOF

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n aws-load-balancer-controller \
  -f values.yaml
```

* Tag ROSA AWS Subnets

    * Tag all the rosa private subnets with kubernetes.io/role/internal-elb = 1
    * Tag all the rosa public subnets with kubernetes.io/role/elb = 1

## Validate the deployment with Echo Server application

### Deploy Echo Server Ingress with ALB

```
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-namespace.yaml
oc adm policy add-scc-to-user anyuid system:serviceaccount:echoserver:default
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-deployment.yaml
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-service.yaml
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/echoservice/echoserver-ingress.yaml

oc get ingress -n echoserver
NAME         CLASS   HOSTS                    ADDRESS                                                                   PORTS   AGE
echoserver   alb     echoserver.example.com   k8s-echoserv-echoserv-184217cc5b-1916535176.us-east-2.elb.amazonaws.com   80      19s

curl -vvv -H "HOST: echoserver.example.com" http://k8s-echoserv-echoserv-184217cc5b-1916535176.us-east-2.elb.amazonaws.com
```

### Deploy Echo Server NLB Load Balancer

```
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

* helm uninstall aws-load-balancer-controller
* aws iam detach-role-policy --role-name aws-load-balancer-controller --policy-arn $POLICY_ARN
* aws iam delete-role --role-name aws-load-balancer-controller
* aws iam delete-policy --policy-arn $POLICY_ARN