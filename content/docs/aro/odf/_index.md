---
date: '2022-06-28'
title: Configure ARO with OpenShift Data Foundation
tags: ["ARO", "Azure"]
authors:
  - Kevin Collins
  - Mohsen Houshmand Sarvestani
---
**Kevin Collins**

*06/28/2022*

Note:
This guide demonstrates how to setup and configure self-managed OpenShift Data Foundation in Internal Mode on an ARO Cluster and test it out.

## Prerequisites

  * An Azure Red Hat OpenShift cluster ( verion 4.10+ )
  * [kubectl cli](https://kubernetes.io/releases/download/#kubectl)
  * [oc cli](https://docs.openshift.com/container-platform/4.10/cli_reference/openshift_cli/getting-started-cli.html)
  * moreutils (sponge)
  * jq

## Install compute nodes for ODF
   A best practice for optimal performance is to run ODF on dedicated nodes with a minimum of one per zone.  In this guide, we will be provisioning 3 additional compute nodes, one per zone.  Run the following script to create the additional nodes:

1. Log into your ARO Cluster
   ```bash
   export AZ_RG=<rg-name>
   export AZ_ARO=<cluster-name>
   az aro list-credentials --name "${AZ_ARO}" --resource-group "${AZ_RG}"
   az aro show --name "${AZ_ARO}" --resource-group "${AZ_RG}" -o tsv --query consoleProfile         
   API_SERVER=$(az aro show -g "${AZ_RG}" -n "${AZ_ARO}" --query apiserverProfile.url -o tsv)
   KUBE_ADM_USER=$(az aro list-credentials --name "${AZ_ARO}" --resource-group "${AZ_RG}" -o json | jq -r '.kubeadminUsername')
   KUBE_ADM_PASS=$(az aro list-credentials --name "${AZ_ARO}" --resource-group "${AZ_RG}" -o json | jq -r '.kubeadminPassword')
   oc login  -u $KUBE_ADM_USER -p $KUBE_ADM_PASS $API_SERVER
   ```

2. Create the new compute nodes
   ```bash
    for ZONE in 1 2 3
      do
        item=$((ZONE-1))
        MACHINESET=$(oc get machineset -n openshift-machine-api -o=jsonpath="{.items[$item]}" | jq -r '[.metadata.name] | @tsv')
        oc get machineset -n openshift-machine-api $MACHINESET -o json > default_machineset$ZONE.json
        worker=odf-worker-$ZONE
        jq ".metadata.name = \"$worker\"" default_machineset$ZONE.json | sponge default_machineset$ZONE.json
        jq '.spec.replicas = 1' default_machineset$ZONE.json| sponge default_machineset$ZONE.json
        jq ".spec.selector.matchLabels.\"machine.openshift.io/cluster-api-machineset\" = \"$worker\"" default_machineset$ZONE.json| sponge default_machineset$ZONE.json
        jq ".spec.template.metadata.labels.\"machine.openshift.io/cluster-api-machineset\" = \"$worker\"" default_machineset$ZONE.json| sponge default_machineset$ZONE.json
        jq '.spec.template.spec.providerSpec.value.vmSize = "Standard_D16s_v3"' default_machineset$ZONE.json | sponge default_machineset$ZONE.json
        jq ".spec.template.spec.providerSpec.value.zone = \"$ZONE\"" default_machineset$ZONE.json | sponge default_machineset$ZONE.json
        jq 'del(.status)' default_machineset$ZONE.json | sponge default_machineset$ZONE.json
        oc create -f default_machineset$ZONE.json
    done
   ```
4. wait for compute node to be up and running
   It takes just a couple of minutes for new nodes to provision

   ```bash
     while [[ $(oc get machinesets.machine.openshift.io -n openshift-machine-api | grep odf-worker-1 | awk '{ print $5 }') -ne 1 ]] 
       do
        echo "Waiting for worker machines to be ready..."
        sleep 5
       done
   ```
5. Label new compute nodes

   
   Check if the nodes are ready:
   ```bash
   oc get nodes | grep odf-worker
   ```
   expected output:
   ```bash
   odf-worker-1-jg7db                                  Ready    worker   10m     v1.23.5+3afdacb
   odf-worker-2-ktvct                                  Ready    worker   10m     v1.23.5+3afdacb
   odf-worker-3-rk22b                                  Ready    worker   10m     v1.23.5+3afdacb
   ```
   Once you see the three nodes, the next step we need to do is label and taint the nodes.  This will ensure the OpenShift Data Foundation is installed on these nodes, and no other workload will be placed on the nodes.
   ```bash
   for worker in $(oc get nodes | grep odf-worker | awk '{print $1}')
   do
     oc label node $worker cluster.ocs.openshift.io/openshift-storage=``
     oc adm taint nodes $worker node.ocs.openshift.io/storage=true:NoSchedule
   done
   ```
   Check nodes labels. The following command should list all three odf storage node
   ```bash
   oc get node --show-labels | grep storage | awk '{print $1}'
   ```

## Deploy OpenShift Data Foundation
Next, we will install OpenShift Data Foundation via an Operator.

1. Create the openshift-storage namespace
   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: v1
   kind: Namespace
   metadata:
     labels:
       openshift.io/cluster-monitoring: "true"
     name: openshift-storage
   spec: {}
   EOF
   ```
2. Create the Operator Group for openshift-storage
   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1
   kind: OperatorGroup
   metadata:
     name: openshift-storage-operatorgroup
     namespace: openshift-storage
   spec:
     targetNamespaces:
     - openshift-storage
   EOF
   ```
3. Subscribe to the ocs-operator
   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: ocs-operator
     namespace: openshift-storage
   spec:
     channel: "stable-4.10"  # <-- Channel should be modified depending on the OCS version to be installed. Please ensure to maintain compatibility with OCP version
     installPlanApproval: Automatic
     name: ocs-operator
     source: redhat-operators  # <-- Modify the name of the redhat-operators catalogsource if not default
     sourceNamespace: openshift-marketplace
   EOF
   ```
4. Subscribe to the odf-operator
   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: odf-operator
     namespace: openshift-storage
   spec:
     channel: "stable-4.10" # <-- Channel should be modified depending on the OCS version to be installed. Please ensure to maintain compatibility with OCP version
     installPlanApproval: Automatic
     name: odf-operator
     source: redhat-operators  # <-- Modify the name of the redhat-operators catalogsource if not default
     sourceNamespace: openshift-marketplace
   EOF
   ```
5. Create a Storage Cluster
   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: ocs.openshift.io/v1
   kind: StorageCluster
   metadata:
     annotations:
       uninstall.ocs.openshift.io/cleanup-policy: delete
       uninstall.ocs.openshift.io/mode: graceful
     generation: 2
     name: ocs-storagecluster
     namespace: openshift-storage
   spec:
     storageDeviceSets:
     - config: {}
       count: 1
       dataPVCTemplate:
         spec:
           accessModes:
           - ReadWriteOnce
           resources:
             requests:
               storage: 2Ti
           storageClassName: managed-premium
           volumeMode: Block
       name: ocs-deviceset-managed-premium
       portable: true
       replica: 3
     version: 4.10.0
   EOF
   ```

## Validate the install

1. List the cluster service version for the ODF operators
   ```bash
   oc get csv -n openshift-storage
   ```

   verify that the operators below have succeeded.
   ```
   NAME                  DISPLAY                       VERSION   REPLACES   PHASE
   mcg-operator.v4.10.4   NooBaa Operator               4.10.4                Succeeded
   ocs-operator.v4.10.4   OpenShift Container Storage   4.10.4                Succeeded
   odf-operator.v4.10.4   OpenShift Data Foundation     4.10.4                Succeeded
   ```

1. Check that Storage cluster is ready
   ```bash
   while [[ $(oc get storageclusters.ocs.openshift.io -n openshift-storage | grep ocs-storagecluster | awk '{ print $3 }') != "Ready" ]]
     do  
       echo  "storage cluster status is $(oc get storageclusters.ocs.openshift.io -n openshift-storage | grep ocs-storagecluster | awk '{ print $3 }')" 
       echo "wait for storage cluster to be ready"
       sleep 10
     done
   ```

1. Check that the ocs storage classes have been created
   >note: this can take around 5 minutes
   ```bash
   oc get sc
   ```
   ```
   NAME                          PROVISIONER                             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
   managed-csi                   disk.csi.azure.com                      Delete          WaitForFirstConsumer   true                   118m
   managed-premium (default)     kubernetes.io/azure-disk                Delete          WaitForFirstConsumer   true                   119m
   ocs-storagecluster-ceph-rbd   openshift-storage.rbd.csi.ceph.com      Delete          Immediate              true                   7s
   ocs-storagecluster-cephfs     openshift-storage.cephfs.csi.ceph.com   Delete          Immediate              true                   7s
   ```
## Test it out
   To test out ODF, we will create 'writer' pods on each node across all zones and then a reader pod to read the data that is written.  This will prove both regional storage along with "read write many" mode is working correctly.

1. Create a new project

   ```bash
   oc new-project odf-demo
   ```

1. Create a RWX Persistent Volume Claim for ODF
   ```bash
   cat <<EOF | kubectl apply -f -
   kind: PersistentVolumeClaim
   apiVersion: v1
   metadata:
     name: standard
   spec:
     accessModes:
       - ReadWriteMany
     resources:
       requests:
         storage: 400Gi
     storageClassName: ocs-storagecluster-cephfs
   EOF
   ```

1. Check PVC and PV status. It should be "Bound"

   ```bash
   oc get pvc
   oc get pv
   ```

2. Create writer pods via a DaemonSet
   Using a deamonset will ensure that we have a 'writer pod' on each worker node and will also prove that we correctly set a taint on the 'ODF Workers' where which we do not want workload to be added to.

   The writer pods will write out which worker node the pod is running on, the data, and a hello message.

   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: apps/v1
   kind: DaemonSet
   metadata:
     name: test-odf
     labels:
       app: test-odf
   spec:
     selector:
       matchLabels:
         name: test-odf
     template:
       metadata:
         labels:
           name: test-odf
       spec:
         containers:
           - name: azodf
             image: centos:latest
             command: ["sh", "-c"]
             resources:
               limits:
                 cpu: 1
                 memory: "1Gi"
             args:
               [
                 "while true; do printenv --null NODE_NAME | tee -a /mnt/odf-data/verify-odf; echo ' says hello '$(date) | tee -a /mnt/odf-data/verify-odf; sleep 15; done;",
               ]
             volumeMounts:
               - name: odf-vol
                 mountPath: "/mnt/odf-data"
             env:
               - name: NODE_NAME
                 valueFrom:
                   fieldRef:
                     fieldPath: spec.nodeName
         volumes:
           - name: odf-vol
             persistentVolumeClaim:
               claimName: standard
   EOF
   ```

3. Check the writer pods are running.
   >note: there should be 1 pod per non-ODF worker node
   ```bash
   oc get pods
   ```

   expected output
   ```
   NAME             READY   STATUS    RESTARTS   AGE    IP            NODE                                   NOMINATED NODE   READINESS GATES
   test-odf-47p2g   1/1     Running   0          107s   10.128.2.15   aro-kmobb-7zff2-worker-eastus1-xgksq   <none>           <none>
   test-odf-p5xk6   1/1     Running   0          107s   10.131.0.18   aro-kmobb-7zff2-worker-eastus3-h4gv7   <none>           <none>
   test-odf-ss8b5   1/1     Running   0          107s   10.129.2.32   aro-kmobb-7zff2-worker-eastus2-sbfpm   <none>           <none>
   ```
4. Create a reader pod
   The reader pod will simply log data written by the writer pods.
   ```bash
   cat <<EOF | oc apply -f -
   apiVersion: v1
   kind: Pod
   metadata:
     name: test-odf-read
   spec:
     containers:
       - name: test-odf-read
         image: centos:latest
         command: ["/bin/bash", "-c", "--"]
         resources:
           limits:
             cpu: 1
             memory: "1Gi"
         args: ["tail -f /mnt/odf-data/verify-odf"]
         volumeMounts:
           - name: odf-vol
             mountPath: "/mnt/odf-data"
     volumes:
       - name: odf-vol
         persistentVolumeClaim:
           claimName: standard
   EOF
   ```

5. Now let's verify the POD is reading from shared volume.

   ```bash
   oc logs test-odf-read
   ```
   Expected output
   ```
   aro-kmobb-7zff2-worker-eastus1-xgksq says hello Wed Jun 29 10:41:06 EDT 2022
   aro-kmobb-7zff2-worker-eastus3-h4gv7 says hello Wed Jun 29 10:41:06 EDT 2022
   aro-kmobb-7zff2-worker-eastus2-sbfpm says hello Wed Jun 29 10:41:06 EDT 2022
   aro-kmobb-7zff2-worker-eastus1-xgksq says hello Wed Jun 29 10:41:06 EDT 2022
   aro-kmobb-7zff2-worker-eastus3-h4gv7 says hello Wed Jun 29 10:41:06 EDT 2022
   aro-kmobb-7zff2-worker-eastus2-sbfpm says hello Wed Jun 29 10:41:06 EDT 2022
   aro-kmobb-7zff2-worker-eastus1-xgksq says hello Wed Jun 29 10:41:06 EDT 2022
   aro-kmobb-7zff2-worker-eastus3-h4gv7 says hello Wed Jun 29 10:41:06 EDT 2022
   
   ```

   Notice that pods in different zones are writing to the PVC which is managed by ODF.
