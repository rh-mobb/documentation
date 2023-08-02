#!/bin/sh
oc create ns aws-load-balancer-operator
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
ROSA_CLUSTER_VPC_ID=$(aws ec2 describe-subnets --subnet-ids $ROSA_CLUSTER_SUBNET --query 'Subnets[0].VpcId' --output text)
echo "ROSA cluster VPC ID $ROSA_CLUSTER_VPC_ID"

aws ec2 create-tags --resources ${ROSA_CLUSTER_VPC_ID} \
  --tags Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned \
  --region ${REGION}


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


# Configuring egress proxy for AWS Load Balancer Operator
# oc -n aws-load-balancer-operator create configmap trusted-ca
# oc -n aws-load-balancer-operator label cm trusted-ca config.openshift.io/inject-trusted-cabundle=true
# oc -n aws-load-balancer-operator patch subscription aws-load-balancer-operator --type='merge' -p '{"spec":{"config":{"env":[{"name":"TRUSTED_CA_CONFIGMAP_NAME","value":"trusted-ca"}],"volumes":[{"name":"trusted-ca","configMap":{"name":"trusted-ca"}}],"volumeMounts":[{"name":"trusted-ca","mountPath":"/etc/pki/tls/certs/albo-tls-ca-bundle.crt","subPath":"ca-bundle.crt"}]}}}'
# oc -n aws-load-balancer-operator exec deploy/aws-load-balancer-operator-controller-manager -c manager -- bash -c "ls -l /etc/pki/tls/certs/albo-tls-ca-bundle.crt; printenv TRUSTED_CA_CONFIGMAP_NAME"
# oc -n aws-load-balancer-operator rollout restart deployment/aws-load-balancer-operator-controller-manager
# end of Configuring egress proxy section