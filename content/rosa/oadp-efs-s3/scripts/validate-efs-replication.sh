#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-efs-replication.sh --env-file FILE

Verifies guide-created EFS file systems, mount targets, and replication status
after configure-efs-replication.sh has run.
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

: "${PRIMARY_REGION:?}"
: "${DR_REGION:?}"
: "${PRIMARY_EFS:?}"
: "${DR_EFS:?}"
: "${DR_ENV:?}"

export AWS_PAGER=""

check_file_system() {
  local region="$1"
  local fs="$2"
  local state
  local unavailable_targets

  state=$(aws efs describe-file-systems \
    --region "$region" \
    --file-system-id "$fs" \
    --query 'FileSystems[0].LifeCycleState' \
    --output text)
  printf 'efs/%s region=%s state=%s\n' "$fs" "$region" "$state"
  [ "$state" = "available" ] || { echo "EFS file system ${fs} is not available." >&2; exit 1; }

  aws efs describe-mount-targets \
    --region "$region" \
    --file-system-id "$fs" \
    --query 'MountTargets[].{SubnetId:SubnetId,LifeCycleState:LifeCycleState}' \
    --output table

  unavailable_targets=$(aws efs describe-mount-targets \
    --region "$region" \
    --file-system-id "$fs" \
    --query 'length(MountTargets[?LifeCycleState!=`available`])' \
    --output text)
  [ "$unavailable_targets" = "0" ] || { echo "EFS ${fs} has unavailable mount targets." >&2; exit 1; }
}

check_file_system "$PRIMARY_REGION" "$PRIMARY_EFS"
check_file_system "$DR_REGION" "$DR_EFS"

aws efs describe-replication-configurations \
  --region "$PRIMARY_REGION" \
  --file-system-id "$PRIMARY_EFS" \
  --query 'Replications[0].Destinations[0].{Status:Status,LastReplicatedTimestamp:LastReplicatedTimestamp}' \
  --output table

status=$(aws efs describe-replication-configurations \
  --region "$PRIMARY_REGION" \
  --file-system-id "$PRIMARY_EFS" \
  --query 'Replications[0].Destinations[0].Status' \
  --output text)
[ "$status" = "ENABLED" ] || { echo "EFS replication status is ${status}, not ENABLED." >&2; exit 1; }

duplicates=$(cut -d= -f1 "$DR_ENV" | sort | uniq -d)
[ -z "$duplicates" ] || { printf 'Duplicate dr.env keys:\n%s\n' "$duplicates" >&2; exit 1; }

echo "EFS replication validation PASS."
