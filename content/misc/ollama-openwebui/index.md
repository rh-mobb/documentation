---
date: '2024-09-11'
title: Deploying and Running Ollama and Open WebUI in a ROSA Cluster with GPUs
tags: ["AWS", "ROSA", "GPU", "Ollama", "OpenWebUI"]
aliases: ["/docs/misc/ollama-openwebui-graviton-gpu"]
authors:
  - Florian Jacquin
---

Red Hat OpenShift Service on AWS (ROSA) provides a managed OpenShift environment that can leverage AWS's GPU instances. This guide will walk you through deploying Ollama and OpenWebUI on ROSA using Graviton instances with GPU for inferences.

## Prerequisites

* A Red Hat OpenShift on AWS (ROSA) 4.16+ cluster
* The OC CLI
* The ROSA CLI

## Set up GPU-enabled Machine Pool

First we need to check availability of our instance type used here (g5g.2xlarge), it should be in same region of the cluster. Note you can use also x86_64 based instance like g4dn*.

```bash
for region in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
    echo "Region: $region"
    aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters Name=instance-type,Values=g5g.2xlarge --region $region \
    --query 'InstanceTypeOfferings[].Location' --output table
    echo ""
done
```

And then we can create a machine pool with GPU-enabled instances, in our example i use eu-central-1c AZ; this is the only place where you can find spot instance g5g.2xlarge in EU at the moment:

```bash
rosa create machine-pool -c $CLUSTER_NAME --name gpu --replicas=1 --availability-zone eu-central-1c --instance-type g5g.2xlarge --use-spot-instances
```

This command creates a machine pool named "gpu" with one replica using the g5g.2xlarge spot instance, which is a Graviton-based CPU instance (ARM64) with Nvidia T4 16GB GPU. A.K.A best performance/price at the moment. (0.2610$/h)

Note that mixed architecture for nodes is available only on HCP since 4.16.

## Deploy Required Operators

We'll use kustomize to deploy the necessary operators thanks to this repository provided by Red Hat COP (Community of Practices) https://github.com/redhat-cop/gitops-catalog

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

After the operators are installed, create their instances:

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

## Deploy Ollama and OpenWebUI

Now, let's deploy Ollama for inference and OpenWebUI for interacting with the LLM:

1. Create a new project:
   ```bash
   oc new-project llm
   ```

2. Deploy Ollama:
   ```bash
   oc new-app docker.io/ollama/ollama:0.3.10 --import-mode=PreserveOriginal
   oc patch deployment ollama -p '{"spec":{"strategy":{"type":"Recreate"}}}'
   oc set volume deployment/ollama --add --type=pvc --claim-size=50Gi --mount-path=/.ollama --name=config
   oc set resources deployment/ollama --limits=nvidia.com/gpu=1
   ```
   This deploys Ollama, sets up persistent storage, and allocates a GPU to the deployment.

3. Deploy OpenWebUI:
   ```bash
   oc new-app ghcr.io/open-webui/open-webui:0.3.19 -e WEBUI_SECRET_KEY=secret -e OLLAMA_BASE_URL=http://ollama:11434 --import-mode=PreserveOriginal
   oc set volume deployment/open-webui --add --type=pvc --claim-size=5Gi --mount-path=/app/backend/data --name=data
   oc set volume deployment/open-webui --add --type=emptyDir --mount-path=/app/backend/static --name=static
   ```
   This deploys OpenWebUI and sets up the necessary storage and environment variables.

4. Create a route for OpenWebUI:
   ```bash
   oc create route edge --service=open-webui
   ```
   This creates an edge-terminated route to access OpenWebUI.

## Accessing OpenWebUI

After deploying OpenWebUI, follow these steps to access and configure it:

1. Get the route URL:
   ```bash
   oc get route open-webui
   ```

2. Open the URL in your web browser. You should see the OpenWebUI login page.

3. Initial Setup:
   - The first time you access OpenWebUI, you'll need to register.
   - Choose a strong password for the admin account.

4. Configuring Models:
   - Once logged in, go to the "Models" section to download and configure the LLMs you want to use.
   - Start with a smaller model to test your setup before moving to larger, more resource-intensive models.

5. Testing Your Setup:
   - Create a new chat and select one of the models you've configured.
   - Try sending a test prompt to ensure everything is working correctly.

## Conclusion

You now have Ollama and OpenWebUI deployed on your ROSA cluster, leveraging Graviton GPU instances for inference. This setup allows you to run and interact with large language models efficiently using the power of AWS's GPU instances within a managed OpenShift environment. This approach represents the best of both worlds: the reliability and support of a managed OpenShift service, combined with the innovation and rapid advancement of the open-source AI community. It allows organizations to stay at the forefront of AI technology while maintaining the security, compliance, and operational standards required in enterprise environments.
