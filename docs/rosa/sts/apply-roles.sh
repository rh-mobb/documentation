#!/bin/bash

set -eox

if ! jq -h > /dev/null; then
    echo "jq is not installed. Please install it before running this script."
    exit 1
fi

for role in `find ./iam_assets_apply -name "*-role.json"`
do
  policy=$(sed -e 's/role/policy/' <<< ${role})
  role_name=$(jq -r .RoleName ${role})
  policy_name=$(jq -r .PolicyName ${policy})

  aws iam get-role --role-name=$role_name 2> /dev/null > /dev/null || \
    aws iam create-role --cli-input-json file://${role}

  policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='${policy_name}'].Arn" --output text)
  if [[ -z ${policy_arn} ]]; then
    policy_arn=$(aws iam create-policy --output json --cli-input-json file://$policy | grep Arn | awk '{print $2}' | awk -F '"' '{print $2}')
  fi
  aws iam attach-role-policy --role-name $role_name --policy-arn $policy_arn

  sleep 5

done
