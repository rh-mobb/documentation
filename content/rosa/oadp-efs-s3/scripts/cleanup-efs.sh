#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cleanup-efs.sh --env-file FILE

Deletes EFS resources recorded in dr.env in this order:
replication, access points, mount targets with wait, file systems, security groups.
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

: "${PRIMARY_REGION:?}"
: "${DR_REGION:?}"
: "${PRIMARY_EFS:?}"
: "${DR_EFS:?}"
: "${EFS_SG_PRIMARY:?}"
: "${EFS_SG_DR:?}"

timestamp() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

efs_exists() {
  aws efs describe-file-systems \
    --file-system-id "$1" \
    --region "$2" >/dev/null 2>&1
}

delete_replication_if_present() {
  if aws efs describe-replication-configurations \
    --file-system-id "$PRIMARY_EFS" \
    --region "$PRIMARY_REGION" \
    --query 'Replications[0].SourceFileSystemId' \
    --output text 2>/dev/null | grep -qv '^None$'; then
    aws efs delete-replication-configuration \
      --source-file-system-id "$PRIMARY_EFS" \
      --region "$PRIMARY_REGION" >/dev/null
    echo "Deleted EFS replication for $PRIMARY_EFS."
  else
    echo "EFS replication is already absent."
  fi
}

wait_replication_absent() {
  local fs="$1"
  local region="$2"
  local replications

  for attempt in $(seq 1 60); do
    replications=$(aws efs describe-replication-configurations \
      --file-system-id "$fs" \
      --region "$region" \
      --query 'length(Replications)' \
      --output text 2>/dev/null || echo 0)
    printf '[%s] efs/%s replications=%s\n' "$(timestamp)" "$fs" "$replications"
    [ "$replications" = "0" ] && return
    sleep 10
  done

  echo "Timed out waiting for EFS replication to clear on $fs." >&2
  return 1
}

delete_efs_tree() {
  local fs="$1"
  local region="$2"
  local ap
  local mt
  local mt_count

  if ! efs_exists "$fs" "$region"; then
    echo "EFS file system $fs is already absent."
    return
  fi

  wait_replication_absent "$fs" "$region"

  for ap in $(aws efs describe-access-points \
    --file-system-id "$fs" \
    --region "$region" \
    --query 'AccessPoints[].AccessPointId' \
    --output text); do
    aws efs delete-access-point --access-point-id "$ap" --region "$region"
    echo "Deleted access point $ap."
  done

  for mt in $(aws efs describe-mount-targets \
    --file-system-id "$fs" \
    --region "$region" \
    --query 'MountTargets[].MountTargetId' \
    --output text); do
    aws efs delete-mount-target --mount-target-id "$mt" --region "$region"
    echo "Requested deletion of mount target $mt."
  done

  for attempt in $(seq 1 60); do
    mt_count=$(aws efs describe-mount-targets \
      --file-system-id "$fs" \
      --region "$region" \
      --query 'length(MountTargets)' \
      --output text)
    printf '[%s] efs/%s mount-targets=%s\n' "$(timestamp)" "$fs" "$mt_count"
    [ "$mt_count" = "0" ] && break
    [ "$attempt" -lt 60 ] || {
      echo "Timed out waiting for EFS mount targets to delete on $fs." >&2
      return 1
    }
    sleep 5
  done

  aws efs delete-file-system --file-system-id "$fs" --region "$region"
  echo "Deleted file system $fs."
}

delete_security_group() {
  local sg="$1"
  local region="$2"
  local err
  err=$(mktemp)
  if aws ec2 delete-security-group --group-id "$sg" --region "$region" 2>"$err"; then
    rm -f "$err"
    echo "Deleted security group $sg."
    return
  fi

  if grep -q 'InvalidGroup.NotFound' "$err"; then
    rm -f "$err"
    echo "Security group $sg is already absent."
    return
  fi

  cat "$err" >&2
  rm -f "$err"
  return 1
}

delete_replication_if_present
delete_efs_tree "$PRIMARY_EFS" "$PRIMARY_REGION"
delete_efs_tree "$DR_EFS" "$DR_REGION"
delete_security_group "$EFS_SG_PRIMARY" "$PRIMARY_REGION"
delete_security_group "$EFS_SG_DR" "$DR_REGION"
