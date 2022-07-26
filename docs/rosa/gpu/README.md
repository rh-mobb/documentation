# ROSA with GPU Workloads

ROSA guide to running GPU workloads.


## Table of Contents

* Do not remove this line (it will not be displayed)
{:toc}

## Prerequisites

* oc cli
* rosa cli

If you need to install an ROSA cluster, please read our [ROSA Quick start guide](https://mobb.ninja/docs/quickstart-rosa.html). Please be sure if you're installing or using an existing ROSA cluster that it is 4.10.x or higher.

### Creating a ROSA Cluster
Minimum cluster requirements
/docs/gpu/images/minsizeclusters.png

Be connected to both Red Hat account and AWS account
/docs/rosa/gpu/images/rosainit.png

### Install Red Hat OpenShift Data Science(RHODS) addon

1. Log into cloud.redhat.com

1. Browse to https://cloud.redhat.com/openshift and click on cluster that was created.
/docs/gpu/images/2-console.png

1. Install and configure RHODS add-on
/docs/rosa/gpu/images/3-addons.png
/docs/rosa/gpu/images/3-RHODS.png
/docs/rosa/gpu/images/3-RHODSnotify.png

### Adding a Machine Pool with GPUs
GPU cluster requirements
/docs/gpu/images/4-clusterGPU.png

Here is list of instance sizes that are supported for GPU 
/docs/rosa/gpu/images/4-GPUinstancesize.png
More information can be found on [AWS website](https://aws.amazon.com/ec2/instance-types/#Accelerated_Computing)

1. Click on MachinePools tab and add machine pool with compute instance that supports GPU
/docs/rosa/gpu/images/4-machinepool.png
/docs/rosa/gpu/images/4-addGPUmachinepool.png

### Install GPU add-on
1. Pre-requiste for installing NVIDIA Operator
/docs/rosa/gpu/images/5-NVIDIAGPUprereq.png

1. Install NVIDIA add-on
/docs/rosa/gpu/images/5-GPUaddon.png
/docs/rosa/gpu/images/5-NVIDIAinstalloperator.png