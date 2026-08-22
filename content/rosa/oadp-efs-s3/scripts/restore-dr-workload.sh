#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: restore-dr-workload.sh --env-file FILE

Creates an OADP Restore from BACKUP_NAME, waits for completion, then applies
DR-specific service-account IAM annotations and S3/region environment values.
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

: "${DR_CLUSTER_NAME:?}"
: "${DR_REGION:?}"
: "${BACKUP_NAME:?}"
: "${APP_BUCKET_DR:?}"
: "${APP_S3_ROLE_ARN_DR:?}"
: "${TF_VAR_admin_password:?Source .env.fallback from the repository root before running this script.}"

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

RESTORE_NAME="dr-restore-$(date +%Y%m%d-%H%M)"
export RESTORE_NAME
upsert_env RESTORE_NAME "$RESTORE_NAME"

echo "Creating OADP Restore ${RESTORE_NAME} on ${DR_CLUSTER_NAME}."
login_cluster "$DR_CLUSTER_NAME"

cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${RESTORE_NAME}
  namespace: openshift-adp
spec:
  backupName: ${BACKUP_NAME}
  includedNamespaces:
    - dr-demo
  excludedResources:
    - pods
    - replicasets.apps
    - persistentvolumes
    - persistentvolumeclaims
  restorePVs: false
  existingResourcePolicy: update
EOF

for attempt in $(seq 1 60); do
  phase=$(oc get restore -n openshift-adp "$RESTORE_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  phase=${phase:-Pending}
  printf '[%s] restore/%s phase=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$RESTORE_NAME" "$phase"
  case "$phase" in
    Completed) break ;;
    Failed|PartiallyFailed)
      oc describe restore -n openshift-adp "$RESTORE_NAME" >&2 || true
      exit 1
      ;;
  esac
  if [ "$attempt" -eq 60 ]; then
    oc describe restore -n openshift-adp "$RESTORE_NAME" >&2 || true
    echo "Timed out waiting for restore ${RESTORE_NAME}." >&2
    exit 1
  fi
  sleep 10
done

echo "Applying DR-specific S3 role and environment values."
oc annotate sa/s3-writer sa/dashboard -n dr-demo \
  eks.amazonaws.com/role-arn="$APP_S3_ROLE_ARN_DR" \
  --overwrite

oc set env deployment/telemetry-transmitter deployment/mission-control -n dr-demo \
  S3_BUCKET="$APP_BUCKET_DR" \
  AWS_REGION="$DR_REGION" \
  CLUSTER_NAME="$DR_CLUSTER_NAME" \
  AWS_ROLE_ARN="$APP_S3_ROLE_ARN_DR"

echo "DR workload restore and configuration completed."
