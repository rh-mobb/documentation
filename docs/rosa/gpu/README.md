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
![UI Create Project](/docs/rosa/gpu/images/0-minsizeclusters.png)

Be connected to both Red Hat account and AWS account
![Rosa CLI](/docs/rosa/gpu/images/0-rosainit.png)

### Install Red Hat OpenShift Data Science(RHODS) addon

- Log into cloud.redhat.com

- Browse to https://cloud.redhat.com/openshift and click on cluster that was created

![Console](/docs/rosa/gpu/images/2-console.png)

- Install and configure RHODS add-on

![Addon](/docs/rosa/gpu/images/3-addons.png)

- Click Install

![RHODS](/docs/rosa/gpu/images/3-RHODS.png)

- Add email to get notification

![RHODSnot](/docs/rosa/gpu/images/3-RHODSnotify.png)

### Adding a Machine Pool with GPUs
 - GPU cluster requirements

![clusterGPU](/docs/rosa/gpu/images/4-clusterGPU.png)

- Here is list of instance sizes that are supported for GPU

![GPUinstance](/docs/rosa/gpu/images/4-GPUinstancesize.png)

More information can be found on [AWS website](https://aws.amazon.com/ec2/instance-types/#Accelerated_Computing)

- Click on MachinePools tab

![machinepool](/docs/rosa/gpu/images/4-machinepool.png)

- Add machine pool with compute instance that supports GPU

![machinepoolGPU](/docs/rosa/gpu/images/4-addGPUmachinepool.png)

### Install NVIDIA add-on
- Pre-requiste for installing NVIDIA Operator
![GPU prereq](/docs/rosa/gpu/images/5-NVIDIAGPUprereq.png)

- Once the prerequistes are met one can install NVIDIA add-on

![NVIDIAoperator](/docs/rosa/gpu/images/5-NVIDIAinstalloperator.png)
