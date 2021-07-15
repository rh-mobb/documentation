#!/bin/bash

set -eox

aws iam create-role \
--role-name ROSA-${ROSA_CLUSTER_NAME}-install \
  --assume-role-policy-document \
  file://roles/ManagedOpenShift_IAM_Role.json

aws iam put-role-policy \
  --role-name ROSA-${ROSA_CLUSTER_NAME}-install \
  --policy-name ROSA-${ROSA_CLUSTER_NAME}-install \
  --policy-document \
  file://roles/ManagedOpenShift_IAM_Role_Policy.json

aws iam create-role \
  --role-name ROSA-${ROSA_CLUSTER_NAME}-control \
  --assume-role-policy-document \
  file://roles/ManagedOpenShift_ControlPlane_Role.json

aws iam put-role-policy \
  --role-name ROSA-${ROSA_CLUSTER_NAME}-control \
  --policy-name ROSA-${ROSA_CLUSTER_NAME}-control \
  --policy-document \
  file://roles/ManagedOpenShift_ControlPlane_Role_Policy.json

aws iam create-role \
  --role-name ROSA-${ROSA_CLUSTER_NAME}-worker \
  --assume-role-policy-document \
  file://roles/ManagedOpenShift_Worker_Role.json

aws iam put-role-policy \
  --role-name ROSA-${ROSA_CLUSTER_NAME}-worker \
  --policy-name ROSA-${ROSA_CLUSTER_NAME}-worker \
  --policy-document \
  file://roles/ManagedOpenShift_Worker_Role_Policy.json

aws iam create-role \
  --role-name ROSA-${ROSA_CLUSTER_NAME}-support \
  --assume-role-policy-document file://roles/RH_Support_Role.json

aws iam create-policy \
  --policy-name ROSA-${ROSA_CLUSTER_NAME}-support \
  --policy-document file://roles/RH_Support_Policy.json

policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='ROSA-${ROSA_CLUSTER_NAME}-support'].Arn" --output text)

aws iam attach-role-policy \
  --role-name ROSA-${ROSA_CLUSTER_NAME}-support \
  --policy-arn $policy_arn