---
date: '2026-03-17'
title: Deploy Red Hat Quay on ROSA HCP with AWS S3, RDS, and ElastiCache (CLI)
tags: ["AWS", "ROSA", "Quay", "HCP", "S3", "RDS", "ElastiCache", "IRSA", "STS"]
authors:
  - Kumudu Herath
---

{{% alert state="info" %}}This guide has been validated on **OpenShift 4.20** (ROSA HCP) with the **Red Hat Quay Operator** channel **`stable-3.16`**. CSV versions and Quay `config.yaml` fields may differ on other versions; confirm the channel with `oc get packagemanifest quay-operator -n openshift-marketplace`.{{% /alert %}}

This guide deploys [Red Hat Quay](https://docs.redhat.com/en/documentation/red_hat_quay/) on **Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Planes (HCP)** using **only** the `oc` and `aws` CLIs. It uses:

* **Amazon S3** for registry storage with **IRSA** and the Quay **STSS3Storage** backend (no long-lived S3 access keys).
* **Amazon RDS for PostgreSQL** for the Quay metadata database (password authentication via `DB_URI`).
* **Amazon ElastiCache for Redis** for Quay’s Redis workloads (in-VPC connectivity; optional AUTH token).

The **RDS networking and bootstrap** steps follow the same pattern as [Connect to RDS database with STS from ROSA](/experts/rosa/sts-rds/). ElastiCache is created in the **same database VPC** with a matching security-group pattern.

**References**

* [Deploying the Red Hat Quay registry | Red Hat Quay 3.16](https://docs.redhat.com/en/documentation/red_hat_quay/3.16/html/deploying_the_red_hat_quay_operator_on_openshift_container_platform/deploying-quay-registry#registry-deploy-cli)
* [Using an external PostgreSQL database](https://docs.redhat.com/en/documentation/red_hat_quay/3.16/html/deploying_the_red_hat_quay_operator_on_openshift_container_platform/using-an-external-postgresql-database)
* [Using an external Redis database](https://docs.redhat.com/en/documentation/red_hat_quay/3.16/html/deploying_the_red_hat_quay_operator_on_openshift_container_platform/using-an-external-redis-database)
* [Configure AWS S3 cloud storage with STS](https://docs.redhat.com/en/documentation/red_hat_quay/3.16/html/configure_red_hat_quay/configuring-aws-sts-quay)
* [S3 IAM bucket policy for Quay Enterprise (Solution 3680151)](https://access.redhat.com/solutions/3680151) — use with the **bucket policy** in §5.4 to avoid `403 Forbidden` on S3
* [Troubleshooting the QuayRegistry CR](https://docs.redhat.com/en/documentation/red_hat_quay/3.16/html/deploying_the_red_hat_quay_operator_on_openshift_container_platform/troubleshooting-the-quayregistry-cr)

---

## Prerequisites

* A **ROSA HCP** cluster with `cluster-admin` (or equivalent) access
* [OpenShift CLI](https://docs.openshift.com/rosa/cli_reference/openshift_cli/getting-started-cli.html) (`oc`) logged in
* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with permissions to create VPC, RDS, ElastiCache, S3, IAM roles/policies
* `jq` installed (required for **§1.2**–**§1.3** tag merge and helpers)
* Optional: **ROSA CLI** (`rosa`) if you prefer `rosa describe cluster` for region/OIDC (alternatives below use only `oc`)

{{% alert state="warning" %}}**RDS IAM database authentication:** Quay expects a stable `DB_URI` (user + password). RDS IAM tokens expire about every **15 minutes**, so this guide uses a **dedicated PostgreSQL user and password** for Quay. You can still follow [sts-rds](/experts/rosa/sts-rds/) for VPC, subnet group, and RDS creation; skip attaching `rds-db:connect` to the **Quay** service account unless you have a separate use case.{{% /alert %}}

---

## 1. Names and environment variables

Set names used throughout this guide:

```bash
export QUAY_NAMESPACE="${QUAY_NAMESPACE:-quay-enterprise}"
export QUAY_REGISTRY_NAME="${QUAY_REGISTRY_NAME:-example-registry}"
export CLUSTER_NAME=$(oc get infrastructure cluster -o=jsonpath="{.status.apiServerURL}" | awk -F '.' '{print $2}')
```

This **`CLUSTER_NAME`** segment is used in AWS resource names (RDS, subnet groups, IAM policy name, etc.). Override with `export CLUSTER_NAME=...` if your API server hostname does not match the name you want for those resources.

**Quay app service account** (used in the IAM trust policy) is typically:

```bash
export QUAY_APP_SA="${QUAY_REGISTRY_NAME}-quay-app"
```

Confirm after install with `oc get sa -n "${QUAY_NAMESPACE}"` and adjust the trust policy if your operator version uses a different name.

### 1.1 Region, account, OIDC (ROSA HCP)

```bash
export AWS_REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_PAGER=""
export SCRATCH_DIR="${SCRATCH_DIR:-/tmp/quay-rosa-scratch}"
mkdir -p "${SCRATCH_DIR}"

export OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')

echo "AWS_REGION=${AWS_REGION} AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}"
echo "OIDC_PROVIDER=${OIDC_PROVIDER}"
```

{{% alert state="info" %}}If you use **classic ROSA** with the `rosa` CLI, you can instead set `AWS_REGION` and `OIDC_PROVIDER` from `rosa describe cluster -c "${CLUSTER_NAME}" -o json` as in [Connect to RDS database with STS from ROSA](/experts/rosa/sts-rds/).{{% /alert %}}

### 1.2 AWS resource tags — Step 6 (Option A: single JSON env var)

Set **`QUAY_AWS_TAGS_JSON`** to a **JSON array** of `{"Key":"…","Value":"…"}` objects (same information you might keep in a Terraform `map`). Customize keys/values for your organization.

The guide **merges** **`ROSAClusterName`** to the current **`${CLUSTER_NAME}`** (§1) so the tag stays aligned with the API-derived cluster name; any prior **`ROSAClusterName`** entry in the array is replaced.

```bash
export QUAY_AWS_TAGS_JSON='[
  {"Key":"Terraform","Value":"true"},
  {"Key":"cost-center","Value":"CC468"},
  {"Key":"owner","Value":"kherath@redhat.com"},
  {"Key":"service-phase","Value":"lab"},
  {"Key":"app-code","Value":"MOBB-001"}
]'

export QUAY_AWS_TAGS_MERGED=$(echo "${QUAY_AWS_TAGS_JSON}" | jq -c --arg c "${CLUSTER_NAME}" '
  (map(select(.Key != "ROSAClusterName")) + [{"Key":"ROSAClusterName","Value":$c}]) | unique_by(.Key)
')

echo "QUAY_AWS_TAGS_MERGED=${QUAY_AWS_TAGS_MERGED}"
```

{{% alert state="warning" %}}Avoid **commas** inside tag **values** when using the AWS CLI `Key=…,Value=…` shorthand below; commas break parsing. Prefer short codes or omit problematic characters.{{% /alert %}}

### 1.3 AWS tag helpers — Step 7

Define helpers once (same shell session as **§2**–**§5**). They read **`QUAY_AWS_TAGS_MERGED`** from **§1.2**.

```bash
# RDS, ElastiCache, IAM: repeated --tags Key=a,Value=b ...
quay_aws_tags_to_cli_pairs() {
  jq -r '.[] | "Key=\(.Key),Value=\(.Value)"' <<< "${QUAY_AWS_TAGS_MERGED}"
}

# S3 PutBucketTagging body: {"TagSet":[...]}
quay_aws_s3_tagging_body() {
  echo "${QUAY_AWS_TAGS_MERGED}" | jq -c '{TagSet: .}'
}

export QUAY_AWS_S3_TAGGING_JSON=$(quay_aws_s3_tagging_body)
```

**Usage pattern**

* **EC2 `create-tags`:** load pairs into a bash array, then pass **`--tags "${ARRAY[@]}"`**:

  ```bash
  mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)
  aws ec2 create-tags --resources "${RESOURCE_ID}" --region "${AWS_REGION}" --tags "${_QUAY_AWS_TAG_PAIRS[@]}"
  ```

* **RDS / ElastiCache / IAM:** append **`--tags "${_QUAY_AWS_TAG_PAIRS[@]}"`** to **`create-db-subnet-group`**, **`create-db-instance`**, **`create-cache-subnet-group`**, **`create-cache-cluster`**, **`create-policy`**, and **`create-role`** (see **§2**, **§3**, **§5**).

* **S3:** use **`${QUAY_AWS_S3_TAGGING_JSON}`** with **`aws s3api put-bucket-tagging --tagging`** (**§2**).

{{% alert state="info" %}}**`mapfile`:** The examples use **`mapfile`** (bash 4+). If your shell lacks it, replace **`mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)`** with a loop that builds the **`--tags`** arguments from **`quay_aws_tags_to_cli_pairs`**.{{% /alert %}}

### 1.4 ROSA VPC and CIDR (for peering and security groups)

Quay on ROSA must reach **private** RDS and ElastiCache in **`VPC_DB`**. You need **private IP connectivity** between the **ROSA cluster VPC** and **`VPC_DB`**—typically **VPC peering** (§3.2) or **AWS Transit Gateway** ([What is Transit Gateway?](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html)). A NAT gateway public IP is **not** used for these rules.

```bash
export NODE=$(oc get nodes --selector=node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')
export VPC_ROSA=$(aws ec2 describe-instances \
  --filters "Name=private-dns-name,Values=${NODE}" \
  --query 'Reservations[*].Instances[*].VpcId' \
  --region "${AWS_REGION}" \
  --output text | head -1)

export ROSA_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "${VPC_ROSA}" \
  --region "${AWS_REGION}" \
  --query 'Vpcs[0].CidrBlock' --output text)

echo "VPC_ROSA=${VPC_ROSA} ROSA_VPC_CIDR=${ROSA_VPC_CIDR}"
```

{{% alert state="warning" %}}**Non-overlapping CIDRs:** `VPC_DB` uses **`10.23.0.0/16`** in §3.1. It **must not overlap** `${ROSA_VPC_CIDR}`. If it does, change the `--cidr-block` when creating `VPC_DB` or use a different network design.{{% /alert %}}

### 1.5 Passwords

Amazon RDS `MasterUserPassword` accepts only **printable ASCII** and **must not** contain `/`, `@`, `"`, or space ([CreateDBInstance](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_CreateDBInstance.html)). Passwords from `openssl rand -base64` often include `/` (and sometimes `@`), which triggers `InvalidParameterValue`.

Use **hex** secrets for RDS and for the Quay DB user (also keeps `DB_URI` free of `@`, `:`, `#`, and `%` in the password):

```bash
# RDS master user (postgres) — hex only, always valid for CreateDBInstance
export PSQL_PASSWORD=$(openssl rand -hex 24)

export QUAY_DB_USER="${QUAY_DB_USER:-quay}"
export QUAY_DB_NAME="${QUAY_DB_NAME:-quay}"
# Optional ElastiCache AUTH token (leave empty if you disable Redis AUTH). If you set it, use only ElastiCache-allowed characters.
export REDIS_AUTH_TOKEN="${REDIS_AUTH_TOKEN:-}"
```

---

## 2. Create S3 bucket for Quay

Complete **§1.2** and **§1.3** first so **`QUAY_AWS_S3_TAGGING_JSON`** is set.

```bash
export QUAY_S3_BUCKET="quay-registry-${CLUSTER_NAME}-${AWS_REGION}"
aws s3 mb "s3://${QUAY_S3_BUCKET}" --region "${AWS_REGION}"

aws s3api put-bucket-tagging \
  --bucket "${QUAY_S3_BUCKET}" \
  --tagging "${QUAY_AWS_S3_TAGGING_JSON}" \
  --region "${AWS_REGION}"
```

Requires **`QUAY_AWS_S3_TAGGING_JSON`** from **§1.3**. Optional (recommended for production): enable default encryption and block public access using your organization’s standards.

---

## 3. Database VPC, RDS, and ElastiCache

Create a dedicated **`VPC_DB`** for RDS and ElastiCache, **peer** it to the ROSA VPC (`VPC_ROSA` from §1.4), then allow **private** traffic from **`${ROSA_VPC_CIDR}`** on the RDS and Redis security groups.

{{% alert state="info" %}}**VPC connectivity:** You **must** have private routing between the cluster and `VPC_DB`—either **VPC peering** (§3.2) or **Transit Gateway** (not detailed here). See [VPC peering](https://docs.aws.amazon.com/vpc/latest/peering/create-vpc-peering-connection.html) and [Transit Gateway](https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html).{{% /alert %}}

Run **§1.2** and **§1.3** before **§3** so **`quay_aws_tags_to_cli_pairs`** is defined. Each subsection below runs **`mapfile`** to refresh **`_QUAY_AWS_TAG_PAIRS`** for that shell.

### 3.1 VPC and subnets

```bash
mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)

VPC_DB=$(aws ec2 create-vpc --cidr-block 10.23.0.0/16 --region "${AWS_REGION}" | jq -r .Vpc.VpcId)
aws ec2 modify-vpc-attribute --vpc-id "${VPC_DB}" --enable-dns-hostnames "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id "${VPC_DB}" --enable-dns-support "{\"Value\":true}"

aws ec2 create-tags --resources "${VPC_DB}" --region "${AWS_REGION}" --tags "${_QUAY_AWS_TAG_PAIRS[@]}"

export VPC_DB_CIDR=$(aws ec2 describe-vpcs --vpc-ids "${VPC_DB}" --region "${AWS_REGION}" \
  --query 'Vpcs[0].CidrBlock' --output text)

SUBNET_A=$(aws ec2 create-subnet --vpc-id "${VPC_DB}" --cidr-block 10.23.1.0/24 \
  --availability-zone "${AWS_REGION}a" --region "${AWS_REGION}" | jq -r .Subnet.SubnetId)
SUBNET_B=$(aws ec2 create-subnet --vpc-id "${VPC_DB}" --cidr-block 10.23.2.0/24 \
  --availability-zone "${AWS_REGION}b" --region "${AWS_REGION}" | jq -r .Subnet.SubnetId)
SUBNET_C=$(aws ec2 create-subnet --vpc-id "${VPC_DB}" --cidr-block 10.23.3.0/24 \
  --availability-zone "${AWS_REGION}c" --region "${AWS_REGION}" | jq -r .Subnet.SubnetId)

aws ec2 create-tags --resources "${SUBNET_A}" "${SUBNET_B}" "${SUBNET_C}" --region "${AWS_REGION}" \
  --tags "${_QUAY_AWS_TAG_PAIRS[@]}"

echo "VPC_DB=${VPC_DB} VPC_DB_CIDR=${VPC_DB_CIDR}"
```

### 3.2 VPC peering (ROSA VPC ↔ database VPC)

Run **after** §1.4 and §3.1 so `VPC_ROSA`, `ROSA_VPC_CIDR`, `VPC_DB`, and `VPC_DB_CIDR` are set.

1. **Create and accept** the peering connection (same AWS account):

   ```bash
   mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)

   export VPC_PEERING_ID=$(aws ec2 create-vpc-peering-connection \
     --vpc-id "${VPC_ROSA}" \
     --peer-vpc-id "${VPC_DB}" \
     --region "${AWS_REGION}" \
     --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)

   aws ec2 create-tags --resources "${VPC_PEERING_ID}" --region "${AWS_REGION}" \
     --tags "${_QUAY_AWS_TAG_PAIRS[@]}"

   aws ec2 accept-vpc-peering-connection \
     --vpc-peering-connection-id "${VPC_PEERING_ID}" \
     --region "${AWS_REGION}" \
     --query 'VpcPeeringConnection.Status.Code' --output text
   ```

2. **Optional — DNS across the peering** (helps resolve RDS/ElastiCache endpoints from the cluster):

   ```bash
   aws ec2 modify-vpc-peering-connection-options \
     --vpc-peering-connection-id "${VPC_PEERING_ID}" \
     --requester-peering-connection-options '{"AllowDnsResolutionFromRemoteVpc":true}' \
     --accepter-peering-connection-options '{"AllowDnsResolutionFromRemoteVpc":true}' \
     --region "${AWS_REGION}"
   ```

3. **Routes** — add a route to **`VPC_DB`** in **every** route table used by the **ROSA** VPC (private subnets, worker subnets), and a route to **`ROSA_VPC_CIDR`** in **every** route table in **`VPC_DB`**. Use **replace** with your route table IDs if you manage them explicitly; this loop targets all route tables in each VPC:

   ```bash
   for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ROSA}" \
     --region "${AWS_REGION}" --query 'RouteTables[*].RouteTableId' --output text); do
     aws ec2 create-route --route-table-id "${RT}" \
       --destination-cidr-block "${VPC_DB_CIDR}" \
       --vpc-peering-connection-id "${VPC_PEERING_ID}" \
       --region "${AWS_REGION}" 2>/dev/null || true
   done

   for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_DB}" \
     --region "${AWS_REGION}" --query 'RouteTables[*].RouteTableId' --output text); do
     aws ec2 create-route --route-table-id "${RT}" \
       --destination-cidr-block "${ROSA_VPC_CIDR}" \
       --vpc-peering-connection-id "${VPC_PEERING_ID}" \
       --region "${AWS_REGION}" 2>/dev/null || true
   done
   ```

   If a route already exists, `create-route` may fail—ignore or use `delete-route` + `create-route` to update.

4. Wait until the peering status is **`active`** (poll until `Status.Code` is `active`):

   ```bash
   until [[ "$(aws ec2 describe-vpc-peering-connections \
     --vpc-peering-connection-ids "${VPC_PEERING_ID}" \
     --region "${AWS_REGION}" \
     --query 'VpcPeeringConnections[0].Status.Code' --output text)" == "active" ]]; do
     sleep 5
   done
   ```

{{% alert state="info" %}}**Transit Gateway:** For large or hub-and-spoke networks, use **TGW** attachments instead of peering; the security group rules below still apply using **`${ROSA_VPC_CIDR}`** (or the CIDR of the attachment that carries ROSA traffic).{{% /alert %}}

### 3.3 RDS subnet group

```bash
mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)

aws rds create-db-subnet-group \
  --db-subnet-group-name "db-group-${CLUSTER_NAME}" \
  --db-subnet-group-description "Quay RDS subnet group" \
  --subnet-ids "${SUBNET_A}" "${SUBNET_B}" "${SUBNET_C}" \
  --region "${AWS_REGION}" \
  --tags "${_QUAY_AWS_TAG_PAIRS[@]}"
```

### 3.4 Create RDS PostgreSQL

Private RDS **without** a public IP (reachable from ROSA over the peering):

```bash
mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)

RDS_DB="$(aws rds create-db-instance \
  --db-instance-identifier "psql-${CLUSTER_NAME}" \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --master-user-password "${PSQL_PASSWORD}" \
  --allocated-storage 20 \
  --master-username postgres \
  --region "${AWS_REGION}" \
  --db-subnet-group-name "db-group-${CLUSTER_NAME}" \
  --enable-iam-database-authentication \
  --no-publicly-accessible \
  --tags "${_QUAY_AWS_TAG_PAIRS[@]}" \
  | jq -c '.DBInstance | {DbiResourceId, VpcSecurityGroups: .VpcSecurityGroups[0].VpcSecurityGroupId}')"
echo "${RDS_DB}"
```

Wait until the instance is **available**:

```bash
aws rds wait db-instance-available --db-instance-identifier "psql-${CLUSTER_NAME}" --region "${AWS_REGION}"
```

### 3.5 Allow ROSA to reach RDS

Allow **TCP 5432** from the **ROSA VPC CIDR** (private traffic over the peering / TGW):

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$(echo "${RDS_DB}" | jq -r .VpcSecurityGroups)" \
  --protocol tcp \
  --port 5432 \
  --cidr "${ROSA_VPC_CIDR}" \
  --region "${AWS_REGION}"
```

For tighter security, use a **worker subnet CIDR** or **security group** reference instead of the whole VPC CIDR.

### 3.6 ElastiCache subnet group and security group

```bash
mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)

aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name "quay-redis-${CLUSTER_NAME}" \
  --cache-subnet-group-description "Quay Redis" \
  --subnet-ids "${SUBNET_A}" "${SUBNET_B}" "${SUBNET_C}" \
  --region "${AWS_REGION}" \
  --tags "${_QUAY_AWS_TAG_PAIRS[@]}"

REDIS_SG=$(aws ec2 create-security-group \
  --group-name "quay-redis-${CLUSTER_NAME}" \
  --description "Quay ElastiCache" \
  --vpc-id "${VPC_DB}" \
  --region "${AWS_REGION}" \
  --query GroupId --output text)

aws ec2 create-tags --resources "${REDIS_SG}" --region "${AWS_REGION}" --tags "${_QUAY_AWS_TAG_PAIRS[@]}"

aws ec2 authorize-security-group-ingress \
  --group-id "${REDIS_SG}" \
  --protocol tcp \
  --port 6379 \
  --cidr "${ROSA_VPC_CIDR}" \
  --region "${AWS_REGION}"
```

{{% alert state="info" %}}From a pod in `${QUAY_NAMESPACE}`, verify **`nc -vz "${REDIS_ENDPOINT}" 6379`** or **`redis-cli`** to confirm the path before relying on Quay.{{% /alert %}}

### 3.7 Create Redis cluster

Single-node example (adjust node type for production). Leave `REDIS_AUTH_TOKEN` unset for the simplest path; enabling `AUTH` often requires **transit encryption** on the replication group—see [ElastiCache in-transit encryption](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/in-transit-encryption.html).

```bash
mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)

EARGS=(--cache-cluster-id "quay-redis-${CLUSTER_NAME}" --engine redis --cache-node-type cache.t4g.micro \
  --num-cache-nodes 1 --cache-subnet-group-name "quay-redis-${CLUSTER_NAME}" \
  --security-group-ids "${REDIS_SG}" --region "${AWS_REGION}" \
  --tags "${_QUAY_AWS_TAG_PAIRS[@]}")
if [[ -n "${REDIS_AUTH_TOKEN}" ]]; then
  EARGS+=(--auth-token "${REDIS_AUTH_TOKEN}")
fi
aws elasticache create-cache-cluster "${EARGS[@]}"

aws elasticache wait cache-cluster-available --cache-cluster-id "quay-redis-${CLUSTER_NAME}" --region "${AWS_REGION}"
```

### 3.8 Endpoints

```bash
export DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "psql-${CLUSTER_NAME}" \
  --query 'DBInstances[0].Endpoint.Address' --output text --region "${AWS_REGION}")

export REDIS_ENDPOINT=$(aws elasticache describe-cache-clusters \
  --cache-cluster-id "quay-redis-${CLUSTER_NAME}" \
  --show-cache-node-info \
  --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' \
  --output text --region "${AWS_REGION}")

echo "DB_ENDPOINT=${DB_ENDPOINT} REDIS_ENDPOINT=${REDIS_ENDPOINT}"
```

### 3.9 Tags applied (end of AWS provisioning)

This guide tags the following resources with **`QUAY_AWS_TAGS_MERGED`** (**§1.2**) using **§1.3** helpers and the **`mapfile` / `--tags`** calls above:

| AWS resource | Mechanism |
|--------------|-----------|
| S3 bucket | **`aws s3api put-bucket-tagging`** (**§2**) |
| **`VPC_DB`**, subnets **`SUBNET_A`–`C`**, VPC peering **`VPC_PEERING_ID`** | **`aws ec2 create-tags`** (**§3.1**, **§3.2**) |
| Redis security group **`REDIS_SG`** | **`aws ec2 create-tags`** (**§3.6**) |
| RDS subnet group, RDS instance **`psql-${CLUSTER_NAME}`** | **`--tags`** on create (**§3.3**, **§3.4**) |
| ElastiCache subnet group, Redis **`quay-redis-${CLUSTER_NAME}`** | **`--tags`** on create (**§3.6**, **§3.7**) |
| IAM policy **`${CLUSTER_NAME}-quay-s3-policy`**, IRSA role **`${CLUSTER_NAME}-quay-irsa`** | **`--tags`** on create (**§5.1**, **§5.3**) |

The RDS instance **default VPC security group** in **`VPC_DB`** is not tagged by this guide (only the ingress rule in §3.5 is added).

---

## 4. Prepare PostgreSQL for Quay

Create a dedicated database user and database for Quay, and enable extensions required by Red Hat Quay ([external PostgreSQL](https://docs.redhat.com/en/documentation/red_hat_quay/3.16/html/deploying_the_red_hat_quay_operator_on_openshift_container_platform/using-an-external-postgresql-database)).

1. Generate a password for the Quay DB user and keep it for §7 (`DB_URI`). Use **hex** (same rule as §1.5—avoid `/`, `@`, `"`, and space for consistency and safe `DB_URI`):

   ```bash
   export QUAY_DB_PASSWORD=$(openssl rand -hex 24)
   echo "Save QUAY_DB_PASSWORD securely for config.yaml (DB_URI)."
   ```

2. Run a short-lived client pod on the cluster:

   ```bash
   oc run -it --rm quay-prep-db --restart=Never \
     --image=registry.redhat.io/rhel8/postgresql-15 \
     --env="PGPASSWORD=${PSQL_PASSWORD}" \
     --env="DB_ENDPOINT=${DB_ENDPOINT}" \
     -- /bin/bash
   ```

3. Inside the pod, connect as the RDS master user (`postgres`):

   ```bash
   psql -h "$DB_ENDPOINT" -U postgres -d postgres
   ```

4. In `psql`, run (replace `quay` if you changed `QUAY_DB_USER` / `QUAY_DB_NAME`). Use the same password as `QUAY_DB_PASSWORD` on your workstation—you can `echo` it in another terminal and paste it into the SQL.

   Create the user, then create the database **without** `OWNER` (owned by `postgres` initially), then **`ALTER DATABASE … OWNER TO`**:

   ```sql
   CREATE USER quay WITH PASSWORD 'paste-QUAY_DB_PASSWORD-here';
   CREATE DATABASE quay;
   ALTER DATABASE quay OWNER TO quay;
   \c quay
   CREATE EXTENSION IF NOT EXISTS pg_trgm;
   CREATE EXTENSION IF NOT EXISTS citext;
   \q
   ```

   {{% alert state="info" %}}**Why not `CREATE DATABASE quay OWNER quay`?** PostgreSQL only allows that if the session user is a **superuser** or can **`SET ROLE`** to the owner role ([`CREATE DATABASE`](https://www.postgresql.org/docs/current/sql-createdatabase.html)). On **Amazon RDS**, the master user is not always equivalent to a true superuser for this check, so you may see **`ERROR: must be able to SET ROLE "quay"`**. Creating the database first (default owner `postgres`), then **`ALTER DATABASE quay OWNER TO quay`**, avoids that.{{% /alert %}}

5. `exit` the pod shell.

{{% alert state="info" %}}Hex passwords (`openssl rand -hex`) avoid `@`, `:`, `#`, and `%` in `DB_URI`. If you choose a different password, URL-encode it for `DB_URI` when needed.{{% /alert %}}

---

## 5. IAM role for Quay (S3 via IRSA / STSS3Storage)

The Quay application pod uses **AWS credentials from the service account** (IRSA). You need:

1. An **identity-based IAM policy** attached to the Quay IRSA role (§5.1–5.3).
2. A **resource-based S3 bucket policy** on the registry bucket that allows that same IAM role as `Principal` (§5.4).

Red Hat documents this combination in [S3 IAM bucket policy for Quay Enterprise (Solution 3680151)](https://access.redhat.com/solutions/3680151), which addresses errors such as `Invalid storage configuration`, `S3ResponseError: 403 Forbidden`, and related S3 access failures when Quay uses IAM roles for storage.

### 5.1 S3 policy document

```bash
cat <<EOF > "${SCRATCH_DIR}/quay-s3-policy.json"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket",
        "s3:GetBucketLocation", "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::${QUAY_S3_BUCKET}",
        "arn:aws:s3:::${QUAY_S3_BUCKET}/*"
      ]
    }
  ]
}
EOF

mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)

S3_POLICY_ARN=$(aws iam create-policy \
  --policy-name "${CLUSTER_NAME}-quay-s3-policy" \
  --policy-document "file://${SCRATCH_DIR}/quay-s3-policy.json" \
  --tags "${_QUAY_AWS_TAG_PAIRS[@]}" \
  --query Policy.Arn --output text)
echo "S3_POLICY_ARN=${S3_POLICY_ARN}"
```

### 5.2 Trust policy (OIDC → Quay service account)

```bash
cat <<EOF > "${SCRATCH_DIR}/quay-trust-policy.json"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${QUAY_NAMESPACE}:${QUAY_APP_SA}",
          "${OIDC_PROVIDER}:aud": "openshift"
        }
      }
    }
  ]
}
EOF
```

{{% alert state="info" %}}Some clusters use a different **audience** for bound tokens. If Quay pods fail to assume the role, check [AWS STS with ROSA](https://docs.openshift.com/rosa/security/iam-sts-role-token.html) and align `:aud` with your token configuration.{{% /alert %}}

### 5.3 Create role and attach S3 policy

```bash
QUAY_IRSA_ROLE_NAME="${CLUSTER_NAME}-quay-irsa"
mapfile -t _QUAY_AWS_TAG_PAIRS < <(quay_aws_tags_to_cli_pairs)

export QUAY_IRSA_ROLE_ARN=$(aws iam create-role \
  --role-name "${QUAY_IRSA_ROLE_NAME}" \
  --assume-role-policy-document "file://${SCRATCH_DIR}/quay-trust-policy.json" \
  --tags "${_QUAY_AWS_TAG_PAIRS[@]}" \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name "${QUAY_IRSA_ROLE_NAME}" \
  --policy-arn "${S3_POLICY_ARN}"

echo "QUAY_IRSA_ROLE_ARN=${QUAY_IRSA_ROLE_ARN}"
```

### 5.4 S3 bucket policy (resource-based)

Apply a bucket policy that allows the **Quay IRSA role ARN** to access the bucket. This follows the pattern in [S3 IAM bucket policy for Quay Enterprise (Solution 3680151)](https://access.redhat.com/solutions/3680151): set `Principal.AWS` to the role Quay assumes (the same `QUAY_IRSA_ROLE_ARN` from §5.3).

```bash
cat <<EOF > "${SCRATCH_DIR}/quay-s3-bucket-policy.json"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowQuayIAMRoleBucketAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${QUAY_IRSA_ROLE_ARN}"
      },
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": [
        "arn:aws:s3:::${QUAY_S3_BUCKET}",
        "arn:aws:s3:::${QUAY_S3_BUCKET}/*"
      ]
    }
  ]
}
EOF

aws s3api put-bucket-policy \
  --bucket "${QUAY_S3_BUCKET}" \
  --policy "file://${SCRATCH_DIR}/quay-s3-bucket-policy.json" \
  --region "${AWS_REGION}"
```

{{% alert state="info" %}}You must create the **IAM role first** (§5.3) so `${QUAY_IRSA_ROLE_ARN}` is known. If your organization uses [SCPs](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html) or [S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html) defaults, ensure they do not deny this role’s access to the bucket.{{% /alert %}}

---

## 6. Install the Red Hat Quay Operator (CLI)

This guide installs the operator in **`openshift-operators`** with an **AllNamespaces** `OperatorGroup` (the default global pattern on OpenShift). That mode is required for **operator-managed monitoring** on the `QuayRegistry` ([operator reconcile](https://github.com/quay/quay-operator/blob/master/controllers/quay/quayregistry_controller.go)). Use **`channel: stable-3.16`** as below; confirm the channel exists with `oc get packagemanifest quay-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}{"\n"}'`.

{{% alert state="warning" %}}Do **not** create a second `Subscription` for `quay-operator` in **`${QUAY_NAMESPACE}`**—only the subscription in **`openshift-operators`** applies for this guide.{{% /alert %}}

### 6.1 Ensure a global OperatorGroup exists

Default OpenShift clusters already have an AllNamespaces group in **`openshift-operators`**:

```bash
oc get operatorgroup -n openshift-operators
```

You should see a group whose `spec` is empty or has no `targetNamespaces` (AllNamespaces). If your cluster has no such group, create one (adjust the name if it conflicts):

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: global-operators-quay
  namespace: openshift-operators
spec: {}
EOF
```

{{% alert state="warning" %}}Do not create a second global `OperatorGroup` in `openshift-operators` if one already exists; OpenShift allows only one AllNamespaces group per namespace. Use the existing group.{{% /alert %}}

### 6.2 Create the Quay registry namespace

For `QuayRegistry`, secrets, and workloads (same as the rest of this guide):

```bash
oc new-project "${QUAY_NAMESPACE}" 2>/dev/null || oc project "${QUAY_NAMESPACE}"
```

### 6.3 Subscribe in `openshift-operators`

Install the Red Hat Quay Operator from **`openshift-operators`** (not from **`${QUAY_NAMESPACE}`**):

```bash
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: openshift-operators
spec:
  channel: stable-3.16
  installPlanApproval: Automatic
  name: quay-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 6.4 Wait for the CSV

```bash
oc get csv -n openshift-operators -w
```

Stop when the **Red Hat Quay** CSV shows **Succeeded**.

### 6.5 Confirm the operator deployment

Name/version may differ:

```bash
oc get deploy -n openshift-operators | grep quay
```

---

## 7. Build `config.yaml` and secrets

Set `DB_URI` (URL-encode special characters in the password if needed). Example:

```bash
# Use the same password you set for the quay DB user (QUAY_DB_PASSWORD)
export QUAY_DB_PASSWORD="${QUAY_DB_PASSWORD:?set QUAY_DB_PASSWORD}"

cat <<EOF > "${SCRATCH_DIR}/config.yaml"
ALLOW_PULLS_WITHOUT_STRICT_LOGGING: false
AUTHENTICATION_TYPE: Database
DEFAULT_TAG_EXPIRATION: 2w
FEATURE_USER_INITIALIZE: true
SUPER_USERS:
  - quayadmin
BROWSER_API_CALLS_XHR_ONLY: false
FEATURE_USER_CREATION: false
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - STSS3Storage
    - storage_path: /datastorage/registry
      s3_bucket: ${QUAY_S3_BUCKET}
      s3_region: ${AWS_REGION}
DB_URI: postgresql://${QUAY_DB_USER}:${QUAY_DB_PASSWORD}@${DB_ENDPOINT}:5432/${QUAY_DB_NAME}
DB_CONNECTION_ARGS:
  sslmode: require
BUILDLOGS_REDIS:
  host: ${REDIS_ENDPOINT}
  port: 6379
  ssl: false
USER_EVENTS_REDIS:
  host: ${REDIS_ENDPOINT}
  port: 6379
  ssl: false
EOF
```

{{% alert state="warning" %}}**RDS and TLS:** Keep **`DB_CONNECTION_ARGS: sslmode: require`** for Amazon RDS. Without it, connections can fail with **`no pg_hba.conf entry … no encryption`**, including on the **`${QUAY_REGISTRY_NAME}-quay-app-upgrade-*`** migration pods.{{% /alert %}}

If you enabled **Redis AUTH**, add `password: ...` under both `BUILDLOGS_REDIS` and `USER_EVENTS_REDIS` (use the same token as `REDIS_AUTH_TOKEN`).

Create the config bundle secret:

```bash
oc create secret generic quay-config-bundle-secret \
  --from-file=config.yaml="${SCRATCH_DIR}/config.yaml" \
  -n "${QUAY_NAMESPACE}" \
  --dry-run=client -o yaml | oc apply -f -
```

Remove `config.yaml` from shared machines after applying, or create the secret without writing a world-readable file (e.g. process substitution) per your security policy.

---

## 8. Create the QuayRegistry

After **§6** (AllNamespaces operator install), set **`monitoring: managed: true`** so the operator can create `ServiceMonitor` resources and related monitoring integration (requires [User Workload Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/enabling-monitoring-for-user-defined-projects.html) or equivalent, per Red Hat Quay documentation).

```bash
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: ${QUAY_REGISTRY_NAME}
  namespace: ${QUAY_NAMESPACE}
spec:
  configBundleSecret: quay-config-bundle-secret
  components:
    - kind: clair
      managed: true
    - kind: postgres
      managed: false
    - kind: objectstorage
      managed: false
    - kind: redis
      managed: false
    - kind: mirror
      managed: true
    - kind: monitoring
      managed: true
    - kind: route
      managed: true
    - kind: tls
      managed: true
    - kind: quay
      managed: true
    - kind: horizontalpodautoscaler
      managed: true
    - kind: clairpostgres
      managed: true
EOF
```

{{% alert state="info" %}}**Monitoring:** **`monitoring: managed: true`** only works when the Quay operator runs in **AllNamespaces** mode (**§6**). If you see **`RolloutBlocked`** / **`MonitoringComponentDependencyError`**, confirm the operator **`Subscription`** is only in **`openshift-operators`** and the CSV is **Succeeded**.{{% /alert %}}

---

## 9. Annotate the Quay app service account (IRSA)

After the operator creates the Quay deployment, confirm the service account name:

```bash
oc get sa -n "${QUAY_NAMESPACE}"
```

Annotate the **Quay application** service account (usually `${QUAY_REGISTRY_NAME}-quay-app`):

```bash
oc annotate serviceaccount "${QUAY_APP_SA}" -n "${QUAY_NAMESPACE}" \
  eks.amazonaws.com/role-arn="${QUAY_IRSA_ROLE_ARN}" --overwrite
```

Restart Quay app pods so they pick up the annotation:

```bash
oc get deploy -n "${QUAY_NAMESPACE}"
# Restart the Quay application deployment (name often contains "quay" and "app"), for example:
# oc rollout restart deployment "${QUAY_REGISTRY_NAME}-quay-app" -n "${QUAY_NAMESPACE}"
```

If the trust policy `sub` does not match the actual SA, edit `quay-trust-policy.json`, run `aws iam update-assume-role-policy`, then verify again.

---

## 10. Verification

```bash
oc describe quayregistry "${QUAY_REGISTRY_NAME}" -n "${QUAY_NAMESPACE}"
```

Look for **ComponentsCreationSuccess** in Events.

```bash
oc get pods -n "${QUAY_NAMESPACE}"
```

Retrieve the registry route:

```bash
oc get route -n "${QUAY_NAMESPACE}"
```

Optional: push an image to confirm S3 and the full stack.

---

## 11. Create the first user (API)

With `FEATURE_USER_INITIALIZE: true` and `SUPER_USERS` set in `config.yaml`, use the Red Hat procedure:

[Using the API to create the first user](https://docs.redhat.com/en/documentation/red_hat_quay/3.16/html/deploying_the_red_hat_quay_operator_on_openshift_container_platform/using-the-api-to-create-the-first-user)

Example (replace host and payload per the documentation):

```bash
QUAY_HOST=$(oc get route -n "${QUAY_NAMESPACE}" -o jsonpath='{.items[0].spec.host}')
curl -k -X POST "https://${QUAY_HOST}/api/v1/user/initialize" \
  -H "Content-Type: application/json" \
  -d '{"username":"quayadmin","password":"<secure-password>","email":"quayadmin@example.com","access_token":"..."}'
```

Follow the official doc for the exact JSON and token fields required by your Quay version.

---

## 12. Cleanup (optional)

Remove OpenShift resources:

```bash
oc delete quayregistry "${QUAY_REGISTRY_NAME}" -n "${QUAY_NAMESPACE}"
oc delete subscription quay-operator -n openshift-operators 2>/dev/null || true
oc delete project "${QUAY_NAMESPACE}"
```

Do not delete the default global `OperatorGroup` in `openshift-operators` unless your cluster policy allows it.

### 12.1 AWS cleanup (CLI)

Use the **same** `AWS_REGION`, `CLUSTER_NAME`, `QUAY_S3_BUCKET`, and `VPC_DB` values as when you created resources (re-export from §1–§3 if needed). Set **`AWS_ACCOUNT_ID`** if unset: `export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`. **Do not** delete the **ROSA** VPC (`VPC_ROSA`); only tear down **`VPC_DB`** and resources this guide created.

{{% alert state="warning" %}}**Data loss:** The examples below use **`--skip-final-snapshot`** for RDS and delete S3 objects. For production, take a **final RDS snapshot** and confirm backups before deleting anything.{{% /alert %}}

**1. S3 — remove objects and the bucket** (bucket policy is removed with the bucket):

```bash
aws s3 rb "s3://${QUAY_S3_BUCKET}" --force --region "${AWS_REGION}"
```

**2. IAM — detach the policy, delete the role, delete the customer managed policy**

Policy and role names match §5.1 and §5.3 (`${CLUSTER_NAME}-quay-s3-policy`, `${CLUSTER_NAME}-quay-irsa`):

```bash
export QUAY_IRSA_ROLE_NAME="${CLUSTER_NAME}-quay-irsa"
export S3_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CLUSTER_NAME}-quay-s3-policy"

aws iam detach-role-policy \
  --role-name "${QUAY_IRSA_ROLE_NAME}" \
  --policy-arn "${S3_POLICY_ARN}"

aws iam delete-role --role-name "${QUAY_IRSA_ROLE_NAME}"

aws iam delete-policy --policy-arn "${S3_POLICY_ARN}"
```

If `delete-policy` fails because another principal still references the policy, list attachments with `aws iam list-entities-for-policy --policy-arn "${S3_POLICY_ARN}"` and detach them first.

**3. ElastiCache — delete the cluster, then the subnet group**

```bash
aws elasticache delete-cache-cluster \
  --cache-cluster-id "quay-redis-${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

aws elasticache wait cache-cluster-deleted \
  --cache-cluster-id "quay-redis-${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

aws elasticache delete-cache-subnet-group \
  --cache-subnet-group-name "quay-redis-${CLUSTER_NAME}" \
  --region "${AWS_REGION}"
```

**4. RDS — delete the instance, then the DB subnet group**

```bash
aws rds delete-db-instance \
  --db-instance-identifier "psql-${CLUSTER_NAME}" \
  --skip-final-snapshot \
  --region "${AWS_REGION}"

aws rds wait db-instance-deleted \
  --db-instance-identifier "psql-${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

aws rds delete-db-subnet-group \
  --db-subnet-group-name "db-group-${CLUSTER_NAME}" \
  --region "${AWS_REGION}"
```

To retain a snapshot instead of `--skip-final-snapshot`, use **`--final-db-snapshot-identifier`** per [delete-db-instance](https://docs.aws.amazon.com/cli/latest/reference/rds/delete-db-instance.html).

**5. VPC peering — delete the connection** (saves `VPC_PEERING_ID` from §3.2, or discover it)

```bash
# If you still have VPC_PEERING_ID from §3.2:
# aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id "${VPC_PEERING_ID}" --region "${AWS_REGION}"

# Otherwise, find the peering created in §3.2 (ROSA = requester, DB VPC = accepter):
export VPC_PEERING_ID=$(aws ec2 describe-vpc-peering-connections \
  --region "${AWS_REGION}" \
  --filters "Name=requester-vpc-info.vpc-id,Values=${VPC_ROSA}" \
            "Name=accepter-vpc-info.vpc-id,Values=${VPC_DB}" \
  --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' \
  --output text)

aws ec2 delete-vpc-peering-connection \
  --vpc-peering-connection-id "${VPC_PEERING_ID}" \
  --region "${AWS_REGION}"
```

If **`VPC_PEERING_ID`** is `None`, swap **requester** / **accepter** filters (or list all peerings for **`${VPC_DB}`** and pick the correct ID).

**6. Security groups — delete the Redis SG** (optional: revoke RDS ingress you added)

The Redis security group name is **`quay-redis-${CLUSTER_NAME}`**. If RDS used the **default** security group for `VPC_DB`, revoke the rule you added in §3.5 instead of deleting that group:

```bash
REDIS_SG=$(aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_DB}" "Name=group-name,Values=quay-redis-${CLUSTER_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text)

aws ec2 delete-security-group --group-id "${REDIS_SG}" --region "${AWS_REGION}" || true

# Optional — revoke §3.5 Postgres ingress from the RDS instance security group (replace SG id if known):
# aws ec2 revoke-security-group-ingress --group-id "${RDS_SG}" --protocol tcp --port 5432 \
#   --cidr "${ROSA_VPC_CIDR}" --region "${AWS_REGION}"
```

**7. Subnets and VPC — delete subnets, then `VPC_DB`**

Use the subnet IDs from §3.1 (`SUBNET_A`, `SUBNET_B`, `SUBNET_C`), or list them:

```bash
for SID in $(aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_DB}" \
  --query 'Subnets[*].SubnetId' --output text); do
  aws ec2 delete-subnet --subnet-id "${SID}" --region "${AWS_REGION}"
done

aws ec2 delete-vpc --vpc-id "${VPC_DB}" --region "${AWS_REGION}"
```

If subnet delete fails, dependencies remain (ENIs, load balancers, etc.); resolve those in the VPC console or with `describe-network-interfaces --filters Name=subnet-id,Values=...`.

**Suggested order summary**

1. OpenShift resources (above).  
2. S3 bucket (**12.1** step 1).  
3. IAM role and policy (step 2).  
4. ElastiCache (step 3).  
5. RDS (step 4).  
6. VPC peering (step 5).  
7. Security groups (step 6).  
8. Subnets and **`VPC_DB`** (step 7).

---

## 13. Troubleshooting

* [Troubleshooting the QuayRegistry CR](https://docs.redhat.com/en/documentation/red_hat_quay/3.16/html/deploying_the_red_hat_quay_operator_on_openshift_container_platform/troubleshooting-the-quayregistry-cr)
* **IRSA / S3 `403 Forbidden` or invalid storage configuration:** Confirm the **IAM role policy** (§5.1) and the **S3 bucket policy** (§5.4) both allow the Quay IRSA role for `arn:aws:s3:::${QUAY_S3_BUCKET}` and `arn:aws:s3:::${QUAY_S3_BUCKET}/*`. See [S3 IAM bucket policy for Quay Enterprise (Solution 3680151)](https://access.redhat.com/solutions/3680151). Verify `eks.amazonaws.com/role-arn` on the Quay app SA, trust policy `sub` and `aud`, and that `Principal.AWS` in the bucket policy matches `QUAY_IRSA_ROLE_ARN` exactly.
* **Database connection errors:** Verify **VPC peering** (§3.2) routes and security group allows **5432** from **`${ROSA_VPC_CIDR}`** (§3.5), `DB_URI` credentials, and `sslmode` (often `require` for RDS).
* **`example-registry-quay-app-upgrade-*` pod `CrashLoopBackOff` / `psycopg2.OperationalError`:** The **upgrade** (migration) `Job` uses the same `configBundleSecret` as the registry. Two common RDS issues show up together in logs:
  * **`FATAL: no pg_hba.conf entry for host "…", user "quay", database "quay", no encryption`** — The client connected **without TLS**. Amazon RDS for PostgreSQL expects SSL; keep **`DB_CONNECTION_ARGS`** with **`sslmode: require`** (see §7). If that block is missing or the secret was created before you added it, update `config.yaml`, re-create the config bundle secret, and let the operator reconcile (or delete the failed upgrade `Job` so it is recreated). With `force_ssl` enabled on the instance, non-SSL attempts are rejected and `pg_hba` can report **no encryption**.
  * **`FATAL: password authentication failed for user "quay"`** — The password in **`DB_URI`** does not match the **`quay`** role in PostgreSQL (typo when pasting in §4, different `QUAY_DB_PASSWORD` than used in `CREATE USER`, or shell/`heredoc` altered the password). Reset with `ALTER USER quay WITH PASSWORD '...';` in `psql`, then set the same value in `DB_URI`, re-apply the secret, and fix the `Job`.
  * Ensure **private** connectivity from the ROSA VPC to **`VPC_DB`** (§3.2) and that the RDS security group allows **`${ROSA_VPC_CIDR}`** on **5432** (§3.5).
* **`CREATE DATABASE quay OWNER quay` → `ERROR: must be able to SET ROLE "quay"`:** Use **`CREATE DATABASE quay;`** then **`ALTER DATABASE quay OWNER TO quay;`** as in §4 (RDS master user is not always treated like a full superuser for the single-step `OWNER` clause).
* **Redis / `BUILDLOGS_REDIS` … `context deadline exceeded`:** The client **timed out** connecting to Redis (wrong host/port, missing **§3.2** routes, or SG). Confirm **VPC peering** (or TGW) and **`${ROSA_VPC_CIDR}`** on **TCP 6379** (§3.6). Confirm **`host`** in `BUILDLOGS_REDIS` / `USER_EVENTS_REDIS` is the **primary endpoint** from `aws elasticache describe-cache-clusters`. If you enabled **Redis AUTH**, set **`password`** in both Redis blocks. If you enabled **in-transit encryption**, set **`ssl: true`** in config and follow [ElastiCache in-transit encryption](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/in-transit-encryption.html) (port is still typically **6379** for the cluster endpoint).
* **`RolloutBlocked` / `MonitoringComponentDependencyError` (*Monitoring is only supported in AllNamespaces mode*):** Confirm **§6**—the **`quay-operator`** `Subscription` must be in **`openshift-operators`** with a **Succeeded** CSV, and **`monitoring: managed: true`** in **§8** must match that install mode. Reapply the `QuayRegistry` after fixing the operator install.
