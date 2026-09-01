#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-efs-csi.sh --cluster NAME --region REGION

Installs/configures EFS CSI prerequisites for the currently logged-in cluster.
Writes generated IAM values to the shared dr.env file.
EOF
}

CLUSTER_NAME=""
REGION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER_NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$CLUSTER_NAME" ] || { echo "--cluster is required" >&2; exit 1; }
[ -n "$REGION" ] || { echo "--region is required" >&2; exit 1; }


wait_subscription_csv_succeeded() {
  local namespace="$1"
  local subscription="$2"
  local csv_name
  local status
  local reason
  local message
  for _ in $(seq 1 90); do
    csv_name=$(oc get subscription "$subscription" -n "$namespace" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$csv_name" ]; then
      status=$(oc get csv "$csv_name" -n "$namespace" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [ "$status" = "Succeeded" ]; then
        return 0
      fi
      if [ "$status" = "Failed" ]; then
        reason=$(oc get csv "$csv_name" -n "$namespace" \
          -o jsonpath='{.status.reason}' 2>/dev/null || true)
        message=$(oc get csv "$csv_name" -n "$namespace" \
          -o jsonpath='{.status.message}' 2>/dev/null || true)
        echo "CSV ${namespace}/${csv_name} failed." >&2
        echo "Phase: ${status}" >&2
        echo "Reason: ${reason}" >&2
        echo "Message: ${message}" >&2
        return 1
      fi
    fi
    sleep 10
  done
  echo "Timed out waiting for ${subscription} CSV to reach Succeeded in ${namespace}." >&2
  return 1
}

wait_deployment_available() {
  local namespace="$1"
  local deployment="$2"
  oc wait "deployment/${deployment}" -n "$namespace" \
    --for=condition=Available --timeout=900s
}

wait_serviceaccount() {
  local namespace="$1"
  local serviceaccount="$2"
  for _ in $(seq 1 60); do
    if oc get serviceaccount "$serviceaccount" -n "$namespace" >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for serviceaccount/${serviceaccount} in ${namespace}." >&2
  return 1
}

ensure_policy_version() {
  local policy_arn="$1"
  local policy_name="$2"
  local policy_doc="$3"
  local version_count
  local old_version
  if aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
    version_count=$(aws iam list-policy-versions \
      --policy-arn "$policy_arn" \
      --query 'length(Versions)' \
      --output text)
    if [ "$version_count" -ge 5 ]; then
      old_version=$(aws iam list-policy-versions \
        --policy-arn "$policy_arn" \
        --query 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId' \
        --output text)
      require_nonempty_policy_version "$policy_arn" "$old_version"
      aws iam delete-policy-version \
        --policy-arn "$policy_arn" \
        --version-id "$old_version" >/dev/null
    fi
    aws iam create-policy-version \
      --policy-arn "$policy_arn" \
      --policy-document "file://$policy_doc" \
      --set-as-default >/dev/null
  else
    aws iam create-policy \
      --policy-name "$policy_name" \
      --policy-document "file://$policy_doc" >/dev/null
  fi
}

require_nonempty_policy_version() {
  local policy_arn="$1"
  local version_id="$2"
  if [ -z "$version_id" ] || [ "$version_id" = "None" ]; then
    echo "Cannot create a new policy version for ${policy_arn}; no non-default version is available to delete." >&2
    exit 1
  fi
}

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ENDPOINT=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')
POLICY_NAME="${CLUSTER_NAME}-aws-efs-csi-policy"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
ROLE_NAME="${CLUSTER_NAME}-aws-efs-csi-operator"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
NAMESPACE="openshift-cluster-csi-drivers"

POLICY_DOC=$(mktemp)
TRUST_DOC=$(mktemp)
trap 'rm -f "$POLICY_DOC" "$TRUST_DOC"' EXIT

cat > "$POLICY_DOC" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:CreateAccessPoint",
        "elasticfilesystem:DeleteAccessPoint",
        "elasticfilesystem:TagResource",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    }
  ]
}
JSON

cat > "$TRUST_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_ENDPOINT}:sub": [
          "system:serviceaccount:${NAMESPACE}:aws-efs-csi-driver-operator",
          "system:serviceaccount:${NAMESPACE}:aws-efs-csi-driver-controller-sa"
        ]
      }
    }
  }]
}
EOF

ensure_policy_version "$POLICY_ARN" "$POLICY_NAME" "$POLICY_DOC"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://$TRUST_DOC" >/dev/null
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_DOC" >/dev/null
fi

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: aws-efs-csi-driver-operator
  namespace: ${NAMESPACE}
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: aws-efs-csi-driver-operator
  namespace: ${NAMESPACE}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: aws-efs-csi-driver-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

wait_subscription_csv_succeeded "$NAMESPACE" "aws-efs-csi-driver-operator"
wait_serviceaccount "$NAMESPACE" "aws-efs-csi-driver-operator"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aws-efs-cloud-credentials
  namespace: ${NAMESPACE}
stringData:
  credentials: |
    [default]
    role_arn = ${ROLE_ARN}
    web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF

cat <<'EOF' | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: efs.csi.aws.com
spec:
  managementState: Managed
EOF

wait_serviceaccount "$NAMESPACE" "aws-efs-csi-driver-controller-sa"
wait_deployment_available "$NAMESPACE" "aws-efs-csi-driver-controller"

ENV_PREFIX=$(echo "$CLUSTER_NAME" | tr '[:lower:]-' '[:upper:]_')
echo "export ${ENV_PREFIX}_EFS_CSI_ROLE_NAME=$ROLE_NAME"
echo "export ${ENV_PREFIX}_EFS_CSI_ROLE_ARN=$ROLE_ARN"
echo "export ${ENV_PREFIX}_EFS_CSI_POLICY_NAME=$POLICY_NAME"
echo "export ${ENV_PREFIX}_EFS_CSI_POLICY_ARN=$POLICY_ARN"

echo "EFS CSI setup completed for $CLUSTER_NAME." >&2
