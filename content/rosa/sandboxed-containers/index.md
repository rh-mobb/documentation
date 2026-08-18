---
date: '2026-08-17'
title: OpenShift sandboxed containers on ROSA HCP
tags: ["ROSA HCP"]
authors:
  - Paul Czarkowski
validated_version: "4.20"
---

This guide shows how to install OpenShift sandboxed containers (OSC) **1.13.1** on an existing Red Hat OpenShift Service on AWS (ROSA) cluster with hosted control planes (HCP) and STS. Use the `rosa`, `oc`, `aws`, and `jq` CLIs. If you need to create a cluster, see [Deploying a ROSA HCP cluster with Terraform](/experts/rosa/terraform/hcp/).

The flow in this guide covers:

* creating an IAM Roles for Service Accounts (IRSA) role for OSC
* installing the Operator with `ROLEARN` and a Manual InstallPlan
* opening worker security group ports for peer pods
* creating `peer-pods-cm` and a `KataConfig`
* running a `kata-remote` sample workload (validates peer pods when metal is not available)
* adding a metal machine pool for local `kata` (preferred for sandboxed workloads)
* cleaning up Operator, AWS, and IAM resources

This guide was validated on ROSA HCP 4.20.32 in `ap-southeast-2` with default `m5.xlarge` workers (peer pods) and an optional `c5n.metal` machine pool (local Kata).

{{% alert state="warning" header="Technology Preview" %}}
AWS STS authentication and HCP AWS peer pods are **Technology Preview** in OpenShift sandboxed containers 1.13. They are not supported with Red Hat production SLAs and might not be functionally complete. Do not use this configuration for production workloads. See [Technology Preview Features Support Scope](https://access.redhat.com/support/offerings/techpreview).
{{% /alert %}}

## About OSC on ROSA HCP

OSC adds optional `RuntimeClass` objects. On ROSA HCP, the two RuntimeClasses that matter are:

| RuntimeClass | Handler | Where the VM runs | Needs metal workers? |
|--------------|---------|-------------------|----------------------|
| `kata` | Local Kata / QEMU on the worker | Nested VM on the **worker node** | **Yes.** Needs `/dev/kvm` (Intel or AMD **bare metal**). Fails on `m5.xlarge`. |
| `kata-remote` | Cloud API Adaptor (CAA) plus a peer pod | A separate **EC2 instance** (pod VM) in the same VPC, subnet, and security group as the worker | **No.** Works on `m5.xlarge`. |

For sandboxed workloads on ROSA HCP, **prefer local `kata` on a metal machine pool**. Pods stay on ROSA workers, schedule through normal Kubernetes controls, and you can overcommit CPU and memory on the metal node like any other worker. **`kata-remote` peer pods** launch a separate EC2 instance per pod outside that model: one pod VM per workload, no cluster overcommit, and extra AWS IAM, networking, and cost outside the ROSA data plane. Use peer pods when you cannot add metal workers, or to validate the peer-pod path in a lab.

Setting `enablePeerPods: true` on `KataConfig` installs both classes (and `kata-nvidia-gpu` in 1.13). Local `kata` requires a metal machine pool. Peer pods work on standard ROSA workers but are not the preferred runtime for ongoing workloads.

ROSA HCP has no Cloud Credential Operator path for OSC. Create an IRSA role and pass `ROLEARN` on the Operator Subscription. Do not reuse one OSC IAM role across clusters. The OIDC issuer is per cluster.

## Prerequisites

* An existing ROSA HCP cluster with STS, at least one Ready worker, and `cluster-admin` access. This procedure does not apply to ROSA Classic. If you create that cluster with Terraform, run Terraform in a clean shell. Inherited `TF_VAR_*` values (cluster name, region) override module defaults and can target a cluster that is still deleting.
* OpenShift **4.18.38** or later (OSC 1.13 install prerequisite). Confirm the current OSC compatibility matrix for HCP AWS peer pods. Some matrices list a later 4.20.z than that operator prerequisite.
* Operator catalog `redhat-operators` (default on ROSA)
* `rosa` CLI, logged in (`rosa whoami`)
* `oc` CLI
* AWS CLI v2 with permission to create IAM roles and policies, plus `ec2:AuthorizeSecurityGroupIngress`, `ec2:DescribeInstances`, and `ec2:CreateTags`
* `jq`

Decide the test scope before you start:

| Goal | Extra cost | Sections |
|------|------------|----------|
| **Preferred:** local `kata` on metal | Several USD per hour for the cheapest Intel metal in the Region (for example `c5n.metal`) | Full guide through [Local Kata on Intel metal](#9-local-kata-on-intel-metal-preferred-for-workloads) |
| Peer pods only (`kata-remote`) when metal is not an option | About one `t3.medium` per running peer pod | IAM through section 8, then cleanup |

Do **not** leave a metal machine pool running after a lab test. For production sandboxed workloads, plan a dedicated metal pool and size it for expected overcommit like any other worker pool.

## 1. Verify identity and the cluster

1. Confirm CLI identity.

    ```bash
    rosa whoami
    aws sts get-caller-identity
    oc whoami
    oc whoami --show-server
    ```

1. Set the ROSA cluster name and confirm it is HCP with Ready workers.

    ```bash
    export CLUSTER="<cluster-name>"
    export AWS_PAGER=""
    export SCRATCH="/tmp/${CLUSTER}/osc"
    mkdir -p "${SCRATCH}"

    rosa describe cluster --cluster "${CLUSTER}"
    oc get nodes -L node.kubernetes.io/instance-type,hypershift.openshift.io/nodePool
    ```

1. Confirm the cluster OIDC issuer (STS).

    ```bash
    oc get authentication.config.openshift.io cluster \
      -o jsonpath='{.spec.serviceAccountIssuer}{"\n"}'
    ```

    Expect a URL such as `https://oidc.op1.openshiftapps.com/<oidc-id>`.

## 2. Create the STS IAM role

Create the role **before** you install the Operator. See [Configure an IAM role for STS authentication](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_openshift_sandboxed_containers_on_aws/install-osc-overview_aws-osc#configure-iam-role-for-sts_aws-osc).

1. Collect the account ID and OIDC provider.

    ```bash
    export ROLE_NAME="${CLUSTER}-openshift-sandboxed-containers"
    export POLICY_NAME="${CLUSTER}-OSC-ImageCreation-Policy"

    export AWS_ACCOUNT_ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

    export OIDC_PROVIDER
    OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster \
      -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')

    echo "AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}"
    echo "OIDC_PROVIDER=${OIDC_PROVIDER}"
    echo "ROLE_NAME=${ROLE_NAME}"
    ```

1. Write the trust policy.

    Official 1.13 trust is scoped to:

    * Service account: `system:serviceaccount:openshift-sandboxed-containers-operator:default`
    * Audience: `openshift`

    The Operator projects a token with audience `openshift`. Use that audience in the trust policy. If `AssumeRoleWithWebIdentity` fails, see [Troubleshooting](#troubleshooting).

    ```bash
    cat > "${SCRATCH}/osc-trust-policy.json" <<EOF
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
              "${OIDC_PROVIDER}:sub": "system:serviceaccount:openshift-sandboxed-containers-operator:default",
              "${OIDC_PROVIDER}:aud": "openshift"
            }
          }
        }
      ]
    }
    EOF
    ```

1. Create the role and attach two policies:

    * Runtime (keep): `AmazonEC2FullAccess` so CAA can create and terminate peer-pod EC2 instances. You can replace this with a tighter EC2 policy later.
    * Image build (temporary): a customer-managed policy for the `vmimport` role and `podvm-*` S3 buckets. Detach it after the AMI exists.

    ```bash
    aws iam create-role \
      --role-name "${ROLE_NAME}" \
      --assume-role-policy-document "file://${SCRATCH}/osc-trust-policy.json"

    aws iam attach-role-policy \
      --role-name "${ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

    cat > "${SCRATCH}/osc-extended-policy.json" <<EOF
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "VMImportRoleManagement",
          "Effect": "Allow",
          "Action": [
            "iam:CreateRole",
            "iam:PutRolePolicy",
            "iam:GetRole",
            "iam:ListRolePolicies",
            "iam:DeleteRole",
            "iam:DeleteRolePolicy"
          ],
          "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/vmimport"
        },
        {
          "Sid": "S3BucketManagement",
          "Effect": "Allow",
          "Action": [
            "s3:CreateBucket",
            "s3:DeleteBucket",
            "s3:GetBucketLocation",
            "s3:ListBucket",
            "s3:GetBucketAcl"
          ],
          "Resource": "arn:aws:s3:::podvm-*"
        },
        {
          "Sid": "S3ObjectManagement",
          "Effect": "Allow",
          "Action": [
            "s3:PutObject",
            "s3:GetObject",
            "s3:DeleteObject"
          ],
          "Resource": "arn:aws:s3:::podvm-*/*"
        },
        {
          "Sid": "S3ListAllBuckets",
          "Effect": "Allow",
          "Action": "s3:ListAllMyBuckets",
          "Resource": "*"
        }
      ]
    }
    EOF

    aws iam create-policy \
      --policy-name "${POLICY_NAME}" \
      --policy-document "file://${SCRATCH}/osc-extended-policy.json"

    aws iam attach-role-policy \
      --role-name "${ROLE_NAME}" \
      --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

    aws iam list-attached-role-policies --role-name "${ROLE_NAME}"

    export ROLEARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
    echo "ROLEARN=${ROLEARN}"
    ```

    Expected attached policies: `AmazonEC2FullAccess` and `${POLICY_NAME}`.

## 3. Install the Operator

1. Create the namespace and an `OwnNamespace` OperatorGroup.

    ```bash
    oc create -f - <<'EOF'
    apiVersion: v1
    kind: Namespace
    metadata:
      name: openshift-sandboxed-containers-operator
    EOF

    oc create -f - <<'EOF'
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
      name: sandboxed-containers-operator-group
      namespace: openshift-sandboxed-containers-operator
    spec:
      targetNamespaces:
      - openshift-sandboxed-containers-operator
    EOF
    ```

1. Create a Subscription that pins CSV **1.13.1**, sets `ROLEARN`, and uses **Manual** `installPlanApproval` so you can confirm permissions before CSV upgrades.

    ```bash
    oc create -f - <<EOF
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: sandboxed-containers-operator
      namespace: openshift-sandboxed-containers-operator
    spec:
      channel: stable
      name: sandboxed-containers-operator
      source: redhat-operators
      sourceNamespace: openshift-marketplace
      startingCSV: sandboxed-containers-operator.v1.13.1
      installPlanApproval: Manual
      config:
        env:
        - name: ROLEARN
          value: ${ROLEARN}
    EOF
    ```

1. Approve the InstallPlan for `sandboxed-containers-operator.v1.13.1`.

    ```bash
    oc get installplan -n openshift-sandboxed-containers-operator

    IP=$(oc get installplan -n openshift-sandboxed-containers-operator \
      -o jsonpath='{.items[0].metadata.name}')

    oc patch installplan "${IP}" -n openshift-sandboxed-containers-operator \
      --type merge -p '{"spec":{"approved":true}}'

    oc get csv -n openshift-sandboxed-containers-operator
    ```

    Wait until `PHASE` is `Succeeded` for `sandboxed-containers-operator.v1.13.1`.

1. Confirm STS wiring on the controller Deployment. `ROLEARN` should match the role you created. The Operator creates `peer-pods-secret` later, when you create the `KataConfig`. Do not share secret contents.

    ```bash
    oc get deploy controller-manager -n openshift-sandboxed-containers-operator \
      -o jsonpath='{.spec.template.spec.containers[0].env}' ; echo
    ```

## 4. Open worker security group ports 15150 and 9000

The peer-pod shim talks to the kata-agent on the EC2 VM (TCP 15150) and the tunnel (TCP 9000). Rules are self-referential on the worker security group.

{{% alert state="info" %}}
These `authorize-security-group-ingress` calls are not idempotent. A second run returns `InvalidPermission.Duplicate`. Inspect existing rules first. The following commands use `|| true` so a duplicate does not stop the loop.
{{% /alert %}}

ROSA worker security groups already include TCP/UDP 9000-9999 for internal cluster communication. Still add the exact TCP 9000 and TCP 15150 self-references from the OSC documentation. When you clean up, revoke only those extra OSC rules. Do not delete the 9000-9999 range.

1. Resolve a worker instance, region, and security groups.

    ```bash
    export INSTANCE_ID AWS_REGION
    INSTANCE_ID=$(oc get nodes -l 'node-role.kubernetes.io/worker' \
      -o jsonpath='{.items[0].spec.providerID}' | sed 's#[^ ]*/##g')

    AWS_REGION=$(oc get infrastructure/cluster \
      -o jsonpath='{.status.platformStatus.aws.region}')

    AWS_SG_IDS=($(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[*].Instances[*].SecurityGroups[*].GroupId' \
      --output text --region "${AWS_REGION}"))
    export AWS_SG_IDS

    echo "INSTANCE_ID=${INSTANCE_ID}"
    echo "AWS_REGION=${AWS_REGION}"
    echo "AWS_SG_IDS=${AWS_SG_IDS[*]}"
    ```

1. Inspect existing rules, then add the OSC self-references.

    ```bash
    for AWS_SG_ID in "${AWS_SG_IDS[@]}"; do
      aws ec2 describe-security-groups --group-ids "${AWS_SG_ID}" --region "${AWS_REGION}" \
        --query 'SecurityGroups[0].IpPermissions[?FromPort==`15150` || FromPort==`9000`]'
    done

    for AWS_SG_ID in "${AWS_SG_IDS[@]}"; do
      aws ec2 authorize-security-group-ingress --group-id "${AWS_SG_ID}" \
        --protocol tcp --port 15150 --source-group "${AWS_SG_ID}" --region "${AWS_REGION}" || true
      aws ec2 authorize-security-group-ingress --group-id "${AWS_SG_ID}" \
        --protocol tcp --port 9000 --source-group "${AWS_SG_ID}" --region "${AWS_REGION}" || true
    done
    ```

## 5. Create `peer-pods-cm`

1. Pull VPC, subnet, and security group IDs from the same worker instance CAA uses for pod VMs.

    ```bash
    AWS_SUBNET_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].SubnetId' --region "${AWS_REGION}" --output text)
    AWS_VPC_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].VpcId' --region "${AWS_REGION}" --output text)
    AWS_SG_CSV=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[*].Instances[*].SecurityGroups[*].GroupId' \
      --region "${AWS_REGION}" --output json | jq -r '.[][][]' | paste -sd "," -)

    echo "AWS_SUBNET_ID=${AWS_SUBNET_ID}"
    echo "AWS_VPC_ID=${AWS_VPC_ID}"
    echo "AWS_SG_CSV=${AWS_SG_CSV}"
    ```

1. Create the ConfigMap. Leave `PODVM_AMI_ID` empty. The Operator fills it after the image job. Do not set a placeholder AMI ID.

    `DISABLECVM: "true"` is required on AWS unless you use confidential VMs, which this guide does not cover. OSC 1.13 uses `PROXY_TIMEOUT: "8m"`.

    The OSC 1.13 pod VM AMI is imported with TPM 2.0. Do not include `t2.*` types in `PODVM_INSTANCE_TYPES`. CAA selects a type from that list based on the pod's CPU and memory requests, and `t2.small` fails with `UnsupportedOperation` (AMI TPM v2.0). Use Nitro types such as `t3.medium` and `t3.large`.

    ```bash
    oc create -f - <<EOF
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: peer-pods-cm
      namespace: openshift-sandboxed-containers-operator
    data:
      CLOUD_PROVIDER: "aws"
      VXLAN_PORT: "9000"
      PROXY_TIMEOUT: "8m"
      PODVM_INSTANCE_TYPE: "t3.medium"
      PODVM_INSTANCE_TYPES: "t3.medium,t3.large"
      PODVM_AMI_ID: ""
      AWS_REGION: "${AWS_REGION}"
      AWS_SUBNET_ID: "${AWS_SUBNET_ID}"
      AWS_VPC_ID: "${AWS_VPC_ID}"
      AWS_SG_IDS: "${AWS_SG_CSV}"
      TAGS: "purpose=osc-peerpod,cluster=${CLUSTER}"
      PEERPODS_LIMIT_PER_NODE: "10"
      ROOT_VOLUME_SIZE: "6"
      DISABLECVM: "true"
    EOF
    ```

## 6. Create KataConfig

1. Create the `KataConfig`. An empty selector applies Kata to all workers.

    ```bash
    oc create -f - <<'EOF'
    apiVersion: kataconfiguration.openshift.io/v1
    kind: KataConfig
    metadata:
      name: example-kataconfig
    spec:
      enablePeerPods: true
      logLevel: info
    EOF
    ```

    Optional: set `spec.kataConfigPoolSelector.matchLabels` to limit which workers get Kata.

1. Confirm `peer-pods-secret` now exists and `AWS_ROLE_ARN` matches `${ROLEARN}`.

    ```bash
    oc get secret peer-pods-secret -n openshift-sandboxed-containers-operator \
      -o jsonpath='{.data.AWS_ROLE_ARN}' | base64 -d ; echo
    ```

{{% alert state="warning" header="ROSA HCP does not reboot workers via MachineConfig" %}}
The OpenShift sandboxed containers documentation describes creating a `KataConfig` as a MachineConfig change that reboots workers (often 10 to 60 minutes or more). That procedure applies to self-managed OpenShift.

On ROSA HCP, MachineConfig is not available on workers. OSC installs with a DaemonSet (`osc-rpm-install`) and an rpm-ostree live layer. Workers are labeled `node-role.kubernetes.io/kata-oc=` and `kataconfiguration.openshift.io/kata-ds-rpm-install=installed`. Workers do not reboot. Do not wait for a reboot. After `KataConfig` is ready, wait for the pod VM AMI job.
{{% /alert %}}

1. Watch install progress.

    ```bash
    oc get kataconfig example-kataconfig
    ```

    Worker RPM install can finish (`COMPLETED` equals `TOTAL`) while `INPROGRESS` stays `True` because the operator is still creating the pod VM AMI. `waitingForMcoToStart` stays `false` on ROSA HCP. Do not wait for a MachineConfig reboot.

    ```bash
    oc get ds -n openshift-sandboxed-containers-operator
    ```

    Expect `osc-rpm-install` first. After the AMI exists, also expect `osc-caa-ds` (one CAA pod per `kata-oc` node) and `openshift-sandboxed-containers-monitor`.

    ```bash
    oc get runtimeclass
    oc get nodes -L node-role.kubernetes.io/kata-oc,kataconfiguration.openshift.io/kata-ds-rpm-install
    ```

    RuntimeClasses `kata` and `kata-nvidia-gpu` appear when the RPMs are installed. `kata-remote` appears after the AMI job completes.

## 7. Wait for the pod VM AMI

This job is the first end-to-end check of STS and IRSA. The job `osc-podvm-image-creation` uses IRSA to create `vmimport`, an S3 `podvm-*` bucket, and an AMI. Uploading the raw disk (about 10 GiB) and AWS snapshot conversion often takes 10 minutes or more.

1. Follow the job until `peer-pods-cm` has a real AMI ID.

    ```bash
    oc get job -n openshift-sandboxed-containers-operator
    oc logs -n openshift-sandboxed-containers-operator job/osc-podvm-image-creation -f

    oc get cm peer-pods-cm -n openshift-sandboxed-containers-operator \
      -o jsonpath='{.data.PODVM_AMI_ID}{"\n"}'
    ```

    Wait until the value is an `ami-...` ID. If the job fails with STS or audience errors, fix the IAM trust and re-run. Do not use static AWS access keys.

1. Optional: detach the image-creation policy after the AMI exists. Reattach it if you need to rebuild the AMI. Keep `AmazonEC2FullAccess` (or a tighter EC2 policy) for CAA.

    ```bash
    aws iam detach-role-policy \
      --role-name "${ROLE_NAME}" \
      --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
    ```

## 8. Test peer pods (`kata-remote`)

Use this section to validate peer pods when you cannot add metal workers, or as a lab check after OSC install. For ongoing sandboxed workloads, prefer [local Kata on Intel metal](#9-local-kata-on-intel-metal-preferred-for-workloads) so pods stay on ROSA workers and you can overcommit CPU and memory on the metal pool.

Do **not** put test workloads in the Operator namespace.

1. Create a sample pod.

    ```bash
    oc create namespace osc-test

    oc create -f - <<'EOF'
    apiVersion: v1
    kind: Pod
    metadata:
      name: osc-peer-ec2
      namespace: osc-test
    spec:
      runtimeClassName: kata-remote
      restartPolicy: Never
      containers:
      - name: pause
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
    EOF

    oc get pod osc-peer-ec2 -n osc-test -o wide
    ```

1. Verify the following:

    * Pod `Running` `1/1` (often about two to three minutes while the peer EC2 instance boots).
    * CAA launched an EC2 instance named like `podvm-osc-peer-ec2-*` (`t3.medium` unless overridden), in the same VPC, subnet, and security group as the workers.
    * The pod IP is on the cluster overlay. The peer VM has a **different** private IP in the worker subnet.

    ```bash
    oc get pod osc-peer-ec2 -n osc-test -o custom-columns=\
    NAME:.metadata.name,RC:.spec.runtimeClassName,NODE:.spec.nodeName,IP:.status.podIP,PHASE:.status.phase

    aws ec2 describe-instances --region "${AWS_REGION}" \
      --filters "Name=tag:Name,Values=podvm-*" "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,Type:InstanceType,IP:PrivateIpAddress}' \
      --output table
    ```

{{% alert state="info" %}}
Use pod Ready and a running peer EC2 instance as the functional test. The default Kata agent policy allows `oc exec`, but `oc exec` into `kata-remote` can hang. For production, disable `ExecProcessRequest` in the [Kata agent policy](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_openshift_sandboxed_containers_on_aws/configure-osc-overview_aws-osc).
{{% /alert %}}

    Optional: override the peer VM instance type on the pod:

    ```yaml
    metadata:
      annotations:
        io.katacontainers.config.hypervisor.machine_type: t3.medium
    ```

## 9. Local Kata on Intel metal (preferred for workloads)

Prefer this path for sandboxed workloads on ROSA HCP. Pods use `runtimeClassName: kata` on ROSA metal workers: they schedule and scale like any other pod, CPU and memory can be overcommitted on the pool, and workloads stay inside the ROSA platform. Peer pods (`kata-remote`) remain useful when metal is not available, but each peer pod provisions a separate EC2 instance with no overcommit.

`runtimeClassName: kata` needs `/dev/kvm` on the worker. Nested virtualization on `m5.xlarge` is not available. A `kata` pod on `m5.xlarge` fails with `FailedCreatePodSandBox` / `DeadlineExceeded` after about four minutes.

Metal instances are expensive. For a lab, use one replica, pick the cheapest Intel metal type ROSA HCP offers in the cluster Availability Zone, and delete the pool in the same session. For production, size a dedicated metal pool for your workload density and overcommit targets.

1. Confirm a metal instance type is offered. `rosa list instance-types` may prompt for an installer role if several exist. Pick the cluster's HCP installer role.

    ```bash
    rosa list instance-types --hosted-cp --region "${AWS_REGION}" --role-arn "${INSTALLER_ROLE}" | grep -i metal
    ```

    If `rosa list instance-types` prompts for an installer role, pass the cluster HCP installer role:

    ```bash
    export INSTALLER_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName, '${CLUSTER}-HCP-ROSA-Installer')].Arn" --output text)
    ```

    Example on-demand Linux prices from validation in `ap-southeast-2`. Confirm current pricing and availability in your Region:

    | Type | Approx. USD/hr | vCPU / memory |
    |------|----------------|---------------|
    | `c5n.metal` | 5.08 | 72 / 192 GiB |
    | `c5.metal` | 5.33 | 96 / 192 GiB |
    | `z1d.metal` | 5.42 | 48 / 384 GiB |

1. Create a one-node pool on the **same private subnet** as existing workers (HCP workers are private).

    ```bash
    rosa create machinepool \
      --cluster "${CLUSTER}" \
      --name kata-metal-0 \
      --replicas 1 \
      --instance-type c5n.metal \
      --labels 'kata-metal=true' \
      --subnet "${AWS_SUBNET_ID}"
    ```

    Wait until current replicas is 1 and the node is Ready. Metal first boot is slow (ostree reboot, large disk, long POST). The EC2 instance can reach `running` well before the node is Ready (about 20 minutes in validation).

    ```bash
    rosa describe machinepool --cluster "${CLUSTER}" --machinepool kata-metal-0
    oc get nodes -L node.kubernetes.io/instance-type,hypershift.openshift.io/nodePool,kata-metal
    ```

1. After the node is Ready, confirm `/dev/kvm` and that OSC DaemonSets landed on it. An empty `KataConfig` selector should install on the new node automatically (`kata-oc` role).

    ```bash
    oc debug node/<metal-node> --quiet -- chroot /host ls -l /dev/kvm
    oc get pods -n openshift-sandboxed-containers-operator -o wide
    ```

    Confirm `osc-rpm-install` / `osc-caa-ds` pods are on the metal node before you create the test pod.

1. Delete any failed `kata` pod that scheduled onto `m5.xlarge`, then create a local Kata pod pinned to metal.

    ```bash
    oc create -f - <<'EOF'
    apiVersion: v1
    kind: Pod
    metadata:
      name: osc-local-kata
      namespace: osc-test
    spec:
      runtimeClassName: kata
      nodeSelector:
        kata-metal: "true"
      restartPolicy: Never
      containers:
      - name: pause
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
    EOF

    oc get pod osc-local-kata -n osc-test -o wide
    oc exec -n osc-test osc-local-kata -- uname -a
    ```

    Verify that the pod is Running (about 16 seconds on `c5n.metal` in validation) and that `oc exec` succeeds.

## 10. Cleanup

Delete resources in this order to control cost: test pods (this terminates peer EC2 instances), then the metal pool if you created one, then KataConfig, then the Operator, then IAM.

Do not delete ROSA cluster roles (`*-HCP-ROSA-*`, ingress, CSI, EFS, cert-manager, and similar).

1. Delete workloads and confirm peer VMs are gone.

    ```bash
    oc delete pod -n osc-test --all --wait=true
    oc delete ns osc-test

    aws ec2 describe-instances --region "${AWS_REGION}" \
      --filters "Name=tag:Name,Values=podvm-*" "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].InstanceId' --output text
    ```

    If a `podvm-*` instance is still running after the pod is gone:

    ```bash
    aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids i-...
    ```

1. Delete the metal pool if you created one. Confirm the metal EC2 instance reaches `terminated` before you destroy the VPC. `c5n.metal` can sit in `shutting-down` for 10 minutes or more.

    ```bash
    rosa delete machinepool --cluster "${CLUSTER}" --machinepool kata-metal-0 --yes

    aws ec2 describe-instances --region "${AWS_REGION}" \
      --filters "Name=instance-type,Values=c5n.metal" \
                "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
      --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}' --output table
    ```

1. Delete `KataConfig`, then the Operator. Deleting `KataConfig` uninstalls RPMs (DaemonSet `osc-rpm-uninstall`) and triggers `osc-podvm-image-deletion` (AMI, S3, `vmimport`). Wait for the image-deletion job to complete. It removes AWS artifacts the IAM role created.

    ```bash
    oc delete kataconfig example-kataconfig
    ```

    Wait until it is gone (finalizer `kataconfiguration.openshift.io/finalizer`).

    ```bash
    oc delete subscription sandboxed-containers-operator -n openshift-sandboxed-containers-operator
    oc delete csv sandboxed-containers-operator.v1.13.1 -n openshift-sandboxed-containers-operator
    oc delete operatorgroup sandboxed-containers-operator-group -n openshift-sandboxed-containers-operator
    oc delete ns openshift-sandboxed-containers-operator

    oc delete crd kataconfigs.kataconfiguration.openshift.io peerpods.confidentialcontainers.org
    ```

1. Revoke only the extra OSC security group self-references (TCP 15150 and TCP 9000). Leave ROSA's 9000-9999 cluster communication rules.

    ```bash
    for AWS_SG_ID in "${AWS_SG_IDS[@]}"; do
      aws ec2 revoke-security-group-ingress --region "${AWS_REGION}" --group-id "${AWS_SG_ID}" \
        --protocol tcp --port 15150 --source-group "${AWS_SG_ID}" || true
      aws ec2 revoke-security-group-ingress --region "${AWS_REGION}" --group-id "${AWS_SG_ID}" \
        --protocol tcp --port 9000 --source-group "${AWS_SG_ID}" || true
    done
    ```

1. Delete the OSC IAM role and customer-managed policy.

    ```bash
    aws iam detach-role-policy --role-name "${ROLE_NAME}" \
      --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess || true
    aws iam detach-role-policy --role-name "${ROLE_NAME}" \
      --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}" || true
    aws iam delete-role --role-name "${ROLE_NAME}"
    aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
    ```

1. If image-deletion ran, `vmimport` and `podvm-*` S3/AMI should already be gone. Verify:

    ```bash
    aws iam get-role --role-name vmimport
    aws s3 ls | grep podvm || true
    aws ec2 describe-images --owners self --region "${AWS_REGION}" \
      --filters Name=name,Values='*podvm*' --query 'Images[].ImageId'
    ```

    `get-role` should return `NoSuchEntity` for `vmimport`.

1. If you created the cluster only for this test, destroy it after OSC cleanup. Wait until the metal instance is `terminated` first. If `terraform destroy` hangs on the VPC, ROSA sometimes leaves a `*-vpce-private-router` security group that Terraform does not manage. Delete that group, then let destroy continue.

    ```bash
    aws ec2 describe-security-groups --region "${AWS_REGION}" \
      --filters "Name=group-name,Values=*vpce-private-router*" \
      --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,Vpc:VpcId}' --output table
    ```

## Troubleshooting

### STS assume-role or AMI job failures

The image job `osc-podvm-image-creation` is the first IRSA check. If logs show `AssumeRoleWithWebIdentity` or audience errors:

1. Confirm the Subscription `ROLEARN` matches the role you created.
1. Confirm trust `sub` is `system:serviceaccount:openshift-sandboxed-containers-operator:default`.
1. Confirm trust `aud` is `openshift` (the Operator-projected token audience). ROSA IRSA for other operators often also allows `sts.amazonaws.com`. If assume-role still fails after the product-doc trust policy, add a second statement (or a second `StringEquals` audience) for `sts.amazonaws.com`.
1. Do not use static AWS access keys.

```bash
oc logs -n openshift-sandboxed-containers-operator job/osc-podvm-image-creation
```

### `InvalidPermission.Duplicate` on security groups

The OSC `authorize-security-group-ingress` calls are not idempotent. Inspect rules before adding them, or ignore the duplicate error (`|| true`). During cleanup, revoke only TCP 15150 and the extra TCP 9000 self-referential rule. Do not remove ROSA's 9000-9999 range.

### `t2` instance types fail with TPM v2.0 AMI

CAA may select `t2.small` from a product-doc `PODVM_INSTANCE_TYPES` list when the sample pod requests little CPU and memory. The OSC 1.13 pod VM AMI requires TPM 2.0, which `t2` instance types do not support. Set `PODVM_INSTANCE_TYPES` to Nitro types (`t3.medium,t3.large`), restart the `osc-caa-ds` DaemonSet, and recreate the test pod.

```bash
oc logs -n openshift-sandboxed-containers-operator ds/osc-caa-ds
```

Look for `The t2.small instance type does not support an AMI with TPM version v2.0`.

### Local Kata `DeadlineExceeded` on `m5.xlarge`

`runtimeClassName: kata` needs `/dev/kvm`. Standard (non-metal) ROSA workers do not provide nested KVM. Prefer a metal machine pool and `runtimeClassName: kata` as in [Local Kata on Intel metal](#9-local-kata-on-intel-metal-preferred-for-workloads). Use `kata-remote` only when metal is not an option.

### `oc exec` hangs on `kata-remote`

This can happen even when the pod is Running and the peer EC2 instance exists. Use pod Ready and EC2 existence as the health check. For production, disable `ExecProcessRequest` in the Kata agent policy.

## Next steps

* [Deploying a ROSA HCP cluster with Terraform](/experts/rosa/terraform/hcp/)
* [Installing OpenShift sandboxed containers on AWS](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_openshift_sandboxed_containers_on_aws/install-osc-overview_aws-osc)
* [Configuring OpenShift sandboxed containers on AWS](https://docs.redhat.com/en/documentation/openshift_sandboxed_containers/1.13/html/deploying_openshift_sandboxed_containers_on_aws/configure-osc-overview_aws-osc)
