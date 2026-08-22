#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: record-efs-mapping.sh --namespace NAMESPACE --region REGION --output FILE

Records PVC -> PV -> EFS access point metadata for EFS CSI PVCs.
Run this while the primary cluster API is available.
EOF
}

NAMESPACE=""
REGION=""
OUTPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$NAMESPACE" ] || { echo "--namespace is required" >&2; exit 1; }
[ -n "$REGION" ] || { echo "--region is required" >&2; exit 1; }
[ -n "$OUTPUT" ] || { echo "--output is required" >&2; exit 1; }

echo "namespace,pvc,pv,source_access_point_id,efs_path,posix_uid,posix_gid,root_owner_uid,root_owner_gid,root_permissions,statefulset_ordinal,requested_storage,access_modes" > "$OUTPUT"

for pvc in $(oc get pvc -n "$NAMESPACE" -o json | jq -r '.items[].metadata.name'); do
  pv=$(oc get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
  [ -n "$pv" ] || continue

  driver=$(oc get pv "$pv" -o jsonpath='{.spec.csi.driver}' 2>/dev/null || true)
  [ "$driver" = "efs.csi.aws.com" ] || continue

  handle=$(oc get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}')
  access_point_id=$(echo "$handle" | awk -F'::' '{print $2}')
  [ -n "$access_point_id" ] || continue

  access_point_json=$(aws efs describe-access-points \
    --access-point-id "$access_point_id" \
    --region "$REGION" \
    --output json)

  efs_path=$(echo "$access_point_json" | jq -r '.AccessPoints[0].RootDirectory.Path // empty')
  posix_uid=$(echo "$access_point_json" | jq -r '.AccessPoints[0].PosixUser.Uid // empty')
  posix_gid=$(echo "$access_point_json" | jq -r '.AccessPoints[0].PosixUser.Gid // empty')
  root_owner_uid=$(echo "$access_point_json" | jq -r '.AccessPoints[0].RootDirectory.CreationInfo.OwnerUid // empty')
  root_owner_gid=$(echo "$access_point_json" | jq -r '.AccessPoints[0].RootDirectory.CreationInfo.OwnerGid // empty')
  root_permissions=$(echo "$access_point_json" | jq -r '.AccessPoints[0].RootDirectory.CreationInfo.Permissions // empty')

  [ -n "$efs_path" ] || { echo "Access point $access_point_id has no root path" >&2; exit 1; }
  [ -n "$posix_uid" ] || { echo "Access point $access_point_id has no PosixUser.Uid" >&2; exit 1; }
  [ -n "$posix_gid" ] || { echo "Access point $access_point_id has no PosixUser.Gid" >&2; exit 1; }
  [ -n "$root_owner_uid" ] || { echo "Access point $access_point_id has no root CreationInfo.OwnerUid" >&2; exit 1; }
  [ -n "$root_owner_gid" ] || { echo "Access point $access_point_id has no root CreationInfo.OwnerGid" >&2; exit 1; }
  [ -n "$root_permissions" ] || { echo "Access point $access_point_id has no root CreationInfo.Permissions" >&2; exit 1; }

  ordinal=""
  if echo "$pvc" | grep -Eq -- '-[0-9]+$'; then
    ordinal=$(echo "$pvc" | sed -E 's/^.*-([0-9]+)$/\1/')
  fi

  requested_storage=$(oc get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')
  access_modes=$(oc get pvc "$pvc" -n "$NAMESPACE" -o json | jq -r '.spec.accessModes | join(";")')

  echo "$NAMESPACE,$pvc,$pv,$access_point_id,$efs_path,$posix_uid,$posix_gid,$root_owner_uid,$root_owner_gid,$root_permissions,$ordinal,$requested_storage,$access_modes" >> "$OUTPUT"
done

echo "Wrote EFS PVC mapping to $OUTPUT"
