#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cleanup-iam.sh --env-file FILE

Deletes helper-created IAM roles and customer-managed policies recorded in dr.env.
Attached managed policies and inline role policies are removed before role deletion.
Non-default policy versions are removed before policy deletion.
EOF
}

ENV_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$ENV_FILE" ] || { echo "--env-file is required" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

role_name_from_arn() {
  local arn="${1:-}"
  [ -n "$arn" ] || return 0
  printf '%s\n' "${arn##*/}"
}

env_prefix() {
  printf '%s\n' "$1" | tr '[:lower:]-.' '[:upper:]__'
}

env_value() {
  local key="$1"
  printf '%s\n' "${!key:-}"
}

role_exists() {
  aws iam get-role --role-name "$1" >/dev/null 2>&1
}

policy_exists() {
  aws iam get-policy --policy-arn "$1" >/dev/null 2>&1
}

delete_role_policy_attachment() {
  local role_name="$1"
  local policy_arn="$2"
  [ -n "$role_name" ] && [ -n "$policy_arn" ] || return 0
  role_exists "$role_name" || return 0
  policy_exists "$policy_arn" || return 0
  aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn" >/dev/null 2>&1 || true
}

delete_role() {
  local role_name="$1"
  local policy_name
  local policy_arn
  [ -n "$role_name" ] || return 0
  if ! role_exists "$role_name"; then
    echo "Role $role_name is already absent."
    return
  fi

  for policy_name in $(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name"
  done

  for policy_arn in $(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn"
  done

  aws iam delete-role --role-name "$role_name"
  echo "Deleted role $role_name."
}

delete_policy() {
  local policy_arn="$1"
  local version_id
  [ -n "$policy_arn" ] || return 0
  if ! policy_exists "$policy_arn"; then
    echo "Policy $policy_arn is already absent."
    return
  fi

  for version_id in $(aws iam list-policy-versions \
    --policy-arn "$policy_arn" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
    --output text); do
    aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$version_id"
  done

  aws iam delete-policy --policy-arn "$policy_arn"
  echo "Deleted policy $policy_arn."
}

PRIMARY_PREFIX=$(env_prefix "${PRIMARY_CLUSTER_NAME:?}")
DR_PREFIX=$(env_prefix "${DR_CLUSTER_NAME:?}")

S3_REPLICATION_ROLE_NAME="${S3_REPLICATION_ROLE_NAME:-$(role_name_from_arn "${S3_REPLICATION_ROLE_ARN:-}")}"
OADP_ROLE_NAME_PRIMARY="$(role_name_from_arn "${OADP_ROLE_ARN_PRIMARY:-}")"
OADP_ROLE_NAME_DR="$(role_name_from_arn "${OADP_ROLE_ARN_DR:-}")"
PRIMARY_EFS_CSI_ROLE_ARN="$(env_value "${PRIMARY_PREFIX}_EFS_CSI_ROLE_ARN")"
DR_EFS_CSI_ROLE_ARN="$(env_value "${DR_PREFIX}_EFS_CSI_ROLE_ARN")"
PRIMARY_EFS_CSI_POLICY_ARN="$(env_value "${PRIMARY_PREFIX}_EFS_CSI_POLICY_ARN")"
DR_EFS_CSI_POLICY_ARN="$(env_value "${DR_PREFIX}_EFS_CSI_POLICY_ARN")"
PRIMARY_EFS_CSI_ROLE_NAME="$(env_value "${PRIMARY_PREFIX}_EFS_CSI_ROLE_NAME")"
DR_EFS_CSI_ROLE_NAME="$(env_value "${DR_PREFIX}_EFS_CSI_ROLE_NAME")"
PRIMARY_EFS_CSI_ROLE_NAME="${PRIMARY_EFS_CSI_ROLE_NAME:-$(role_name_from_arn "$PRIMARY_EFS_CSI_ROLE_ARN")}"
DR_EFS_CSI_ROLE_NAME="${DR_EFS_CSI_ROLE_NAME:-$(role_name_from_arn "$DR_EFS_CSI_ROLE_ARN")}"

delete_role_policy_attachment "${APP_S3_ROLE_NAME_PRIMARY:-}" "${APP_S3_POLICY_ARN:-}"
delete_role_policy_attachment "${APP_S3_ROLE_NAME_DR:-}" "${APP_S3_POLICY_ARN:-}"
delete_role "${APP_S3_ROLE_NAME_PRIMARY:-}"
delete_role "${APP_S3_ROLE_NAME_DR:-}"
delete_policy "${APP_S3_POLICY_ARN:-}"

delete_role "$S3_REPLICATION_ROLE_NAME"

delete_role_policy_attachment "$OADP_ROLE_NAME_PRIMARY" "${OADP_POLICY_ARN:-}"
delete_role_policy_attachment "$OADP_ROLE_NAME_DR" "${OADP_POLICY_ARN:-}"
delete_role "$OADP_ROLE_NAME_PRIMARY"
delete_role "$OADP_ROLE_NAME_DR"
delete_policy "${OADP_POLICY_ARN:-}"

delete_role_policy_attachment "$PRIMARY_EFS_CSI_ROLE_NAME" "$PRIMARY_EFS_CSI_POLICY_ARN"
delete_role_policy_attachment "$DR_EFS_CSI_ROLE_NAME" "$DR_EFS_CSI_POLICY_ARN"
delete_role "$PRIMARY_EFS_CSI_ROLE_NAME"
delete_role "$DR_EFS_CSI_ROLE_NAME"
delete_policy "$PRIMARY_EFS_CSI_POLICY_ARN"
delete_policy "$DR_EFS_CSI_POLICY_ARN"
