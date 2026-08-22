#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: recover-efs-volumes.sh --env-file FILE

Consumes efs-pvc-map.csv, creates one DR EFS access point per original PVC
path while preserving POSIX/root metadata, creates static PV/PVC objects using
${DR_EFS}::${DR_ACCESS_POINT_ID}, and waits for each claim to bind.
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
: "${DR_EFS:?}"
: "${EFS_MAPPING_FILE:?}"
: "${TF_VAR_admin_password:?Source .env.fallback from the repository root before running this script.}"

export AWS_PAGER=""

[ -f "$EFS_MAPPING_FILE" ] || { echo "Mapping file not found: $EFS_MAPPING_FILE" >&2; exit 1; }

login_cluster() {
  local cluster_name="$1"
  local api
  api=$(rosa describe cluster -c "$cluster_name" -o json | jq -r '.api.url')
  oc login "$api" --username admin --password "$TF_VAR_admin_password" >/dev/null
  oc get nodes >/dev/null
}

wait_access_point_available() {
  local access_point_id="$1"
  local state
  for attempt in $(seq 1 60); do
    state=$(aws efs describe-access-points \
      --region "$DR_REGION" \
      --access-point-id "$access_point_id" \
      --query 'AccessPoints[0].LifeCycleState' \
      --output text)
    [ "$state" = "available" ] && return 0
    [ "$state" = "error" ] && { echo "Access point ${access_point_id} entered error state." >&2; return 1; }
    printf '[%s] access-point/%s state=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$access_point_id" "$state"
    sleep 5
  done
  echo "Timed out waiting for access point ${access_point_id}." >&2
  return 1
}

echo "Reconstructing DR EFS access points and static PVCs on ${DR_CLUSTER_NAME}."
login_cluster "$DR_CLUSTER_NAME"

oc create namespace dr-demo --dry-run=client -o yaml | oc apply -f -

{
  read -r header
  while IFS=, read -r namespace pvc pv source_ap_id efs_path posix_uid posix_gid root_owner_uid root_owner_gid root_permissions ordinal requested_storage access_modes; do
    [ -n "${pvc:-}" ] || continue
    : "${namespace:?}"
    : "${source_ap_id:?}"
    : "${efs_path:?}"
    : "${posix_uid:?}"
    : "${posix_gid:?}"
    : "${root_owner_uid:?}"
    : "${root_owner_gid:?}"
    : "${root_permissions:?}"
    : "${requested_storage:?}"
    : "${access_modes:?}"

    static_pv="dr-${pv}"
    access_mode_yaml=$(printf '%s\n' "$access_modes" | tr ';' '\n' | sed 's/^/    - /')

    dr_access_point_id=$(aws efs create-access-point \
      --file-system-id "$DR_EFS" \
      --region "$DR_REGION" \
      --client-token "dr-${source_ap_id}" \
      --posix-user "Uid=${posix_uid},Gid=${posix_gid}" \
      --root-directory "Path=${efs_path},CreationInfo={OwnerUid=${root_owner_uid},OwnerGid=${root_owner_gid},Permissions=${root_permissions}}" \
      --tags "Key=Name,Value=dr-${pvc}" "Key=SourceAccessPoint,Value=${source_ap_id}" "Key=SourcePVC,Value=${namespace}/${pvc}" \
      --query 'AccessPointId' \
      --output text)

    wait_access_point_available "$dr_access_point_id"
    echo "${pvc} -> ${DR_EFS}::${dr_access_point_id} | path=${efs_path}"

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${static_pv}
spec:
  capacity:
    storage: ${requested_storage}
  volumeMode: Filesystem
  accessModes:
${access_mode_yaml}
  persistentVolumeReclaimPolicy: Retain
  storageClassName: efs-sc
  claimRef:
    namespace: ${namespace}
    name: ${pvc}
  csi:
    driver: efs.csi.aws.com
    volumeHandle: "${DR_EFS}::${dr_access_point_id}"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${namespace}
spec:
  accessModes:
${access_mode_yaml}
  resources:
    requests:
      storage: ${requested_storage}
  storageClassName: efs-sc
  volumeName: ${static_pv}
EOF
  done
} < "$EFS_MAPPING_FILE"

{
  read -r header
  while IFS=, read -r namespace pvc rest; do
    [ -n "${pvc:-}" ] || continue
    until [ "$(oc get pvc "$pvc" -n "$namespace" -o jsonpath='{.status.phase}')" = "Bound" ]; do
      echo "Waiting for ${namespace}/${pvc} to bind..."
      sleep 5
    done
    echo "${namespace}/${pvc} is Bound"
  done
} < "$EFS_MAPPING_FILE"

echo "DR EFS static volume recovery completed."
