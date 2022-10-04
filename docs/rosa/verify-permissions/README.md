# Verify Permissions for ROSA STS Deployment

**Tyler Stacey**

*Last updated 4 Oct 2022*

To proceed with the deployment of a ROSA cluster, an account must support the required roles and permissions. AWS Service Control Policies (SCPs) cannot block the API calls made by the installer or operator roles.

Details about the IAM resources required for an STS-enabled installation of ROSA can be found here: [https://docs.openshift.com/rosa/rosa_architecture/rosa-sts-about-iam-resources.html](https://docs.openshift.com/rosa/rosa_architecture/rosa-sts-about-iam-resources.html)

This guide is validated for ROSA v4.11.X.

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
- [ROSA CLI](https://github.com/openshift/rosa/releases/tag/v1.2.6) v1.2.6
- [jq CLI](https://stedolan.github.io/jq/)
- [AWS role with required permissions](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_testing-policies.html)

## Verify ROSA Permissions

To verify the permissions required for ROSA we can run the script below without ever creating any AWS resources.

The script uses the `rosa`, `aws`, and `jq` CLI commands to create files in the working directory that will be used to verify permissions in the account connected to the current AWS configuration.

The AWS Policy Simulator is used to verify the permissions of each role policy against the API calls extracted by `jq`; results are then stored in a text file appended with `.results`.

This script will verify the permissions for the current account and region.

```bash
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
```

## Usage Instructions

To use the script, run the following commands in a `bash` terminal (the -p option defines a prefix for the roles):

```bash
mkdir scratch
cd scratch
curl https://raw.githubusercontent.com/rh-mobb/documentation/main/docs/rosa/verify-permissions/verify-permissions.sh --output verify-permissions.sh
chmod +x verify-permissions.sh
./verify-permissions.sh -p SimPolTest
```

After the script completes, review each results file to ensure that none of the required API calls are blocked:

```bash
$ cat sts_support_permission_policy.json.results
EVALUATIONRESULTS	cloudtrail:DescribeTrails	allowed	*
MATCHEDSTATEMENTS	PolicyInputList.1	IAM Policy
ENDPOSITION	6	159
STARTPOSITION	17	3
EVALUATIONRESULTS	cloudtrail:LookupEvents	allowed	*
MATCHEDSTATEMENTS	PolicyInputList.1	IAM Policy
ENDPOSITION	6	159
STARTPOSITION	17	3
EVALUATIONRESULTS	cloudwatch:GetMetricData	allowed	*
MATCHEDSTATEMENTS	PolicyInputList.1	IAM Policy
ENDPOSITION	6	159
STARTPOSITION	17	3
...
```

> If any actions are blocked, review the error provided by AWS and consult with your Administrator to determine if SCPs are blocking the required API calls.


