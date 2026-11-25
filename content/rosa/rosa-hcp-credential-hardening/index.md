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
| Default SCCs | A managed admission webhook blocks customer updates to, and deletion of, a named list of default SCCs, including `privileged`, even for `cluster-admin`. It does **not** control RBAC grants of `use` on those SCCs, and a wildcard role already includes `use` on every SCC. |
| Protected accounts and bindings | Managed webhooks stop customers from deleting service accounts in `kube-system` and `openshift-*` namespaces, and ClusterRoleBindings whose subjects include those accounts. This changes how you revoke an `argocd-manager` account (step 4). |
| Audit profile | The API server uses the `Default` audit profile and you cannot change it. Request bodies for pods and RBAC objects are not recorded, so the audit log does not show which role a binding grants. Pod Security admission still annotates pod requests that would be privileged or use host access in namespaces audited at the `restricted` level (step 6). Check the profile with `oc get apiserver cluster -o jsonpath='{.spec.audit.profile}'`. |
| Audit log source | You get the audit log through control-plane log forwarding to CloudWatch or Amazon S3. RHACS runtime policies that rely on Kubernetes audit log events are not supported on HCP clusters. |
| Client IP | In testing, `sourceIPs` in forwarded audit events was an internal address for requests from outside the cluster. Don't use it to attribute a client; detect token misuse by identity, user agent and behavior instead. |
| API network access | There is no source-IP allowlist for a public API endpoint. To restrict API access by network, use a private (AWS PrivateLink) cluster. Additional security groups on its API endpoint grant access to more sources; they don't narrow the default access from the machine CIDR. |
| Worker nodes | IMDSv2 is set per machine pool with `--ec2-metadata-http-tokens required`. In testing, the worker instance role had only the `ROSAWorkerInstancePolicy` managed policy, which has no AWS write actions (EC2 describe calls and image pulls from Red Hat ECR repositories). The workers had no EC2 key pair, but the managed worker security group allowed TCP 22 from the machine CIDR, so an SSH key planted on a node would be usable from inside the VPC. |
| Node integrity tools | The File Integrity Operator is not supported on HCP. |

### Why ROSA HCP limits the blast radius

- **The control plane is out of reach.** An escape from a pod to a worker host does not expose cluster-wide keys. You replace the affected workers; you do not rebuild etcd or rotate the cluster's signing keys because of a node escape.
- **A stolen in-cluster credential cannot switch off the audit trail.** The API server configuration, the audit profile and the managed admission webhooks cannot be changed through the cluster API, even by `cluster-admin`. Log forwarding is configured in OpenShift Cluster Manager, outside the cluster, so a token for the cluster cannot disable it.
- **Recovery is fast.** Replacing all workers is a machine pool operation that takes minutes, and you never replace control-plane hosts. Provisioning a new cluster from infrastructure as code and GitOps takes minutes rather than hours.
- **The AWS blast radius is smaller.** The managed worker instance policy has no AWS write actions. Require IMDSv2 on every machine pool, and check any extra policies attached to the worker role with `aws iam list-attached-role-policies` and `aws iam list-role-policies`.
- **Shared responsibility still applies.** Red Hat SRE operates and monitors the control plane. Your identities, RBAC, workloads and automation credentials remain your responsibility. See the [ROSA responsibility matrix](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition#rosa-policy-responsibility-matrix).

None of these managed guardrails stop a wildcard role from being misused. That is what the rest of this guide fixes.

## Prerequisites

* A ROSA HCP 4.22 cluster and a user with `cluster-admin`. This guide was validated on a public ROSA HCP 4.22.19 cluster with STS and OpenShift GitOps 1.22.
* An Argo CD instance that deploys to the cluster. It can run on the same cluster or on another one (a GitOps hub). If you don't have one, the optional block in step 3 creates a lab instance on the same cluster.
* CLIs: `rosa`, `oc` (4.22), `aws` (v2) and `jq`. On macOS you can install them with `brew install rosa-cli openshift-cli awscli jq`; on Linux, use the ROSA, OpenShift and AWS CLI download pages. Commands use `bash` or `zsh`.
* Logged in: `rosa whoami` and `aws sts get-caller-identity` succeed, and `oc whoami` shows a `cluster-admin` user on the ROSA HCP cluster. If Argo CD runs on another cluster, also have a kubeconfig context for it.
* Permissions:
  * OpenShift Cluster Manager: create and delete log forwarders and machine pools for the cluster.
  * AWS IAM: create roles and inline role policies.
  * Amazon CloudWatch Logs: create log groups, set retention, create metric filters, filter and test log events, run Logs Insights queries.
  * Amazon CloudWatch and Amazon SNS: create alarms, topics and subscriptions.
  * AWS CloudTrail: look up events.
* About 2 hours. Costs: CloudWatch ingestion and storage for the audit log, five alarms, and in step 8, the replacement machine pool runs alongside the old one until you delete it.

## Set environment variables

Set the values you choose, then let the rest be discovered. Run this with your `oc` context set to the ROSA HCP cluster:

```bash
export CLUSTER=<your-cluster-name>
export ALERT_EMAIL=<address that receives alerts>
export GITOPS_NS=openshift-gitops        # namespace of your Argo CD instance
export ARGOCD_SA_NS=argocd-access        # namespace for the new deployment account
export APP_NS=demo-app                   # namespace Argo CD deploys the application into
export LOG_RETENTION_DAYS=90

export WORKLOAD_CTX=$(oc config current-context)
export HUB_CTX=$WORKLOAD_CTX             # change to your Argo CD cluster's context if it runs elsewhere
export REGION=$(rosa describe cluster -c "$CLUSTER" -o json | jq -r .region.id)
export AWS_REGION=$REGION
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export API=$(oc --context "$WORKLOAD_CTX" whoami --show-server)
export LOG_GROUP=${CLUSTER}-control-plane-audit
export LOG_ROLE=$(echo "CustomerLogDistribution-${CLUSTER}" | cut -c1-64)
export DEPLOYER_SA=system:serviceaccount:${ARGOCD_SA_NS}:argocd-deployer
export METRIC_NS=ROSAAudit/${CLUSTER}
echo "cluster=$CLUSTER region=$REGION account=$ACCOUNT api=$API hub=$HUB_CTX"
```

Check that no value is empty or `null` and that `api` is the API URL of the cluster you mean to change. `AWS_REGION` makes every `aws` command use the cluster's Region.

## 1. Forward control-plane audit logs to CloudWatch

Check whether the cluster already forwards logs:

```bash
rosa list log-forwarders -c "$CLUSTER" -o json \
  | jq -r '.[] | "\(.id)\t\((.groups // []) | map(.id) | join(","))\t\(.cloudwatch.log_group_name // "-")"'
```

If a forwarder already sends the `api` group to a CloudWatch log group, set `LOG_GROUP` to that log group (for example `export LOG_GROUP=<log group from the output>`) and skip to the check at the end of this step. A forwarder that only sends to S3 doesn't support the CloudWatch detections in step 6.

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

You should see `kube-apiserver-*` and `openshift-apiserver-*` streams and an event with `"level": "Metadata"`. Forwarding has no backfill: events from before it was enabled are not delivered, so set it up before you need it.

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
    | .metadata.name as $b | .subjects[]? | select(.kind == "ServiceAccount")
    | select(.namespace | test("^(openshift-|hypershift|open-cluster-management)") | not)
    | "\($k)\t\($b)\t\(.namespace)/\(.name)"'
done | sort -u
```

On the new ROSA HCP 4.22 test cluster, the second command printed nothing. A cluster registered with the default `argocd cluster add` prints `clusterrolebindings  argocd-manager-role-binding  kube-system/argocd-manager`. Don't exclude `kube-system` from this check: that is where `argocd cluster add` creates its account. This is a quick check for literal wildcards. It does not find every powerful account, for example one with a long list of explicit permissions, so also review accounts bound to `cluster-admin`-like roles by name.

List long-lived service account token Secrets. Tokens stored this way never expire:

```bash
oc get secrets -A --field-selector type=kubernetes.io/service-account-token \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,SA:.metadata.annotations.kubernetes\.io/service-account\.name,CREATED:.metadata.creationTimestamp'
```

Treat every non-platform entry in either list as a finding. For each account, check what it can do. Include the service account groups, because RBAC can also grant permissions through them:

```bash
oc auth can-i --list --as=system:serviceaccount:kube-system:argocd-manager \
  --as-group=system:serviceaccounts --as-group=system:serviceaccounts:kube-system
```

## 3. Give Argo CD a least-privilege, short-lived credential

Create the new credential first and switch Argo CD to it, then revoke the old one in step 4. That way deployments don't stop. Commands that change Argo CD run against `HUB_CTX`; commands that change the workload cluster use your current context.

<details>
<summary>Optional: create a lab Argo CD instance on the same cluster</summary>

Skip this if you already have an Argo CD instance. This installs OpenShift GitOps 1.22 without its default instance and creates an Argo CD instance with no route. Set `GITOPS_NS` to a new namespace first, for example `export GITOPS_NS=gitops-lab`.

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
  channel: gitops-1.22
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

The account lives in its own namespace, not `kube-system`. The Role lists the exact resources and verbs the application needs. It has no direct API access to Secrets, service accounts, RBAC or SCCs, and can only read pods. Writing Deployments still gives it control over what runs in `APP_NS`, which is why step 5 adds an admission policy. Adjust the rules to the resource types your application actually deploys.

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

Find the Argo CD instance. This must print exactly one name:

```bash
ARGOCD_NAME=$(oc --context "$HUB_CTX" get argocd -n "$GITOPS_NS" -o jsonpath='{.items[*].metadata.name}')
echo "$ARGOCD_NAME"
```

If Argo CD already has a cluster secret for this API URL (for example the one `argocd cluster add` created), update that secret in place rather than adding a second registration for the same server. Find it, and keep its `name` value so Applications that refer to the cluster by name keep working:

```bash
CLUSTER_SECRET=$(oc --context "$HUB_CTX" get secrets -n "$GITOPS_NS" -l argocd.argoproj.io/secret-type=cluster -o json \
  | jq -r --arg s "$API" '.items[] | select((.data.server | @base64d) == $s) | .metadata.name')
CLUSTER_SECRET=${CLUSTER_SECRET:-workload-cluster}
CLUSTER_NAME=$(oc --context "$HUB_CTX" get secret "$CLUSTER_SECRET" -n "$GITOPS_NS" -o jsonpath='{.data.name}' 2>/dev/null | base64 -d)
CLUSTER_NAME=${CLUSTER_NAME:-workload-cluster}
echo "secret=$CLUSTER_SECRET name=$CLUSTER_NAME"
```

If more than one secret name is printed, the server is registered twice: set `CLUSTER_SECRET` to the one your Applications use and remove the other. Before you narrow access, list the Applications that deploy to this cluster and confirm they only target `APP_NS`:

```bash
oc --context "$HUB_CTX" get applications -n "$GITOPS_NS" -o json \
  | jq -r --arg s "$API" --arg n "$CLUSTER_NAME" '.items[]
    | select(.spec.destination.server == $s or .spec.destination.name == $n)
    | "\(.metadata.name)\t\(.spec.destination.namespace)"'
```

ROSA HCP does not cap the lifetime you request: in testing, `oc create token --duration=8760h` returned a token valid for a full year. Choose a short duration on purpose and plan to rotate it (step 3.3). This example uses 24 hours.

Write the new credential into the cluster secret. It limits Argo CD to `APP_NS` and to namespaced resources. Server-side apply updates an existing secret without storing a copy of the token in the `kubectl.kubernetes.io/last-applied-configuration` annotation:

```bash
TOKEN=$(oc --context "$WORKLOAD_CTX" create token argocd-deployer -n "$ARGOCD_SA_NS" --duration=24h)
oc create secret generic "$CLUSTER_SECRET" -n "$GITOPS_NS" \
  --from-literal=name="$CLUSTER_NAME" \
  --from-literal=server="$API" \
  --from-literal=namespaces="$APP_NS" \
  --from-literal=clusterResources=false \
  --from-literal=config="{\"bearerToken\":\"${TOKEN}\",\"tlsClientConfig\":{\"insecure\":false}}" \
  --dry-run=client -o yaml \
  | oc label -f - --local -o yaml argocd.argoproj.io/secret-type=cluster \
  | oc --context "$HUB_CTX" apply --server-side --force-conflicts --field-manager=credential-hardening -f -
unset TOKEN
oc --context "$HUB_CTX" annotate secret "$CLUSTER_SECRET" -n "$GITOPS_NS" kubectl.kubernetes.io/last-applied-configuration-
```

The last command removes a copy of the old token if the secret was ever created with client-side `oc apply`; otherwise it reports that the annotation was not found. The public ROSA HCP API certificate validated without extra CA data in testing. Keep `insecure` set to `false`.

Tell the Argo CD controller to watch only the resource types its RBAC allows. This setting applies to every cluster the instance manages. Without it, the controller tries to list resource types it cannot access and logs `403` errors; a few still appeared at startup in testing.

```bash
oc --context "$HUB_CTX" patch argocd "$ARGOCD_NAME" -n "$GITOPS_NS" --type merge \
  -p '{"spec":{"extraConfig":{"resource.respectRBAC":"strict"}}}'
```

Deploy a sample application through the new credential. It deploys only the Deployment and Service from the OpenShift GitOps getting-started repository, without its public Route:

```bash
cat <<EOF | oc --context "$HUB_CTX" apply -f -
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
oc --context "$HUB_CTX" wait application/petclinic -n "$GITOPS_NS" --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s
oc --context "$HUB_CTX" get application petclinic -n "$GITOPS_NS" -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
```

Expected result: `Synced/Healthy`. For your own Applications, restrict the destinations and source repositories they may use in their AppProject as well.

### 3.3 Rotate the token

A 24-hour token stops working after 24 hours. Rotation means issuing a new token and updating the cluster secret:

```bash
TOKEN=$(oc --context "$WORKLOAD_CTX" create token argocd-deployer -n "$ARGOCD_SA_NS" --duration=24h)
oc --context "$HUB_CTX" patch secret "$CLUSTER_SECRET" -n "$GITOPS_NS" --type merge \
  -p "{\"stringData\":{\"config\":\"{\\\"bearerToken\\\":\\\"${TOKEN}\\\",\\\"tlsClientConfig\\\":{\\\"insecure\\\":false}}\"}}"
unset TOKEN
oc --context "$HUB_CTX" annotate application petclinic -n "$GITOPS_NS" argocd.argoproj.io/refresh=hard --overwrite
sleep 20
oc --context "$HUB_CTX" get application petclinic -n "$GITOPS_NS" \
  -o jsonpath='{.status.sync.status}/{.status.health.status} reconciledAt={.status.reconciledAt} conditions={.status.conditions}{"\n"}'
```

Expected result: `Synced/Healthy`, a `reconciledAt` time after the rotation, and no conditions. A `ComparisonError` or `Unauthorized` condition means Argo CD is not using a valid token.

Run rotation from an automated, access-controlled job that alerts when it fails, and put it in place before you rely on short-lived tokens. Don't rotate by hand. A longer-term option is a pull model, such as the Red Hat Advanced Cluster Management (RHACM) GitOps pull model or the Argo CD Agent, where each cluster pulls its own configuration and the hub stores no cluster credentials. Check their support status for the OpenShift GitOps and RHACM versions you run.

## 4. Revoke the wildcard credential

When Argo CD syncs through the new account, remove the old credential. On ROSA, managed admission webhooks stop customers from deleting a service account in `kube-system` or an `openshift-*` namespace (other than `builder`, `default` and `deployer`), and from deleting a ClusterRoleBinding whose subjects include such an account. They don't block changes to the binding, so you remove its subjects first. These commands use the names the default, cluster-wide `argocd cluster add` creates; use the names you found in step 2.

List every binding that references the old role, so you don't miss one:

```bash
oc get clusterrolebindings,rolebindings -A -o json \
  | jq -r '.items[] | select(.roleRef.name == "argocd-manager-role") | "\(.kind)\t\(.metadata.namespace // "-")/\(.metadata.name)"'
```

Delete the account's long-lived token Secrets, then remove the binding's subjects, delete the binding and delete the role. Delete any other binding the previous command listed in the same way:

```bash
oc get secrets -n kube-system --field-selector type=kubernetes.io/service-account-token -o json \
  | jq -r '.items[] | select(.metadata.annotations["kubernetes.io/service-account.name"] == "argocd-manager") | .metadata.name' \
  | while read -r s; do oc delete secret "$s" -n kube-system; done
oc patch clusterrolebinding argocd-manager-role-binding --type json -p '[{"op":"remove","path":"/subjects"}]'
oc delete clusterrolebinding argocd-manager-role-binding
oc delete clusterrole argocd-manager-role
```

In testing, deleting a ClusterRoleBinding with a `kube-system` service account subject was denied with `Deleting ClusterRoleBinding ... is not allowed`, and the same delete succeeded after its subjects were removed.

The `kube-system/argocd-manager` service account itself stays: you cannot delete it on ROSA. Without its bindings it has only the default permissions every authenticated identity has. Open a support case if you want it removed.

How revocation behaves, as tested on ROSA HCP 4.22:

* **Long-lived token Secret:** deleting the Secret revokes the token. It kept working for a few seconds and was rejected from about 10 seconds after deletion.
* **Tokens from `oc create token` or a projected volume:** for accounts in your own namespaces, deleting and recreating the ServiceAccount revokes every token issued for it, because the token is bound to the account's UID. For `kube-system/argocd-manager` you cannot do that, so any such token an attacker issued stays valid until it expires; removing the bindings is what takes away its power.
* **Open connections:** revoking a token does not close API watch connections that were opened with it earlier; they end when they time out. That is one more reason to rotate the Secrets the account could read (step 8).

Check the result. The first command prints nothing, the next two return `NotFound`, and the last one shows only default permissions such as `selfsubjectreviews`:

```bash
oc get secrets -n kube-system -o json | jq -r '.items[] | select(.metadata.annotations["kubernetes.io/service-account.name"] == "argocd-manager") | .metadata.name'
oc get clusterrolebinding argocd-manager-role-binding
oc get clusterrole argocd-manager-role
oc auth can-i --list --as=system:serviceaccount:kube-system:argocd-manager \
  --as-group=system:serviceaccounts --as-group=system:serviceaccounts:kube-system | head -8
```

If you kept a copy of an old long-lived token, `oc whoami --token=<old token>` must return `error: You must be logged in to the server (Unauthorized)`.

## 5. Block privileged and host-access pods with an admission policy

Least privilege keeps the deployment account from creating privileged pods. An admission policy is the backstop for every other identity, including `cluster-admin`. It denies privileged containers, `hostPath` volumes, and host network, PID and IPC namespaces everywhere except `openshift`, `openshift-*` and `kube-*` namespaces and namespaces labelled `host-access-exempt=true`.

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
      !(request.namespace.startsWith('openshift-') || request.namespace.startsWith('kube-') || request.namespace == 'openshift')
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

Before you enforce, check the policy and find workloads it would block:

```bash
oc get validatingadmissionpolicy deny-host-access-pods -o jsonpath='{.status.typeChecking}{"\n"}'
oc get pods -A -o json | jq -r '.items[]
  | select((.metadata.namespace | test("^(openshift-|kube-)|^openshift$")) | not)
  | select(.spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true
           or any(.spec.volumes[]?; has("hostPath"))
           or any(.spec.containers[]?, .spec.initContainers[]?, .spec.ephemeralContainers[]?; .securityContext.privileged == true))
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

The first command prints `{}` when the policy's expressions have no type-checking warnings. The second lists running pods that the policy would block if they were created again; workloads that are scaled to zero or not yet deployed are not listed, so also review their manifests.

For each namespace that legitimately needs host access, such as a security agent or a responder namespace for node debugging, label it, for example `oc label namespace <namespace> host-access-exempt=true`. Anyone who can label namespaces can exempt them, and a cluster-wide credential can create an `openshift-` namespace to avoid the policy, so keep those rights to administrators.

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

In `Warn` mode, each of the last three pods is accepted with a `Validation failed for ValidatingAdmissionPolicy 'deny-host-access-pods'` warning. If you see no policy warning, wait a few seconds and run the test again; a new policy can take a moment to load. Then switch to `Deny`, keep `Audit` so violations are also recorded in the audit log, and run the test again:

```bash
oc patch validatingadmissionpolicybinding deny-host-access-pods --type merge -p '{"spec":{"validationActions":["Deny","Audit"]}}'
sleep 15
oc apply --dry-run=server -n "$APP_NS" -f test-pods.yaml 2>&1 | grep -v PodSecurity
```

Expected result: `policy-test-plain created (server dry run)`, and the other three are `forbidden: ValidatingAdmissionPolicy 'deny-host-access-pods' with binding 'deny-host-access-pods' denied request`. As `cluster-admin` you are denied too.

If enforcement blocks something it shouldn't, go back to warnings while you fix the exemption:

```bash
oc patch validatingadmissionpolicybinding deny-host-access-pods --type merge -p '{"spec":{"validationActions":["Warn","Audit"]}}'
```

Things to know:

* The policy checks new and updated pods. It does not evict pods that are already running.
* Workloads that don't request host access are not affected. In testing, a rollout of the Argo CD-managed application succeeded with the policy enforced.
* **Node debugging:** `oc debug node/<node>` runs its pod in the namespace you pass with `--to-namespace` or `-n`. Without either, it uses your current project if that project is labelled `pod-security.kubernetes.io/enforce=privileged`, as `default` is, and otherwise creates a temporary `openshift-debug-*` namespace. With the policy enforced, `oc debug node/<node>` was denied when run from the `default` project, and these two forms worked:
  * `oc debug node/<node> --to-namespace=<namespace labelled host-access-exempt=true>`
  * `oc debug node/<node>` run while the current project is a restricted one, such as `APP_NS`, without `-n`
* Anyone with `cluster-admin` can delete the policy. Least privilege (steps 3 and 4) comes first. To restore a deleted policy automatically, manage it from outside the cluster, for example with RHACM governance policies.

## 6. Detect misuse in the audit log

Use what the `Default` audit profile records on ROSA HCP: the identity, the verb, the resource, the response code, the user agent, and annotations such as `authentication.k8s.io/legacy-token` and `pod-security.kubernetes.io/audit-violations`.

In testing, the audit log showed the Argo CD controller as `argocd-application-controller/...` and a workstation using the same token as `oc/4.22.0 (darwin/amd64)`. `sourceIPs` showed an internal address for both. Every request made with a long-lived token Secret carried `authentication.k8s.io/legacy-token` and `authentication.k8s.io/legacy-token-manual-secret` annotations.

The client sets its own user agent, so a mismatch is a strong lead, not proof, and a careful attacker can copy the expected value. Don't alert on generic tool names alone either: on ROSA HCP, a platform account in `kube-system` (`kas-connection-checker`) calls the API with a `curl` user agent.

### 6.1 Automate alerts with CloudWatch metric filters, alarms and SNS

Create an SNS topic and subscribe your address, then confirm the subscription from the email you receive. Alarms do not notify an address that has not confirmed.

```bash
TOPIC_ARN=$(aws sns create-topic --name "${CLUSTER}-audit-alerts" --query TopicArn --output text)
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL"
```

After you click the link in the email, the subscription shows an ARN instead of `PendingConfirmation`:

```bash
aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --query 'Subscriptions[].SubscriptionArn' --output text
```

Detection 1: the deployment account is used by anything other than Argo CD. The Argo CD server also uses the cluster credential for some UI actions, so both Argo CD user agents are excluded.

```bash
aws logs put-metric-filter --log-group-name "$LOG_GROUP" --filter-name DeploymentAccountUnexpectedClient \
  --filter-pattern "{ \$.user.username = \"${DEPLOYER_SA}\" && \$.userAgent != \"argocd-application-controller/*\" && \$.userAgent != \"argocd-server/*\" }" \
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

Detection 5: a pod that asks for privileged mode, a `hostPath` volume or host namespaces is created or attempted in a namespace audited at the `restricted` Pod Security level, the default for new projects. Pod Security admission names these violations in the `pod-security.kubernetes.io/audit-violations` annotation. In testing it did so for requests the policy in step 5 denied as well as for accepted ones.

```bash
aws logs put-metric-filter --log-group-name "$LOG_GROUP" --filter-name HostAccessPodAttempt \
  --filter-pattern '?"securityContext.privileged=true" ?"restricted volume type" ?"host namespaces"' \
  --metric-transformations metricName=HostAccessPodAttempt,metricNamespace="$METRIC_NS",metricValue=1,defaultValue=0
```

OpenShift raises a namespace's Pod Security audit level automatically when a service account in it is allowed to use a privileged SCC, and a cluster-wide credential can change namespace labels, so treat detection 5 as one signal among several.

Create one alarm per detection. Each alarm fires when one or more matching events arrive in a 5-minute period:

```bash
for m in DeploymentAccountUnexpectedClient LegacyServiceAccountTokenUsed SCCWrite ClusterRBACWriteNonPlatform HostAccessPodAttempt; do
  aws cloudwatch put-metric-alarm --alarm-name "${CLUSTER}-${m}" --namespace "$METRIC_NS" --metric-name "$m" \
    --statistic Sum --period 300 --evaluation-periods 1 --threshold 1 \
    --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN"
done
aws cloudwatch describe-alarms --alarm-name-prefix "${CLUSTER}-" --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
```

An alarm notifies when it changes to `ALARM`, not once per matching event, and returns to `OK` after a 5-minute period with no matches. Human administrators changing cluster RBAC also trigger detection 4. Review those alerts against your change records, or add exclusions for named break-glass identities. Because missing data is treated as not breaching, a break in log delivery looks quiet; check that new log streams keep arriving.

Test each pattern before you rely on it. `aws logs test-metric-filter` runs a pattern against sample events, for example the latest event from the deployment account:

```bash
SAMPLE=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" --filter-pattern "{ \$.user.username = \"${DEPLOYER_SA}\" }" \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --max-items 1 --query 'events[0].message' --output text | head -1)
aws logs test-metric-filter --log-event-messages "$SAMPLE" \
  --filter-pattern "{ \$.user.username = \"${DEPLOYER_SA}\" && \$.userAgent != \"argocd-application-controller/*\" && \$.userAgent != \"argocd-server/*\" }" \
  --query 'length(matches)'
```

The result is `0` when the sample came from Argo CD and `1` when it came from another client.

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
  and user.username not like /^system:serviceaccount:(openshift-|hypershift:|open-cluster-management|kube-system:kas-connection-checker$)/
  and userAgent not like /^kube-controller-manager\//
| stats count(*) as requests by user.username, userAgent
| sort requests desc
| limit 50
EOF
```

* `q-sa-then-pod.txt`: namespaces where a service account was created and a pod was created directly (not by a controller) within the same 10-minute window. This matches step 3 of the attack chain; it shows that both happened, not their order or who did each.
* `q-token-requests.txt`: token requests for service accounts by anyone other than platform components.
* `q-automation-agents.txt`: the user agents each automation account uses, including accounts in `kube-system` such as `argocd-manager`. More than one client per account is worth a look.

Run a query over the last 24 hours:

```bash
QUERY_ID=$(aws logs start-query --log-group-name "$LOG_GROUP" \
  --start-time $(( $(date +%s) - 86400 )) --end-time $(date +%s) \
  --query-string "$(cat q-automation-agents.txt)" --query queryId --output text)
sleep 10
aws logs get-query-results --query-id "$QUERY_ID" --output json \
  | jq -r '.status, (.results[] | map("\(.field)=\(.value)") | join("  "))'
```

The first line of output is the query status. If it is `Running` or `Scheduled`, run the `get-query-results` command again; if it is `Failed` or `Cancelled`, check the query text. To run the other queries, replace the file name in `--query-string`.

### 6.3 Use the same detections in any SIEM

The detections are field conditions on the Kubernetes audit event, so they port to any SIEM. Send the audit log to it with the log forwarder's S3 destination, or with a CloudWatch Logs subscription filter into Amazon Data Firehose. Common destinations include Splunk, Microsoft Sentinel, Elastic, Datadog and Sumo Logic. For Elastic, see [Forwarding ROSA HCP control plane audit logs with Filebeat](/experts/rosa/audit-logs-filebeat/).

| Detection | Audit event conditions |
|---|---|
| Deployment account, unexpected client | `user.username` is the deployment account and `userAgent` starts with neither `argocd-application-controller/` nor `argocd-server/` |
| Long-lived token used | `annotations` contains `authentication.k8s.io/legacy-token` |
| SCC write | `objectRef.resource` = `securitycontextconstraints`, `verb` not in (`get`, `list`, `watch`), `user.username` not `system:admin` or `system:serviceaccount:openshift-*` |
| Cluster RBAC write | `objectRef.resource` in (`clusterroles`, `clusterrolebindings`), write verb, identity not on a platform allowlist |
| Host-access pod | `annotations."pod-security.kubernetes.io/audit-violations"` mentions `securityContext.privileged=true`, a restricted volume type or host namespaces |
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

In testing, `${CLUSTER}-DeploymentAccountUnexpectedClient` changed to `ALARM` 1 to 2 minutes after the request, and the confirmed address received an email. If the alarm is already in `ALARM` from an earlier test, wait until it returns to `OK` before you trigger it again:

```bash
aws cloudwatch describe-alarms --alarm-names "${CLUSTER}-DeploymentAccountUnexpectedClient" \
  --query 'MetricAlarms[0].StateValue' --output text
```

## 8. If a credential has already been stolen

Prepare before an incident: follow [Container Forensics on ROSA HCP](/experts/rosa/rosa-hcp-container-forensics-acs/) step 1 for log forwarding ([1.1](/experts/rosa/rosa-hcp-container-forensics-acs/#11-forward-control-plane-logs-to-cloudwatch)), an evidence bucket with Object Lock ([1.3](/experts/rosa/rosa-hcp-container-forensics-acs/#13-create-an-evidence-bucket-with-object-lock)) and a least-privilege responder role ([1.4](/experts/rosa/rosa-hcp-container-forensics-acs/#14-create-a-forensics-namespace-and-a-least-privilege-responder-role)).

When a credential has been stolen, work through these steps. Do steps 1 and 2 at the same time: revoking the credential stops further misuse, and evidence on pods and nodes is destroyed when they are deleted or replaced.

1. **Revoke the credential and open a support case.** Remove the stolen credential's bindings and token Secrets with step 4. For accounts in your own namespaces, also recreate the ServiceAccount to revoke bound tokens ([forensics 6.10](/experts/rosa/rosa-hcp-container-forensics-acs/#610-revoke-the-stolen-credentials)). Open a support case with Red Hat at the same time.
2. **Preserve evidence.** In the forensics guide: scope the incident ([6.1](/experts/rosa/rosa-hcp-container-forensics-acs/#61-scope)), preserve the node by turning off AutoRepair and cordoning it ([6.2](/experts/rosa/rosa-hcp-container-forensics-acs/#62-preserve-the-node)), capture volatile state ([6.3](/experts/rosa/rosa-hcp-container-forensics-acs/#63-capture-volatile-state-before-isolating)), isolate the pod with a network policy ([6.4](/experts/rosa/rosa-hcp-container-forensics-acs/#64-isolate-the-pod)), checkpoint and collect it ([6.5](/experts/rosa/rosa-hcp-container-forensics-acs/#65-checkpoint-the-container) to [6.7](/experts/rosa/rosa-hcp-container-forensics-acs/#67-collect-the-writable-layer)), collect logs, objects and the image ([6.8](/experts/rosa/rosa-hcp-container-forensics-acs/#68-logs-objects-and-the-image)) and store the evidence with integrity ([6.11](/experts/rosa/rosa-hcp-container-forensics-acs/#611-store-the-evidence-with-integrity)). Record the names, machine pools and EC2 instance IDs of the nodes before anything replaces them:

   ```bash
   oc get nodes -o custom-columns='NODE:.metadata.name,POOL:.metadata.labels.hypershift\.openshift\.io/nodePool,INSTANCE:.spec.providerID'
   ```

3. **Investigate.** Use the audit log and CloudTrail queries in the forensics guide ([7](/experts/rosa/rosa-hcp-container-forensics-acs/#7-investigate-with-the-audit-log-and-cloudtrail)) and the hunting queries in step 6.2.
4. **Sweep for persistence.** This is a triage aid, not proof that a cluster is clean; compare its output with a known-good cluster or an earlier baseline. Set `SINCE` to a UTC time before the earliest suspicious activity, then list standalone objects created since then and objects last written by a CLI or script client:

   ```bash
   export SINCE=<UTC time, for example 2026-01-01T00:00:00Z>
   for r in serviceaccounts roles rolebindings clusterroles clusterrolebindings pods daemonsets deployments statefulsets cronjobs jobs \
            validatingwebhookconfigurations mutatingwebhookconfigurations validatingadmissionpolicies validatingadmissionpolicybindings; do
     oc get "$r" -A -o json | jq -r --arg r "$r" --arg s "$SINCE" '.items[]
       | select(.metadata.creationTimestamp >= $s)
       | select((.metadata.ownerReferences // []) | length == 0)
       | select(.metadata.labels["olm.owner"] == null)
       | select((.metadata.namespace // "") | test("^openshift") | not)
       | select(.metadata.name | test("^(system:|openshift|dedicated-admin)|^(default|builder|deployer)$") | not)
       | "\($r)\t\(.metadata.namespace // "-")/\(.metadata.name)\t\(.metadata.creationTimestamp)"'
   done
   for r in serviceaccounts roles rolebindings clusterroles clusterrolebindings daemonsets cronjobs secrets; do
     oc get "$r" -A --show-managed-fields -o json | jq -r --arg r "$r" '.items[]
       | select(any(.metadata.managedFields[]?; (.manager // "") | test("^(kubectl|oc|curl|python|Go-http-client)"; "i")))
       | "\($r)\t\(.metadata.namespace // "-")/\(.metadata.name)\t\([.metadata.managedFields[] | select((.manager // "") | test("^(kubectl|oc|curl|python|Go-http-client)"; "i")) | "\(.manager):\(.operation)@\(.time)"] | join(","))"'
   done
   ```

   `--show-managed-fields` is required: without it, `oc get` omits the field that records which client last wrote each object, and the second check silently finds nothing. That field shows the client name, not who used it, and objects your own administrators created with `oc` also appear; compare them with your change records. Then check who can use the privileged SCCs, which users and groups are listed directly on SCCs, and recent certificate signing requests, and run the step 2 token Secret list and the step 5 host-access pod query again:

   ```bash
   oc adm policy who-can use scc privileged
   oc get scc -o json | jq -r '.items[] | select(((.users // []) | length) > 0 or ((.groups // []) | length) > 0)
     | "\(.metadata.name)\tusers=\((.users // []) | join(","))\tgroups=\((.groups // []) | join(","))"'
   oc get csr --sort-by=.metadata.creationTimestamp
   ```

5. **Replace the worker nodes.** Treat any node where a privileged or host-mount pod ran as untrusted, and collect the evidence you need from it first (step 2). For each affected machine pool, create a replacement with the same settings and IMDSv2 required, wait for its nodes, drain the old pool and delete it. Set the affected pool and a name for its replacement, then copy the settings:

   ```bash
   export OLD_POOL=<affected machine pool>
   export NEW_POOL=<new machine pool name>
   MP=$(rosa describe machinepool -c "$CLUSTER" --machinepool "$OLD_POOL" -o json)
   MP_TYPE=$(echo "$MP" | jq -r .aws_node_pool.instance_type)
   MP_SUBNET=$(echo "$MP" | jq -r .subnet)
   MP_REPLICAS=$(echo "$MP" | jq -r .replicas)
   MP_DISK=$(echo "$MP" | jq -r .aws_node_pool.root_volume.size)
   MP_LABELS=$(echo "$MP" | jq -r '(.labels // {}) | to_entries | map("\(.key)=\(.value)") | join(",")')
   MP_TAINTS=$(echo "$MP" | jq -r '(.taints // []) | map("\(.key)=\(.value):\(.effect)") | join(",")')
   MP_SGS=$(echo "$MP" | jq -r '(.aws_node_pool.additional_security_group_ids // []) | join(",")')
   echo "type=$MP_TYPE subnet=$MP_SUBNET replicas=$MP_REPLICAS disk=$MP_DISK labels=$MP_LABELS taints=$MP_TAINTS sgs=$MP_SGS"
   ```

   If `replicas` is `null`, the pool uses autoscaling: replace `--replicas "$MP_REPLICAS"` in the next command with `--enable-autoscaling --min-replicas <min> --max-replicas <max>` from the `autoscaling` field of `$MP`. Create the replacement and wait until all its nodes are `Ready`:

   ```bash
   rosa create machinepool -c "$CLUSTER" --name "$NEW_POOL" --replicas "$MP_REPLICAS" \
     --instance-type "$MP_TYPE" --subnet "$MP_SUBNET" --disk-size "${MP_DISK}GiB" --ec2-metadata-http-tokens required \
     ${MP_LABELS:+--labels=$MP_LABELS} ${MP_TAINTS:+--taints=$MP_TAINTS} ${MP_SGS:+--additional-security-group-ids=$MP_SGS}
   oc wait nodes -l hypershift.openshift.io/nodePool=${CLUSTER}-${NEW_POOL} --for=condition=Ready --timeout=20m
   oc get nodes -l hypershift.openshift.io/nodePool=${CLUSTER}-${NEW_POOL}
   ```

   Run `oc wait` again if it reports that no nodes were found yet, and continue only when the number of `Ready` nodes matches the old pool. The node pool label is the cluster name and the machine pool name joined by `-`; check it against the `POOL` column you recorded in step 2. Move the workloads and delete the old pool:

   ```bash
   oc adm cordon -l hypershift.openshift.io/nodePool=${CLUSTER}-${OLD_POOL}
   oc adm drain -l hypershift.openshift.io/nodePool=${CLUSTER}-${OLD_POOL} --ignore-daemonsets --delete-emptydir-data --timeout=10m
   rosa delete machinepool -c "$CLUSTER" "$OLD_POOL" -y
   oc get nodes -L hypershift.openshift.io/nodePool
   ```

   `--delete-emptydir-data` discards data in `emptyDir` volumes on the drained nodes. If the drain stops because a PodDisruptionBudget cannot be met, fix the workload and run it again. In testing, a new node was `Ready` about 4 minutes after `rosa create machinepool`, the drained workload moved to it immediately, and the old node left the cluster about 1 minute after the pool was deleted.

6. **Rotate secrets.** A wildcard token can read every Secret in the cluster. Rotate application credentials, registry credentials, identity-provider client secrets and any cloud credentials stored in the cluster.
7. **Check AWS activity for the worker role.** Worker instance role sessions are named after the EC2 instance ID. Review where each session was used from since `SINCE`, for the current nodes and for the instance IDs you recorded in step 2:

   ```bash
   for i in $(oc get nodes -o jsonpath='{.items[*].spec.providerID}' | tr ' ' '\n' | awk -F/ '{print $NF}'); do
     aws cloudtrail lookup-events --lookup-attributes AttributeKey=Username,AttributeValue="$i" \
       --start-time "$SINCE" --max-results 50 --query 'Events[].CloudTrailEvent' --output json \
       | jq -r --arg i "$i" '.[] | fromjson | "\($i)\t\(.eventTime)\t\(.eventSource)\t\(.eventName)\t\(.sourceIPAddress)"'
   done
   ```

   Calls from addresses outside your VPC's egress addresses mean the credentials were used elsewhere. CloudTrail event history covers 90 days in the current Region; use a trail or CloudTrail Lake for longer or multi-Region searches.
8. **Find and close the source of the token** before you register clusters again: the GitOps hub's cluster Secrets and who can read them, CI runners, scripts, repositories and backups that held tokens.

## Cleanup

These blocks remove what you created only for testing. Don't run a block for anything you adopted: if you migrated your real Argo CD registration in step 3, keep `CLUSTER_SECRET`, `ARGOCD_SA_NS` and the Role and RoleBinding in `APP_NS`.

Remove the sample application, and the namespaces only if you created them for this guide:

```bash
oc --context "$HUB_CTX" delete application petclinic -n "$GITOPS_NS"
oc delete namespace "$APP_NS" "$ARGOCD_SA_NS"
```

Remove the test registration only if you created it for this guide rather than migrating an existing one:

```bash
oc --context "$HUB_CTX" delete secret "$CLUSTER_SECRET" -n "$GITOPS_NS"
```

Remove the admission policy if you are not keeping it:

```bash
oc delete -f host-access-policy.yaml
```

Remove the detections:

```bash
for m in DeploymentAccountUnexpectedClient LegacyServiceAccountTokenUsed SCCWrite ClusterRBACWriteNonPlatform HostAccessPodAttempt; do
  aws cloudwatch delete-alarms --alarm-names "${CLUSTER}-${m}"
  aws logs delete-metric-filter --log-group-name "$LOG_GROUP" --filter-name "$m"
done
TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':${CLUSTER}-audit-alerts')].TopicArn" --output text)
echo "$TOPIC_ARN"
aws sns delete-topic --topic-arn "$TOPIC_ARN"
```

Remove log forwarding only if you created it in step 1. Deleting the log group permanently deletes the audit history in it. The `echo` must print exactly one forwarder ID:

```bash
LOG_FWD_ID=$(rosa list log-forwarders -c "$CLUSTER" -o json | jq -r '.[] | select(.cloudwatch.log_group_name == env.LOG_GROUP) | .id')
echo "$LOG_FWD_ID"
rosa delete log-forwarder -c "$CLUSTER" "$LOG_FWD_ID" -y
aws iam delete-role-policy --role-name "$LOG_ROLE" --policy-name logfwd
aws iam delete-role --role-name "$LOG_ROLE"
aws logs delete-log-group --log-group-name "$LOG_GROUP"
```

If you created the lab Argo CD instance in step 3, delete it and the operator. The operator also created an empty `openshift-gitops` namespace:

```bash
oc delete argocd argocd -n "$GITOPS_NS"
oc delete namespace "$GITOPS_NS"
oc delete subscription openshift-gitops-operator -n openshift-gitops-operator
oc delete csv -n openshift-gitops-operator -l operators.coreos.com/openshift-gitops-operator.openshift-gitops-operator
oc delete namespace openshift-gitops-operator openshift-gitops
```

Remove the local files this guide created:

```bash
rm -f logfwd-trust.json logfwd-policy.json logfwd.yaml host-access-policy.yaml test-pods.yaml \
  q-sa-then-pod.txt q-token-requests.txt q-automation-agents.txt
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
