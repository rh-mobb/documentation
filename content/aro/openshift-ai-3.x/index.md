---
date: '2026-07-22'
title: Installing Red Hat OpenShift AI 3.x on Azure Red Hat OpenShift
tags: ["ARO", "RHOAI"]
authors:
  - Kumudu Herath
  - Kevin Collins
---
<!-- TODO(validate): add validated_version once re-tested end to end on ARO -->

This guide installs Red Hat OpenShift AI (RHOAI) 3.x Self-Managed on an Azure Red Hat OpenShift (ARO) cluster. You get the dashboard, workbenches, model serving (KServe), AI pipelines and the model registry. Optional components such as GPUs and distributed workloads are added afterwards.

Planning a proof of concept? See the [ARO POC guide for OpenShift AI](https://github.com/rh-mobb/poc-guides/blob/main/aro/04-special-considerations/04b-AI.md) for sizing and success criteria.

## Prerequisites

* An ARO cluster on a version supported by RHOAI 3.x. See [Supported configurations](https://access.redhat.com/articles/rhoai-supported-configs-3.x).
* At least 3 worker nodes with 8 vCPUs and 32 GiB of memory each (for example `Standard_D8s_v5`).
* The `oc` CLI, logged in as a cluster administrator.

> **Note:** RHOAI works with ARO [egress lockdown](https://learn.microsoft.com/en-us/azure/openshift/concepts-egress-lockdown). Your firewall must allow access to the Red Hat registries.

## Check the cluster

Confirm the worker nodes have enough capacity:

```bash
oc get nodes -l node-role.kubernetes.io/worker -o custom-columns='NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory' \
  | awk 'NR==1{printf "%-55s %-6s %s\n",$1,"vCPUs","MEMORY"} NR>1{m=$3; gsub(/Ki/,"",m); printf "%-55s %-6s %.0f GB\n",$1,$2,m/1024/1024}'
```

## Install the cert-manager Operator

KServe and the distributed workloads components need cert-manager.

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Wait for the operator to finish installing:

```bash
oc wait subscription/openshift-cert-manager-operator -n cert-manager-operator \
  --for=jsonpath='{.status.state}'=AtLatestKnown --timeout=300s
oc wait csv -n cert-manager-operator -l operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

## Install the OpenShift AI Operator

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable-3.x
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```
<!-- TODO(validate): consider pinning to stable-3.<minor> once re-tested; confirm channel list with
     oc get packagemanifest rhods-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' -->

```bash
oc wait subscription/rhods-operator -n redhat-ods-operator \
  --for=jsonpath='{.status.state}'=AtLatestKnown --timeout=600s
oc wait csv -n redhat-ods-operator -l operators.coreos.com/rhods-operator.redhat-ods-operator \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s
```

> **Tip:** To control upgrades yourself, set `installPlanApproval: Manual`. Then approve each InstallPlan with `oc get installplan -n redhat-ods-operator` and `oc patch installplan <name> -n redhat-ods-operator --type merge -p '{"spec":{"approved":true}}'`.

## Create the DataScienceCluster

The DataScienceCluster sets which components the operator deploys. This example turns on the core components and leaves the optional ones as `Removed`. You can turn those on later (see [Optional components](#optional-components)).

```bash
cat <<EOF | oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    workbenches:
      managementState: Managed
      workbenchNamespace: rhods-notebooks
    aipipelines:
      managementState: Managed
    kserve:
      managementState: Managed
    modelregistry:
      managementState: Managed
      registriesNamespace: rhoai-model-registries
    kueue:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
    feastoperator:
      managementState: Removed
    llamastackoperator:
      managementState: Removed
EOF
```

It can take up to 10 minutes for the components to become ready:

```bash
oc wait datasciencecluster/default-dsc --for=jsonpath='{.status.phase}'=Ready --timeout=900s
```

## Open the dashboard

```bash
echo "https://rh-ai.$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')"
```

Log in with your OpenShift credentials. Then create a data science project and start a workbench to check the installation.

> **Note:** In RHOAI 3.4 and later, the dashboard is served at `rh-ai.apps.<cluster-domain>`. The legacy `rhods-dashboard` and `data-science-gateway` URLs redirect there.

## Validate

Check that every component condition reports `True`:

```bash
oc get datasciencecluster default-dsc \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\n"}{end}'
oc get pods -n redhat-ods-applications
```

> **Next step:** Before you can create a pipeline server, AI pipelines need S3-compatible object storage. On ARO, follow [Data science pipelines with Azure Blob storage on ARO](/experts/aro/openshift-ai-pipelines-storage/).

## Optional components

Each optional component needs some extra setup, and then you set it to `Managed` in the DataScienceCluster.

| Component | Extra setup | DataScienceCluster change |
|---|---|---|
| AI pipelines storage | An S3-compatible bucket. See [Data science pipelines with Azure Blob storage on ARO](/experts/aro/openshift-ai-pipelines-storage/) | None (configured per project) |
| GPUs | GPU MachineSet, Node Feature Discovery, NVIDIA GPU Operator. See [ARO with NVIDIA GPU workloads](/experts/aro/gpu/), then [create a hardware profile](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/working_with_accelerators/index) | None |
| Distributed workloads (Ray, Training) | Red Hat build of Kueue Operator (see below) | `kueue: Unmanaged`, `ray` / `trainingoperator: Managed` |
| Distributed inference (llm-d) | Leader Worker Set and Red Hat Connectivity Link operators | See the [RHOAI docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/installing_and_uninstalling_openshift_ai_self-managed/index) |
| Llama Stack | Service Mesh 3, plus GPUs | `llamastackoperator: Managed` |
| TrustyAI, Feast | None | `trustyai` / `feastoperator: Managed` |

### Enable distributed workloads

1. Install the Red Hat build of Kueue Operator:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      name: openshift-kueue-operator
      labels:
        openshift.io/cluster-monitoring: "true"
    ---
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
      name: kueue-operator
      namespace: openshift-kueue-operator
    ---
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: kueue-operator
      namespace: openshift-kueue-operator
    spec:
      channel: stable-v1.3
      name: kueue-operator
      source: redhat-operators
      sourceNamespace: openshift-marketplace
      installPlanApproval: Automatic
    EOF

    oc wait subscription/kueue-operator -n openshift-kueue-operator \
      --for=jsonpath='{.status.state}'=AtLatestKnown --timeout=300s
    oc wait csv -n openshift-kueue-operator -l operators.coreos.com/kueue-operator.openshift-kueue-operator \
      --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
    ```
    <!-- TODO(validate): channel name was taken from the original PR; confirm against the packagemanifest -->

1. Create the Kueue instance:

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: kueue.openshift.io/v1
    kind: Kueue
    metadata:
      name: cluster
      namespace: openshift-kueue-operator
    spec:
      managementState: Managed
      config:
        integrations:
          frameworks:
          - BatchJob
          - RayJob
          - RayCluster
          - PyTorchJob
    EOF
    ```
    <!-- TODO(validate): confirm RayJob/RayCluster/PyTorchJob are accepted framework values in RHBoK -->

1. Turn on the components in the DataScienceCluster:

    ```bash
    oc patch datasciencecluster default-dsc --type merge -p \
      '{"spec":{"components":{"kueue":{"managementState":"Unmanaged"},"ray":{"managementState":"Managed"},"trainingoperator":{"managementState":"Managed"}}}}'
    ```

1. Label each data science project that should use Kueue:

    ```bash
    oc label namespace <project> kueue.openshift.io/managed=true
    ```

## Troubleshooting

{{% expand "DataScienceCluster stays in Progressing" %}}
Find the condition that isn't `True`, then check the operator logs:

```bash
oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[?(@.status!="True")]}{.type}: {.message}{"\n"}{end}'
oc logs -n redhat-ods-operator deployment/rhods-operator --tail=50
```
A component that needs an operator you haven't installed (for example `kueue` without the Kueue Operator) will report it here.
{{% /expand %}}

{{% expand "An operator wait times out" %}}
Check for an InstallPlan that is waiting for approval. Some cluster policies force manual approval:

```bash
oc get installplan -n <namespace>
oc patch installplan <name> -n <namespace> --type merge -p '{"spec":{"approved":true}}'
```
{{% /expand %}}

{{% expand "Service Mesh CSV fails with \"OwnNamespace InstallModeType not supported\"" %}}
The default install in this guide doesn't need Service Mesh. Service Mesh 3 only supports the `AllNamespaces` install mode, so this error means it was subscribed in a namespace whose OperatorGroup sets `targetNamespaces`. Find the Subscription and its OperatorGroup:

```bash
oc get subscription -A | grep servicemesh
oc get operatorgroup -n <namespace> -o yaml
```
Remove `targetNamespaces` from that OperatorGroup, or remove the Subscription if nothing needs it.
{{% /expand %}}

## Clean up

> **Warning:** This removes OpenShift AI from the whole cluster, including every workbench, model deployment and model registry, and the data stored in them. Back up anything you need first.

```bash
oc create configmap delete-self-managed-odh -n redhat-ods-operator
oc label configmap/delete-self-managed-odh api.openshift.com/addon-managed-odh-delete=true -n redhat-ods-operator
oc wait --for=delete namespace/redhat-ods-applications --timeout=15m
oc delete namespace redhat-ods-operator
```

If the wait times out, check `oc get datasciencecluster -o yaml` and the operator logs for resources that are blocking deletion.

cert-manager and Kueue may be used by other workloads. Check before you remove them (for example, `oc get certificates -A` and `oc get clusterqueues`).
