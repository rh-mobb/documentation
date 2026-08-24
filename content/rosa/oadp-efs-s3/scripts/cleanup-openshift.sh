#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cleanup-openshift.sh

Deletes validation-created OpenShift resources from the current oc context.
Run once while logged in to the primary cluster and once while logged in to the DR cluster.
EOF
}


while [ $# -gt 0 ]; do
  case "$1" in
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

# shellcheck disable=SC1090

oc whoami >/dev/null

oc delete namespace dr-demo --ignore-not-found
oc delete namespace efs-smoke --ignore-not-found

oc delete dpa dr-demo-dpa -n openshift-adp --ignore-not-found
oc delete secret cloud-credentials -n openshift-adp --ignore-not-found
oc delete subscription redhat-oadp-operator -n openshift-adp --ignore-not-found

oc delete clustercsidriver efs.csi.aws.com --ignore-not-found
oc delete secret aws-efs-cloud-credentials -n openshift-cluster-csi-drivers --ignore-not-found
oc delete subscription aws-efs-csi-driver-operator -n openshift-cluster-csi-drivers --ignore-not-found

echo "OpenShift cleanup completed for current context: $(oc config current-context)"
