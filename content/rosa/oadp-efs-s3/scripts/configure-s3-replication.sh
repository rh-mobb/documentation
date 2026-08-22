#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: configure-s3-replication.sh --env-file FILE

Requires PRIMARY_CLUSTER_NAME, DR_CLUSTER_NAME, PRIMARY_REGION, DR_REGION in dr.env.
Creates app and OADP buckets, enables versioning, and configures one-way CRR.
EOF
}

ENV_FILE="./dr.env"
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

source "$ENV_FILE"

: "${PRIMARY_CLUSTER_NAME:?}"
: "${DR_CLUSTER_NAME:?}"
: "${PRIMARY_REGION:?}"
: "${DR_REGION:?}"
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

APP_BUCKET_PRIMARY="${APP_BUCKET_PRIMARY:-${PRIMARY_CLUSTER_NAME}-app-data}"
APP_BUCKET_DR="${APP_BUCKET_DR:-${DR_CLUSTER_NAME}-app-data}"
OADP_BUCKET_PRIMARY="${OADP_BUCKET_PRIMARY:-${PRIMARY_CLUSTER_NAME}-oadp-backups}"
OADP_BUCKET_DR="${OADP_BUCKET_DR:-${DR_CLUSTER_NAME}-oadp-backups}"
ROLE_NAME="${PRIMARY_CLUSTER_NAME}-s3-replication"
APP_POLICY_NAME="${PRIMARY_CLUSTER_NAME}-dr-demo-s3"

create_bucket() {
  local bucket="$1"
  local region="$2"
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    return
  fi
  if [ "$region" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$bucket" --region "$region" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "$bucket" \
      --region "$region" \
      --create-bucket-configuration "LocationConstraint=$region" >/dev/null
  fi
}

for item in \
  "$APP_BUCKET_PRIMARY:$PRIMARY_REGION" \
  "$APP_BUCKET_DR:$DR_REGION" \
  "$OADP_BUCKET_PRIMARY:$PRIMARY_REGION" \
  "$OADP_BUCKET_DR:$DR_REGION"; do
  bucket=${item%%:*}
  region=${item##*:}
  create_bucket "$bucket" "$region"
  aws s3api put-bucket-versioning \
    --bucket "$bucket" \
    --versioning-configuration Status=Enabled >/dev/null
done

TRUST_DOC=$(mktemp)
POLICY_DOC=$(mktemp)
APP_REPL=$(mktemp)
OADP_REPL=$(mktemp)
APP_POLICY_DOC=$(mktemp)
APP_TRUST_PRIMARY=$(mktemp)
APP_TRUST_DR=$(mktemp)
trap 'rm -f "$TRUST_DOC" "$POLICY_DOC" "$APP_REPL" "$OADP_REPL" "$APP_POLICY_DOC" "$APP_TRUST_PRIMARY" "$APP_TRUST_DR"' EXIT

cat > "$TRUST_DOC" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "s3.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
JSON

if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_DOC" >/dev/null
else
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://$TRUST_DOC" >/dev/null
fi

cat > "$POLICY_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetReplicationConfiguration", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${APP_BUCKET_PRIMARY}",
        "arn:aws:s3:::${OADP_BUCKET_PRIMARY}"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"],
      "Resource": [
        "arn:aws:s3:::${APP_BUCKET_PRIMARY}/*",
        "arn:aws:s3:::${OADP_BUCKET_PRIMARY}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"],
      "Resource": [
        "arn:aws:s3:::${APP_BUCKET_DR}/*",
        "arn:aws:s3:::${OADP_BUCKET_DR}/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name s3-crr-policy \
  --policy-document "file://$POLICY_DOC" >/dev/null

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

make_replication_doc() {
  local id="$1"
  local dest_bucket="$2"
  local output="$3"
  cat > "$output" <<EOF
{
  "Role": "${ROLE_ARN}",
  "Rules": [{
    "ID": "${id}",
    "Priority": 1,
    "Status": "Enabled",
    "Filter": {},
    "DeleteMarkerReplication": {"Status": "Enabled"},
    "Destination": {"Bucket": "arn:aws:s3:::${dest_bucket}"}
  }]
}
EOF
}

make_replication_doc app-data-crr "$APP_BUCKET_DR" "$APP_REPL"
make_replication_doc oadp-backups-crr "$OADP_BUCKET_DR" "$OADP_REPL"

aws s3api put-bucket-replication \
  --bucket "$APP_BUCKET_PRIMARY" \
  --replication-configuration "file://$APP_REPL"

aws s3api put-bucket-replication \
  --bucket "$OADP_BUCKET_PRIMARY" \
  --replication-configuration "file://$OADP_REPL"

cat > "$APP_POLICY_DOC" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"],
    "Resource": [
      "arn:aws:s3:::${APP_BUCKET_PRIMARY}",
      "arn:aws:s3:::${APP_BUCKET_PRIMARY}/*",
      "arn:aws:s3:::${APP_BUCKET_DR}",
      "arn:aws:s3:::${APP_BUCKET_DR}/*"
    ]
  }]
}
EOF

APP_POLICY_ARN=$(ensure_policy "$APP_POLICY_NAME" "$APP_POLICY_DOC")

make_app_trust() {
  local cluster_name="$1"
  local output="$2"
  local oidc_endpoint
  oidc_endpoint=$(rosa describe cluster -c "$cluster_name" -o json | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')
  cat > "$output" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${oidc_endpoint}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${oidc_endpoint}:sub": [
          "system:serviceaccount:dr-demo:s3-writer",
          "system:serviceaccount:dr-demo:dashboard",
          "system:serviceaccount:dr-demo:default"
        ]
      }
    }
  }]
}
EOF
}

make_app_trust "$PRIMARY_CLUSTER_NAME" "$APP_TRUST_PRIMARY"
make_app_trust "$DR_CLUSTER_NAME" "$APP_TRUST_DR"

APP_ROLE_PRIMARY="${PRIMARY_CLUSTER_NAME}-dr-demo-s3"
APP_ROLE_DR="${DR_CLUSTER_NAME}-dr-demo-s3"

if ! aws iam get-role --role-name "$APP_ROLE_PRIMARY" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$APP_ROLE_PRIMARY" \
    --assume-role-policy-document "file://$APP_TRUST_PRIMARY" >/dev/null
else
  aws iam update-assume-role-policy \
    --role-name "$APP_ROLE_PRIMARY" \
    --policy-document "file://$APP_TRUST_PRIMARY" >/dev/null
fi

if ! aws iam get-role --role-name "$APP_ROLE_DR" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$APP_ROLE_DR" \
    --assume-role-policy-document "file://$APP_TRUST_DR" >/dev/null
else
  aws iam update-assume-role-policy \
    --role-name "$APP_ROLE_DR" \
    --policy-document "file://$APP_TRUST_DR" >/dev/null
fi

aws iam attach-role-policy --role-name "$APP_ROLE_PRIMARY" --policy-arn "$APP_POLICY_ARN" >/dev/null 2>&1 || true
aws iam attach-role-policy --role-name "$APP_ROLE_DR" --policy-arn "$APP_POLICY_ARN" >/dev/null 2>&1 || true

APP_S3_ROLE_ARN_PRIMARY=$(aws iam get-role --role-name "$APP_ROLE_PRIMARY" --query 'Role.Arn' --output text)
APP_S3_ROLE_ARN_DR=$(aws iam get-role --role-name "$APP_ROLE_DR" --query 'Role.Arn' --output text)

upsert_env "APP_BUCKET_PRIMARY" "$APP_BUCKET_PRIMARY"
upsert_env "APP_BUCKET_DR" "$APP_BUCKET_DR"
upsert_env "OADP_BUCKET_PRIMARY" "$OADP_BUCKET_PRIMARY"
upsert_env "OADP_BUCKET_DR" "$OADP_BUCKET_DR"
upsert_env "S3_REPLICATION_ROLE_NAME" "$ROLE_NAME"
upsert_env "S3_REPLICATION_ROLE_ARN" "$ROLE_ARN"
upsert_env "APP_S3_POLICY_ARN" "$APP_POLICY_ARN"
upsert_env "APP_S3_ROLE_NAME_PRIMARY" "$APP_ROLE_PRIMARY"
upsert_env "APP_S3_ROLE_NAME_DR" "$APP_ROLE_DR"
upsert_env "APP_S3_ROLE_ARN_PRIMARY" "$APP_S3_ROLE_ARN_PRIMARY"
upsert_env "APP_S3_ROLE_ARN_DR" "$APP_S3_ROLE_ARN_DR"

echo "S3 replication configured from $PRIMARY_REGION to $DR_REGION."
