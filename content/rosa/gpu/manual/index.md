---
date: '2023-02-21'
title: ROSA with Nvidia GPU Workloads - Manual
tags: ["AWS", "ROSA", "GPU"]
authors:
  - Chris Kang
  - Diana Sari
---


This is a guide to install GPU on ROSA cluster manually, which is an alternative to our [Helm chart guide](https://cloud.redhat.com/experts/rosa/gpu/).

### Prerequisites

* ROSA cluster (4.14+) 
    - You can install a Classic version using [CLI](https://cloud.redhat.com/experts/rosa/sts/) or an HCP one using [Terraform](https://cloud.redhat.com/experts/rosa/terraform/hcp/).
    - Please be sure you are logged in to the cluster with a cluster admin access.
* rosa cli
* oc cli


### 1. Setting up GPU machine pools

In this tutorial, I'm using `g5.4xlarge node` for the GPU machine pools with auto-scaling enabled up to 4 nodes. Please replace `your-cluster-name` with the name of your cluster. 

*Note that you can also use another instance type and not using auto-scaling.* 

```
rosa create machinepool --cluster=<your-cluster-name> --name=gpu-pool --instance-type=g5.4xlarge --min-replicas=1 --max-replicas=4 --enable-autoscaling --labels='gpu-node=true' --taints='nvidia.com/gpu=present:NoSchedule'
```

### 2. Installing NFD operator

The [Node Feature Discovery operator](https://github.com/kubernetes-sigs/node-feature-discovery-operator) will discover the GPU on your nodes and NFD instance will appropriately label the nodes so you can target them for workloads. Please refer to the [official OpenShift documentation](https://docs.openshift.com/container-platform/4.16/hardware_enablement/psap-node-feature-discovery-operator.html) for more details.  

```
#!/bin/bash

set -e

# create the openshift-nfd namespace
oc create namespace openshift-nfd

# apply the OperatorGroup and Subscription
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: openshift-nfd-
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
  channel: "stable"
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for NFD Operator to be deployed..."

# wait for the NFD Operator deployment to be available
while ! oc get deployment -n openshift-nfd | grep -q nfd-controller-manager; do
  sleep 5
done

# wait for the deployment to be ready
oc wait --for=condition=available --timeout=300s deployment/nfd-controller-manager -n openshift-nfd

# check if the deployment is ready
if [ $? -eq 0 ]; then
  echo "NFD Operator is deployed and ready."
else
  echo "Timeout waiting for NFD Operator to be ready. Please check the deployment status manually."
fi

# display the pods in the openshift-nfd namespace
echo "Pods in openshift-nfd namespace:"
oc get pods -n openshift-nfd
```

Note that this above might take a few minutes. And then next, we will create the NFD instance.

```
#!/bin/bash

set -e

# apply the NodeFeatureDiscovery configuration
cat <<EOF | oc apply -f -
kind: NodeFeatureDiscovery
apiVersion: nfd.openshift.io/v1
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery@sha256:07658ef3df4b264b02396e67af813a52ba416b47ab6e1d2d08025a350ccd2b7b
    servicePort: 12000
EOF

echo "Waiting for NFD instance to be created..."
timeout 300 bash -c 'until oc get nodefeaturediscovery nfd-instance -n openshift-nfd &>/dev/null; do sleep 5; done'

if [ $? -eq 0 ]; then
    echo "NFD instance has been successfully created."
else
    echo "Timed out waiting for NFD instance to be created."
    exit 1
fi
```


### 3. Installing GPU operator

Next, we will set up [NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator) that manages NVIDIA software components and `ClusterPolicy` object to ensure the right setup for NVIDIA GPU in the OpenShift environment. Please refer to the [official NVIDIA documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/openshift/install-gpu-ocp.html) for more details.

```
#!/bin/bash

set -e

# fetch the latest channel
CHANNEL=$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')

# fetch the latest CSV
STARTINGCSV=$(oc get packagemanifests/gpu-operator-certified -n openshift-marketplace -o json | jq -r --arg CHANNEL "$CHANNEL" '.status.channels[] | select(.name == $CHANNEL) | .currentCSV')

# create namespace if it doesn't exist
oc create namespace nvidia-gpu-operator 2>/dev/null || true

# apply the OperatorGroup and Subscription
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
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
  channel: "${CHANNEL}"
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF

# wait for the CSV to be available
echo "Waiting for ClusterServiceVersion to be available..."
while ! oc get csv -n nvidia-gpu-operator ${STARTINGCSV} &>/dev/null; do
    sleep 5
done

# apply the ClusterPolicy
oc get csv -n nvidia-gpu-operator ${STARTINGCSV} -ojsonpath='{.metadata.annotations.alm-examples}' | jq '.[0]' | oc apply -f -

echo "GPU Operator installation completed successfully."
```

And finally, let's update the `ClusterPolicy`.

```
#!/bin/bash

set -e

# apply the ClusterPolicy for the GPU operator
cat <<EOF | oc apply -f -
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
  daemonsets:
    enabled: true
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
  devicePlugin:
    enabled: true
  driver:
    enabled: true
  gfd:
    enabled: true
  migManager:
    enabled: true
  nodeStatusExporter:
    enabled: true
  toolkit:
    enabled: true
EOF

echo "Waiting for ClusterPolicy to be ready..."
if oc wait clusterpolicy/gpu-cluster-policy --for=condition=Ready --timeout=300s -n gpu-operator-resources; then
    echo "ClusterPolicy has been successfully created and is ready."
    echo "ClusterPolicy status:"
    oc get clusterpolicy -n gpu-operator-resources
else
    echo "Timed out waiting for ClusterPolicy to be ready."
    exit 1
fi
```

### Validating GPU (optional)

By now you should have your GPU setup correctly, however, if you'd like to validate it, you could run the following on terminal. 


```
#!/bin/bash

# wait for GPU operator components
wait_for_gpu_operator() {
    echo "Waiting for GPU Operator components to be ready..."
    while [[ $(oc get pods -n nvidia-gpu-operator -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | grep -v True) != "" ]]; do
        echo "Waiting for all pods to be ready in nvidia-gpu-operator namespace..."
        sleep 10
    done
    echo "All GPU Operator components are ready."
}

# verify NFD can see your GPU(s)
echo "Verifying NFD GPU detection:"
oc describe node -l node-role.kubernetes.io/worker="" | grep nvidia.com/gpu.present || echo "No GPU nodes detected"

# verify GPU Operator added node label to your GPU nodes
echo -e "\nVerifying GPU node labels:"
oc get node -l nvidia.com/gpu.present || echo "No nodes with GPU labels found"

# wait for GPU operator components
wait_for_gpu_operator

# test GPU access using NVIDIA SMI
echo -e "\nTesting GPU access with NVIDIA SMI:"
DRIVER_POD=$(oc get pods -n nvidia-gpu-operator | grep nvidia-driver | grep Running | awk '{print $1}' | head -n 1)
if [ -n "$DRIVER_POD" ]; then
    echo "Running nvidia-smi in pod $DRIVER_POD"
    oc exec -n nvidia-gpu-operator $DRIVER_POD -c nvidia-driver-ctr -- nvidia-smi || echo "Failed to run nvidia-smi"
else
    echo "No NVIDIA driver pod found. Checking all pods in nvidia-gpu-operator namespace:"
    oc get pods -n nvidia-gpu-operator
    echo "Unable to find a running NVIDIA driver pod. Please check if the NVIDIA GPU Operator is installed correctly."
fi

# create and run a test pod
echo -e "\nRunning a test GPU workload:"
cat <<EOF | oc create -f - || echo "Failed to create test pod"
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vector-add
  namespace: nvidia-gpu-operator
spec:
  restartPolicy: OnFailure
  containers:
    - name: cuda-vector-add
      image: "nvidia/samples:vectoradd-cuda11.2.1"
      resources:
        limits:
          nvidia.com/gpu: 1
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
EOF

# wait for the pod to complete and check its logs
echo "Waiting for test pod to complete..."
if oc wait --for=condition=completed pod/cuda-vector-add -n nvidia-gpu-operator --timeout=120s; then
    oc logs cuda-vector-add -n nvidia-gpu-operator || echo "Failed to retrieve logs"
else
    echo "Test pod did not complete within the expected time. Checking pod status:"
    oc describe pod cuda-vector-add -n nvidia-gpu-operator
fi

# clean up
echo -e "\nCleaning up:"
oc delete pod cuda-vector-add -n nvidia-gpu-operator || echo "Failed to delete test pod"

echo "GPU validation process completed."
```

In essence, here you verify that NFD can detect the GPUs, run `nvidia-smi` on the GPU driver daemonset pod, run a simple CUDA vector addition test pod, and delete it.


Note that the script could take a few minutes to complete. And if you were seeing any error, e,g, `No GPU nodes detected`, etc., then you might want to try again in the next few minutes. 



