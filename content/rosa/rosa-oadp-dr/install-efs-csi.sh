#!/bin/bash
#
# Install the AWS EFS CSI Driver Operator on a ROSA HCP cluster.
# Run once per cluster. The script prompts for all required values
# so it works with any ROSA HCP cluster.
#
# Prerequisites:
#   - oc logged in to the target cluster
#   - aws CLI configured with appropriate permissions
#   - rosa CLI authenticated
#
set -euo pipefail

# --- Prompt for required environment variables ---

echo ""
echo "=== AWS EFS CSI Driver Operator Installer ==="
echo ""

read -rp "ROSA cluster name: " CLUSTER_NAME
if [ -z "$CLUSTER_NAME" ]; then
  echo "ERROR: Cluster name is required."
  exit 1
fi

echo ""
echo "Detecting cluster settings..."

REGION=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.region.id')
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ENDPOINT=$(rosa describe cluster -c "$CLUSTER_NAME" -o json \
  | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')

echo ""
echo "  Cluster:        $CLUSTER_NAME"
echo "  Region:         $REGION"
echo "  AWS Account:    $AWS_ACCOUNT_ID"
echo "  OIDC Endpoint:  $OIDC_ENDPOINT"
echo ""
read -rp "Continue with these values? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
  echo "Aborted."
  exit 0
fi

# --- Verify oc is logged into the correct cluster ---

CURRENT_SERVER=$(oc whoami --show-server 2>/dev/null || true)
EXPECTED_API=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r '.api.url')

if [ "$CURRENT_SERVER" != "$EXPECTED_API" ]; then
  echo ""
  echo "WARNING: oc is logged into $CURRENT_SERVER"
  echo "         but cluster $CLUSTER_NAME API is $EXPECTED_API"
  echo ""
  read -rp "Continue anyway? (y/n): " OC_CONFIRM
  if [[ ! "$OC_CONFIRM" =~ ^[Yy] ]]; then
    echo "Log in to the correct cluster first: oc login $EXPECTED_API"
    exit 1
  fi
fi

# --- Step 1: Create the IAM role for the EFS CSI driver operator ---

ROLE_NAME="${CLUSTER_NAME}-aws-efs-csi-operator"

cat <<EOF > /tmp/efs-csi-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ENDPOINT}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_ENDPOINT}:sub": [
            "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-operator",
            "system:serviceaccount:openshift-cluster-csi-drivers:aws-efs-csi-driver-controller-sa"
          ]
        }
      }
    }
  ]
}
EOF

echo ""
echo "Step 1/5: Creating IAM role: $ROLE_NAME"
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "  Role already exists, updating trust policy..."
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document file:///tmp/efs-csi-trust-policy.json
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file:///tmp/efs-csi-trust-policy.json \
    --query 'Role.Arn' --output text
fi

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
echo "  Role ARN: $ROLE_ARN"

# --- Step 2: Install the AWS EFS CSI Driver Operator ---

echo ""
echo "Step 2/5: Installing AWS EFS CSI Driver Operator..."

oc create namespace openshift-cluster-csi-drivers 2>/dev/null || true

cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cluster-csi-drivers
  namespace: openshift-cluster-csi-drivers
spec: {}
EOF

cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: aws-efs-csi-driver-operator
  namespace: openshift-cluster-csi-drivers
spec:
  channel: stable
  installPlanApproval: Automatic
  name: aws-efs-csi-driver-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "  Waiting for operator to install..."
for i in $(seq 1 60); do
  CSV_STATUS=$(oc get csv -n openshift-cluster-csi-drivers \
    -o jsonpath='{.items[?(@.spec.displayName=="AWS EFS CSI Driver Operator")].status.phase}' 2>/dev/null || true)
  if [ "$CSV_STATUS" = "Succeeded" ]; then
    echo "  Operator installed successfully."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "  WARNING: Timed out waiting for operator. Check: oc get csv -n openshift-cluster-csi-drivers"
    break
  fi
  sleep 10
done

# --- Step 3: Create the cloud credentials secret ---

echo ""
echo "Step 3/6: Creating aws-efs-cloud-credentials secret..."

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aws-efs-cloud-credentials
  namespace: openshift-cluster-csi-drivers
stringData:
  credentials: |
    [default]
    role_arn = ${ROLE_ARN}
    web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
EOF

echo "  Secret created."

# --- Step 4: Create the ClusterCSIDriver ---

echo ""
echo "Step 4/6: Creating ClusterCSIDriver..."

cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: efs.csi.aws.com
spec:
  managementState: Managed
EOF

echo "  Waiting for EFS CSI driver pods..."
for i in $(seq 1 60); do
  READY=$(oc get deployment aws-efs-csi-driver-controller \
    -n openshift-cluster-csi-drivers \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "$READY" -ge 1 ] 2>/dev/null; then
    echo "  EFS CSI driver controller is running ($READY replicas)."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "  WARNING: Timed out waiting for CSI driver. Check: oc get pods -n openshift-cluster-csi-drivers"
    break
  fi
  sleep 10
done

# --- Step 4: Find the worker IAM role name ---

echo ""
echo "Step 5/6: Finding worker IAM role..."

INSTANCE_PROFILE_ARN=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*worker*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text 2>/dev/null || echo "None")

WORKER_ROLE=""
if [ "$INSTANCE_PROFILE_ARN" != "None" ] && [ -n "$INSTANCE_PROFILE_ARN" ]; then
  INSTANCE_PROFILE_NAME=$(echo "$INSTANCE_PROFILE_ARN" | sed 's|.*instance-profile/||')
  WORKER_ROLE=$(aws iam get-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || echo "")
fi

if [ -z "$WORKER_ROLE" ] || [ "$WORKER_ROLE" = "None" ]; then
  echo "  Could not auto-detect worker IAM role."
  read -rp "  Enter the worker IAM role name manually: " WORKER_ROLE
  if [ -z "$WORKER_ROLE" ]; then
    echo "ERROR: Worker role name is required."
    exit 1
  fi
fi

echo "  Worker role: $WORKER_ROLE"

# --- Step 5: Attach EFS permissions to the worker role ---

echo ""
echo "Step 6/6: Attaching AmazonEFSCSIDriverPolicy to worker role..."

aws iam attach-role-policy \
  --role-name "$WORKER_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy

echo "  Done."

# --- Summary ---

echo ""
echo "============================================="
echo "  EFS CSI Driver Operator - Install Complete"
echo "============================================="
echo ""
echo "  Cluster:      $CLUSTER_NAME"
echo "  Region:       $REGION"
echo "  CSI Role:     $ROLE_ARN"
echo "  Worker Role:  $WORKER_ROLE"
echo ""
echo "  Next: Continue with the DR guide to create"
echo "  EFS file systems, security groups, and"
echo "  mount targets."
echo ""
