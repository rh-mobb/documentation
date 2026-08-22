#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: configure-oadp.sh --cluster NAME --region REGION --bucket BUCKET --role-suffix NAME --env-file FILE

Installs OADP for the currently logged-in cluster and configures a DPA.
Writes generated OADP IAM values to dr.env.
EOF
}

CLUSTER_NAME=""
REGION=""
BUCKET=""
ROLE_SUFFIX=""
ENV_FILE="./dr.env"

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) CLUSTER_NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --role-suffix) ROLE_SUFFIX="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$CLUSTER_NAME" ] || { echo "--cluster is required" >&2; exit 1; }
[ -n "$REGION" ] || { echo "--region is required" >&2; exit 1; }
[ -n "$BUCKET" ] || { echo "--bucket is required" >&2; exit 1; }
[ -n "$ROLE_SUFFIX" ] || { echo "--role-suffix is required" >&2; exit 1; }

source "$ENV_FILE"
: "${AWS_ACCOUNT_ID:?}"

upsert_env() {
  local key="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp)
  touch "$ENV_FILE"
  grep -v -E "^export ${key}=" "$ENV_FILE" > "$tmp" || true
  printf 'export %s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
}

wait_subscription_csv_succeeded() {
  local namespace="$1"
  local subscription="$2"
  local csv_name
  local status
  for _ in $(seq 1 90); do
    csv_name=$(oc get subscription "$subscription" -n "$namespace" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$csv_name" ]; then
      status=$(oc get csv "$csv_name" -n "$namespace" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [ "$status" = "Succeeded" ]; then
        return 0
      fi
    fi
    sleep 10
  done
  echo "Timed out waiting for ${subscription} CSV to reach Succeeded in ${namespace}." >&2
  return 1
}

wait_crd() {
  local crd="$1"
  for _ in $(seq 1 60); do
    if oc get crd "$crd" >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for CRD ${crd}." >&2
  return 1
}

ensure_policy() {
  local policy_name="$1"
  local policy_doc="$2"
  local policy_arn
  local version_count
  local old_version
  policy_arn=$(aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='${policy_name}'].Arn | [0]" \
    --output text)
  if [ "$policy_arn" = "None" ]; then
    aws iam create-policy \
      --policy-name "$policy_name" \
      --policy-document "file://$policy_doc" \
      --query 'Policy.Arn' --output text
    return
  fi

  version_count=$(aws iam list-policy-versions \
    --policy-arn "$policy_arn" \
    --query 'length(Versions)' \
    --output text)
  if [ "$version_count" -ge 5 ]; then
    old_version=$(aws iam list-policy-versions \
      --policy-arn "$policy_arn" \
      --query 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId' \
      --output text)
    if [ -z "$old_version" ] || [ "$old_version" = "None" ]; then
      echo "Cannot update ${policy_arn}; no non-default policy version is available to delete." >&2
      exit 1
    fi
    aws iam delete-policy-version \
      --policy-arn "$policy_arn" \
      --version-id "$old_version" >/dev/null
  fi
  aws iam create-policy-version \
    --policy-arn "$policy_arn" \
    --policy-document "file://$policy_doc" \
    --set-as-default >/dev/null
  echo "$policy_arn"
}

OIDC_ENDPOINT=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')
POLICY_NAME="${PRIMARY_CLUSTER_NAME}-oadp-velero"
ROLE_NAME="${CLUSTER_NAME}-oadp-velero"

POLICY_DOC=$(mktemp)
TRUST_DOC=$(mktemp)
CREDENTIALS=$(mktemp)
trap 'rm -f "$POLICY_DOC" "$TRUST_DOC" "$CREDENTIALS"' EXIT

cat > "$POLICY_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:DescribeVolumes", "ec2:DescribeSnapshots", "ec2:CreateTags", "ec2:CreateVolume", "ec2:CreateSnapshot", "ec2:DeleteSnapshot"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:DeleteObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::${OADP_BUCKET_PRIMARY}/*", "arn:aws:s3:::${OADP_BUCKET_DR}/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::${OADP_BUCKET_PRIMARY}", "arn:aws:s3:::${OADP_BUCKET_DR}"]
    }
  ]
}
EOF

POLICY_ARN=$(ensure_policy "$POLICY_NAME" "$POLICY_DOC")

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
          "system:serviceaccount:openshift-adp:openshift-adp-controller-manager",
          "system:serviceaccount:openshift-adp:velero"
        ]
      }
    }
  }]
}
EOF

if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_DOC" >/dev/null
else
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://$TRUST_DOC" >/dev/null
fi

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

oc create namespace openshift-adp >/dev/null 2>&1 || true

cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: adp
  namespace: openshift-adp
spec:
  targetNamespaces:
    - openshift-adp
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  channel: stable
  installPlanApproval: Automatic
  name: redhat-oadp-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

wait_subscription_csv_succeeded "openshift-adp" "redhat-oadp-operator"
wait_crd "dataprotectionapplications.oadp.openshift.io"
wait_crd "backups.velero.io"
wait_crd "restores.velero.io"

cat > "$CREDENTIALS" <<EOF
[default]
role_arn = ${ROLE_ARN}
web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF

oc create secret generic cloud-credentials \
  -n openshift-adp \
  --from-file=cloud="$CREDENTIALS" \
  --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: dr-demo-dpa
  namespace: openshift-adp
spec:
  configuration:
    velero:
      defaultPlugins:
        - aws
        - openshift
        - csi
    nodeAgent:
      enable: false
      uploaderType: kopia
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${BUCKET}
          prefix: velero
        config:
          region: ${REGION}
        credential:
          name: cloud-credentials
          key: cloud
EOF

ENV_PREFIX=$(echo "$ROLE_SUFFIX" | tr '[:lower:]-' '[:upper:]_')
upsert_env "OADP_POLICY_ARN" "$POLICY_ARN"
upsert_env "OADP_ROLE_ARN_${ENV_PREFIX}" "$ROLE_ARN"

echo "OADP configuration submitted for $CLUSTER_NAME. Verify BSL availability before continuing."
