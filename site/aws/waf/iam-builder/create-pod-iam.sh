#!/bin/bash

set -x
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

AWS_CREDENTIAL_FILE=$HOME_DIR/.aws/credentials
AWS_CONFIG_FILE=$HOME_DIR/.aws/config
OIDC_S3_BUCKET_NAME=my-ocp-bucket-oidc

#AWS_PROFILE=""
AWS_REGION=us-east-2
OC_CONFIG_FILE=$HOME_DIR/.kube/config
WEBHOOK_DIR=$HOME_DIR/amazon-eks-pod-identity-webhook
ASSETS_DIR=${DIR}/runtime-assets
CLIENT_ID=sts.amazonaws.com
BIN_DIR=${DIR}/bin
POD_IDENTITY_WEBHOOK_NAMESPACE="pod-identity-webhook"
OS=$(echo $(uname) | awk '{print tolower($0)}')

while [[ $# -gt 0 ]]; do
  ARG="$1"
  case $ARG in
    --aws-credentials-file)
      AWS_CREDENTIAL_FILE="$2"
      shift
      shift
      ;;
    --aws-config-file)
      AWS_CONFIG_FILE="$2"
      shift
      shift
      ;;
    --aws-profile)
      AWS_PROFILE="$2"
      shift
      shift
      ;;
    --aws-region)
      AWS_REGION="$2"
      shift
      shift
      ;;
    --aws-output-format)
      AWS_OUTPUT_FORMAT="$2"
      shift
      shift
      ;;
    --oc-config-file)
      OC_CONFIG_FILE="$2"
      shift
      shift
      ;;
    --oidc-s3-bucket-name)
      OIDC_S3_BUCKET_NAME="$2"
      shift
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

for app in aws oc jq openssl; do
  command -v ${app} >/dev/null 2>&1 || { echo >&2 "${app} is required but not installed.  Aborting."; exit 1; }
done

#Check if bucket name was specified
if [ -z $OIDC_S3_BUCKET_NAME ]; then
  echo "--oidc-s3-bucket-name is required. Aborting."
  exit 1
fi

LOCATIONCONSTRAINT_OPTION=""
HOSTNAME=s3-$AWS_REGION.amazonaws.com

# US EAST 1 Modifications
if [ "${AWS_REGION}" != "us-east-1" ]; then
  LOCATIONCONSTRAINT_OPTION="LocationConstraint=${AWS_REGION}"
  HOSTNAME=s3.$AWS_REGION.amazonaws.com
fi


ISSUER_HOSTPATH=$HOSTNAME/$OIDC_S3_BUCKET_NAME

existing_oidc_s3_bucket=$(aws s3api list-buckets --query "Buckets[?Name=='${OIDC_S3_BUCKET_NAME}'].Name | [0]" --out text)
if [ $existing_oidc_s3_bucket == "None" ]; then
echo "Creating OIDC S3 Bucket: '${OIDC_S3_BUCKET_NAME}"
aws s3api create-bucket --bucket $OIDC_S3_BUCKET_NAME --create-bucket-configuration "${LOCATIONCONSTRAINT_OPTION}" > /dev/null
fi


# Create Runtime assets directory if it does not exist
if [ ! -d "${ASSETS_DIR}" ]; then
  mkdir -p ${ASSETS_DIR}
fi

#Get OpenShift keys
PKCS_KEY="sa-signer-pkcs8.pub"
oc get -n openshift-kube-apiserver cm -o json bound-sa-token-signing-certs | jq -r '.data["service-account-001.pub"]' > "${ASSETS_DIR}/${PKCS_KEY}"

if [ $? -ne 0 ]; then
  echo "Error retrieving Kube API Signer CA"
  exit 1
fi

# Create OIDC documents
cat <<EOF > ${ASSETS_DIR}/discovery.json
{
    "issuer": "https://$ISSUER_HOSTPATH/",
    "jwks_uri": "https://$ISSUER_HOSTPATH/keys.json",
    "authorization_endpoint": "urn:kubernetes:programmatic_authorization",
    "response_types_supported": [
        "id_token"
    ],
    "subject_types_supported": [
        "public"
    ],
    "id_token_signing_alg_values_supported": [
        "RS256"
    ],
    "claims_supported": [
        "sub",
        "iss"
    ]
}
EOF

if [ ! -f "${BIN_DIR}/self-hosted-${OS}" ]; then
  echo "Could not locate self hosted binary"
  exit 1
fi

"${BIN_DIR}/self-hosted-${OS}" -key "${ASSETS_DIR}/${PKCS_KEY}"  | jq '.keys += [.keys[0]] | .keys[1].kid = ""' > "${ASSETS_DIR}/keys.json"

# Copy files to OIDC S3 Bucket
echo "Uploading configurations to OIDC S3 Bucket"
aws s3 cp --acl public-read "${ASSETS_DIR}/discovery.json" s3://$OIDC_S3_BUCKET_NAME/.well-known/openid-configuration > /dev/null
aws s3 cp --acl public-read "${ASSETS_DIR}/keys.json" s3://$OIDC_S3_BUCKET_NAME/keys.json > /dev/null

# Create OIDC Provider
FINGERPRINT=`echo | openssl s_client -servername ${HOSTNAME} -showcerts -connect ${HOSTNAME}:443 2>/dev/null | openssl x509 -fingerprint -noout | sed s/://g | sed 's/.*=//'`

cat <<EOF > ${ASSETS_DIR}/create-open-id-connect-provider.json
{
    "Url": "https://$ISSUER_HOSTPATH",
    "ClientIDList": [
        "$CLIENT_ID"
    ],
    "ThumbprintList": [
        "$FINGERPRINT"
    ]
}
EOF

OIDC_IDENTITY_PROVIDER_ARN=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn, '/${OIDC_S3_BUCKET_NAME}')]".Arn --out text)

if [ "${OIDC_IDENTITY_PROVIDER_ARN}" != "" ]; then
  echo "Deleting existing open id connect identity provider"
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn=${OIDC_IDENTITY_PROVIDER_ARN} > /dev/null
fi

echo "Creating Identity Provider"
OIDC_IDENTITY_PROVIDER_ARN=$(aws iam create-open-id-connect-provider --cli-input-json file://${ASSETS_DIR}/create-open-id-connect-provider.json | jq -r .OpenIDConnectProviderArn)


cat <<EOF > ${ASSETS_DIR}/trust-policy.json
{
 "Version": "2012-10-17",
 "Statement": [
  {
   "Effect": "Allow",
   "Principal": {
    "Federated": "${OIDC_IDENTITY_PROVIDER_ARN}"
   },
   "Action": "sts:AssumeRoleWithWebIdentity"
  }
 ]
}
EOF

policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].{ARN:Arn}" --output text)

if [ "${policy_arn}" != "" ]; then
   # Check to see how many policies we have
  policy_versions=$(aws iam list-policy-versions --policy-arn=${policy_arn} --query "Versions[] | length(@)")

  if [ $policy_versions -gt 1 ]; then
    oldest_policy_version=$(aws iam list-policy-versions --policy-arn=${policy_arn} --query "Versions[-1].VersionId" | jq -r)

    echo "Deleting Oldest Policy Version: ${oldest_policy_version}"
    aws iam delete-policy-version --policy-arn=${policy_arn} --version-id=${oldest_policy_version} > /dev/null
  fi

  echo "Creating new Policy Version"
  aws iam create-policy-version --policy-arn ${policy_arn} --policy-document file://${ASSETS_DIR}/bucket-policy.json --set-as-default > /dev/null

else
  echo "Creating new IAM Policy: AWSLoadBalancerControllerIAMPolicy"
  policy_arn=$(aws iam create-policy --policy-name "AWSLoadBalancerControllerIAMPolicy" --policy-document file://iam-policy.json --query Policy.Arn --output text)
fi

role_arn=$(aws iam list-roles --query "Roles[?RoleName=='AWSLoadBalancerControllerIAMRole'].{ARN:Arn}" --out text)

if [ "${role_arn}" == "" ]; then
  echo "Creating Assume Role Policy"
  role_arn=$(aws iam create-role --role-name AWSLoadBalancerControllerIAMRole --assume-role-policy-document file://${ASSETS_DIR}/trust-policy.json --query Role.Arn --output text)
else
  echo "Updating Assume Role Policy"
  aws iam update-assume-role-policy --role-name AWSLoadBalancerControllerIAMRole --policy-document file://${ASSETS_DIR}/trust-policy.json > /dev/null
fi

echo "Attaching Policy to IAM Role"
aws iam attach-role-policy --role-name AWSLoadBalancerControllerIAMRole --policy-arn ${policy_arn} > /dev/null

# echo "Creating OpenShift Manifests"
# until oc apply -f "${DIR}/manifests/pod-identity-webhook" 2>/dev/null; do sleep 2; done

# echo "Waiting for webhook pod to be deployed"
# oc rollout status deploy/pod-identity-webhook -n $POD_IDENTITY_WEBHOOK_NAMESPACE

# echo "Waiting for CSR's to be Created"
# until [ "$(oc get csr -o jsonpath="{ .items[?(@.spec.username==\"system:serviceaccount:$POD_IDENTITY_WEBHOOK_NAMESPACE:pod-identity-webhook\")].metadata.name}")" != "" ]; do sleep 2; done

# echo "Approving CSR's"
# for csr in `oc get csr -n ${POD_IDENTITY_WEBHOOK_NAMESPACE} -o name`; do
#   oc adm certificate approve $csr
# done


echo "Patching OpenShift Cluster Authentication"
oc patch authentication.config.openshift.io cluster --type "json" -p="[{\"op\": \"replace\", \"path\": \"/spec/serviceAccountIssuer\", \"value\":\"https://${ISSUER_HOSTPATH}\"}]"

# echo "Creating Mutating Webhook"
# CA_BUNDLE=$(oc get configmap -n kube-system extension-apiserver-authentication -o=jsonpath='{.data.client-ca-file}' | base64 | tr -d '\n')

# (
# cat <<EOF
# apiVersion: admissionregistration.k8s.io/v1beta1
# kind: MutatingWebhookConfiguration
# metadata:
#   name: pod-identity-webhook
#   namespace: pod-identity-webhook
# webhooks:
# - name: pod-identity-webhook.amazonaws.com
#   failurePolicy: Ignore
#   clientConfig:
#     service:
#       name: pod-identity-webhook
#       namespace: pod-identity-webhook
#       path: "/mutate"
#     caBundle: ${CA_BUNDLE}
#   rules:
#   - operations: [ "CREATE" ]
#     apiGroups: [""]
#     apiVersions: ["v1"]
#     resources: ["pods"]
# EOF
#  ) | oc apply -f-

# echo "Rolling Webhook pods"
# oc delete pods -n ${POD_IDENTITY_WEBHOOK_NAMESPACE} -l=app.kubernetes.io/component=webhook

# echo "Waiting a moment...."
# sleep 10

# echo "Creating Sample Application Resources"
# oc apply -f "${DIR}/manifests/sample-app/namespace.yaml"

# (
# cat <<EOF
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   annotations:
#     sts.amazonaws.com/role-arn: "${role_arn}"
#   name: s3-manager
#   namespace: sample-iam-webhook-app
# EOF
#  ) | oc apply -f-

# oc apply -f "${DIR}/manifests/sample-app/deployment.yaml"


echo
echo "POD IAM Completed Successfully!"
echo "ARN for serviceAccount: ${role_arn}"

