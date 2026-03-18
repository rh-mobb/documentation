---
date: '2026-03-18'
title: Deploying ROSA HCP in a Shared VPC Pattern
tags: ["AWS", "ROSA", "HCP", "Shared VPC", "PrivateLink"]
authors:
  - Nerav Doshi
---

Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Planes (HCP) supports a **shared VPC** deployment pattern where the cluster's networking infrastructure (VPC, subnets, Route 53 hosted zones) lives in a centralized networking account while the ROSA cluster is owned by a separate workload account. This pattern is common in enterprises that use a hub-and-spoke networking model with AWS Organizations.

This tutorial walks through deploying a private ROSA HCP cluster in a shared VPC using the `rosa` and `aws` CLI tools, including customer-managed KMS encryption for etcd and node volumes.

> **Note:** A [Terraform automation](#terraform-automation-optional) is available as an alternative to the manual CLI steps. See the appendix at the end of this tutorial.

## Architecture

The shared VPC pattern separates infrastructure ownership across two AWS accounts:
 - Shared VPC Account (VPC Owner / Networking)
     - VPC, Subnet, NAT Gateway, Internet Gateway
 - Cluster Account (Cluster Creator / Workload)
 - Red Hat SRE (Managed)
     - HCP Control Plane: runs in Red Hat AWS account
     - PrivateLink VPC Endpoint: connects to worker VPC 


**Key design points:**

- The HCP control plane runs in a Red Hat-managed AWS account and connects to the worker nodes via a PrivateLink VPC endpoint created in the shared VPC.
- Route 53 private hosted zones in the shared VPC account handle DNS for both internal HCP communication and application ingress.
- Cross-account access is mediated through IAM roles with explicit trust policies — no VPC peering or Transit Gateway required.
- A customer-managed KMS key in the cluster account encrypts both etcd and EBS volumes.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| AWS CLI | v2 | AWS resource management |
| `rosa` CLI | >= 1.2.49 | ROSA role, OIDC, and cluster creation |
| `oc` CLI | latest | Cluster access (post-install) |
| `jq` | latest | JSON parsing |
| RHCS token | — | [Get token here](https://console.redhat.com/openshift/token) |

**AWS requirements:**

- Two AWS accounts in the same AWS Organization (or a single account for testing):
  - **VPC Owner account:** owns the VPC, subnets, Route 53 zones, and shared VPC IAM roles
  - **Cluster Creator account:** owns the ROSA subscription, account roles, operator roles, and KMS key
- AWS CLI profiles configured for both accounts
- [Resource sharing enabled](https://docs.aws.amazon.com/ram/latest/userguide/getting-started-sharing.html#getting-started-sharing-orgs) from the management account for your organization
- Sufficient quotas: at least 3 `m5.xlarge` instances, 1 Elastic IP, 1 NAT Gateway, 2 Route 53 hosted zones
- OpenShift version 4.17.9 or later

> **Tip:** For testing, both accounts can be the same AWS account. The tutorial indicates where you can skip cross-account steps in that scenario.

## IAM Roles and Policies Reference

Before starting, review the full set of IAM roles required by the shared VPC pattern.

### Shared VPC Account Roles

These roles are created in the VPC Owner account and assumed by ROSA components from the Cluster Creator account.

#### 1. Route 53 Role — `<cluster>-route53-role`

Allows ROSA to manage DNS records in the shared VPC's private hosted zones.

**Trust policy** (final, after Step 9):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::<CLUSTER_ACCOUNT_ID>:role/<PREFIX>-HCP-ROSA-Installer-Role",
          "arn:aws:iam::<CLUSTER_ACCOUNT_ID>:role/<PREFIX>-openshift-ingress-operator-cloud-credentials",
          "arn:aws:iam::<CLUSTER_ACCOUNT_ID>:role/<PREFIX>-kube-system-control-plane-operator"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Permissions policy:** AWS managed [`ROSASharedVPCRoute53Policy`](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/ROSASharedVPCRoute53Policy.html)

| Action | Scope |
|--------|-------|
| `route53:ChangeResourceRecordSets` | Restricted to `*.hypershift.local` and `*.openshiftapps.com` patterns |
| `route53:GetHostedZone` | All hosted zones |
| `route53:ListHostedZones` | All |
| `route53:ListResourceRecordSets` | All |
| `route53:ChangeTagsForResource` | Hosted zones |
| `tag:GetResources` | All |

**Assumed by:**

| Principal | Purpose |
|-----------|---------|
| Installer Role | Initial DNS setup during cluster creation |
| ingress-operator | Ongoing DNS record management for app routes |
| control-plane-operator | DNS management for HCP internal communication |

#### 2. VPC Endpoint Role — `<cluster>-vpc-endpoint-role`

Allows ROSA to create and manage PrivateLink VPC endpoints for the HCP control plane.

**Trust policy** (final, after Step 9):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::<CLUSTER_ACCOUNT_ID>:role/<PREFIX>-HCP-ROSA-Installer-Role",
          "arn:aws:iam::<CLUSTER_ACCOUNT_ID>:role/<PREFIX>-kube-system-control-plane-operator"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Permissions policy:** AWS managed [`ROSASharedVPCEndpointPolicy`](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/ROSASharedVPCEndpointPolicy.html)

| Action | Scope |
|--------|-------|
| `ec2:CreateVpcEndpoint` | With `red-hat-managed` tag condition |
| `ec2:ModifyVpcEndpoint`, `ec2:DeleteVpcEndpoints` | With `red-hat-managed` tag condition |
| `ec2:CreateSecurityGroup`, `ec2:DeleteSecurityGroup` | With `red-hat-managed` tag condition |
| `ec2:AuthorizeSecurityGroupIngress/Egress` | With `red-hat-managed` tag condition |
| `ec2:CreateTags` | Restricted to `CreateVpcEndpoint` and `CreateSecurityGroup` actions |

**Assumed by:**

| Principal | Purpose |
|-----------|---------|
| Installer Role | Initial VPC endpoint creation |
| control-plane-operator | Ongoing VPC endpoint lifecycle management |

### Cluster Account Roles (rosa CLI)

**Account roles** — created by `rosa create account-roles --hosted-cp`:

| Role | Purpose |
|------|---------|
| `<PREFIX>-HCP-ROSA-Installer-Role` | Cluster installation and initial setup |
| `<PREFIX>-HCP-ROSA-Support-Role` | Red Hat SRE support access |
| `<PREFIX>-HCP-ROSA-Worker-Role` | Worker node instance profile |

**Operator roles** — created by `rosa create operator-roles --hosted-cp`:

| Role | Namespace | Purpose |
|------|-----------|---------|
| `<PREFIX>-kube-system-capa-controller-manager` | kube-system | Cluster API AWS controller |
| `<PREFIX>-kube-system-control-plane-operator` | kube-system | HCP control plane management |
| `<PREFIX>-kube-system-kms-provider` | kube-system | KMS encryption for etcd |
| `<PREFIX>-kube-system-kube-controller-manager` | kube-system | Kubernetes controller manager |
| `<PREFIX>-openshift-cloud-network-config-controller-cloud-credential` | openshift-cloud-network-config-controller | Cloud network config |
| `<PREFIX>-openshift-cluster-csi-drivers-ebs-cloud-credentials` | openshift-cluster-csi-drivers | EBS CSI driver |
| `<PREFIX>-openshift-image-registry-installer-cloud-credentials` | openshift-image-registry | Image registry S3 backend |
| `<PREFIX>-openshift-ingress-operator-cloud-credentials` | openshift-ingress-operator | Ingress DNS management |

> When you pass `--route53-role-arn` and `--vpc-endpoint-role-arn` to the `rosa create account-roles` and `rosa create operator-roles` commands, the CLI automatically configures the operator roles with `sts:AssumeRole` inline policies for the shared VPC roles.

### KMS Key Policy

The customer-managed KMS key policy grants each ROSA operator only the minimum permissions required:

| Principal | KMS Actions |
|-----------|-------------|
| Account root | `kms:*` (administrative) |
| Installer Role | `CreateGrant`, `DescribeKey`, `GenerateDataKeyWithoutPlaintext` |
| Support Role | `DescribeKey` |
| Kube Controller Manager | `DescribeKey` |
| KMS Provider (etcd) | `Encrypt`, `Decrypt`, `DescribeKey` |
| CAPA Controller Manager | `DescribeKey`, `GenerateDataKeyWithoutPlaintext`, `CreateGrant` |
| EBS CSI Driver | `Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey` |
| EBS CSI Driver (grants) | `CreateGrant`, `RevokeGrant`, `ListGrants` (condition: `kms:GrantIsForAWSResource`) |

### Route 53 Hosted Zone Naming

ROSA HCP validates that hosted zone names match specific patterns. Incorrect naming causes cluster creation to fail.

| Zone | Name Pattern | Example |
|------|-------------|---------|
| HCP internal | `<cluster_name>.hypershift.local` | `mycluster.hypershift.local` |
| Ingress | `rosa.<cluster_name>.<base_dns_domain>` | `rosa.mycluster.abcd.p3.openshiftapps.com` |

> **Important:** The `base_dns_domain` must be reserved under `p3.openshiftapps.com` (the HCP architecture parent) via `rosa create dns-domain --hosted-cp`. Classic ROSA domains (`p1`) or custom domains are not compatible.

---

## Step-by-Step Deployment

### Step 1: Set Environment Variables

Set these variables in your terminal. They are referenced throughout the tutorial.

```bash
export CLUSTER_NAME="mycluster"
export REGION="us-east-1"

export VPC_OWNER_ACCOUNT_ID="222222222222"     # Shared VPC / Networking account
export CLUSTER_CREATOR_ACCOUNT_ID="111111111111" # Workload account

export ROLES_PREFIX="${CLUSTER_NAME}"
export VPC_CIDR="10.0.0.0/16"

export RHCS_TOKEN="<your-ocm-token>"  # From https://console.redhat.com/openshift/token
rosa login --token=$RHCS_TOKEN
```

> **Single-account testing:** Set both account IDs to the same value. Where the tutorial says "switch to the VPC Owner account," you can skip the profile switch.

If you have separate AWS CLI profiles for each account:

```bash
export VPC_OWNER_PROFILE="vpc-owner"
export CLUSTER_CREATOR_PROFILE="cluster-creator"
```

Throughout the tutorial, commands that run against the VPC Owner account use `--profile $VPC_OWNER_PROFILE` and commands against the Cluster Creator account use `--profile $CLUSTER_CREATOR_PROFILE`. Omit the `--profile` flag if you are using a single account.

---

### Step 2: Create the VPC and Networking (VPC Owner Account)

Create the VPC with DNS support enabled:

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block $VPC_CIDR \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${CLUSTER_NAME}-shared-vpc}]" \
  --query "Vpc.VpcId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID \
  --enable-dns-hostnames \
  --region $REGION --profile $VPC_OWNER_PROFILE

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID \
  --enable-dns-support \
  --region $REGION --profile $VPC_OWNER_PROFILE

echo "VPC ID: $VPC_ID"
```

Expected output:

```
VPC ID: vpc-0abc1234def56789a
```

Create an Internet Gateway:

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${CLUSTER_NAME}-igw}]" \
  --query "InternetGateway.InternetGatewayId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

aws ec2 attach-internet-gateway \
  --internet-gateway-id $IGW_ID --vpc-id $VPC_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE

echo "IGW ID: $IGW_ID"
```

Create three private subnets (one per Availability Zone):

```bash
PRIVATE_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.0.0/19" \
  --availability-zone "${REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-private-${REGION}a},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --query "Subnet.SubnetId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

PRIVATE_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.32.0/19" \
  --availability-zone "${REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-private-${REGION}b},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --query "Subnet.SubnetId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

PRIVATE_SUBNET_C=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.64.0/19" \
  --availability-zone "${REGION}c" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-private-${REGION}c},{Key=kubernetes.io/role/internal-elb,Value=1}]" \
  --query "Subnet.SubnetId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

SUBNET_IDS="${PRIVATE_SUBNET_A},${PRIVATE_SUBNET_B},${PRIVATE_SUBNET_C}"
echo "Private Subnet IDs: $SUBNET_IDS"
```

Expected output:

```
Private Subnet IDs: subnet-0aaa...,subnet-0bbb...,subnet-0ccc...
```

Create a public subnet (for the NAT Gateway and optional bastion):

```bash
PUBLIC_SUBNET=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block "10.0.128.0/20" \
  --availability-zone "${REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public}]" \
  --query "Subnet.SubnetId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

aws ec2 modify-subnet-attribute \
  --subnet-id $PUBLIC_SUBNET --map-public-ip-on-launch \
  --region $REGION --profile $VPC_OWNER_PROFILE

echo "Public Subnet ID: $PUBLIC_SUBNET"
```

Create a NAT Gateway for outbound internet access from private subnets:

```bash
EIP_ALLOC=$(aws ec2 allocate-address \
  --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${CLUSTER_NAME}-nat-eip}]" \
  --query "AllocationId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

NAT_GW_ID=$(aws ec2 create-nat-gateway \
  --subnet-id $PUBLIC_SUBNET \
  --allocation-id $EIP_ALLOC \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${CLUSTER_NAME}-nat}]" \
  --query "NatGateway.NatGatewayId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

echo "Waiting for NAT Gateway to become available..."
aws ec2 wait nat-gateway-available \
  --nat-gateway-ids $NAT_GW_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE

echo "NAT Gateway ID: $NAT_GW_ID"
```

Create route tables and associate subnets:

```bash
# Private route table — routes internet-bound traffic through NAT
PRIVATE_RT=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${CLUSTER_NAME}-private-rt}]" \
  --query "RouteTable.RouteTableId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

aws ec2 create-route \
  --route-table-id $PRIVATE_RT \
  --destination-cidr-block "0.0.0.0/0" \
  --nat-gateway-id $NAT_GW_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE > /dev/null

aws ec2 associate-route-table --route-table-id $PRIVATE_RT \
  --subnet-id $PRIVATE_SUBNET_A \
  --region $REGION --profile $VPC_OWNER_PROFILE > /dev/null
aws ec2 associate-route-table --route-table-id $PRIVATE_RT \
  --subnet-id $PRIVATE_SUBNET_B \
  --region $REGION --profile $VPC_OWNER_PROFILE > /dev/null
aws ec2 associate-route-table --route-table-id $PRIVATE_RT \
  --subnet-id $PRIVATE_SUBNET_C \
  --region $REGION --profile $VPC_OWNER_PROFILE > /dev/null

# Public route table — routes traffic directly to the Internet Gateway
PUBLIC_RT=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${CLUSTER_NAME}-public-rt}]" \
  --query "RouteTable.RouteTableId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

aws ec2 create-route \
  --route-table-id $PUBLIC_RT \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id $IGW_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE > /dev/null

aws ec2 associate-route-table --route-table-id $PUBLIC_RT \
  --subnet-id $PUBLIC_SUBNET \
  --region $REGION --profile $VPC_OWNER_PROFILE > /dev/null

echo "Route tables created and associated."
```

---

### Step 3: Create Shared VPC IAM Roles (VPC Owner Account)

Create the **Route 53 role** with the AWS managed `ROSASharedVPCRoute53Policy`. The initial trust policy uses the cluster account root — it will be tightened to specific role ARNs in Step 9.

```bash
cat <<EOF > /tmp/shared-vpc-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${CLUSTER_CREATOR_ACCOUNT_ID}:root"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

ROUTE53_ROLE_ARN=$(aws iam create-role \
  --role-name "${CLUSTER_NAME}-route53-role" \
  --assume-role-policy-document file:///tmp/shared-vpc-trust-policy.json \
  --query "Role.Arn" --output text \
  --profile $VPC_OWNER_PROFILE)

aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-route53-role" \
  --policy-arn "arn:aws:iam::aws:policy/ROSASharedVPCRoute53Policy" \
  --profile $VPC_OWNER_PROFILE

echo "Route 53 Role ARN: $ROUTE53_ROLE_ARN"
```

Expected output:

```
Route 53 Role ARN: arn:aws:iam::222222222222:role/mycluster-route53-role
```

Create the **VPC Endpoint role** with the AWS managed `ROSASharedVPCEndpointPolicy`:

```bash
VPCE_ROLE_ARN=$(aws iam create-role \
  --role-name "${CLUSTER_NAME}-vpc-endpoint-role" \
  --assume-role-policy-document file:///tmp/shared-vpc-trust-policy.json \
  --query "Role.Arn" --output text \
  --profile $VPC_OWNER_PROFILE)

aws iam attach-role-policy \
  --role-name "${CLUSTER_NAME}-vpc-endpoint-role" \
  --policy-arn "arn:aws:iam::aws:policy/ROSASharedVPCEndpointPolicy" \
  --profile $VPC_OWNER_PROFILE

echo "VPC Endpoint Role ARN: $VPCE_ROLE_ARN"
```

Expected output:

```
VPC Endpoint Role ARN: arn:aws:iam::222222222222:role/mycluster-vpc-endpoint-role
```

---

### Step 4: Create Route 53 Private Hosted Zones (VPC Owner Account)

ROSA HCP requires two private hosted zones with **specific naming patterns**. Create them now; the DNS domain from Step 5 is needed for the ingress zone name, so if you have not yet reserved a domain, skip this step and return after Step 5.

> If you already know your `base_dns_domain`, proceed here. Otherwise, complete Step 5 first, then return.

```bash
export BASE_DNS_DOMAIN="<your-domain>.p3.openshiftapps.com"  # From Step 5
```

Create the **HCP internal** hosted zone (`<cluster>.hypershift.local`):

```bash
HCP_HZ_ID=$(aws route53 create-hosted-zone \
  --name "${CLUSTER_NAME}.hypershift.local" \
  --vpc VPCRegion=${REGION},VPCId=${VPC_ID} \
  --hosted-zone-config PrivateZone=true \
  --caller-reference "${CLUSTER_NAME}-hcp-$(date +%s)" \
  --query "HostedZone.Id" --output text \
  --profile $VPC_OWNER_PROFILE | sed 's|/hostedzone/||')

echo "HCP Internal Hosted Zone ID: $HCP_HZ_ID"
```

Expected output:

```
HCP Internal Hosted Zone ID: Z0123456789ABCDEFGHIJ
```

Create the **Ingress** hosted zone (`rosa.<cluster>.<base_dns_domain>`):

```bash
INGRESS_HZ_ID=$(aws route53 create-hosted-zone \
  --name "rosa.${CLUSTER_NAME}.${BASE_DNS_DOMAIN}" \
  --vpc VPCRegion=${REGION},VPCId=${VPC_ID} \
  --hosted-zone-config PrivateZone=true \
  --caller-reference "${CLUSTER_NAME}-ingress-$(date +%s)" \
  --query "HostedZone.Id" --output text \
  --profile $VPC_OWNER_PROFILE | sed 's|/hostedzone/||')

echo "Ingress Hosted Zone ID: $INGRESS_HZ_ID"
```

Expected output:

```
Ingress Hosted Zone ID: Z9876543210KJIHGFEDCBA
```

---

### Step 5: Reserve an HCP DNS Domain (Cluster Creator Account)

Shared VPC HCP clusters require a `base_dns_domain` registered under the `p3.openshiftapps.com` parent:

```bash
rosa create dns-domain --hosted-cp
```

Expected output:

```
I: DNS domain 'abcd.p3.openshiftapps.com' has been created.
I: To view all DNS domains, run 'rosa list dns-domains'
```

Confirm and save the domain:

```bash
rosa list dns-domains
```

Expected output:

```
ID                                    DNS Domain
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  abcd.p3.openshiftapps.com
```

```bash
export BASE_DNS_DOMAIN="abcd.p3.openshiftapps.com"  # Replace with your actual domain
```

> **If you skipped Step 4**, go back now and create the hosted zones using this domain.

---

### Step 6: Create OIDC Config (Cluster Creator Account)

```bash
OIDC_CONFIG_ID=$(rosa create oidc-config --mode auto --managed=false -y \
  --output json | jq -r '.id')

echo "OIDC Config ID: $OIDC_CONFIG_ID"
```

Expected output:

```
I: Setting up managed OIDC configuration
I: Created OIDC provider with ARN 'arn:aws:iam::111111111111:oidc-provider/...'
OIDC Config ID: 2pXXXXXXXXXXXXXXX
```

> Save the OIDC Config ID — it is required for operator roles and cluster creation.

---

### Step 7: Create Account Roles (Cluster Creator Account)

Pass the shared VPC role ARNs so the CLI configures the roles for cross-account access:

```bash
rosa create account-roles \
  --prefix $ROLES_PREFIX \
  --hosted-cp \
  --route53-role-arn $ROUTE53_ROLE_ARN \
  --vpc-endpoint-role-arn $VPCE_ROLE_ARN \
  --mode auto -y
```

Expected output:

```
I: Creating roles using 'arn:aws:iam::111111111111:user/admin'
I: Created role 'mycluster-HCP-ROSA-Installer-Role' ...
I: Created role 'mycluster-HCP-ROSA-Support-Role' ...
I: Created role 'mycluster-HCP-ROSA-Worker-Role' ...
```

Retrieve the Installer Role ARN:

```bash
INSTALLER_ROLE_ARN=$(aws iam get-role \
  --role-name "${ROLES_PREFIX}-HCP-ROSA-Installer-Role" \
  --query "Role.Arn" --output text \
  --profile $CLUSTER_CREATOR_PROFILE)

echo "Installer Role ARN: $INSTALLER_ROLE_ARN"
```

Verify:

```bash
rosa list account-roles | grep $ROLES_PREFIX
```

Expected output:

```
mycluster-HCP-ROSA-Installer-Role    ...    arn:aws:iam::111111111111:role/mycluster-HCP-ROSA-Installer-Role
mycluster-HCP-ROSA-Support-Role      ...    arn:aws:iam::111111111111:role/mycluster-HCP-ROSA-Support-Role
mycluster-HCP-ROSA-Worker-Role       ...    arn:aws:iam::111111111111:role/mycluster-HCP-ROSA-Worker-Role
```

---

### Step 8: Create Operator Roles (Cluster Creator Account)

```bash
rosa create operator-roles \
  --prefix $ROLES_PREFIX \
  --hosted-cp \
  --oidc-config-id $OIDC_CONFIG_ID \
  --installer-role-arn $INSTALLER_ROLE_ARN \
  --route53-role-arn $ROUTE53_ROLE_ARN \
  --vpc-endpoint-role-arn $VPCE_ROLE_ARN \
  --mode auto -y
```

Expected output:

```
I: Creating roles using 'arn:aws:iam::111111111111:user/admin'
I: Created role 'mycluster-openshift-ingress-operator-cloud-credentials' ...
I: Created role 'mycluster-openshift-cluster-csi-drivers-ebs-cloud-credentials' ...
I: Created role 'mycluster-kube-system-kube-controller-manager' ...
I: Created role 'mycluster-kube-system-capa-controller-manager' ...
I: Created role 'mycluster-kube-system-control-plane-operator' ...
I: Created role 'mycluster-kube-system-kms-provider' ...
I: Created role 'mycluster-openshift-image-registry-installer-cloud-credentials' ...
I: Created role 'mycluster-openshift-cloud-network-config-controller-cloud-credential' ...
```

Verify:

```bash
rosa list operator-roles --prefix $ROLES_PREFIX
```

Save the key operator role ARNs for later steps:

```bash
CONTROL_PLANE_OP_ARN=$(aws iam get-role \
  --role-name "${ROLES_PREFIX}-kube-system-control-plane-operator" \
  --query "Role.Arn" --output text \
  --profile $CLUSTER_CREATOR_PROFILE)

INGRESS_OP_ARN=$(aws iam get-role \
  --role-name "${ROLES_PREFIX}-openshift-ingress-operator-cloud-credentials" \
  --query "Role.Arn" --output text \
  --profile $CLUSTER_CREATOR_PROFILE)

echo "Control Plane Operator ARN: $CONTROL_PLANE_OP_ARN"
echo "Ingress Operator ARN:       $INGRESS_OP_ARN"
```

---

### Step 9: Update Shared VPC Trust Policies (VPC Owner Account)

Now that the ROSA roles exist, tighten the trust policies on the shared VPC roles to only allow the specific roles that need access. This replaces the broad `root` trust from Step 3.

Update the **Route 53 role** trust policy:

```bash
cat <<EOF > /tmp/route53-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "${INSTALLER_ROLE_ARN}",
          "${INGRESS_OP_ARN}",
          "${CONTROL_PLANE_OP_ARN}"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam update-assume-role-policy \
  --role-name "${CLUSTER_NAME}-route53-role" \
  --policy-document file:///tmp/route53-trust-policy.json \
  --profile $VPC_OWNER_PROFILE

echo "Updated Route 53 role trust policy."
```

Update the **VPC Endpoint role** trust policy:

```bash
cat <<EOF > /tmp/vpce-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "${INSTALLER_ROLE_ARN}",
          "${CONTROL_PLANE_OP_ARN}"
        ]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam update-assume-role-policy \
  --role-name "${CLUSTER_NAME}-vpc-endpoint-role" \
  --policy-document file:///tmp/vpce-trust-policy.json \
  --profile $VPC_OWNER_PROFILE

echo "Updated VPC Endpoint role trust policy."
```

> **IAM propagation:** AWS IAM changes are eventually consistent and can take 5–15 seconds to propagate globally. Wait before proceeding to cluster creation.

```bash
echo "Waiting 15 seconds for IAM propagation..."
sleep 15
```

---

### Step 10: Create a Customer-Managed KMS Key (Cluster Creator Account) — Optional

If you want customer-managed encryption for etcd and EBS volumes, create a KMS key with a policy granting the ROSA operator roles access.

Retrieve the remaining operator role ARNs:

```bash
SUPPORT_ROLE_ARN=$(aws iam get-role \
  --role-name "${ROLES_PREFIX}-HCP-ROSA-Support-Role" \
  --query "Role.Arn" --output text \
  --profile $CLUSTER_CREATOR_PROFILE)

KUBE_CTRL_MGR_ARN=$(aws iam get-role \
  --role-name "${ROLES_PREFIX}-kube-system-kube-controller-manager" \
  --query "Role.Arn" --output text \
  --profile $CLUSTER_CREATOR_PROFILE)

KMS_PROVIDER_ARN=$(aws iam get-role \
  --role-name "${ROLES_PREFIX}-kube-system-kms-provider" \
  --query "Role.Arn" --output text \
  --profile $CLUSTER_CREATOR_PROFILE)

CAPA_ARN=$(aws iam get-role \
  --role-name "${ROLES_PREFIX}-kube-system-capa-controller-manager" \
  --query "Role.Arn" --output text \
  --profile $CLUSTER_CREATOR_PROFILE)

EBS_CSI_ARN=$(aws iam get-role \
  --role-name "${ROLES_PREFIX}-openshift-cluster-csi-drivers-ebs-cloud-credentials" \
  --query "Role.Arn" --output text \
  --profile $CLUSTER_CREATOR_PROFILE)
```

Create the KMS key policy:

```bash
cat <<EOF > /tmp/kms-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnableIAMUserPermissions",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${CLUSTER_CREATOR_ACCOUNT_ID}:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowROSAInstallerRole",
      "Effect": "Allow",
      "Principal": { "AWS": "${INSTALLER_ROLE_ARN}" },
      "Action": [
        "kms:CreateGrant",
        "kms:DescribeKey",
        "kms:GenerateDataKeyWithoutPlaintext"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowROSASupportRole",
      "Effect": "Allow",
      "Principal": { "AWS": "${SUPPORT_ROLE_ARN}" },
      "Action": "kms:DescribeKey",
      "Resource": "*"
    },
    {
      "Sid": "AllowKubeControllerManager",
      "Effect": "Allow",
      "Principal": { "AWS": "${KUBE_CTRL_MGR_ARN}" },
      "Action": "kms:DescribeKey",
      "Resource": "*"
    },
    {
      "Sid": "AllowKMSProviderForEtcd",
      "Effect": "Allow",
      "Principal": { "AWS": "${KMS_PROVIDER_ARN}" },
      "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
      "Resource": "*"
    },
    {
      "Sid": "AllowCAPAControllerForNodes",
      "Effect": "Allow",
      "Principal": { "AWS": "${CAPA_ARN}" },
      "Action": [
        "kms:DescribeKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:CreateGrant"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowEBSCSIDriverKMSOperations",
      "Effect": "Allow",
      "Principal": { "AWS": "${EBS_CSI_ARN}" },
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowEBSCSIDriverCreateGrant",
      "Effect": "Allow",
      "Principal": { "AWS": "${EBS_CSI_ARN}" },
      "Action": [ "kms:CreateGrant", "kms:RevokeGrant", "kms:ListGrants" ],
      "Resource": "*",
      "Condition": {
        "Bool": { "kms:GrantIsForAWSResource": "true" }
      }
    }
  ]
}
EOF
```

Create the key:

```bash
KMS_KEY_ARN=$(aws kms create-key \
  --description "ROSA HCP encryption key for cluster ${CLUSTER_NAME}" \
  --policy file:///tmp/kms-policy.json \
  --query "KeyMetadata.Arn" --output text \
  --region $REGION --profile $CLUSTER_CREATOR_PROFILE)

aws kms create-alias \
  --alias-name "alias/${CLUSTER_NAME}-key" \
  --target-key-id $KMS_KEY_ARN \
  --region $REGION --profile $CLUSTER_CREATOR_PROFILE

echo "KMS Key ARN: $KMS_KEY_ARN"
```

Expected output:

```
KMS Key ARN: arn:aws:kms:us-east-1:111111111111:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

---

### Step 11: Create the ROSA HCP Cluster (Cluster Creator Account)

Assemble the `rosa create cluster` command with all the shared VPC parameters:

```bash
rosa create cluster \
  --cluster-name $CLUSTER_NAME \
  --sts \
  --hosted-cp \
  --region $REGION \
  --subnet-ids $SUBNET_IDS \
  --machine-cidr $VPC_CIDR \
  --private \
  --operator-roles-prefix $ROLES_PREFIX \
  --oidc-config-id $OIDC_CONFIG_ID \
  --base-domain $BASE_DNS_DOMAIN \
  --hcp-internal-communication-hosted-zone-id $HCP_HZ_ID \
  --ingress-private-hosted-zone-id $INGRESS_HZ_ID \
  --route53-role-arn $ROUTE53_ROLE_ARN \
  --vpc-endpoint-role-arn $VPCE_ROLE_ARN \
  --additional-allowed-principals "${ROUTE53_ROLE_ARN},${VPCE_ROLE_ARN}" \
  --kms-key-arn $KMS_KEY_ARN \
  --etcd-encryption \
  --etcd-encryption-kms-arn $KMS_KEY_ARN \
  --mode auto -y
```

> **Without KMS:** Omit the `--kms-key-arn`, `--etcd-encryption`, and `--etcd-encryption-kms-arn` flags if you skipped Step 10.

Expected output:

```
I: Creating cluster 'mycluster'
I: To view a list of clusters and their status, run 'rosa list clusters'
I: Cluster 'mycluster' has been created and is now installing.
I: To check the status, run 'rosa describe cluster -c mycluster'
```

Monitor the installation:

```bash
rosa logs install -c $CLUSTER_NAME --watch
```

Or check the status periodically:

```bash
watch "rosa describe cluster -c $CLUSTER_NAME | grep -E 'State|DNS|API URL|Console URL'"
```

Expected states: `waiting` → `installing` → `ready` (takes 20–30 minutes).

When the cluster reaches `ready`:

```bash
rosa describe cluster -c $CLUSTER_NAME
```

Expected output:

```
Name:                       mycluster
ID:                         xxxxxxxxxxxxxxxxxxxx
External ID:                xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Control Plane:              ROSA Service Hosted
OpenShift Version:          4.18.32
DNS:                        mycluster.abcd.p3.openshiftapps.com
AWS Account:                111111111111
API URL:                    https://api.mycluster.abcd.p3.openshiftapps.com:443
Console URL:                https://console-openshift-console.apps.rosa.mycluster.abcd.p3.openshiftapps.com
Region:                     us-east-1
Multi-AZ:                   true
State:                      ready
Private:                    Yes
```

---

### Step 12: Access the Private Cluster

The cluster API is private and not reachable from the internet. Set up a bastion host in the shared VPC.

#### Launch a bastion instance

```bash
aws ec2 create-key-pair \
  --key-name ${CLUSTER_NAME}-bastion \
  --query "KeyMaterial" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE \
  > ~/.ssh/${CLUSTER_NAME}-bastion.pem
chmod 600 ~/.ssh/${CLUSTER_NAME}-bastion.pem

MY_IP=$(curl -s https://checkip.amazonaws.com)

SG_ID=$(aws ec2 create-security-group \
  --group-name ${CLUSTER_NAME}-bastion-sg \
  --description "Bastion SSH" \
  --vpc-id $VPC_ID \
  --query "GroupId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 22 --cidr "${MY_IP}/32" \
  --region $REGION --profile $VPC_OWNER_PROFILE > /dev/null

AMI_ID=$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.micro \
  --key-name ${CLUSTER_NAME}-bastion \
  --subnet-id $PUBLIC_SUBNET \
  --security-group-ids $SG_ID \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-bastion}]" \
  --query "Instances[0].InstanceId" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

echo "Waiting for bastion to start..."
aws ec2 wait instance-running \
  --instance-ids $INSTANCE_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE

BASTION_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text \
  --region $REGION --profile $VPC_OWNER_PROFILE)

echo "Bastion IP: $BASTION_IP"
```

#### Connect using sshuttle (recommended)

[`sshuttle`](https://github.com/sshuttle/sshuttle) creates a transparent VPN over SSH. All traffic to the VPC CIDR is routed through the bastion — no per-command proxy needed, and browser access works out of the box.

```bash
# Install (macOS)
brew install sshuttle

# Start the tunnel (uses sudo for firewall rules)
sudo sshuttle \
  -r ec2-user@${BASTION_IP} \
  --ssh-cmd "ssh -i ${HOME}/.ssh/${CLUSTER_NAME}-bastion.pem -o StrictHostKeyChecking=no" \
  ${VPC_CIDR} --dns
```

> Use the absolute path to the SSH key (`${HOME}/.ssh/` not `~/.ssh/`) because `sudo` runs as root.

#### Alternative: SOCKS proxy

```bash
ssh -o StrictHostKeyChecking=no \
  -i ~/.ssh/${CLUSTER_NAME}-bastion.pem \
  -D 1080 -f -N ec2-user@${BASTION_IP}

# All oc commands need the proxy prefix:
export HTTPS_PROXY=socks5://localhost:1080
```

---

### Step 13: Log In and Verify the Cluster

Create a temporary cluster admin:

```bash
rosa create admin --cluster $CLUSTER_NAME
```

Expected output:

```
I: Admin account has been added to cluster 'mycluster'.
I: Please securely store this generated password.
I: To login, run the following command:

   oc login https://api.mycluster.abcd.p3.openshiftapps.com:443 \
     --username cluster-admin --password XXXXX-XXXXX-XXXXX-XXXXX
```

Wait 1–2 minutes for the admin to propagate, then log in:

```bash
oc login https://api.${CLUSTER_NAME}.${BASE_DNS_DOMAIN}:443 \
  --username cluster-admin --password <PASSWORD> \
  --insecure-skip-tls-verify
```

Verify the nodes:

```bash
oc get nodes
```

Expected output:

```
NAME                          STATUS   ROLES    AGE   VERSION
ip-10-0-x-x.ec2.internal     Ready    worker   15m   v1.31.x+xxxxx
ip-10-0-x-x.ec2.internal     Ready    worker   15m   v1.31.x+xxxxx
ip-10-0-x-x.ec2.internal     Ready    worker   15m   v1.31.x+xxxxx
```

Verify the cluster version:

```bash
oc get clusterversion
```

Expected output:

```
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.18.32   True        False         10m     Cluster version is 4.18.32
```

Verify KMS encryption (if enabled):

```bash
# etcd encryption
oc get etcd -o jsonpath='{.items[0].spec.encryption.type}'
# Expected: aescbc

# Confirm the KMS key is in use
rosa describe cluster -c $CLUSTER_NAME | grep -i kms
```

Verify the shared VPC connectivity:

```bash
# Check that the private hosted zones are resolving
oc get dns.config cluster -o jsonpath='{.spec}'

# Verify ingress is working
oc get routes -A | head -5
```

---

## Cleanup

### 1. Delete the ROSA cluster

```bash
rosa delete cluster -c $CLUSTER_NAME -y --watch
```

This takes 10–15 minutes. Wait for completion before proceeding.

### 2. Clean up rosa CLI resources

```bash
rosa delete operator-roles --prefix $ROLES_PREFIX --mode auto -y
rosa delete oidc-config --oidc-config-id $OIDC_CONFIG_ID --mode auto -y
rosa delete account-roles --prefix $ROLES_PREFIX --mode auto -y
```

### 3. Delete the KMS key (if created)

```bash
aws kms schedule-key-deletion \
  --key-id $KMS_KEY_ARN \
  --pending-window-in-days 7 \
  --region $REGION --profile $CLUSTER_CREATOR_PROFILE
```

### 4. Terminate the bastion

```bash
aws ec2 terminate-instances --instance-ids $INSTANCE_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE
aws ec2 delete-security-group --group-id $SG_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE
aws ec2 delete-key-pair --key-name ${CLUSTER_NAME}-bastion \
  --region $REGION --profile $VPC_OWNER_PROFILE
rm -f ~/.ssh/${CLUSTER_NAME}-bastion.pem
```

### 5. Delete Route 53 hosted zones (VPC Owner Account)

Hosted zones must be empty (only NS and SOA records) before deletion:

```bash
aws route53 delete-hosted-zone --id $INGRESS_HZ_ID \
  --profile $VPC_OWNER_PROFILE
aws route53 delete-hosted-zone --id $HCP_HZ_ID \
  --profile $VPC_OWNER_PROFILE
```

> If deletion fails with `HostedZoneNotEmpty`, list and delete non-NS/SOA records first:
> ```bash
> aws route53 list-resource-record-sets --hosted-zone-id $INGRESS_HZ_ID \
>   --profile $VPC_OWNER_PROFILE
> ```

### 6. Delete shared VPC IAM roles (VPC Owner Account)

```bash
aws iam detach-role-policy \
  --role-name "${CLUSTER_NAME}-route53-role" \
  --policy-arn "arn:aws:iam::aws:policy/ROSASharedVPCRoute53Policy" \
  --profile $VPC_OWNER_PROFILE
aws iam delete-role --role-name "${CLUSTER_NAME}-route53-role" \
  --profile $VPC_OWNER_PROFILE

aws iam detach-role-policy \
  --role-name "${CLUSTER_NAME}-vpc-endpoint-role" \
  --policy-arn "arn:aws:iam::aws:policy/ROSASharedVPCEndpointPolicy" \
  --profile $VPC_OWNER_PROFILE
aws iam delete-role --role-name "${CLUSTER_NAME}-vpc-endpoint-role" \
  --profile $VPC_OWNER_PROFILE
```

### 7. Delete VPC resources (VPC Owner Account)

Resources must be deleted in reverse dependency order:

```bash
# NAT Gateway + EIP
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE
echo "Waiting for NAT Gateway deletion..."
sleep 60

aws ec2 release-address --allocation-id $EIP_ALLOC \
  --region $REGION --profile $VPC_OWNER_PROFILE

# Subnets
for SUBNET in $PRIVATE_SUBNET_A $PRIVATE_SUBNET_B $PRIVATE_SUBNET_C $PUBLIC_SUBNET; do
  aws ec2 delete-subnet --subnet-id $SUBNET \
    --region $REGION --profile $VPC_OWNER_PROFILE
done

# Route tables (disassociate first, skip the main route table)
for RT in $PRIVATE_RT $PUBLIC_RT; do
  ASSOC_IDS=$(aws ec2 describe-route-tables --route-table-ids $RT \
    --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" \
    --output text --region $REGION --profile $VPC_OWNER_PROFILE)
  for ASSOC in $ASSOC_IDS; do
    aws ec2 disassociate-route-table --association-id $ASSOC \
      --region $REGION --profile $VPC_OWNER_PROFILE
  done
  aws ec2 delete-route-table --route-table-id $RT \
    --region $REGION --profile $VPC_OWNER_PROFILE
done

# Internet Gateway
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE

# VPC
aws ec2 delete-vpc --vpc-id $VPC_ID \
  --region $REGION --profile $VPC_OWNER_PROFILE

echo "VPC cleanup complete."
```

### 8. Clean up temporary files

```bash
rm -f /tmp/shared-vpc-trust-policy.json /tmp/route53-trust-policy.json \
  /tmp/vpce-trust-policy.json /tmp/kms-policy.json
```

## Additional Resources

- [Configuring a shared VPC for ROSA HCP clusters](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_clusters/rosa-hcp-shared-vpc-config) — Official Red Hat documentation
- [ROSA HCP documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4)
- [Terraform RHCS provider](https://registry.terraform.io/providers/terraform-redhat/rhcs/latest/docs)
- [AWS managed policies for ROSA](https://docs.aws.amazon.com/rosa/latest/userguide/security-iam-awsmanpol.html)
- [ROSA CLI reference](https://docs.openshift.com/rosa/cli_reference/rosa_cli/rosa-manage-objects-cli.html)
