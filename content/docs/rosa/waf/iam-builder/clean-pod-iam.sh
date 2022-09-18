#!/bin/bash

set -x
set -e

echo "Patching OpenShift Cluster Authentication"
oc patch authentication.config.openshift.io cluster --type "json" \
    -p="[{\"op\": \"remove\", \"path\": \"/spec/serviceAccountIssuer\"}]" || echo "already done"

echo "Deleting IAM Policy"
policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].{ARN:Arn}" --output text)

if [ "${policy_arn}" != "" ]; then

  aws iam detach-role-policy --role-name AWSLoadBalancerControllerIAMRole --policy-arn=${policy_arn} > /dev/null

  policy_versions=$(aws iam list-policy-versions --policy-arn=${policy_arn} --query "Versions[] | length(@)")
  while [ $policy_versions -gt 1 ]; do
    oldest_policy_version=$(aws iam list-policy-versions --policy-arn=${policy_arn} --query "Versions[-1].VersionId" | jq -r)

    echo "Deleting Oldest Policy Version: ${oldest_policy_version}"
    aws iam delete-policy-version --policy-arn=${policy_arn} --version-id=${oldest_policy_version} > /dev/null
    policy_versions=$(aws iam list-policy-versions --policy-arn=${policy_arn} --query "Versions[] | length(@)")
  done

  # policy_versions=$(aws iam list-policy-versions --policy-arn=${policy_arn} --query "Versions[] | length(@)")
  # echo $policy_versions
  # exit 0
  aws iam delete-policy \
        --policy-arn=$policy_arn > /dev/null
fi


role_arn=$(aws iam list-roles --query "Roles[?RoleName=='AWSLoadBalancerControllerIAMRole'].{ARN:Arn}" --out text)

echo "Deleting IAM Role"
if [ "${role_arn}" != "" ]; then
  aws iam delete-role --role-name=AWSLoadBalancerControllerIAMRole > /dev/null
fi
