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
CCO_POLICY=$(cat openshift_cloud_credential_operator_cloud_credential_operator_iam_ro_creds_policy.json | jq)
REGISTRY_POLICY=$(cat openshift_image_registry_installer_cloud_credentials_policy.json | jq)
INGRESS_POLICY=$(cat openshift_ingress_operator_cloud_credentials_policy.json | jq)
CSI_POLICY=$(cat openshift_cluster_csi_drivers_ebs_cloud_credentials_policy.json | jq)
NETWORK_POLICY=$(cat openshift_cloud_network_config_controller_cloud_credentials_policy.json | jq)
MACHINE_POLICY=$(cat openshift_machine_api_aws_cloud_credentials_policy.json | jq)

simulatePolicy () {
    outputFile="${2}.results"
    echo $2
    aws iam simulate-custom-policy --policy-input-list "$1" --action-names $(jq '.Statement | map(select(.Effect == "Allow"))[].Action | if type == "string" then . else .[] end' "$2" -r) --output text > $outputFile
}

simulatePolicy "$INSTALLER_POLICY" "sts_installer_permission_policy.json"
simulatePolicy "$CONTROL_PLANE_POLICY" "sts_instance_controlplane_permission_policy.json"
simulatePolicy "$WORKER_POLICY" "sts_instance_worker_permission_policy.json"
simulatePolicy "$SUPPORT_POLICY" "sts_support_permission_policy.json"
simulatePolicy "$CCO_POLICY" "openshift_cloud_credential_operator_cloud_credential_operator_iam_ro_creds_policy.json"
simulatePolicy "$REGISTRY_POLICY" "openshift_image_registry_installer_cloud_credentials_policy.json"
simulatePolicy "$INGRESS_POLICY" "openshift_ingress_operator_cloud_credentials_policy.json"
simulatePolicy "$CSI_POLICY" "openshift_cluster_csi_drivers_ebs_cloud_credentials_policy.json"
simulatePolicy "$NETWORK_POLICY" "openshift_cloud_network_config_controller_cloud_credentials_policy.json"
