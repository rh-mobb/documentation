#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-efs-csi.sh --env-file FILE

Creates or updates the EFS StorageClass on both clusters, performs a primary
dynamic PVC smoke test, and removes the smoke-test namespace.
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
: "${PRIMARY_EFS:?}"
: "${DR_EFS:?}"
: "${TF_VAR_admin_password:?Source .env.fallback from the repository root before running this script.}"

login_cluster() {
  local cluster_name="$1"
  local api
  api=$(rosa describe cluster -c "$cluster_name" -o json | jq -r '.api.url')
  oc login "$api" --username admin --password "$TF_VAR_admin_password" >/dev/null
  oc get nodes >/dev/null
}

apply_storageclass() {
  local file_system_id="$1"
  cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
parameters:
  basePath: /dynamic_provisioning
  directoryPerms: "755"
  fileSystemId: ${file_system_id}
  gidRangeEnd: "2000"
  gidRangeStart: "1000"
  provisioningMode: efs-ap
provisioner: efs.csi.aws.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
}

echo "Configuring EFS StorageClass on primary cluster ${PRIMARY_CLUSTER_NAME}."
login_cluster "$PRIMARY_CLUSTER_NAME"
apply_storageclass "$PRIMARY_EFS"

echo "Running primary dynamic PVC smoke test."
oc create namespace efs-smoke --dry-run=client -o yaml | oc apply -f -
cat <<'EOF' | oc apply -n efs-smoke -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efs-smoke
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: efs-sc
  resources:
    requests:
      storage: 1Gi
EOF

oc wait pvc/efs-smoke -n efs-smoke --for=jsonpath='{.status.phase}'=Bound --timeout=300s
oc get pvc -n efs-smoke -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,PV:.spec.volumeName
oc delete namespace efs-smoke --wait=true

echo "Configuring EFS StorageClass on DR cluster ${DR_CLUSTER_NAME}."
login_cluster "$DR_CLUSTER_NAME"
apply_storageclass "$DR_EFS"
oc get storageclass efs-sc

echo "EFS CSI dynamic provisioning validation completed."
