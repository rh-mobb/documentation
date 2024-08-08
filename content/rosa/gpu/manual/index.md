---
date: '2023-02-21'
title: Manual steps for ROSA with Nvidia GPU Workloads
tags: ["AWS", "ROSA", "GPU"]
authors:
  - Chris Kang
  - Diana Sari
  - Paul Czarkowski
---

### Manually

#### Install Nvidia GPU Operator

1. Create Nvidia namespace

   ```bash
   oc create namespace nvidia-gpu-operator
   ```

1. Create Operator Group

   ```yaml
   cat <<EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     name: nvidia-gpu-operator-group
     namespace: nvidia-gpu-operator
   spec:
    targetNamespaces:
    - nvidia-gpu-operator
   EOF
   ```

1. Get latest nvidia channel

   ```bash
   CHANNEL=$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
   ```

1. Get latest nvidia package

   ```bash
   PACKAGE=$(oc get packagemanifests/gpu-operator-certified -n openshift-marketplace -ojson | jq -r '.status.channels[] | select(.name == "'$CHANNEL'") | .currentCSV')
   ```

1. Create Subscription

   ```yaml
   envsubst  <<EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: gpu-operator-certified
     namespace: nvidia-gpu-operator
   spec:
     channel: "$CHANNEL"
     installPlanApproval: Automatic
     name: gpu-operator-certified
     source: certified-operators
     sourceNamespace: openshift-marketplace
     startingCSV: "$PACKAGE"
   EOF
   ```

1. Wait for Operator to finish installing

   ```bash
   oc rollout status deploy/gpu-operator -n nvidia-gpu-operator --timeout=300s
   ```

#### Install Node Feature Discovery Operator

The node feature discovery operator will discover the GPU on your nodes and appropriately label the nodes so you can target them for workloads.  We'll install the NFD operator into the opneshift-ndf namespace and create the "subscription" which is the configuration for NFD.

Official Documentation for Installing [Node Feature Discovery Operator](https://docs.openshift.com/container-platform/4.10/hardware_enablement/psap-node-feature-discovery-operator.html)

1. Set up namespace

   ```bash
   oc create namespace openshift-nfd
   ```

1. Create OperatorGroup

   ```yaml
   cat <<EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     generateName: openshift-nfd-
     name: openshift-nfd
     namespace: openshift-nfd
   EOF
   ```

1. Create Subscription

   ```yaml
   cat <<EOF | oc apply -f -
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
   ```

1. Wait for Node Feature discovery to complete installation

   ```bash
   oc rollout status deploy/nfd-controller-manager -n openshift-nfd --timeout=300s
   ```

1. Create NFD Instance

   ```yaml
   cat <<EOF | oc apply -f -
   kind: NodeFeatureDiscovery
   apiVersion: nfd.openshift.io/v1
   metadata:
     name: nfd-instance
     namespace: openshift-nfd
   spec:
     customConfig:
       configData: {}
     operand:
       image: >-
         registry.redhat.io/openshift4/ose-node-feature-discovery@sha256:07658ef3df4b264b02396e67af813a52ba416b47ab6e1d2d08025a350ccd2b7b
       servicePort: 12000
     workerConfig:
       configData: |
         core:
           sleepInterval: 60s
         sources:
           pci:
             deviceClassWhitelist:
               - "0200"
               - "03"
               - "12"
             deviceLabelFields:
               - "vendor"
   EOF
   ```

1. Wait until NFD instances are ready

   ```bash
   oc wait --for=jsonpath='{.status.numberReady}'=3 -l app=nfd-master ds -n openshift-nfd
   ```

   ```bash
   oc wait --for=jsonpath='{.status.numberReady}'=5 -l app=nfd-worker ds -n openshift-nfd
   ```

#### Apply nVidia Cluster Config

We'll now apply the nvidia cluster config. Please read the [nvidia documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/openshift/install-gpu-ocp.html) on customizing this if you have your own private repos or specific settings. This will be another process that takes a few minutes to complete.

1. Create cluster config

   ```yaml
   cat <<EOF | oc create -f -
   apiVersion: nvidia.com/v1
   kind: ClusterPolicy
   metadata:
     name: gpu-cluster-policy
   spec:
     migManager:
       enabled: true
     operator:
       defaultRuntime: crio
       initContainer: {}
       runtimeClass: nvidia
       deployGFD: true
     dcgm:
       enabled: true
     gfd: {}
     dcgmExporter:
       config:
         name: ''
     driver:
       licensingConfig:
         nlsEnabled: false
         configMapName: ''
       certConfig:
         name: ''
       kernelModuleConfig:
         name: ''
       repoConfig:
         configMapName: ''
       virtualTopology:
         config: ''
       enabled: true
       use_ocp_driver_toolkit: true
     devicePlugin: {}
     mig:
       strategy: single
     validator:
       plugin:
         env:
           - name: WITH_WORKLOAD
             value: 'true'
     nodeStatusExporter:
       enabled: true
     daemonsets: {}
     toolkit:
       enabled: true
   EOF
   ```

1. Wait until Cluster Policy is ready

   ```bash
   oc wait --for=jsonpath='{.status.state}'=ready clusterpolicy \
    gpu-cluster-policy -n nvidia-gpu-operator --timeout=600s
   ```
