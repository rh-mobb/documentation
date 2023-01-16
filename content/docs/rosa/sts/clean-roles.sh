#!/bin/bash

set -eox

for role in `find ./iam_assets_apply -name "*-role.json"`
do
  policy=$(sed -e 's/05-/06-/' -e 's/role/policy/' <<< ${role})
  role_name=$(jq -r .RoleName ${role})
  policy_name=$(jq -r .PolicyName ${policy})

  policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='${policy_name}'].Arn" --output text)
  if [[ -n ${policy_arn} ]]; then
   aws iam detach-role-policy --role-name $role_name --policy-arn $policy_arn
   aws iam delete-policy --policy-arn=$policy_arn
  fi
  if aws iam get-role --role-name=$role_name 2> /dev/null > /dev/null; then
    aws iam delete-role --role-name=$role_name
  fi

  sleep 5 # Prevents AWS Rate limiting
done
