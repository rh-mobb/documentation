#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-dr-recovery.sh

Validates DR workload readiness, PVC/PV/EFS access-point mapping, old and new
EFS markers, old and new S3 markers, and the route hostname.
EOF
}


while [ $# -gt 0 ]; do
  case "$1" in
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done


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
: "${APP_BUCKET_DR:?}"
: "${EFS_MAPPING_FILE:?}"
: "${VALIDATION_ID:?}"
: "${TF_VAR_admin_password:?Source .env.fallback from the repository root before running this script.}"

export AWS_PAGER=""


login_cluster() {
  local cluster_name="$1"
  local api
  api=$(rosa describe cluster -c "$cluster_name" -o json | jq -r '.api.url')
  oc login "$api" --username admin --password "$TF_VAR_admin_password" >/dev/null
  oc get nodes >/dev/null
}

fail_with_workload_diagnostics() {
  local message="$1"
  echo "$message" >&2
  oc get sts,deploy,pods,pvc -n dr-demo -o wide >&2 || true
  oc get events -n dr-demo --sort-by=.lastTimestamp | tail -n 30 >&2 || true
  exit 1
}

echo "Validating recovered workload on ${DR_CLUSTER_NAME}."
login_cluster "$DR_CLUSTER_NAME"

for attempt in $(seq 1 40); do
  ready_replicas=$(oc get sts flight-recorder -n dr-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  replicas=$(oc get sts flight-recorder -n dr-demo -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  mission_available=$(oc get deployment/mission-control -n dr-demo -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
  telemetry_available=$(oc get deployment/telemetry-transmitter -n dr-demo -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
  printf '[%s] flight-recorder=%s/%s mission-control=%s telemetry-transmitter=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    "${ready_replicas:-0}" "${replicas:-unknown}" "${mission_available:-0}" "${telemetry_available:-0}"

  if [ -n "$replicas" ] &&
    [ "${ready_replicas:-0}" = "$replicas" ] &&
    [ "${mission_available:-0}" -gt 0 ] &&
    [ "${telemetry_available:-0}" -gt 0 ]; then
    break
  fi

  if [ "$attempt" -eq 40 ]; then
    fail_with_workload_diagnostics "Recovered workloads are not ready."
  fi
  sleep 15
done

oc get sts flight-recorder -n dr-demo
oc get pvc -n dr-demo -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,PV:.spec.volumeName

echo "Validating recovered PV handles and DR access-point root paths."
{
  read -r header
  while IFS=, read -r namespace pvc pv source_ap_id efs_path posix_uid posix_gid root_owner_uid root_owner_gid root_permissions ordinal requested_storage access_modes; do
    [ -n "${pvc:-}" ] || continue
    pvc_phase=$(oc get pvc "$pvc" -n "$namespace" -o jsonpath='{.status.phase}')
    if [ "$pvc_phase" != "Bound" ]; then
      fail_with_workload_diagnostics "${namespace}/${pvc} is ${pvc_phase}, not Bound."
    fi
    restored_pv=$(oc get pvc "$pvc" -n "$namespace" -o jsonpath='{.spec.volumeName}')
    handle=$(oc get pv "$restored_pv" -o jsonpath='{.spec.csi.volumeHandle}')
    dr_ap_id=$(printf '%s\n' "$handle" | awk -F'::' '{print $2}')
    if [ -z "$dr_ap_id" ] || [ "$handle" != "$DR_EFS::$dr_ap_id" ]; then
      echo "Unexpected volumeHandle for ${namespace}/${pvc}: ${handle}" >&2
      oc get pv "$restored_pv" -o yaml >&2 || true
      exit 1
    fi

    path_on_ap=$(aws efs describe-access-points \
      --access-point-id "$dr_ap_id" \
      --region "$DR_REGION" \
      --query 'AccessPoints[0].RootDirectory.Path' \
      --output text)
    echo "${pvc} -> ${DR_EFS}::${dr_ap_id} | path=${path_on_ap} | expected=${efs_path}"
    if [ "$path_on_ap" != "$efs_path" ]; then
      echo "DR access-point path mismatch for ${namespace}/${pvc}." >&2
      exit 1
    fi
  done
} < "$EFS_MAPPING_FILE"

echo "Pre-failover EFS marker:"
oc exec -n dr-demo deploy/mission-control -- cat "/shared/validation-${VALIDATION_ID}.txt"

echo "Pre-failover S3 marker:"
aws s3 cp "s3://${APP_BUCKET_DR}/validation/${VALIDATION_ID}.txt" - --region "$DR_REGION"

DR_VALIDATION_ID="dr-$(date +%Y%m%d-%H%M%S)"
export DR_VALIDATION_ID
echo "export DR_VALIDATION_ID=$DR_VALIDATION_ID"

echo "New DR EFS marker:"
oc exec -n dr-demo deploy/mission-control -- \
  sh -c "echo efs-${DR_VALIDATION_ID} > /shared/validation-${DR_VALIDATION_ID}.txt && cat /shared/validation-${DR_VALIDATION_ID}.txt"

echo "New DR S3 marker:"
s3_marker_file=$(mktemp)
trap 'rm -f "$s3_marker_file"' EXIT
printf '%s\n' "s3-${DR_VALIDATION_ID}" > "$s3_marker_file"
aws s3 cp "$s3_marker_file" "s3://${APP_BUCKET_DR}/validation/${DR_VALIDATION_ID}.txt" --region "$DR_REGION" >/dev/null
aws s3 cp "s3://${APP_BUCKET_DR}/validation/${DR_VALIDATION_ID}.txt" - --region "$DR_REGION"

echo "Route hostname:"
oc get route mission-control -n dr-demo -o jsonpath='{.spec.host}{"\n"}'

echo "DR recovery validation completed."
