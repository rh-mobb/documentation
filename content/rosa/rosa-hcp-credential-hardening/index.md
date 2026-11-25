---
date: '2026-11-25'
title: Hardening ROSA HCP Against Stolen Automation Credentials
tags: ["ROSA", "ROSA HCP", "GitOps"]
authors:
  - 'Kumudu Herath'
  - 'Kevin Collins'
validated_version: "4.22"
---

**Worked example: a stolen GitOps (Argo CD) deployment token.**

Automation accounts such as GitOps deployers and CI runners often hold the most powerful credentials in a cluster, and they are rarely watched as closely as human administrators. A common attack chain seen in the field looks like this:

1. An attacker copies a long-lived service account token from wherever automation stores it: a GitOps hub, a CI runner, a script or a repository.
2. The token is bound to a wildcard ClusterRole (`*` verbs on `*` resources), which is what `argocd cluster add` creates by default.
3. The attacker uses it from their own machine to create service accounts and grant them a privileged security context constraint (SCC).
4. They run privileged pods that mount the node's root filesystem.
5. From the node they harvest credentials and add persistence, such as SSH keys.

This guide shows how to break that chain on Red Hat OpenShift Service on AWS (ROSA) with hosted control planes (HCP). You will:

1. Forward control-plane audit logs to Amazon CloudWatch.
2. Find automation accounts with wildcard access and long-lived tokens.
3. Replace a wildcard GitOps credential with a namespace-scoped, short-lived one, then revoke the old one.
4. Block privileged and host-access pods with a ValidatingAdmissionPolicy.
5. Detect misuse with CloudWatch metric filters, alarms and hunting queries, in a form you can port to any SIEM.
6. Respond on ROSA HCP if a credential has already been stolen.

The same controls apply to any automation account, not only Argo CD. This guide complements [ROSA Best Practices and Recommendations](/experts/rosa/best-practices-recommendations/) and [Container Forensics on ROSA HCP with Red Hat Advanced Cluster Security](/experts/rosa/rosa-hcp-container-forensics-acs/).

> **Architecture diagram needs to be created:** Show the Argo CD instance (GitOps hub), the ROSA HCP cluster API in the Red Hat-managed AWS account, worker nodes in the customer VPC, control-plane log forwarding to CloudWatch with alarms to Amazon SNS, and an attacker workstation holding a copied token.

## What is different on ROSA HCP

| Topic | On ROSA HCP |
|---|---|
| Control plane | The API server, etcd and the service account token-signing keys run in a Red Hat-managed AWS account. They are never on your worker nodes, so a privileged pod on a worker cannot read them. |
| Default SCCs | A managed admission webhook blocks changes to the default SCCs, including `privileged`, even for `cluster-admin`. It does **not** stop a cluster-wide role from granting `use` on those SCCs through RBAC, and a wildcard role already includes that. |
| Audit profile | The API server uses the `Default` audit profile and you cannot change it. Events contain request metadata only, not request bodies. The audit log shows that a pod or binding was created, but not that the pod was privileged or which role a binding grants. |
| Audit log source | You get the audit log through control-plane log forwarding to CloudWatch or Amazon S3. RHACS audit-log policies are not supported on HCP. |
| Client IP | `sourceIPs` in forwarded audit events is an internal address, not the real client. Detect token misuse by identity, user agent and behavior instead. |
| API network access | There is no source-IP allowlist for a public API endpoint. To restrict API access by network, use a private (AWS PrivateLink) cluster and attach additional security groups to its API endpoint. |
| Worker nodes | New machine pools require IMDSv2. The worker instance role has only the `ROSAWorkerInstancePolicy` managed policy (EC2 describe calls and image pulls from Red Hat ECR repositories). There is no EC2 key pair, but the managed worker security group allows TCP 22 from the machine CIDR, so an SSH key planted on a node would be usable from inside the VPC. |
| Node integrity tools | The File Integrity Operator is not supported on HCP. |

### Why ROSA HCP limits the blast radius

- **The control plane is out of reach.** An escape from a pod to a worker host does not expose cluster-wide keys. You replace the affected workers; you do not rebuild etcd or rotate the cluster's signing keys because of a node escape.
- **A stolen in-cluster credential cannot switch off the audit trail.** The API server configuration, the audit profile and the managed admission webhooks cannot be changed through the cluster API, even by `cluster-admin`. Log forwarding is configured in OpenShift Cluster Manager, outside the cluster, so a token for the cluster cannot disable it.
- **Recovery is fast.** Replacing all workers is a machine pool operation that takes minutes, and there is no control-plane host work for you. Provisioning a new cluster from infrastructure as code and GitOps takes minutes rather than hours.
- **The AWS blast radius is smaller.** The worker instance role cannot change AWS resources, and IMDSv2 is required on new machine pools.
- **Shared responsibility still applies.** Red Hat SRE operates and monitors the control plane. Your identities, RBAC, workloads and automation credentials remain your responsibility. See the [ROSA responsibility matrix](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition#rosa-policy-responsibility-matrix).

None of these managed guardrails stop a wildcard role from being misused. That is what the rest of this guide fixes.

## Prerequisites

* A ROSA HCP 4.22 cluster and a user with `cluster-admin`. This guide was validated on a public ROSA HCP 4.22.19 cluster with STS.
* An Argo CD instance that deploys to the cluster. If you don't have one, the optional block in step 3 creates a lab instance on the same cluster, which then plays both the hub and the workload cluster.
* CLIs: `rosa`, `oc` (4.22), `aws` (v2) and `jq`, logged in to the cluster and the AWS account. Commands use `bash` or `zsh` on macOS or Linux.
* AWS permissions to create IAM roles, CloudWatch log groups, metric filters and alarms, and SNS topics.
* About 2 hours. Costs: CloudWatch ingestion and storage for the audit log, four alarms, and two temporary m5.xlarge nodes if you run the node-replacement test in step 8.

## Set environment variables

Set the values you choose, then let the rest be discovered:

```bash
export CLUSTER=<your-cluster-name>
export ALERT_EMAIL=<address that receives alerts>
export GITOPS_NS=openshift-gitops        # namespace of your Argo CD instance
export ARGOCD_SA_NS=argocd-access        # namespace for the new deployment account
export APP_NS=demo-app                   # namespace Argo CD deploys the application into
export LOG_RETENTION_DAYS=90

export REGION=$(rosa describe cluster -c "$CLUSTER" -o json | jq -r .region.id)
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export API=$(oc whoami --show-server)
export LOG_GROUP=${CLUSTER}-control-plane-audit
export LOG_ROLE=CustomerLogDistribution-${CLUSTER}
export DEPLOYER_SA=system:serviceaccount:${ARGOCD_SA_NS}:argocd-deployer
export METRIC_NS=ROSAAudit/${CLUSTER}
echo "$CLUSTER $REGION $API"
```

Check that `API` is the API URL of the cluster you mean to change.

## 1. Forward control-plane audit logs to CloudWatch

If the cluster already forwards the `api` log group, skip to the check at the end of this step and use your existing log group as `LOG_GROUP`.

> **Note:** The IAM role name **must** start with `CustomerLogDistribution-`. In testing, a role with any other name was accepted, the forwarder reported that the configuration was applied successfully, and no logs were delivered.

The trust policy principal below is the ROSA central log distribution role from the [ROSA log forwarding documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/logging/rosa-forwarding-control-plane-logs#rosa-create-an-iam-role-policy_rosa-configuring-the-log-forwarder). Check that it still matches the documentation before you apply it.

```bash
aws logs create-log-group --log-group-name "$LOG_GROUP"
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days "$LOG_RETENTION_DAYS"

cat > logfwd-trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"AWS":"arn:aws:iam::859037107838:role/ROSA-CentralLogDistributionRole-241c1a86"},
 "Action":"sts:AssumeRole"}]}
EOF
cat > logfwd-policy.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":"arn:aws:logs:${REGION}:${ACCOUNT}:log-group:${LOG_GROUP}:*"},
 {"Effect":"Allow","Action":["logs:DescribeLogGroups","logs:DescribeLogStreams"],"Resource":"*"}]}
EOF
aws iam create-role --role-name "$LOG_ROLE" --assume-role-policy-document file://logfwd-trust.json
aws iam put-role-policy --role-name "$LOG_ROLE" --policy-name logfwd --policy-document file://logfwd-policy.json

cat > logfwd.yaml <<EOF
cloudwatch:
  cloudwatch_log_role_arn: "arn:aws:iam::${ACCOUNT}:role/${LOG_ROLE}"
  cloudwatch_log_group_name: "${LOG_GROUP}"
  groups: ["api"]
EOF
rosa create log-forwarder -c "$CLUSTER" --log-fwd-config logfwd.yaml -y
rosa list log-forwarders -c "$CLUSTER"
```

After a minute or two, check that audit events arrive:

```bash
aws logs describe-log-streams --log-group-name "$LOG_GROUP" --query 'logStreams[].logStreamName' --output text
aws logs filter-log-events --log-group-name "$LOG_GROUP" --filter-pattern '{ $.kind = "Event" }' \
  --max-items 1 --query 'events[0].message' --output text | head -1 | jq '{level, verb, user: .user.username, userAgent, sourceIPs}'
```

You should see `kube-apiserver-*` and `openshift-apiserver-*` streams and an event with `"level": "Metadata"`. Logs from before forwarding was enabled cannot be recovered, so do this before you need it.

## 2. Find automation accounts with wildcard access or long-lived tokens

List the ClusterRoles that allow every verb on every resource, then the service accounts bound to them outside the platform namespaces:

```bash
WILDCARD_ROLES=$(oc get clusterroles -o json | jq -c '[.items[]
  | select(any(.rules[]?; ((.verbs // []) | index("*")) and ((.resources // []) | index("*"))))
  | .metadata.name]')
echo "$WILDCARD_ROLES"

for kind in clusterrolebindings rolebindings; do
  oc get "$kind" -A -o json | jq -r --arg k "$kind" --argjson roles "$WILDCARD_ROLES" '.items[]
    | select(.roleRef.kind == "ClusterRole" and (.roleRef.name as $r | $roles | index($r)))
    | .subjects[]? | select(.kind == "ServiceAccount")
    | select(.namespace | test("^(openshift-|hypershift|open-cluster-management)") | not)
    | "\($k)\t\(.namespace)/\(.name)"'
done | sort -u
```

On a new ROSA HCP cluster the second command prints nothing. A cluster registered with `argocd cluster add` prints `clusterrolebindings  kube-system/argocd-manager`. Don't exclude `kube-system` from this check: that is where `argocd cluster add` creates its account.

List long-lived service account token Secrets. Tokens stored this way never expire:

```bash
oc get secrets -A --field-selector type=kubernetes.io/service-account-token \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SA:.metadata.annotations.kubernetes\.io/service-account\.name,CREATED:.metadata.creationTimestamp'
```

Treat every non-platform entry in either list as a finding. For each account, check what it can actually do:

```bash
oc auth can-i --list --as=system:serviceaccount:kube-system:argocd-manager
```

## 3. Give Argo CD a least-privilege, short-lived credential

Create the new credential first and switch Argo CD to it, then revoke the old one in step 4. That way deployments don't stop.

<details>
<summary>Optional: create a lab Argo CD instance on the same cluster</summary>

Skip this if you already have an Argo CD instance. This installs OpenShift GitOps without its default instance and creates an Argo CD instance with no route. Set `GITOPS_NS` to the namespace you want (for example `export GITOPS_NS=gitops-lab`) before you run it.

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-gitops-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  config:
    env:
    - name: DISABLE_DEFAULT_ARGOCD_INSTANCE
      value: "true"
EOF
oc get csv -n openshift-gitops-operator -w
```

Press Ctrl+C when the `openshift-gitops-operator` CSV shows `Succeeded`, then create the instance:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${GITOPS_NS}
---
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: argocd
  namespace: ${GITOPS_NS}
spec:
  server:
    route:
      enabled: false
EOF
oc wait argocd/argocd -n "$GITOPS_NS" --for=jsonpath='{.status.phase}'=Available --timeout=300s
```

</details>

### 3.1 Create the account and a namespace-scoped Role on the workload cluster

The account lives in its own namespace, not `kube-system`. The Role lists the exact resources and verbs the application needs. It has no access to Secrets, service accounts, pods (other than read), RBAC or SCCs. Adjust the rules to the resource types your application actually deploys.

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ARGOCD_SA_NS}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${APP_NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-deployer
  namespace: ${ARGOCD_SA_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-deployer
  namespace: ${APP_NS}
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["services", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["route.openshift.io"]
  resources: ["routes"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods", "endpoints", "events"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: argocd-deployer
  namespace: ${APP_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: argocd-deployer
subjects:
- kind: ServiceAccount
  name: argocd-deployer
  namespace: ${ARGOCD_SA_NS}
EOF
```

Check the scope. Each of these must print `no`:

```bash
oc auth can-i create serviceaccounts -n "$APP_NS" --as="$DEPLOYER_SA"
oc auth can-i create pods -n "$APP_NS" --as="$DEPLOYER_SA"
oc auth can-i get secrets -n "$APP_NS" --as="$DEPLOYER_SA"
oc auth can-i create deployments -n default --as="$DEPLOYER_SA"
oc auth can-i create rolebindings -n "$APP_NS" --as="$DEPLOYER_SA"
oc auth can-i use securitycontextconstraints/privileged --as="$DEPLOYER_SA"
oc auth can-i impersonate users --as="$DEPLOYER_SA"
```

`oc auth can-i --list --as="$DEPLOYER_SA" -n "$APP_NS"` also shows rows such as `selfsubjectreviews` and `restricted-v2` SCC use. Those come from the default roles every authenticated user gets.

### 3.2 Register the cluster in Argo CD with a short-lived token

Run these commands against the cluster that hosts Argo CD. In this guide it is the same cluster.

ROSA HCP does not cap the lifetime you request: in testing, `oc create token --duration=8760h` returned a token valid for a full year. Choose a short duration on purpose and plan to rotate it (step 3.3). This example uses 24 hours.

The cluster secret limits Argo CD to `APP_NS` and to namespaced resources. The `name` and `server` keys identify the cluster; if you are replacing an existing cluster secret, use its name so that existing Applications keep working.

```bash
TOKEN=$(oc create token argocd-deployer -n "$ARGOCD_SA_NS" --duration=24h)
oc create secret generic workload-cluster -n "$GITOPS_NS" \
  --from-literal=name=workload-cluster \
  --from-literal=server="$API" \
  --from-literal=namespaces="$APP_NS" \
  --from-literal=clusterResources=false \
  --from-literal=config="{\"bearerToken\":\"${TOKEN}\",\"tlsClientConfig\":{\"insecure\":false}}" \
  --dry-run=client -o yaml \
  | oc label -f - --local -o yaml argocd.argoproj.io/secret-type=cluster \
  | oc apply -f -
unset TOKEN
```

The public ROSA HCP API certificate validated without extra CA data in testing. Keep `insecure` set to `false`.

Tell the Argo CD controller to watch only the resource types its RBAC allows. Without this, it tries to list every resource type in the namespace and logs a stream of `403` errors:

```bash
oc patch argocd argocd -n "$GITOPS_NS" --type merge -p '{"spec":{"extraConfig":{"resource.respectRBAC":"strict"}}}'
```

If your `ArgoCD` resource has a different name, use `oc get argocd -n "$GITOPS_NS"` to find it.

Deploy a sample application through the new credential. It deploys only the Deployment and Service from the OpenShift GitOps getting-started repository, without its public Route:

```bash
cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: petclinic
  namespace: ${GITOPS_NS}
spec:
  project: default
  source:
    repoURL: https://github.com/redhat-developer/openshift-gitops-getting-started
    targetRevision: HEAD
    path: app
    directory:
      include: '{deployment.yaml,service.yaml}'
  destination:
    server: ${API}
    namespace: ${APP_NS}
  syncPolicy:
    automated: {}
EOF
oc wait application/petclinic -n "$GITOPS_NS" --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s
oc get application petclinic -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
```

Expected result: `Synced/Healthy`.

### 3.3 Rotate the token

A 24-hour token stops working after 24 hours. Rotation means issuing a new token and updating the cluster secret:

```bash
TOKEN=$(oc create token argocd-deployer -n "$ARGOCD_SA_NS" --duration=24h)
oc patch secret workload-cluster -n "$GITOPS_NS" --type merge \
  -p "{\"stringData\":{\"config\":\"{\\\"bearerToken\\\":\\\"${TOKEN}\\\",\\\"tlsClientConfig\\\":{\\\"insecure\\\":false}}\"}}"
unset TOKEN
oc annotate application petclinic -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite
oc get application petclinic -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
```

Run rotation from an automated, access-controlled job, not by hand. A longer-term option is a pull model, such as the Red Hat Advanced Cluster Management (RHACM) GitOps pull model or the Argo CD Agent, where each cluster pulls its own configuration and the hub stores no cluster credentials. Check their support status for the OpenShift GitOps and RHACM versions you run.

## 4. Revoke the wildcard credential

When Argo CD syncs through the new account, remove the old one. These commands use the names `argocd cluster add` creates; use the names you found in step 2.

```bash
oc delete clusterrolebinding argocd-manager-role-binding
oc delete clusterrole argocd-manager-role
oc get secrets -n kube-system --field-selector type=kubernetes.io/service-account-token -o json \
  | jq -r '.items[] | select(.metadata.annotations["kubernetes.io/service-account.name"] == "argocd-manager") | .metadata.name' \
  | xargs -r -n1 oc delete secret -n kube-system
oc delete serviceaccount argocd-manager -n kube-system
```

How revocation behaves, as tested on ROSA HCP 4.22:

* **Long-lived token Secret:** deleting the Secret revokes the token. It kept working for a few seconds and was rejected from about 10 seconds after deletion.
* **Tokens from `oc create token` or a projected volume:** deleting and recreating the ServiceAccount revokes every token issued for it, because the token is bound to the account's UID.
* **The binding outlives the account.** RBAC binds by name. If you delete the ServiceAccount but not the ClusterRoleBinding, anyone who recreates `kube-system/argocd-manager` gets the wildcard role back. Delete the binding and the role.

Check that nothing is left. The first command prints nothing, and the last one shows only the default permissions every authenticated user has:

```bash
oc get sa,secret -n kube-system | grep argocd-manager
oc get clusterrole argocd-manager-role
oc get clusterrolebinding argocd-manager-role-binding
oc auth can-i --list --as=system:serviceaccount:kube-system:argocd-manager | head -5
```

If you kept a copy of an old token, `oc whoami --token=<old token>` must return `error: You must be logged in to the server (Unauthorized)`.

## 5. Block privileged and host-access pods with an admission policy

Least privilege keeps the deployment account from creating privileged pods. An admission policy is the backstop for every other identity, including `cluster-admin`. It denies privileged containers, `hostPath` volumes, and host network, PID and IPC namespaces outside `openshift*` and `kube-*` namespaces and namespaces labelled `host-access-exempt=true`.

Start in `Warn` and `Audit` mode so nothing is blocked yet:

```bash
cat > host-access-policy.yaml <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: deny-host-access-pods
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE", "UPDATE"]
      resources: ["pods", "pods/ephemeralcontainers"]
  matchConditions:
  - name: skip-platform-namespaces
    expression: >-
      !(request.namespace.startsWith('openshift') || request.namespace.startsWith('kube-'))
  variables:
  - name: allContainers
    expression: >-
      object.spec.containers +
      (has(object.spec.initContainers) ? object.spec.initContainers : []) +
      (has(object.spec.ephemeralContainers) ? object.spec.ephemeralContainers : [])
  validations:
  - expression: "!has(object.spec.hostNetwork) || object.spec.hostNetwork == false"
    message: "hostNetwork is not allowed in this namespace"
  - expression: "!has(object.spec.hostPID) || object.spec.hostPID == false"
    message: "hostPID is not allowed in this namespace"
  - expression: "!has(object.spec.hostIPC) || object.spec.hostIPC == false"
    message: "hostIPC is not allowed in this namespace"
  - expression: "!has(object.spec.volumes) || object.spec.volumes.all(v, !has(v.hostPath))"
    message: "hostPath volumes are not allowed in this namespace"
  - expression: >-
      variables.allContainers.all(c, !has(c.securityContext) ||
        !has(c.securityContext.privileged) || c.securityContext.privileged == false)
    message: "privileged containers are not allowed in this namespace"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: deny-host-access-pods
spec:
  policyName: deny-host-access-pods
  validationActions: ["Warn", "Audit"]
  matchResources:
    namespaceSelector:
      matchExpressions:
      - key: host-access-exempt
        operator: NotIn
        values: ["true"]
EOF
oc apply -f host-access-policy.yaml
```

> **Note:** The namespace exemption is in the binding's `namespaceSelector`. An exemption written as a `matchConditions` expression on `namespaceObject` failed with `no such key: metadata` in testing.

Before you enforce, find workloads the policy would block. This lists pods outside the exempt namespaces that use host access today:

```bash
oc get pods -A -o json | jq -r '.items[]
  | select((.metadata.namespace | test("^(openshift|kube-)")) | not)
  | select(.spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true
           or any(.spec.volumes[]?; has("hostPath"))
           or any(.spec.containers[]?, .spec.initContainers[]?; .securityContext.privileged == true))
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

For each namespace that legitimately needs host access, such as a security agent, label it, for example `oc label namespace <namespace> host-access-exempt=true`. Anyone who can label namespaces can exempt them, so keep that right to administrators.

Create test pod definitions. They are only submitted with `--dry-run=server`, so nothing is created:

```bash
cat > test-pods.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: policy-test-plain}
spec:
  containers:
  - {name: c, image: registry.access.redhat.com/ubi9/ubi-minimal, command: ["sleep", "60"]}
---
apiVersion: v1
kind: Pod
metadata: {name: policy-test-privileged}
spec:
  containers:
  - name: c
    image: registry.access.redhat.com/ubi9/ubi-minimal
    command: ["sleep", "60"]
    securityContext: {privileged: true}
---
apiVersion: v1
kind: Pod
metadata: {name: policy-test-hostpath}
spec:
  containers:
  - name: c
    image: registry.access.redhat.com/ubi9/ubi-minimal
    command: ["sleep", "60"]
    volumeMounts: [{name: host, mountPath: /host}]
  volumes:
  - {name: host, hostPath: {path: /}}
---
apiVersion: v1
kind: Pod
metadata: {name: policy-test-hostns}
spec:
  hostNetwork: true
  hostPID: true
  containers:
  - {name: c, image: registry.access.redhat.com/ubi9/ubi-minimal, command: ["sleep", "60"]}
EOF
oc apply --dry-run=server -n "$APP_NS" -f test-pods.yaml 2>&1 | grep -v PodSecurity
```

In `Warn` mode, each of the last three pods is accepted with a `Validation failed for ValidatingAdmissionPolicy 'deny-host-access-pods'` warning. Switch to `Deny` and run the test again:

```bash
oc patch validatingadmissionpolicybinding deny-host-access-pods --type merge -p '{"spec":{"validationActions":["Deny"]}}'
sleep 15
oc apply --dry-run=server -n "$APP_NS" -f test-pods.yaml 2>&1 | grep -v PodSecurity
```

Expected result: `policy-test-plain created (server dry run)`, and the other three are `forbidden: ValidatingAdmissionPolicy 'deny-host-access-pods' ... denied request`. As `cluster-admin` you are denied too.

Things to know:

* `oc debug node/<node>` keeps working. When the current namespace is not privileged, `oc` creates a temporary `openshift-debug-*` namespace, which the policy skips. `oc debug node/<node> --to-namespace=default` is denied.
* Normal application rollouts are not affected. A rollout of the Argo CD-managed application succeeded with the policy enforced.
* Anyone with `cluster-admin` can delete the policy. Least privilege (steps 3 and 4) comes first. To restore a deleted policy automatically, manage it from outside the cluster, for example with RHACM governance policies.

## 6. Detect misuse in the audit log

Use what the `Default` audit profile records on ROSA HCP: the identity, the verb, the resource, the response code, the user agent, and annotations such as `authentication.k8s.io/legacy-token`. Request bodies are not recorded, so the policy in step 5, or RHACS deploy-time policies, are what catch the content of a pod spec.

In testing, the audit log showed the Argo CD controller as `argocd-application-controller/...` and a workstation using the same token as `oc/4.22.0 (darwin/amd64)`. `sourceIPs` showed an internal address for both. Every request made with a long-lived token Secret carried `authentication.k8s.io/legacy-token` and `authentication.k8s.io/legacy-token-manual-secret` annotations.

### 6.1 Automate alerts with CloudWatch metric filters, alarms and SNS

Create an SNS topic and subscribe your address. Confirm the subscription from the email you receive; alarms do not notify an unconfirmed address.

```bash
TOPIC_ARN=$(aws sns create-topic --name "${CLUSTER}-audit-alerts" --query TopicArn --output text)
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL"
```

Detection 1: the deployment account is used by anything other than the Argo CD controller.

```bash
aws logs put-metric-filter --log-group-name "$LOG_GROUP" --filter-name DeploymentAccountUnexpectedClient \
  --filter-pattern "{ \$.user.username = \"${DEPLOYER_SA}\" && \$.userAgent != \"argocd-application-controller/*\" }" \
  --metric-transformations metricName=DeploymentAccountUnexpectedClient,metricNamespace="$METRIC_NS",metricValue=1,defaultValue=0
```

Detection 2: any long-lived service account token Secret is used.

```bash
aws logs put-metric-filter --log-group-name "$LOG_GROUP" --filter-name LegacyServiceAccountTokenUsed \
  --filter-pattern '"authentication.k8s.io/legacy-token"' \
  --metric-transformations metricName=LegacyServiceAccountTokenUsed,metricNamespace="$METRIC_NS",metricValue=1,defaultValue=0
```

Detection 3: an SCC is created, changed or deleted by a non-platform identity, including attempts that the managed webhook denies. Platform operators rewrite some SCCs every few minutes on ROSA HCP (in testing, `system:admin` and the cluster monitoring operator), so they are excluded.

```bash
aws logs put-metric-filter --log-group-name "$LOG_GROUP" --filter-name SCCWrite \
  --filter-pattern '{ $.objectRef.resource = "securitycontextconstraints" && $.verb != "get" && $.verb != "list" && $.verb != "watch" && $.user.username != "system:admin" && $.user.username != "system:serviceaccount:openshift-*" }' \
  --metric-transformations metricName=SCCWrite,metricNamespace="$METRIC_NS",metricValue=1,defaultValue=0
```

Detection 4: a ClusterRole or ClusterRoleBinding is written by a non-platform identity. Don't exclude all of `kube-system`, because `argocd cluster add` puts its account there.

```bash
aws logs put-metric-filter --log-group-name "$LOG_GROUP" --filter-name ClusterRBACWriteNonPlatform \
  --filter-pattern '{ ($.objectRef.resource = "clusterroles" || $.objectRef.resource = "clusterrolebindings") && $.verb != "get" && $.verb != "list" && $.verb != "watch" && $.user.username != "system:admin" && $.user.username != "system:serviceaccount:openshift-*" && $.user.username != "system:serviceaccount:kube-system:clusterrole-aggregation-controller" }' \
  --metric-transformations metricName=ClusterRBACWriteNonPlatform,metricNamespace="$METRIC_NS",metricValue=1,defaultValue=0
```

Create one alarm per detection. Each alarm fires when one or more matching events arrive in a 5-minute period:

```bash
for m in DeploymentAccountUnexpectedClient LegacyServiceAccountTokenUsed SCCWrite ClusterRBACWriteNonPlatform; do
  aws cloudwatch put-metric-alarm --alarm-name "${CLUSTER}-${m}" --namespace "$METRIC_NS" --metric-name "$m" \
    --statistic Sum --period 300 --evaluation-periods 1 --threshold 1 \
    --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN"
done
aws cloudwatch describe-alarms --alarm-name-prefix "${CLUSTER}-" --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
```

Human administrators changing cluster RBAC also trigger detection 4. Review those alerts against your change records, or add exclusions for named break-glass identities.

SNS can also deliver to AWS Lambda, HTTPS endpoints and Amazon SQS, so the same alarms can feed chat tools, paging services or a SOAR platform.

### 6.2 Hunt with CloudWatch Logs Insights

Some patterns need correlation rather than a single event. Save the queries:

```bash
cat > q-sa-then-pod.txt <<'EOF'
filter verb = "create" and responseStatus.code < 300 and isblank(objectRef.subresource)
  and requestURI not like /dryRun=All/
  and (objectRef.resource = "serviceaccounts"
       or (objectRef.resource = "pods" and user.username not like /^system:(serviceaccount:kube-system:|node:)/))
| stats count_distinct(objectRef.resource) as kinds, count(*) as events, latest(user.username) as lastUser by objectRef.namespace, bin(10m)
| filter kinds = 2
EOF
cat > q-token-requests.txt <<'EOF'
filter objectRef.resource = "serviceaccounts" and objectRef.subresource = "token" and verb = "create"
  and user.username not like /^system:(node:|kube-controller-manager$|admin$|serviceaccount:openshift-infra:serviceaccount-pull-secrets-controller$)/
| stats count(*) as requests by user.username, objectRef.namespace, objectRef.name, userAgent
| sort requests desc
EOF
cat > q-automation-agents.txt <<'EOF'
filter user.username like /^system:serviceaccount:/
  and user.username not like /^system:serviceaccount:(openshift-|kube-system:|hypershift:|open-cluster-management)/
| stats count(*) as requests by user.username, userAgent
| sort requests desc
| limit 50
EOF
```

* `q-sa-then-pod.txt`: a service account and a directly created pod in the same namespace within 10 minutes, the pattern in step 3 of the attack chain.
* `q-token-requests.txt`: tokens issued for service accounts by anyone other than platform components.
* `q-automation-agents.txt`: the user agents each automation account uses. More than one client per account is worth a look.

Run a query over the last 24 hours. Repeat the `get-query-results` command until `status` is `Complete`:

```bash
QUERY_ID=$(aws logs start-query --log-group-name "$LOG_GROUP" \
  --start-time $(( $(date +%s) - 86400 )) --end-time $(date +%s) \
  --query-string "$(cat q-automation-agents.txt)" --query queryId --output text)
sleep 10
aws logs get-query-results --query-id "$QUERY_ID" --output json \
  | jq -r '.status, (.results[] | map("\(.field)=\(.value)") | join("  "))'
```

To run the other queries, replace the file name in `--query-string`.

### 6.3 Use the same detections in any SIEM

The detections are field conditions on the Kubernetes audit event, so they port to any SIEM. Send the audit log to it with the log forwarder's S3 destination, or with a CloudWatch Logs subscription filter into Amazon Data Firehose. Common destinations include Splunk, Microsoft Sentinel, Elastic, Datadog and Sumo Logic. For Elastic, see [Forwarding ROSA HCP control plane audit logs with Filebeat](/experts/rosa/audit-logs-filebeat/).

| Detection | Audit event conditions |
|---|---|
| Deployment account, unexpected client | `user.username` is the deployment account and `userAgent` does not start with the expected controller (`argocd-application-controller/`) |
| Long-lived token used | `annotations` contains `authentication.k8s.io/legacy-token` |
| SCC write | `objectRef.resource` = `securitycontextconstraints`, `verb` not in (`get`, `list`, `watch`), `user.username` not `system:admin` or `system:serviceaccount:openshift-*` |
| Cluster RBAC write | `objectRef.resource` in (`clusterroles`, `clusterrolebindings`), write verb, identity not on a platform allowlist |
| New service account then pod | `create` of `serviceaccounts` and of `pods` in the same `objectRef.namespace` within 10 minutes, excluding controllers and dry runs |
| Token issued by unexpected identity | `objectRef.resource` = `serviceaccounts`, `objectRef.subresource` = `token`, identity not a platform component |

## 7. Verify the result

Run these checks after steps 1 to 6:

```bash
# The new account is limited to its namespace and cannot reach SCCs or other namespaces (expect: no, no, no)
oc auth can-i create serviceaccounts -n "$APP_NS" --as="$DEPLOYER_SA"
oc auth can-i create deployments -n default --as="$DEPLOYER_SA"
oc auth can-i use securitycontextconstraints/privileged --as="$DEPLOYER_SA"

# Privileged and host-access pods are denied, even for cluster-admin
oc apply --dry-run=server -n "$APP_NS" -f test-pods.yaml 2>&1 | grep -v PodSecurity

# Detection 1 fires when the deployment account is used from a workstation
oc whoami --token="$(oc create token argocd-deployer -n "$ARGOCD_SA_NS" --duration=10m)"
```

Within about 2 minutes, `${CLUSTER}-DeploymentAccountUnexpectedClient` changes to `ALARM` and the confirmed address receives an email:

```bash
aws cloudwatch describe-alarms --alarm-names "${CLUSTER}-DeploymentAccountUnexpectedClient" \
  --query 'MetricAlarms[0].StateValue' --output text
```

## 8. If a credential has already been stolen

Work through these steps in order. Preserve evidence before you delete anything; deleting pods and nodes destroys it.

1. **Prepare before an incident.** Follow [Container Forensics on ROSA HCP](/experts/rosa/rosa-hcp-container-forensics-acs/) step 1: log forwarding ([1.1](/experts/rosa/rosa-hcp-container-forensics-acs/#11-forward-control-plane-logs-to-cloudwatch)), an evidence bucket with Object Lock ([1.3](/experts/rosa/rosa-hcp-container-forensics-acs/#13-create-an-evidence-bucket-with-object-lock)) and a least-privilege responder role ([1.4](/experts/rosa/rosa-hcp-container-forensics-acs/#14-create-a-forensics-namespace-and-a-least-privilege-responder-role)).
2. **Preserve evidence.** In the forensics guide: scope the incident ([6.1](/experts/rosa/rosa-hcp-container-forensics-acs/#61-scope)), preserve the node by turning off AutoRepair and cordoning it ([6.2](/experts/rosa/rosa-hcp-container-forensics-acs/#62-preserve-the-node)), capture volatile state ([6.3](/experts/rosa/rosa-hcp-container-forensics-acs/#63-capture-volatile-state-before-isolating)), isolate the pod ([6.4](/experts/rosa/rosa-hcp-container-forensics-acs/#64-isolate-the-pod)), checkpoint and collect it ([6.5](/experts/rosa/rosa-hcp-container-forensics-acs/#65-checkpoint-the-container) to [6.7](/experts/rosa/rosa-hcp-container-forensics-acs/#67-collect-the-writable-layer)), collect logs, objects and the image ([6.8](/experts/rosa/rosa-hcp-container-forensics-acs/#68-logs-objects-and-the-image)) and store the evidence with integrity ([6.11](/experts/rosa/rosa-hcp-container-forensics-acs/#611-store-the-evidence-with-integrity)).
3. **Investigate.** Use the audit log and CloudTrail queries in the forensics guide ([7](/experts/rosa/rosa-hcp-container-forensics-acs/#7-investigate-with-the-audit-log-and-cloudtrail)) and the hunting queries in step 6.2.
4. **Revoke.** Remove the stolen credential and its bindings with step 4. For bound tokens, recreate the ServiceAccount ([forensics 6.10](/experts/rosa/rosa-hcp-container-forensics-acs/#610-revoke-the-stolen-credentials)).
5. **Sweep for persistence.** Set `SINCE` to a UTC time before the earliest suspicious activity, then list standalone objects created since then and objects last written by a CLI or script client:

   ```bash
   export SINCE=<UTC time, for example 2026-01-01T00:00:00Z>
   for r in serviceaccounts roles rolebindings clusterroles clusterrolebindings daemonsets deployments cronjobs jobs \
            validatingwebhookconfigurations mutatingwebhookconfigurations validatingadmissionpolicies validatingadmissionpolicybindings; do
     oc get "$r" -A -o json | jq -r --arg r "$r" --arg s "$SINCE" '.items[]
       | select(.metadata.creationTimestamp >= $s)
       | select((.metadata.ownerReferences // []) | length == 0)
       | select(.metadata.labels["olm.owner"] == null)
       | select((.metadata.namespace // "") | test("^(openshift|kube-)") | not)
       | select(.metadata.name | test("^(system:|openshift|dedicated-admin)|^(default|builder|deployer)$") | not)
       | "\($r)\t\(.metadata.namespace // "-")/\(.metadata.name)\t\(.metadata.creationTimestamp)"'
   done
   for r in serviceaccounts roles rolebindings clusterroles clusterrolebindings daemonsets cronjobs secrets; do
     oc get "$r" -A --show-managed-fields -o json | jq -r --arg r "$r" '.items[]
       | select(any(.metadata.managedFields[]?; (.manager // "") | test("^(kubectl|oc|curl|python|Go-http-client)"; "i")))
       | "\($r)\t\(.metadata.namespace // "-")/\(.metadata.name)\t\([.metadata.managedFields[] | select((.manager // "") | test("^(kubectl|oc|curl|python|Go-http-client)"; "i")) | "\(.manager):\(.operation)@\(.time)"] | join(","))"'
   done
   ```

   `--show-managed-fields` is required: without it, `oc get` omits the field that records which client last wrote each object, and the second check silently finds nothing. Objects created by your own administrators with `oc` also appear; compare them with your change records. Also check who can use the privileged SCCs and which users are listed directly on SCCs, and compare the output with a known-good cluster:

   ```bash
   oc adm policy who-can use scc privileged
   oc get scc -o json | jq -r '.items[] | select((.users|length)>0 or (.groups|length)>0) | "\(.metadata.name)\tusers=\(.users|join(","))\tgroups=\(.groups|join(","))"'
   oc get csr --sort-by=.metadata.creationTimestamp
   ```

6. **Replace the worker nodes.** Treat any node where a privileged or host-mount pod ran as untrusted. For each affected machine pool, create a replacement with the same instance type, subnet, replica count, labels and taints, wait for its nodes, drain the old pool and delete it. Set the affected pool and a name for its replacement, then copy the settings:

   ```bash
   export OLD_POOL=<affected machine pool>
   export NEW_POOL=<new machine pool name>
   MP=$(rosa describe machinepool -c "$CLUSTER" --machinepool "$OLD_POOL" -o json)
   MP_TYPE=$(echo "$MP" | jq -r .aws_node_pool.instance_type)
   MP_SUBNET=$(echo "$MP" | jq -r .subnet)
   MP_REPLICAS=$(echo "$MP" | jq -r .replicas)
   MP_LABELS=$(echo "$MP" | jq -r '(.labels // {}) | to_entries | map("\(.key)=\(.value)") | join(",")')
   MP_TAINTS=$(echo "$MP" | jq -r '(.taints // []) | map("\(.key)=\(.value):\(.effect)") | join(",")')
   echo "type=$MP_TYPE subnet=$MP_SUBNET replicas=$MP_REPLICAS labels=$MP_LABELS taints=$MP_TAINTS"
   ```

   If `replicas` is `null`, the pool uses autoscaling: replace `--replicas "$MP_REPLICAS"` in the next command with `--enable-autoscaling --min-replicas <min> --max-replicas <max>` from the `autoscaling` field of `$MP`. Create the replacement, move the workloads and delete the old pool:

   ```bash
   rosa create machinepool -c "$CLUSTER" --name "$NEW_POOL" --replicas "$MP_REPLICAS" \
     --instance-type "$MP_TYPE" --subnet "$MP_SUBNET" ${MP_LABELS:+--labels=$MP_LABELS} ${MP_TAINTS:+--taints=$MP_TAINTS}
   oc wait nodes -l hypershift.openshift.io/nodePool=${CLUSTER}-${NEW_POOL} --for=condition=Ready --timeout=20m
   oc adm cordon -l hypershift.openshift.io/nodePool=${CLUSTER}-${OLD_POOL}
   oc adm drain -l hypershift.openshift.io/nodePool=${CLUSTER}-${OLD_POOL} --ignore-daemonsets --delete-emptydir-data --timeout=10m
   rosa delete machinepool -c "$CLUSTER" "$OLD_POOL" -y
   oc get nodes -L hypershift.openshift.io/nodePool
   ```

   In testing, a new node was `Ready` about 4 minutes after `rosa create machinepool`, the drained workload moved to it immediately, and the old node left the cluster about 1 minute after the pool was deleted. `oc wait` can return an error if the new nodes have not registered yet; run it again. If the evidence on a node is still needed, collect it first (step 2). There is no control-plane work for you on ROSA HCP.

7. **Rotate secrets.** A wildcard token can read every Secret in the cluster. Rotate application credentials, registry credentials, identity-provider client secrets and any cloud credentials stored in the cluster.
8. **Check AWS activity for the worker role.** Worker instance role sessions are named after the EC2 instance ID. Review where each session was used from:

   ```bash
   for i in $(oc get nodes -o jsonpath='{.items[*].spec.providerID}' | tr ' ' '\n' | awk -F/ '{print $NF}'); do
     aws cloudtrail lookup-events --lookup-attributes AttributeKey=Username,AttributeValue="$i" --max-results 50 \
       --query 'Events[].CloudTrailEvent' --output json \
       | jq -r --arg i "$i" '.[] | fromjson | "\($i)\t\(.eventTime)\t\(.eventSource)\t\(.eventName)\t\(.sourceIPAddress)"'
   done
   ```

   Calls from addresses outside your VPC's egress addresses mean the credentials were used elsewhere. Nodes that have already been replaced no longer appear in `oc get nodes`; use their instance IDs from your records.
9. **Find and close the source of the token** before you register clusters again: the GitOps hub's cluster Secrets and who can read them, CI runners, scripts, repositories and backups that held tokens.
10. **Open a support case** with Red Hat, and include the evidence from step 2.

## Cleanup

Remove what this guide created for testing. Keep the log forwarding, policy and alarms if you adopt them.

```bash
oc delete application petclinic -n "$GITOPS_NS"
oc delete secret workload-cluster -n "$GITOPS_NS"
oc delete -f host-access-policy.yaml
oc delete namespace "$APP_NS" "$ARGOCD_SA_NS"

for m in DeploymentAccountUnexpectedClient LegacyServiceAccountTokenUsed SCCWrite ClusterRBACWriteNonPlatform; do
  aws cloudwatch delete-alarms --alarm-names "${CLUSTER}-${m}"
  aws logs delete-metric-filter --log-group-name "$LOG_GROUP" --filter-name "$m"
done
aws sns delete-topic --topic-arn "$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':${CLUSTER}-audit-alerts')].TopicArn" --output text)"

LOG_FWD_ID=$(rosa list log-forwarders -c "$CLUSTER" -o json | jq -r '.[] | select(.cloudwatch.log_group_name == env.LOG_GROUP) | .id')
echo "$LOG_FWD_ID"
rosa delete log-forwarder -c "$CLUSTER" "$LOG_FWD_ID" -y
aws iam delete-role-policy --role-name "$LOG_ROLE" --policy-name logfwd
aws iam delete-role --role-name "$LOG_ROLE"
aws logs delete-log-group --log-group-name "$LOG_GROUP"
```

If you created the lab Argo CD instance in step 3, also delete it and the operator:

```bash
oc delete argocd argocd -n "$GITOPS_NS"
oc delete namespace "$GITOPS_NS"
oc delete subscription openshift-gitops-operator -n openshift-gitops-operator
oc delete csv -n openshift-gitops-operator -l operators.coreos.com/openshift-gitops-operator.openshift-gitops-operator
oc delete namespace openshift-gitops-operator
```

## References

* [ROSA: Forwarding control plane logs](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/logging/rosa-forwarding-control-plane-logs)
* [ROSA: Creating a private cluster on ROSA HCP, including additional security groups for the API endpoint](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_clusters/rosa-hcp-aws-private-creating-cluster)
* [ROSA responsibility matrix](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition#rosa-policy-responsibility-matrix)
* [AWS: ROSA architecture models](https://docs.aws.amazon.com/rosa/latest/userguide/rosa-architecture-models.html)
* [AWS: ROSAWorkerInstancePolicy](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/ROSAWorkerInstancePolicy.html)
* [Managed cluster validating webhooks (source)](https://github.com/openshift/managed-cluster-validating-webhooks)
* [RHACS 5.0 documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/5.0)
* [Kubernetes: Validating admission policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
* [Kubernetes: Managing service accounts (bound and legacy tokens)](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/)
* [Argo CD: Declarative setup, clusters](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)
* [Amazon CloudWatch Logs: Filter pattern syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)
* [Amazon CloudWatch Logs: Subscription filters](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/Subscriptions.html)
* [Container Forensics on ROSA HCP with Red Hat Advanced Cluster Security](/experts/rosa/rosa-hcp-container-forensics-acs/)
* [ROSA Best Practices and Recommendations](/experts/rosa/best-practices-recommendations/)
