---
date: '2024-09-11'
title: Deploying and Running Ollama and Open WebUI in a ROSA Cluster with GPUs
tags: ["AWS", "ROSA", "GPU", "Ollama", "OpenWebUI"]
aliases: ["/docs/misc/ollama-openwebui"]
authors:
  - Florian Jacquin
---

Red Hat OpenShift Service on AWS (ROSA) provides a managed OpenShift environment that can leverage AWS GPU instances. This guide will walk you through deploying Ollama and OpenWebUI on ROSA using instances with GPU for inferences.

## Prerequisites

* A Red Hat OpenShift on AWS (ROSA classic or HCP) 4.14+ cluster
* OC CLI (Admin access to cluster)
* ROSA CLI

## Set up GPU-enabled Machine Pool

First we need to check availability of our instance type used here (g4dn.xlarge), it should be in same region of the cluster. Note you can use also Graviton based instance (ARM64) like g5g* but only on HCP 4.16+ cluster.

Using the following command, you can check for the availability of the g4dn.xlarge instance type in all eu-* regions:

```bash
for region in $(aws ec2 describe-regions --query 'Regions[?starts_with(RegionName, `eu`)].RegionName' --output text); do
    echo "Region: $region"
    aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters Name=instance-type,Values=g4dn.xlarge --region $region \
    --query 'InstanceTypeOfferings[].Location' --output table
    echo ""
done
```

Example output :

```bash
Region: eu-south-1
-------------------------------
|DescribeInstanceTypeOfferings|
+-----------------------------+
|  eu-south-1c                |
|  eu-south-1b                |
+-----------------------------+

Region: eu-south-2

Region: eu-central-1
-------------------------------
|DescribeInstanceTypeOfferings|
+-----------------------------+
|  eu-central-1a              |
|  eu-central-1b              |
|  eu-central-1c              |
+-----------------------------+

Region: eu-central-2

Region: eu-north-1
-------------------------------
|DescribeInstanceTypeOfferings|
+-----------------------------+
|  eu-north-1c                |
|  eu-north-1a                |
|  eu-north-1b                |
+-----------------------------+

Region: eu-west-3
-------------------------------
|DescribeInstanceTypeOfferings|
+-----------------------------+
|  eu-west-3b                 |
|  eu-west-3a                 |
|  eu-west-3c                 |
+-----------------------------+

Region: eu-west-2
-------------------------------
|DescribeInstanceTypeOfferings|
+-----------------------------+
|  eu-west-2c                 |
|  eu-west-2a                 |
|  eu-west-2b                 |
+-----------------------------+

Region: eu-west-1
-------------------------------
|DescribeInstanceTypeOfferings|
+-----------------------------+
|  eu-west-1c                 |
|  eu-west-1b                 |
|  eu-west-1a                 |
+-----------------------------+
```
> Here we see that this instance is available everywhere in 3 AZ except in eu-south-2 and eu-central-2.

With the region and zone known, use the following command to create a machine pool with GPU Enabled Instances. In this example I have used region eu-central-1c:

```bash
# Replace $mycluster with the name of your ROSA cluster
export CLUSTER_NAME=$mycluster
rosa create machine-pool -c $CLUSTER_NAME --name gpu --replicas=1 --availability-zone eu-central-1c --instance-type g4dn.xlarge --use-spot-instances
```

This command creates a machine pool named "gpu" with one replica using the g4dn.xlarge spot instance, which is an x86_64 instance with Nvidia T4 16GB GPU. It's the cheapest GPU instance you can have at the moment (0.2114$/h at the moment); 16GB of VRAM is enough for running small/medium models. 

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

After the operators are installed, use the following commands to create their instances:

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

Next, use the following commands to deploy Ollama for model inference and OpenWebUI as the interface for interacting with the language model.

1. Create a new project:

   ```bash
   oc new-project llm
   ```

2. The following command deploys Ollama, sets up persistent storage, and allocates a GPU to the deployment:

   ```bash
   oc new-app docker.io/ollama/ollama:0.3.10 --import-mode=PreserveOriginal
   oc patch deployment ollama --type=json -p '[
     {"op": "remove", "path": "/spec/strategy/rollingUpdate"},
     {"op": "replace", "path": "/spec/strategy/type", "value": "Recreate"}
   ]'
   oc set volume deployment/ollama --add --type=pvc --claim-size=50Gi --mount-path=/.ollama --name=config
   oc set resources deployment/ollama --limits=nvidia.com/gpu=1
   ```

3. The following command deploys OpenWebUI and sets up the necessary storage and environment variables and then expose the service with a route:

   ```bash
   oc new-app ghcr.io/open-webui/open-webui:0.3.19 -e WEBUI_SECRET_KEY=secret -e OLLAMA_BASE_URL=http://ollama:11434 --import-mode=PreserveOriginal
   oc set volume deployment/open-webui --add --type=pvc --claim-size=5Gi --mount-path=/app/backend/data --name=data
   oc set volume deployment/open-webui --add --type=emptyDir --mount-path=/app/backend/static --name=static
   oc create route edge --service=open-webui
   ```

## Verify deployment

1. Use the following commands to ensure all nvidia pods are either running or completed

   ```bash
   oc get pods -n nvidia-gpu-operator
   ```

2. All pods of llm namespace should be running

   ```bash
   oc get pods -n llm
   ```

3. Check logs of ollama, it should detect inference compute card

   ```bash
   oc logs -l deployment=ollama
   time=2024-09-12T07:28:40.446Z level=INFO source=images.go:753 msg="total blobs: 0"
   time=2024-09-12T07:28:40.446Z level=INFO source=images.go:760 msg="total unused blobs removed: 0"
   time=2024-09-12T07:28:40.446Z level=INFO source=routes.go:1172 msg="Listening on [::]:11434 (version 0.3.10)"
   time=2024-09-12T07:28:40.446Z level=INFO source=payload.go:30 msg="extracting embedded files" dir=/tmp/ollama1403693285/runners
   time=2024-09-12T07:28:53.779Z level=INFO source=payload.go:44 msg="Dynamic LLM libraries [cuda_v12 rocm_v60102 cpu cpu_avx cpu_avx2 cuda_v11]"
   time=2024-09-12T07:28:53.779Z level=INFO source=gpu.go:200 msg="looking for compatible GPUs"
   time=2024-09-12T07:28:54.324Z level=INFO source=types.go:107 msg="inference compute" id=GPU-51dedb8e-2306-b077-67c1-774b4206c8da library=cuda variant=v12 compute=7.5 driver=12.4 name="Tesla T4" total="14.6 GiB" available="14.5 GiB"
   ```
## Download a model

1. Download llama3.1 8B using Ollama CLI

   ```bash
   oc exec svc/ollama -- ollama pull llama3.1
   ```
   You can check all models available on [https://ollama.com/library](https://ollama.com/library)

## Accessing OpenWebUI

After deploying OpenWebUI, follow these steps to access and configure it:

1. Get the route URL:

   ```bash
   oc get route open-webui
   ```

2. Open the URL in your web browser. You should see the OpenWebUI login page. [https://docs.openwebui.com/](https://docs.openwebui.com/)

3. Initial Setup:
- The first time you access OpenWebUI, you'll need to register.
- Choose a strong password for the admin account.

4. Configuring Models:
- Once logged in, go to the "Models" section to choose the LLMs you want to use.

5. Testing Your Setup:
- Create a new chat and select one of the models you've configured.
- Try sending a test prompt to ensure everything is working correctly.

6. Discover OpenWeb UI! You get lot of features like :
- Model Builder
- Local and Remote RAG Integration
- Web Browsing Capabilities
- Role-Based Access Control (RBAC)

You can read more about OpenWebUI here : [https://docs.openwebui.com/features](https://docs.openwebui.com/features)


## Implement scaling

If you would like to give best experience for multiple users, for example to improve response time and token/s you can scale the Ollama app.

Note that here you should use the EFS (RWX access) storage class instead of the EBS (RWO access) storage class for the storage of ollama models. For instructions on how to set this up, please see [this tutorial](https://cloud.redhat.com/experts/rosa/aws-efs/)

1. Add new GPU node to machine pool

   ```bash
   rosa edit machine-pool -c $CLUSTER_NAME  gpu --replicas=2
   ```

2. Change storage type for ollama app for using EFS

   ```bash
   oc set volume deployment/ollama --add --claim-class=efs-sc --type=pvc --claim-size=50Gi --mount-path=/.ollama --name=config
   ```

3. Scale ollama deployment

   ```bash
   oc scale deployment/ollama --replicas=2
   ```

## Implement downscaling

For cost optimization, you can scale you machine pool of GPU to 0 :

   ```bash
   rosa edit machine-pool -c $CLUSTER_NAME  gpu --replicas=0
   ```

## Uninstalling

1. Delete llm namespace

   ```bash
   oc delete project llm
   ```

2. Delete operators

   ```bash
   oc delete -k https://github.com/redhat-cop/gitops-catalog/nfd/instance/overlays/only-nvidia
   oc delete -k https://github.com/redhat-cop/gitops-catalog/gpu-operator-certified/instance/overlays/aws
   oc delete -k https://github.com/redhat-cop/gitops-catalog/nfd/operator/overlays/stable
   oc delete -k https://github.com/redhat-cop/gitops-catalog/gpu-operator-certified/operator/overlays/stable
   ```

3. Delete machine pool

   ```bash
   rosa delete machine-pool -c $CLUSTER_NAME gpu
   ```

## Conclusion

- You now have Ollama and OpenWebUI deployed on your ROSA cluster, leveraging AWS GPU instances for inference. 
- This setup allows you to run and interact with large language models efficiently using AWS's GPU instances within a managed OpenShift environment.
- This approach represents the best of both worlds: the reliability and support of a managed OpenShift service and AWS, combined with the innovation and rapid advancement of the open-source AI community.
- It allows organizations to stay at the forefront of AI technology while maintaining the security, compliance, and operational standards required in enterprise environments.
