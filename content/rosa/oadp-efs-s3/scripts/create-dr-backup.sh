#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create-dr-backup.sh --env-file FILE [--sync-to-dr-for-validation]

Creates an OADP Backup for dr-demo, persists BACKUP_NAME in dr.env, waits for
the backup to complete, waits for the exact backup object prefix to replicate
to the DR bucket, and verifies the exact backup name appears on the DR cluster.

Use --sync-to-dr-for-validation only for deterministic validation runs where
you intentionally do not want to wait for S3 CRR timing.
EOF
}

ENV_FILE="./dr.env"
SYNC_TO_DR_FOR_VALIDATION=false

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --sync-to-dr-for-validation) SYNC_TO_DR_FOR_VALIDATION=true; shift ;;
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
: "${OADP_BUCKET_PRIMARY:?}"
: "${OADP_BUCKET_DR:?}"
: "${TF_VAR_admin_password:?Source .env.fallback from the repository root before running this script.}"

export AWS_PAGER=""

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

login_cluster() {
  local cluster_name="$1"
  local api
  api=$(rosa describe cluster -c "$cluster_name" -o json | jq -r '.api.url')
  oc login "$api" --username admin --password "$TF_VAR_admin_password" >/dev/null
  oc get nodes >/dev/null
}

BACKUP_NAME="dr-demo-$(date +%Y%m%d-%H%M)"
export BACKUP_NAME
upsert_env BACKUP_NAME "$BACKUP_NAME"

echo "Creating OADP Backup ${BACKUP_NAME} on ${PRIMARY_CLUSTER_NAME}."
login_cluster "$PRIMARY_CLUSTER_NAME"

cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: openshift-adp
spec:
  includedNamespaces:
    - dr-demo
  excludedResources:
    - pods
    - replicasets.apps
    - persistentvolumes
    - persistentvolumeclaims
  storageLocation: dr-demo-dpa-1
  defaultVolumesToFsBackup: false
  snapshotVolumes: false
EOF

for attempt in $(seq 1 60); do
  phase=$(oc get backup -n openshift-adp "$BACKUP_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  phase=${phase:-Pending}
  printf '[%s] backup/%s phase=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$BACKUP_NAME" "$phase"
  case "$phase" in
    Completed) break ;;
    Failed|PartiallyFailed)
      oc describe backup -n openshift-adp "$BACKUP_NAME" >&2 || true
      exit 1
      ;;
  esac
  if [ "$attempt" -eq 60 ]; then
    oc describe backup -n openshift-adp "$BACKUP_NAME" >&2 || true
    echo "Timed out waiting for backup ${BACKUP_NAME}." >&2
    exit 1
  fi
  sleep 10
done

aws s3 ls "s3://${OADP_BUCKET_PRIMARY}/velero/backups/${BACKUP_NAME}/" --region "$PRIMARY_REGION"

if [ "$SYNC_TO_DR_FOR_VALIDATION" = "true" ]; then
  echo "Validation-only: copying exact backup prefix to DR object bucket."
  aws s3 sync "s3://${OADP_BUCKET_PRIMARY}/velero/backups/${BACKUP_NAME}/" \
    "s3://${OADP_BUCKET_DR}/velero/backups/${BACKUP_NAME}/" \
    --source-region "$PRIMARY_REGION" \
    --region "$DR_REGION"
else
  echo "Waiting for backup prefix to replicate to DR object bucket."
  for attempt in $(seq 1 90); do
    listing=$(aws s3 ls "s3://${OADP_BUCKET_DR}/velero/backups/${BACKUP_NAME}/" --region "$DR_REGION" 2>/dev/null || true)
    if [ -n "$listing" ]; then
      printf '%s\n' "$listing"
      break
    fi
    printf '[%s] waiting for S3 CRR of backup prefix %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$BACKUP_NAME"
    if [ "$attempt" -eq 90 ]; then
      echo "Timed out waiting for backup prefix ${BACKUP_NAME} to replicate to DR bucket." >&2
      exit 1
    fi
    sleep 20
  done
fi

echo "Waiting for backup ${BACKUP_NAME} to appear on ${DR_CLUSTER_NAME}."
login_cluster "$DR_CLUSTER_NAME"
for attempt in $(seq 1 30); do
  if oc get backup -n openshift-adp "$BACKUP_NAME" >/dev/null 2>&1; then
    oc get backup -n openshift-adp "$BACKUP_NAME"
    exit 0
  fi
  printf '[%s] backup/%s not visible on DR yet\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$BACKUP_NAME"
  sleep 10
done

echo "Timed out waiting for backup ${BACKUP_NAME} to appear on DR." >&2
exit 1
