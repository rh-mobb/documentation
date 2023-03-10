#!/bin/bash

while getopts 'p:' OPTION; do
  case "$OPTION" in
    p)
      PREFIX="$OPTARG"
      ;;
    ?)
      echo "script usage: $(basename \$0) [-p PREFIX]" >&2
      exit 1
      ;;
  esac
done
shift "$(($OPTIND -1))"

rosa create account-roles --mode manual --prefix $PREFIX

INSTALLER_POLICY=$(cat sts_installer_permission_policy.json | jq )
CONTROL_PLANE_POLICY=$(cat sts_instance_controlplane_permission_policy.json | jq)
WORKER_POLICY=$(cat sts_instance_worker_permission_policy.json | jq)
SUPPORT_POLICY=$(cat sts_support_permission_policy.json | jq)

simulatePolicy () {
    outputFile="${2}.results"
    echo $2
    aws iam simulate-custom-policy --policy-input-list "$1" --action-names $(jq '.Statement | map(select(.Effect == "Allow"))[].Action | if type == "string" then . else .[] end' "$2" -r) --output text > $outputFile
}

simulatePolicy "$INSTALLER_POLICY" "sts_installer_permission_policy.json"
simulatePolicy "$CONTROL_PLANE_POLICY" "sts_instance_controlplane_permission_policy.json"
simulatePolicy "$WORKER_POLICY" "sts_instance_worker_permission_policy.json"
simulatePolicy "$SUPPORT_POLICY" "sts_support_permission_policy.json"
