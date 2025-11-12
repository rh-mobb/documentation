---
date: '2024-11-12'
title: Deploying vLLM with Audio and LLM Inference on ROSA with GPUs
tags: ["AWS", "ROSA", "GPU", "vLLM", "AI", "Whisper", "Inference"]
aliases: ["/docs/ai-ml/vllm-transcription-webapp"]
authors:
  - Florian Jacquin
---

Red Hat OpenShift Service on AWS (ROSA) provides a managed OpenShift environment that can leverage AWS GPU instances. This guide will walk you through deploying vLLM for both audio transcription (Whisper) and large language model inference on ROSA using GPU instances, along with a web application to interact with both services.

## Use case

Automatically transcribe audio conversations (meetings, customer calls) and analyze content with an LLM to extract insights, decisions, and action items

Maintain confidentiality of sensitive data by avoiding external SaaS services, while benefiting from advanced AI capabilities (transcription + intelligent analysis) with a production-ready and supported solution.

## Prerequisites

* A Red Hat OpenShift on AWS (ROSA classic or HCP) 4.18+ cluster
* OC CLI (Admin access to cluster)
* ROSA CLI

## Set up GPU-enabled Machine Pool

First we need to check availability of our instance type used here (g6.xlarge), it should be in same region of the cluster.

Using the following command, you can check for the availability of the g6.xlarge instance type in all eu-* regions:

```bash
for region in $(aws ec2 describe-regions --query 'Regions[?starts_with(RegionName, `eu`)].RegionName' --output text); do
    echo "Region: $region"
    aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters Name=instance-type,Values=g6.xlarge --region $region \
    --query 'InstanceTypeOfferings[].Location' --output table
    echo ""
done
```

With the region and zone known, use the following command to create a machine pool with GPU Enabled Instances. In this example we use region eu-west-3b:

```bash
# Replace $mycluster with the name of your ROSA cluster
export CLUSTER_NAME=$mycluster
rosa create machine-pool -c $CLUSTER_NAME --name gpu --replicas=2 --instance-type g6.xlarge
```

This command creates a machine pool named "gpu" with two replicas using the g6.xlarge instance, which provides modern GPU capabilities suitable for inference workloads.

## Deploy Required Operators

We'll use kustomize to deploy the necessary operators thanks to this repository provided by Red Hat COP (Community of Practices) [link](https://github.com/redhat-cop/gitops-catalog)

1. Node Feature Discovery (NFD) Operator:

   ```bash
   oc apply -k https://github.com/redhat-cop/gitops-catalog/nfd/operator/overlays/stable
   ```
   The NFD Operator detects hardware features and configuration in your cluster.

2. GPU Operator:

   ```bash
   oc apply -k https://github.com/redhat-cop/gitops-catalog/gpu-operator-certified/operator/overlays/stable
   ```
   The GPU Operator manages NVIDIA GPUs drivers in your cluster.

## Create Operator Instances

After the operators are installed, wait about 20 seconds, then use the following commands to create their instances:

1. NFD Instance:

   ```bash
   oc apply -k https://github.com/redhat-cop/gitops-catalog/nfd/instance/overlays/only-nvidia
   ```
   This creates an NFD instance for cluster.

2. GPU Operator Instance:

   ```bash
   oc apply -k https://github.com/redhat-cop/gitops-catalog/gpu-operator-certified/instance/overlays/aws
   ```
   This creates a GPU Operator instance configured for AWS.

## Deploy vLLM for Audio Inference (Whisper)

Next, we'll deploy a vLLM instance for audio transcription using the Whisper model.

1. Create a new project:

   ```bash
   oc new-project inference
   ```

2. Deploy the Whisper vLLM instance:

   ```bash
   oc new-app registry.redhat.io/rhaiis/vllm-cuda-rhel9:3 --name rh-inf-whisper -l app=rh-inf-whisper \
     -e HF_HUB_OFFLINE=0 \
     -e VLLM_MAX_AUDIO_CLIP_FILESIZE_MB=500
   ```

3. Configure the deployment strategy to use Recreate instead of rolling updates:

   ```bash
   oc patch deployment rh-inf-whisper --type=json -p='[
     {"op": "replace", "path": "/spec/strategy/type", "value": "Recreate"},
     {"op": "remove", "path": "/spec/strategy/rollingUpdate"}
   ]'
   ```

4. Add persistent storage for model caching:

   ```bash
   oc set volume deployment/rh-inf-whisper --add --type=pvc --claim-size=100Gi --mount-path=/opt/app-root/src/.cache --name=llm-cache
   ```

5. Allocate GPU resources:

   ```bash
   oc set resources deployment/rh-inf-whisper --limits=nvidia.com/gpu=1
   ```

6. Configure vLLM to serve the Whisper model:

   ```bash
   oc patch deployment rh-inf-whisper --type='json' -p='[
     {
       "op": "replace",
       "path": "/spec/template/spec/containers/0/command",
       "value": ["vllm"]
     },
     {
       "op": "replace",
       "path": "/spec/template/spec/containers/0/args",
       "value": [
         "serve",
         "RedHatAI/whisper-large-v3-turbo-quantized.w4a16"
       ]
     }
   ]'
   ```

7. Create a service to expose the Whisper inference endpoint:

   ```bash
   oc create service clusterip rh-inf-whisper --tcp=8000:8000
   ```

## Deploy vLLM for LLM Inference

Now we'll deploy a second vLLM instance for language model inference.

1. Deploy the LLM vLLM instance:

   ```bash
   oc new-app registry.redhat.io/rhaiis/vllm-cuda-rhel9:3 --name rh-inf-llm -l app=rh-inf-llm \
     -e HF_HUB_OFFLINE=0 \
     -e VLLM_MAX_AUDIO_CLIP_FILESIZE_MB=500
   ```

2. Configure the deployment strategy:

   ```bash
   oc patch deployment rh-inf-llm --type=json -p='[
     {"op": "replace", "path": "/spec/strategy/type", "value": "Recreate"},
     {"op": "remove", "path": "/spec/strategy/rollingUpdate"}
   ]'
   ```

3. Add persistent storage for model caching:

   ```bash
   oc set volume deployment/rh-inf-llm --add --type=pvc --claim-size=100Gi --mount-path=/opt/app-root/src/.cache --name=llm-cache
   ```

4. Allocate GPU resources:

   ```bash
   oc set resources deployment/rh-inf-llm --limits=nvidia.com/gpu=1
   ```

5. Configure vLLM to serve the language model:

   ```bash
   oc patch deployment rh-inf-llm --type='json' -p='[
     {
       "op": "replace",
       "path": "/spec/template/spec/containers/0/command",
       "value": ["vllm"]
     },
     {
       "op": "replace",
       "path": "/spec/template/spec/containers/0/args",
       "value": [
         "serve",
         "RedHatAI/gpt-oss-20b"
       ]
     }
   ]'
   ```

6. Create a service to expose the LLM inference endpoint:

   ```bash
   oc create service clusterip rh-inf-llm --tcp=8000:8000
   ```

## Deploy the Transcription Web Application

Finally, we'll deploy a web application that integrates both the audio transcription and LLM inference services.

> **Note**: This transcription web application was entirely created using Cursor IDE with a single prompt. The complete prompt used to generate the application can be found in the [PROMPT.md](https://github.com/fjcloud/transcription-webapp/blob/main/PROMPT.md) file of the repository. This demonstrates how modern AI-assisted development tools can rapidly create functional applications from a well-structured prompt.

1. Deploy the application from the Git repository:

   ```bash
   oc new-app https://github.com/fjcloud/transcription-webapp.git --strategy=docker \
   -e AUDIO_INFERENCE_URL=http://rh-inf-whisper:8000 \
   -e AUDIO_MODEL_NAME=RedHatAI/whisper-large-v3-turbo-quantized.w4a16 \
   -e LLM_INFERENCE_URL=http://rh-inf-llm:8000 \
   -e LLM_MODEL_NAME=RedHatAI/gpt-oss-20b
   ```

2. Create a secure route to access the application:

   ```bash
   oc create route edge --service=transcription-webapp
   ```

3. Configure the route timeout for longer processing times:

   ```bash
   oc annotate route transcription-webapp haproxy.router.openshift.io/timeout=180s
   ```

## Verify Deployment

1. Use the following commands to ensure all nvidia pods are either running or completed:

   ```bash
   oc get pods -n nvidia-gpu-operator
   ```

2. All pods in the inference namespace should be running:

   ```bash
   oc get pods -n inference
   ```

3. Check logs of the Whisper inference service to verify GPU detection:

   ```bash
   oc logs -l app=rh-inf-whisper
   ```

4. Check logs of the LLM inference service:

   ```bash
   oc logs -l app=rh-inf-llm
   ```

5. Verify that both vLLM instances can receive requests and have started correctly:

   ```bash
   oc exec deployment/rh-inf-whisper -- curl -XPOST localhost:8000/ping -s -I
   oc exec deployment/rh-inf-llm -- curl -XPOST localhost:8000/ping -s -I
   ```
   
   You should receive HTTP 200 responses from both endpoints, indicating the services are ready to accept inference requests.

## Accessing the Web Application

After deploying the transcription web application, follow these steps to access it:

1. Get the route URL:

   ```bash
   oc get route transcription-webapp
   ```

2. Open the URL in your web browser. You should see the transcription application interface.

3. Testing Your Setup:
   - Upload an audio file to test the Whisper transcription service.
   - The transcribed text can be processed further using the LLM service.
   - Verify that both services are responding correctly.

## Architecture Overview

This deployment creates a complete inference pipeline:

- **Whisper Service**: Handles audio transcription using the Whisper large v3 turbo quantized model
- **LLM Service**: Provides text generation and processing capabilities using the GPT-OSS 20B model
- **Web Application**: Provides a user-friendly interface to interact with both services

Each vLLM instance runs in its own pod with dedicated GPU resources, ensuring optimal performance and isolation.

## Cost Optimization

For development or non-production environments, you can scale down the GPU machine pool to 0 when not in use:

```bash
rosa edit machine-pool -c $CLUSTER_NAME gpu --replicas=0
```

This helps optimize costs while maintaining the ability to quickly scale up when needed.

## Uninstalling

1. Delete the inference namespace:

   ```bash
   oc delete project inference
   ```

2. Delete operator instances:

   ```bash
   oc delete -k https://github.com/redhat-cop/gitops-catalog/nfd/instance/overlays/only-nvidia
   oc delete -k https://github.com/redhat-cop/gitops-catalog/gpu-operator-certified/instance/overlays/aws
   ```

3. Delete operators:

   ```bash
   oc delete -k https://github.com/redhat-cop/gitops-catalog/nfd/operator/overlays/stable
   oc delete -k https://github.com/redhat-cop/gitops-catalog/gpu-operator-certified/operator/overlays/stable
   ```

4. Delete the GPU machine pool:

   ```bash
   rosa delete machine-pool -c $CLUSTER_NAME gpu
   ```

## Conclusion

- **Production-Ready Solution**: By using exclusively Red Hat certified container images (registry.redhat.io), this deployment benefits from the complete Red Hat lifecycle management, including security patches, updates, and enterprise support. This allows organizations to rapidly achieve a fully production-ready AI inference platform.
- **Enhanced Productivity with Confidentiality**: This solution enables organizations to significantly boost employee productivity with AI capabilities while maintaining complete data confidentiality. By deploying models on-premises or in your own cloud infrastructure, you avoid the risks of shadow IT and maintain full control over sensitive data, ensuring it never leaves your security perimeter.
