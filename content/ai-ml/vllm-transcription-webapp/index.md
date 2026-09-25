---
date: '2026-09-25'
title: Deploying vLLM with Audio and LLM Inference on ROSA with GPUs
tags: ["ROSA", "ROSA HCP", "RHOAI"]
aliases: ["/docs/ai-ml/vllm-transcription-webapp"]
authors:
  - Florian Jacquin
validated_version: "4.22"
---

This guide deploys audio transcription and text inference on Red Hat OpenShift Service on AWS (ROSA) with NVIDIA GPUs. Models run on the vLLM runtime that ships with Red Hat OpenShift AI, using Red Hat model images from the container registry.

This procedure was run on a ROSA with hosted control planes cluster, OpenShift 4.22.10, in `us-east-1`. The installed software was:

* Node Feature Discovery Operator `4.22.0-202609151747` from the `stable` channel
* NVIDIA GPU Operator `26.7.1` (`gpu-operator-certified.v26.7.1`) from the `stable` channel
* Red Hat OpenShift AI `3.5.1` from the `stable-3.x` channel
* vLLM `0.24.0` from `registry.redhat.io/rhaii/vllm-cuda-rhel9`, through the OpenShift AI template `vllm-cuda-runtime-template`
* `registry.redhat.io/rhelai1/modelcar-whisper-large-v3-turbo-quantized-w4a16:1.5`
* `registry.redhat.io/rhelai1/modelcar-gpt-oss-20b:1.5`

The GPU pool was two `g6.xlarge` nodes (one NVIDIA L4, 24 GB, per node). `gpt-oss-20b` needs about 16 GB of GPU memory.

## Use case

Transcribe audio conversations, such as meetings or customer calls, and send the transcript to a language model for a summary, decisions, and action items. The models stay on the cluster.

## Prerequisites

* A ROSA with hosted control planes cluster, OpenShift 4.22, with `cluster-admin` access
* The `oc` and `rosa` CLIs, logged in to the cluster, and `jq`
* AWS quota for two `g6.xlarge` instances in the cluster Region
* Three worker nodes besides the GPU pool. This validation used three `m7i.xlarge` workers for OpenShift AI

## 1. Create a GPU machine pool

Create a dedicated pool with one GPU per model server. The taint keeps other workloads off these nodes.

```bash
export CLUSTER=<your-cluster-name>

rosa create machinepool \
  --cluster=$CLUSTER \
  --name=gpu \
  --replicas=2 \
  --instance-type=g6.xlarge \
  --labels=node-role.kubernetes.io/gpu=,nvidia.com/gpu.present=true \
  --taints=nvidia.com/gpu=true:NoSchedule \
  -y
```

On the multi-AZ cluster used for this validation, both replicas were placed in one availability zone. Wait until the pool reports two ready replicas:

```bash
rosa describe machinepool --cluster=$CLUSTER --machinepool=gpu
```

## 2. Install the GPU software stack

Install Node Feature Discovery and the certified NVIDIA GPU Operator from the `stable` channel. On this cluster that installed NFD `4.22.0-202609151747` and `gpu-operator-certified.v26.7.1`.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait until both CSVs are `Succeeded`, then create the NFD instance:

```bash
oc get csv -n openshift-nfd
oc get csv -n nvidia-gpu-operator

cat <<'EOF' | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec: {}
EOF
```

Create the `ClusterPolicy` from the example shipped with the installed GPU Operator:

```bash
CSV=$(oc get csv -n nvidia-gpu-operator -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep '^gpu-operator-certified' | head -n1)

oc get csv -n nvidia-gpu-operator "$CSV" \
  -o jsonpath='{.metadata.annotations.alm-examples}' \
  | jq -r '.[] | select(.kind=="ClusterPolicy")' > gpu-cluster-policy.json

oc apply -f gpu-cluster-policy.json
```

The driver build took about five minutes after the GPU nodes joined. The `ClusterPolicy` can report ready before a GPU node exists. Confirm allocatable GPUs before continuing:

```bash
oc get nodes -l node.kubernetes.io/instance-type=g6.xlarge \
  -o jsonpath='{range .items[*]}{.metadata.name}{" gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

Each GPU node should report `gpu=1`.

## 3. Install OpenShift AI

This validation enabled the dashboard and KServe. The other OpenShift AI components were left `Removed` so they would not schedule onto the three worker nodes.

```bash
oc new-project redhat-ods-operator

cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable-3.x
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Wait until the operator CSV is `Succeeded`:

```bash
oc get csv -n redhat-ods-operator
```

This validation installed `rhods-operator.3.5.1`.

Create the initialization object and the `DataScienceCluster`:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: dscinitialization.opendatahub.io/v2
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: redhat-ods-applications
  monitoring:
    managementState: Managed
    metrics: {}
    namespace: redhat-ods-monitoring
  trustedCABundle:
    customCABundle: ""
    managementState: Managed
---
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    aigateway:
      batchGateway:
        managementState: Removed
      managementState: Removed
    aipipelines:
      managementState: Removed
    dashboard:
      managementState: Managed
    feastoperator:
      managementState: Removed
    kserve:
      managementState: Managed
      modelsAsService:
        managementState: Removed
      nim:
        managementState: Removed
      wva:
        managementState: Removed
    kueue:
      managementState: Removed
    llamastackoperator:
      managementState: Removed
    mcplifecycleoperator:
      managementState: Removed
    mlflowoperator:
      managementState: Removed
    modelregistry:
      managementState: Removed
    ogx:
      managementState: Removed
    ray:
      managementState: Removed
    sparkoperator:
      managementState: Removed
    trainer:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Removed
EOF
```

Wait until the data science cluster is `Ready`:

```bash
oc get dsc default-dsc
```

KServe on this release reports vLLM `v0.24.0`. The first reconcile can fail while the KServe webhook pod is still starting. Wait and check again. It became `Ready` once `kserve-controller-manager` and `llmisvc-controller-manager` were running.

## 4. Deploy the vLLM runtime and the models

Create a project and apply the OpenShift AI vLLM CUDA runtime template. The template creates a `ServingRuntime` named `vllm-cuda-runtime`. It serves the model mounted at `/mnt/models` on port `8080`, and it publishes the InferenceService name as the model id.

```bash
oc new-project inference

oc process -n redhat-ods-applications vllm-cuda-runtime-template | oc apply -n inference -f -
```

Deploy Whisper and `gpt-oss-20b` from the Red Hat model images. Each server requests one GPU and tolerates the machine pool taint.

```bash
cat <<'EOF' | oc apply -n inference -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: whisper
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 1
    model:
      modelFormat:
        name: vLLM
      runtime: vllm-cuda-runtime
      storageUri: oci://registry.redhat.io/rhelai1/modelcar-whisper-large-v3-turbo-quantized-w4a16:1.5
      resources:
        requests:
          cpu: "1"
          memory: 4Gi
          nvidia.com/gpu: "1"
        limits:
          cpu: "2"
          memory: 8Gi
          nvidia.com/gpu: "1"
    tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: "true"
      effect: NoSchedule
---
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: gpt-oss-20b
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 1
    model:
      modelFormat:
        name: vLLM
      runtime: vllm-cuda-runtime
      storageUri: oci://registry.redhat.io/rhelai1/modelcar-gpt-oss-20b:1.5
      resources:
        requests:
          cpu: "1"
          memory: 8Gi
          nvidia.com/gpu: "1"
        limits:
          cpu: "3"
          memory: 12Gi
          nvidia.com/gpu: "1"
    tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: "true"
      effect: NoSchedule
EOF
```

The `gpt-oss-20b` model image is about 41 GB, and the vLLM runtime image is about 18 GB. The first pull and model load took roughly 25 minutes in this validation. Wait until both InferenceServices are `Ready`:

```bash
oc get inferenceservice -n inference
oc get pods -n inference -o wide
```

The predictor Services are headless. Each Service exposes port `80` and targets container port `8080`, but a headless Service does not translate the port. Clients must call port `8080`. A call to port `80` on the pod IP is refused.

The `serving.kserve.io/deploymentMode: RawDeployment` annotation is stored as `Standard` after reconcile. The pods are still normal Deployments, which is what this validation used.

```bash
oc exec -n inference deploy/whisper-predictor -c kserve-container -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/v1/models").read().decode())'

oc exec -n inference deploy/gpt-oss-20b-predictor -c kserve-container -- \
  python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/v1/models").read().decode())'
```

The model ids are `whisper` and `gpt-oss-20b`.

## 5. Deploy the transcription web application

The sample application is [rh-mobb/transcription-webapp](https://github.com/rh-mobb/transcription-webapp). It forwards audio to `/v1/audio/transcriptions` and text to `/v1/chat/completions`.

```bash
oc new-app https://github.com/rh-mobb/transcription-webapp.git --strategy=docker \
  -e AUDIO_INFERENCE_URL=http://whisper-predictor:8080 \
  -e AUDIO_MODEL_NAME=whisper \
  -e LLM_INFERENCE_URL=http://gpt-oss-20b-predictor:8080 \
  -e LLM_MODEL_NAME=gpt-oss-20b
```

Wait for the image build and the rollout:

```bash
oc logs -f buildconfig/transcription-webapp
oc rollout status deploy/transcription-webapp
```

Create the route after the deployment is available:

```bash
oc create route edge transcription-webapp --service=transcription-webapp
oc annotate route transcription-webapp haproxy.router.openshift.io/timeout=180s --overwrite
oc get route transcription-webapp
```

Open the route. The application accepts WAV files only. Upload a WAV file to transcribe it, then summarize the transcript. A one-second tone returned a transcription payload, and a short summary request returned a chat completion from `gpt-oss-20b` (`vllm-0.24.0`).

## Cost

Scale the GPU pool to zero when it is idle:

```bash
rosa edit machinepool gpu --cluster=$CLUSTER --replicas=0
```

## Uninstall

Delete the application project:

```bash
oc delete project inference
```

Remove OpenShift AI. Wait until the `DataScienceCluster` is gone before deleting the operator:

```bash
oc delete datasciencecluster default-dsc
oc delete dscinitialization default-dsci
oc delete subscription rhods-operator -n redhat-ods-operator
oc delete csv -n redhat-ods-operator -l operators.coreos.com/rhods-operator.redhat-ods-operator
oc delete namespace redhat-ods-operator redhat-ods-applications redhat-ods-monitoring
```

Remove the GPU stack and the machine pool:

```bash
oc delete clusterpolicy gpu-cluster-policy
oc delete subscription gpu-operator-certified -n nvidia-gpu-operator
oc delete namespace nvidia-gpu-operator

oc delete nodefeaturediscovery nfd-instance -n openshift-nfd
oc delete subscription nfd -n openshift-nfd
oc delete namespace openshift-nfd

rosa delete machinepool --cluster=$CLUSTER --machinepool=gpu
```
