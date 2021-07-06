#!/bin/bash

set -eox

for role in `find ./iam_assets -name "*-role.json"`
do
  policy=$(sed -e 's/05-/06-/' -e 's/role/policy/' <<< ${role})
  role_name=$(grep RoleName ${policy} | awk '{print $2}' | awk -F '"' '{print $2}')
  policy_name=$(grep PolicyName ${policy} | awk '{print $2}' | awk -F '"' '{print $2}')

  aws iam get-role --role-name=$role_name 2> /dev/null > /dev/null || \
    aws iam create-role --cli-input-json file://${role}
  cat ${policy} | sed '/RoleName/d' > ${policy}.apply
  policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='${policy_name}'].Arn" --output text)
  if [[ -z ${policy_arn} ]]; then
    policy_arn=$(aws iam create-policy --output json --cli-input-json file://$policy.apply | grep Arn | awk '{print $2}' | awk -F '"' '{print $2}')
  fi
  aws iam attach-role-policy --role-name $role_name --policy-arn $policy_arn

  sleep 5

done
