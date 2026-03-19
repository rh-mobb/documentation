---
date: '2026-03-04'
title: Automating ECR Pull Secrets on ROSA Using the External Secrets Operator and STS
tags: ["AWS", "ROSA", "STS"]
authors:
  - Philipp Bergsmann
---

{{% alert state="info" %}}This guide has been validated on **OpenShift 4.20**. Operator CRD names, API versions, and console paths may differ on other versions.{{% /alert %}}

Amazon Elastic Container Registry (ECR) issues short-lived authorization tokens that expire after **12 hours**. On Red Hat OpenShift Service on AWS (ROSA), workloads that pull images from private ECR repositories need those tokens refreshed before they expire — otherwise pods fail to start with `ImagePullBackOff` errors.

The [External Secrets Operator](https://external-secrets.io/) (ESO) solves this by generating and automatically refreshing ECR tokens as Kubernetes `dockerconfigjson` pull secrets. Combined with AWS STS and IAM Roles for Service Accounts (IRSA), this removes every long-lived credential from the picture.

{{% alert state="info" %}}The **External Secrets Operator for Red Hat OpenShift** is available in OperatorHub on ROSA and OpenShift. It is the recommended, fully-supported distribution and is the version used throughout this guide. See the [Red Hat documentation](https://docs.openshift.com/container-platform/latest/security/external-secrets-operator/index.html) for details.{{% /alert %}}

This guide covers two approaches — pick the one that fits your operating model.

#### [Approach A — Namespace-scoped pull secret](#approach-a--namespace-scoped-pull-secret)

Each namespace owns its own IAM role, service account, and ESO resources.

* **IAM role:** one role per namespace/service account
* **ESO resources:** `ECRAuthorizationToken` + `ExternalSecret` per namespace
* **Namespace onboarding:** team creates resources in their namespace
* **Isolation:** strong — each namespace has its own IRSA binding
* **Pros:** least-privilege per team; compromise of one role does not affect others
* **Cons:** more IAM roles to manage; each team must create ESO resources
* **Best for:** multi-tenant clusters, strict isolation

#### [Approach B — Centrally managed with label-based namespace injection](#approach-b--centrally-managed-with-label-based-namespace-injection)

A platform team manages ESO resources once at the cluster level. Namespaces opt in via a label.

* **IAM role:** one shared role on the ESO controller
* **ESO resources:** `ClusterGenerator` + `ClusterExternalSecret` (cluster-scoped)
* **Namespace onboarding:** platform admin adds a label to the namespace
* **Isolation:** shared — single role covers all labeled namespaces
* **Pros:** single setup for the entire cluster; easy onboarding via `oc label`
* **Cons:** broader blast radius — a misconfigured shared role affects all labeled namespaces
* **Best for:** platform-managed clusters, central governance

---

## Prerequisites

* [A ROSA cluster deployed with STS](/experts/rosa/sts/)
* `oc` CLI
* `aws` CLI
* `jq`

### Validate STS

Confirm your cluster is configured with STS before proceeding:

```bash
oc get authentication.config.openshift.io cluster -o json \
  | jq -r .spec.serviceAccountIssuer
```

You should see an HTTPS URL such as `https://oidc.op1.openshiftapps.com/<unique-id>`. If the output is empty, see the [Red Hat documentation on creating an STS cluster](https://docs.openshift.com/rosa/rosa_install_access_delete_clusters/rosa-sts-creating-a-cluster-quickly.html).

### Prepare environment variables

{{% alert state="info" %}}Adjust `AWS_REGION` and `ECR_REPOSITORY` to match your environment.{{% /alert %}}

```bash
export AWS_REGION=us-east-2
export ECR_REPOSITORY=my-private-app

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_PAGER=""  # Disables the AWS CLI interactive pager so command output prints directly to the terminal
export OIDC_ENDPOINT=$(oc get authentication.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|^https://||')
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "Region: ${AWS_REGION}, Account: ${AWS_ACCOUNT_ID}, OIDC: ${OIDC_ENDPOINT}"
```

---

## Install the External Secrets Operator for Red Hat OpenShift

### Option 1: Via the OpenShift Web Console

1. Navigate to **Ecosystem → Software Catalog** and search for **External Secrets Operator**.

1. Select **External Secrets Operator for Red Hat OpenShift** and install it with the default settings (all namespaces, automatic approval).

### Option 2: Via the CLI

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: external-secrets-operator
  namespace: external-secrets-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-external-secrets-operator
  namespace: external-secrets-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-external-secrets-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### Create the ExternalSecretsConfig operand

The operator manager pod installs, but the ESO controllers will not start until you create an `ExternalSecretsConfig` CR named `cluster`. First, wait for the operator CSV to finish installing:

```bash
oc wait csv -n external-secrets-operator -l operators.coreos.com/openshift-external-secrets-operator.external-secrets-operator --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s
```

Then create the operand:

```bash
cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ExternalSecretsConfig
metadata:
  labels:
    app: external-secrets-operator
    app.kubernetes.io/name: cluster
  name: cluster
spec:
  controllerConfig:
    networkPolicies:
    - componentName: ExternalSecretsCoreController
      egress:
      - {}
      name: allow-external-secrets-egress
EOF
```

### Verify the installation

Wait for the operator manager pod to become ready:

```bash
oc get pods -n external-secrets-operator -w
```

After the `ExternalSecretsConfig` operand is created, the operator deploys the ESO controller pods into the `external-secrets` namespace. Verify they are running:

```bash
oc get pods -n external-secrets
```

You should see three pods in `Running` state.

## Create an ECR repository (optional)

{{% alert state="info" %}}Skip this step if you already have a private ECR repository. If so, make sure the `ECR_REPOSITORY` variable set in the previous step matches the name of your existing repository.{{% /alert %}}

```bash
aws ecr create-repository \
  --repository-name ${ECR_REPOSITORY} \
  --region ${AWS_REGION} \
  --image-scanning-configuration scanOnPush=true
```

To push a test image into the new repository so you can validate the pull secret later:

```bash
aws ecr get-login-password --region ${AWS_REGION} | \
  podman login --username AWS --password-stdin ${ECR_REGISTRY}

podman pull --platform linux/amd64 quay.io/nginx/nginx-unprivileged:stable
podman tag quay.io/nginx/nginx-unprivileged:stable ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest
podman push ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest
```

---

## Approach A — Namespace-scoped pull secret

{{% alert state="warning" %}}Complete all [Prerequisites](#prerequisites), [Install the External Secrets Operator for Red Hat OpenShift](#install-the-external-secrets-operator-for-red-hat-openshift), and [Create an ECR repository](#create-an-ecr-repository-optional) steps before continuing.{{% /alert %}}

In this model each namespace owns its own IAM role, service account, and ESO resources. This provides the **strongest isolation** and is the recommended starting point.

### A1) Create an IAM policy for ECR token retrieval

```bash
cat <<EOF > ecr-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${ECR_REPOSITORY}"
    }
  ]
}
EOF

ECR_POLICY_ARN=$(aws iam create-policy \
  --policy-name "RosaEcrPullReadOnly" \
  --policy-document file://ecr-policy.json \
  --query Policy.Arn --output text)
echo ${ECR_POLICY_ARN}
```

{{% alert state="info" %}}`ecr:GetAuthorizationToken` requires `Resource: "*"`. All other actions are scoped to the specific repository.{{% /alert %}}

### A2) Create the application namespace and a dedicated service account

The External Secrets Operator needs a service account annotated with an IAM role to authenticate against AWS via IRSA. A **dedicated** service account (rather than `default`) is used so the IAM trust policy grants ECR access only to the ESO generator — not to every pod in the namespace.

```bash
export APP_NAMESPACE=my-application

oc new-project ${APP_NAMESPACE}
oc create serviceaccount ecr-token-sa -n ${APP_NAMESPACE}
```

### A3) Create an IAM role with an IRSA trust policy

The trust policy restricts role assumption to the specific service account and namespace created above.

```bash
cat <<EOF > trust-policy.json
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
          "${OIDC_ENDPOINT}:sub": "system:serviceaccount:${APP_NAMESPACE}:ecr-token-sa",
          "${OIDC_ENDPOINT}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

ECR_ROLE_ARN=$(aws iam create-role \
  --role-name "rosa-ecr-${APP_NAMESPACE}" \
  --assume-role-policy-document file://trust-policy.json \
  --query Role.Arn --output text)
echo ${ECR_ROLE_ARN}
```

### A4) Attach the policy and annotate the service account

```bash
aws iam attach-role-policy \
  --role-name "rosa-ecr-${APP_NAMESPACE}" \
  --policy-arn ${ECR_POLICY_ARN}

oc annotate serviceaccount ecr-token-sa \
  -n ${APP_NAMESPACE} \
  eks.amazonaws.com/role-arn=${ECR_ROLE_ARN}
```

### A5) Create an ECR token generator

The `ECRAuthorizationToken` custom resource tells the External Secrets Operator how to request a token. The `serviceAccountRef` binds the generator to the IRSA-annotated service account.

```bash
cat <<EOF | oc apply -f -
apiVersion: generators.external-secrets.io/v1alpha1
kind: ECRAuthorizationToken
metadata:
  name: ecr-token-generator
  namespace: ${APP_NAMESPACE}
spec:
  region: ${AWS_REGION}
  auth:
    jwt:
      serviceAccountRef:
        name: ecr-token-sa
EOF
```

### A6) Create an ExternalSecret to render the pull secret

The `ExternalSecret` uses the generator from the previous step and produces a standard `kubernetes.io/dockerconfigjson` secret that OpenShift can use as an image pull secret. The `refreshInterval` is set to **11 hours**, ensuring the token is always refreshed before the 12-hour expiry window.

```bash
cat <<EOF | oc apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ecr-pull-credentials
  namespace: ${APP_NAMESPACE}
spec:
  refreshInterval: 11h
  target:
    name: ecr-docker-credentials
    creationPolicy: Owner
    template:
      type: kubernetes.io/dockerconfigjson
      engineVersion: v2
      data:
        .dockerconfigjson: |
          {
            "auths": {
              "{{ .proxy_endpoint | replace "https://" "" }}": {
                "username": "{{ .username }}",
                "password": "{{ .password }}",
                "auth": "{{ printf "%s:%s" .username .password | b64enc }}"
              }
            }
          }
  dataFrom:
  - sourceRef:
      generatorRef:
        apiVersion: generators.external-secrets.io/v1alpha1
        kind: ECRAuthorizationToken
        name: ecr-token-generator
EOF
```

### A7) Verify the generated secret

```bash
oc get externalsecret ecr-pull-credentials -n ${APP_NAMESPACE} -w
```

The `STATUS` column should show `SecretSynced`. Then confirm the Kubernetes secret exists:

```bash
oc get secret ecr-docker-credentials -n ${APP_NAMESPACE}
```

Expected output:

```
NAME                     TYPE                             DATA   AGE
ecr-docker-credentials   kubernetes.io/dockerconfigjson   1      30s
```

### A8) Link the pull secret to service accounts

By default, OpenShift pods use the `default` service account. That service account does not automatically know about the newly created pull secret. The `oc secrets link --for=pull` command adds the secret to the service account's `imagePullSecrets` list so the kubelet presents the credentials when pulling images.

```bash
oc secrets link default ecr-docker-credentials --for=pull -n ${APP_NAMESPACE}
```

{{% alert state="info" %}}If your workloads use a different service account, link the secret to that service account as well.{{% /alert %}}

### A9) Validate with a test pod

```bash
cat <<EOF | oc apply -n ${APP_NAMESPACE} -f -
apiVersion: v1
kind: Pod
metadata:
  name: ecr-pull-test
spec:
  containers:
  - name: test
    image: ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest
    command: ["/bin/sh", "-c", "echo 'ECR pull succeeded' && sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
EOF
```

Watch the pod until it reaches `Running`:

```bash
oc get pod ecr-pull-test -n ${APP_NAMESPACE} -w
```

If the pod starts successfully the entire pipeline — IRSA, token generator, and pull secret — is working correctly.

### A10) Cleanup

```bash
oc delete project ${APP_NAMESPACE}
aws iam detach-role-policy --role-name "rosa-ecr-${APP_NAMESPACE}" \
  --policy-arn ${ECR_POLICY_ARN}
aws iam delete-role --role-name "rosa-ecr-${APP_NAMESPACE}"
aws iam delete-policy --policy-arn ${ECR_POLICY_ARN}
rm -f ecr-policy.json trust-policy.json
```

---

## Approach B — Centrally managed with label-based namespace injection

{{% alert state="warning" %}}Complete all [Prerequisites](#prerequisites), [Install the External Secrets Operator for Red Hat OpenShift](#install-the-external-secrets-operator-for-red-hat-openshift), and [Create an ECR repository](#create-an-ecr-repository-optional) steps before continuing.{{% /alert %}}

In this model, a platform team manages ESO resources **once at the cluster level**. Any namespace that needs ECR pull secrets simply receives a label.

### How it works

1. The ESO controller service account is annotated with a single shared IRSA role.
2. A **`ClusterGenerator`** defines how to obtain ECR tokens cluster-wide.
3. A **`ClusterExternalSecret`** watches for namespaces with a specific label and creates an `ExternalSecret` (and therefore a pull secret) in each matching namespace automatically.

### B1) Create the shared IAM role for the ESO controller

{{% alert state="info" %}}Reuse the same `OIDC_ENDPOINT` and `AWS_ACCOUNT_ID` variables from the prerequisites section.{{% /alert %}}

```bash
cat <<EOF > central-trust-policy.json
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
          "${OIDC_ENDPOINT}:sub": "system:serviceaccount:external-secrets:external-secrets",
          "${OIDC_ENDPOINT}:aud": "openshift"
        }
      }
    }
  ]
}
EOF

cat <<EOF > ecr-central-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/*"
    }
  ]
}
EOF

CENTRAL_POLICY_ARN=$(aws iam create-policy \
  --policy-name "RosaEcrPullCentral" \
  --policy-document file://ecr-central-policy.json \
  --query Policy.Arn --output text)

CENTRAL_ROLE_ARN=$(aws iam create-role \
  --role-name "rosa-ecr-central" \
  --assume-role-policy-document file://central-trust-policy.json \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name "rosa-ecr-central" \
  --policy-arn ${CENTRAL_POLICY_ARN}

echo "Role ARN: ${CENTRAL_ROLE_ARN}"
```

### B2) Annotate the ESO controller service account

```bash
oc annotate serviceaccount external-secrets \
  -n external-secrets \
  eks.amazonaws.com/role-arn=${CENTRAL_ROLE_ARN}
```

Restart the operator deployment so it picks up the annotation:

```bash
oc rollout restart deployment/external-secrets \
  -n external-secrets
oc rollout status deployment/external-secrets \
  -n external-secrets
```

### B3) Create a cluster-scoped ECR token generator

The `ClusterGenerator` wraps the `ECRAuthorizationToken` spec so it is available across all namespaces without redefining it per team.

```bash
cat <<EOF | oc apply -f -
apiVersion: generators.external-secrets.io/v1alpha1
kind: ClusterGenerator
metadata:
  name: ecr-token-generator
spec:
  kind: ECRAuthorizationToken
  generator:
    ecrAuthorizationTokenSpec:
      region: ${AWS_REGION}
EOF
```

### B4) Create a ClusterExternalSecret with a namespace label selector

The `ClusterExternalSecret` acts as a template: for every namespace carrying the label `ecr-pull-secret: "true"`, the operator creates a namespaced `ExternalSecret` which in turn produces the pull secret.

```bash
cat <<EOF | oc apply -f -
apiVersion: external-secrets.io/v1
kind: ClusterExternalSecret
metadata:
  name: ecr-pull-credentials
spec:
  externalSecretName: ecr-pull-credentials
  namespaceSelectors:
  - matchLabels:
      ecr-pull-secret: "true"
  refreshTime: 1m
  externalSecretSpec:
    refreshInterval: 11h
    target:
      name: ecr-docker-credentials
      creationPolicy: Owner
      template:
        type: kubernetes.io/dockerconfigjson
        engineVersion: v2
        data:
          .dockerconfigjson: |
            {
              "auths": {
                "{{ .proxy_endpoint | replace "https://" "" }}": {
                  "username": "{{ .username }}",
                  "password": "{{ .password }}",
                  "auth": "{{ printf "%s:%s" .username .password | b64enc }}"
                }
              }
            }
    dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: ClusterGenerator
          name: ecr-token-generator
EOF
```

### B5) Onboard namespaces by adding a label

```bash
oc new-project team-a
oc label namespace team-a ecr-pull-secret=true

oc new-project team-b
oc label namespace team-b ecr-pull-secret=true
```

Within a minute the operator will create an `ExternalSecret` and the resulting `ecr-docker-credentials` secret in each labeled namespace:

```bash
oc get externalsecret -n team-a
oc get secret ecr-docker-credentials -n team-a
```

### B6) Link the pull secret in each namespace

As explained in [Approach A, step A8](#a8-link-the-pull-secret-to-service-accounts), linking is required so that pods running under the `default` service account can use the generated pull secret when pulling images from ECR.

```bash
for NS in team-a team-b; do
  oc secrets link default ecr-docker-credentials --for=pull -n ${NS}
done
```

### B7) Validate with a test pod

```bash
cat <<EOF | oc apply -n team-a -f -
apiVersion: v1
kind: Pod
metadata:
  name: ecr-pull-test
spec:
  containers:
  - name: test
    image: ${ECR_REGISTRY}/${ECR_REPOSITORY}:latest
    command: ["/bin/sh", "-c", "echo 'ECR pull succeeded' && sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
EOF

oc get pod ecr-pull-test -n team-a -w
```

### B8) Remove a namespace from ECR pull secret distribution

To stop injecting the secret into a namespace, remove the label:

```bash
oc label namespace team-b ecr-pull-secret-
```

{{% alert state="info" %}}The trailing `-` in the label key tells `oc label` to **remove** the label.{{% /alert %}}

The operator will delete the `ExternalSecret` and the generated secret from that namespace.

### B9) Cleanup (centrally managed)

```bash
oc delete clusterexternalsecret ecr-pull-credentials
oc delete clustergenerator ecr-token-generator
oc delete project team-a team-b

aws iam detach-role-policy --role-name "rosa-ecr-central" \
  --policy-arn ${CENTRAL_POLICY_ARN}
aws iam delete-role --role-name "rosa-ecr-central"
aws iam delete-policy --policy-arn ${CENTRAL_POLICY_ARN}
rm -f ecr-central-policy.json central-trust-policy.json
```

---

## Additional resources

* [External Secrets Operator for Red Hat OpenShift — documentation](https://docs.openshift.com/container-platform/latest/security/external-secrets-operator/index.html)
* [External Secrets Operator — ECR generator reference](https://external-secrets.io/latest/api/generator/ecr/)
* [External Secrets Operator — ClusterExternalSecret reference](https://external-secrets.io/latest/api/clusterexternalsecret/)
* [AWS ECR Private Registry Authentication](https://docs.aws.amazon.com/AmazonECR/latest/userguide/registry_auth.html)
* [Configuring a ROSA cluster to pull images from ECR](/experts/rosa/ecr/)
* [ECR Secret Operator](/experts/rosa/ecr-secret-operator/)
