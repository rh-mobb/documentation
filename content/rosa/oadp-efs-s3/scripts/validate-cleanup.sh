#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-cleanup.sh --env-file FILE

Verifies cleanup removed guide-created S3 buckets, EFS file systems, EFS helper
security groups, IAM roles/policies, and OpenShift validation resources.
Prints PASS / STILL EXISTS lines and returns nonzero if anything remains.
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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
fi

if [ -z "${TF_VAR_admin_password:-}" ] && [ -f "${REPO_ROOT}/.env.fallback" ]; then
  source "${REPO_ROOT}/.env.fallback"
fi

: "${PRIMARY_CLUSTER_NAME:?}"
: "${DR_CLUSTER_NAME:?}"
: "${PRIMARY_REGION:?}"
: "${DR_REGION:?}"
: "${APP_BUCKET_PRIMARY:?}"
: "${APP_BUCKET_DR:?}"
: "${OADP_BUCKET_PRIMARY:?}"
: "${OADP_BUCKET_DR:?}"
: "${PRIMARY_EFS:?}"
: "${DR_EFS:?}"
: "${EFS_SG_PRIMARY:?}"
: "${EFS_SG_DR:?}"
: "${APP_S3_ROLE_NAME_PRIMARY:?}"
: "${APP_S3_ROLE_NAME_DR:?}"
: "${S3_REPLICATION_ROLE_NAME:?}"
: "${OADP_ROLE_ARN_PRIMARY:?}"
: "${OADP_ROLE_ARN_DR:?}"
: "${APP_S3_POLICY_ARN:?}"
: "${OADP_POLICY_ARN:?}"

export AWS_PAGER=""
failures=0

env_prefix() {
  printf '%s\n' "$1" | tr '[:lower:]-.' '[:upper:]__'
}

env_value() {
  local key="$1"
  printf '%s\n' "${!key:-}"
}

mark_absent() {
  local label="$1"
  local exists="$2"
  if [ "$exists" = "yes" ]; then
    echo "STILL EXISTS: $label"
    failures=$((failures + 1))
  else
    echo "PASS deleted: $label"
  fi
}

login_cluster() {
  local cluster_name="$1"
  local api
  : "${TF_VAR_admin_password:?Source .env.fallback from the repository root before running this script.}"
  api=$(rosa describe cluster -c "$cluster_name" -o json | jq -r '.api.url')
  oc login "$api" --username admin --password "$TF_VAR_admin_password" >/dev/null
  [ "$(oc whoami --show-server)" = "$api" ]
}

check_openshift_resource_absent() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    mark_absent "$label" yes
  else
    mark_absent "$label" no
  fi
}

for bucket in "$APP_BUCKET_PRIMARY" "$APP_BUCKET_DR" "$OADP_BUCKET_PRIMARY" "$OADP_BUCKET_DR"; do
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    mark_absent "s3 bucket ${bucket}" yes
  else
    mark_absent "s3 bucket ${bucket}" no
  fi
done

for region_fs in "$PRIMARY_REGION:$PRIMARY_EFS" "$DR_REGION:$DR_EFS"; do
  region=${region_fs%%:*}
  fs=${region_fs##*:}
  if aws efs describe-file-systems --region "$region" --file-system-id "$fs" >/dev/null 2>&1; then
    mark_absent "efs file system ${fs}" yes
  else
    mark_absent "efs file system ${fs}" no
  fi
done

for region_sg in "$PRIMARY_REGION:$EFS_SG_PRIMARY" "$DR_REGION:$EFS_SG_DR"; do
  region=${region_sg%%:*}
  sg=${region_sg##*:}
  if aws ec2 describe-security-groups --region "$region" --group-ids "$sg" >/dev/null 2>&1; then
    mark_absent "efs security group ${sg}" yes
  else
    mark_absent "efs security group ${sg}" no
  fi
done

primary_prefix=$(env_prefix "$PRIMARY_CLUSTER_NAME")
dr_prefix=$(env_prefix "$DR_CLUSTER_NAME")
primary_efs_role_name=$(env_value "${primary_prefix}_EFS_CSI_ROLE_NAME")
dr_efs_role_name=$(env_value "${dr_prefix}_EFS_CSI_ROLE_NAME")
primary_efs_role_arn=$(env_value "${primary_prefix}_EFS_CSI_ROLE_ARN")
dr_efs_role_arn=$(env_value "${dr_prefix}_EFS_CSI_ROLE_ARN")
primary_efs_policy_arn=$(env_value "${primary_prefix}_EFS_CSI_POLICY_ARN")
dr_efs_policy_arn=$(env_value "${dr_prefix}_EFS_CSI_POLICY_ARN")

for role in \
  "$APP_S3_ROLE_NAME_PRIMARY" \
  "$APP_S3_ROLE_NAME_DR" \
  "$S3_REPLICATION_ROLE_NAME" \
  "${OADP_ROLE_ARN_PRIMARY##*/}" \
  "${OADP_ROLE_ARN_DR##*/}" \
  "${primary_efs_role_name:-${primary_efs_role_arn##*/}}" \
  "${dr_efs_role_name:-${dr_efs_role_arn##*/}}"
do
  [ -n "$role" ] || continue
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    mark_absent "iam role ${role}" yes
  else
    mark_absent "iam role ${role}" no
  fi
done

for policy in "$APP_S3_POLICY_ARN" "$OADP_POLICY_ARN" "$primary_efs_policy_arn" "$dr_efs_policy_arn"; do
  [ -n "$policy" ] || continue
  if aws iam get-policy --policy-arn "$policy" >/dev/null 2>&1; then
    mark_absent "iam policy ${policy}" yes
  else
    mark_absent "iam policy ${policy}" no
  fi
done

for cluster in "$PRIMARY_CLUSTER_NAME" "$DR_CLUSTER_NAME"; do
  echo "Checking OpenShift validation resources on ${cluster}."
  login_cluster "$cluster"
  check_openshift_resource_absent "${cluster} namespace/dr-demo" oc get namespace dr-demo
  check_openshift_resource_absent "${cluster} namespace/efs-smoke" oc get namespace efs-smoke
  check_openshift_resource_absent "${cluster} dpa/openshift-adp/dr-demo-dpa" oc get dpa dr-demo-dpa -n openshift-adp
  check_openshift_resource_absent "${cluster} secret/openshift-adp/cloud-credentials" oc get secret cloud-credentials -n openshift-adp
  check_openshift_resource_absent "${cluster} subscription/openshift-adp/redhat-oadp-operator" oc get subscription redhat-oadp-operator -n openshift-adp
  check_openshift_resource_absent "${cluster} clustercsidriver/efs.csi.aws.com" oc get clustercsidriver efs.csi.aws.com
  check_openshift_resource_absent "${cluster} secret/openshift-cluster-csi-drivers/aws-efs-cloud-credentials" oc get secret aws-efs-cloud-credentials -n openshift-cluster-csi-drivers
  check_openshift_resource_absent "${cluster} subscription/openshift-cluster-csi-drivers/aws-efs-csi-driver-operator" oc get subscription aws-efs-csi-driver-operator -n openshift-cluster-csi-drivers
done

if [ "$failures" -gt 0 ]; then
  echo "Cleanup validation FAIL: ${failures} resource checks still exist." >&2
  exit 1
fi

echo "Cleanup validation PASS."
