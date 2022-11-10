---
date: '2022-09-14T22:07:08.584151'
title: Adding infrastructure nodes to an ARO cluster
---

**Paul Czarkowski**

*08/17/2022*

This document shows how to set up infrastructure nodes in an ARO cluster and move infrastructure related workloads to them. This can help with larger clusters that have resource contention between user workloads and infrastructure workloads such as Prometheus.

> **Important note:** Infrastructure nodes are billed at the same rates as your existing ARO worker nodes.

You can find the original (and more detailed) document describing the process for a self-managed OpenShift Container Platform cluster [here](https://docs.openshift.com/container-platform/latest/machine_management/creating-infrastructure-machinesets.html#creating-infra-machines_creating-infrastructure-machinesets)

## Prerequisites

* [Azure Red Hat OpenShift cluster](/docs/quickstart-aro.html)
* [Helm CLI](https://helm.sh/docs/intro/install/)

## Create Infra Nodes

We'll use the MOBB Helm Chart for adding ARO `machinesets` which defaults to creating `infra` nodes, it looks up an existing `machineset` to collect cluster specific settings and then creates a new `machineset` specific for `infra` nodes with the same settings.

1. Add the MOBB chart repository to your Helm

   ```bash
   helm repo add mobb https://rh-mobb.github.io/helm-charts/
   ```

1. Update your repositories

   ```bash
   helm repo update
   ```

1. Install the `mobb/aro-machinesets` Chart to create `infra` nodes

   ```bash
   helm upgrade --install -n openshift-machine-api \
     infra mobb/aro-machinesets
   ```

1. Wait for the new nodes to be available

   ```bash
   watch oc get machines
   ```

## Moving Infra workloads

### Ingress

> You may choose this for any additional Ingress controllers you may have in the cluster, however if you application has very high Ingress resource requirements it may make sense to allow them to spread across the worker nodes, or even a dedicated `MachineSet`.

1. Set the `nodePlacement` on the `ingresscontroller` to `node-role.kubernetes.io/infra` and increase the `replicas` to match the number of infra nodes

   ```bash
   oc patch -n openshift-ingress-operator ingresscontroller default --type=merge  \
      -p='{"spec":{"replicas":3,"nodePlacement":{"nodeSelector":{"matchLabels":{"node-role.kubernetes.io/infra":""}},"tolerations":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/infra","operator":"Exists"}]}}}'
   ```

1. Check the Ingress Controller Operator  is starting `pods` on the new `infra` nodes

   ```bash
   oc -n openshift-ingress get pods -o wide
   ```

   ```
   NAME                              READY   STATUS        RESTARTS   AGE   IP            NODE                                                    NOMINATED NODE   READINESS GATES
   router-default-69f58645b7-6xkvh   1/1     Running       0          66s   10.129.6.6    cz-cluster-hsmtw-infra-aro-machinesets-eastus-3-l6dqw   <none>           <none>
   router-default-69f58645b7-vttqz   1/1     Running       0          66s   10.131.4.6    cz-cluster-hsmtw-infra-aro-machinesets-eastus-1-vr56r   <none>           <none>
   router-default-6cb5ccf9f5-xjgcp   1/1     Terminating   0          23h   10.131.0.11   cz-cluster-hsmtw-worker-eastus2-xj9qx                   <none>           <none>
   ```

### Registry

1. Set the `nodePlacement` on the `registry` to `node-role.kubernetes.io/infra`

   ```bash
   oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
     -p='{"spec":{"affinity":{"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"podAffinityTerm":{"namespaces":["openshift-image-registry"],"topologyKey":"kubernetes.io/hostname"},"weight":100}]}},"logLevel":"Normal","managementState":"Managed","nodeSelector":{"node-role.kubernetes.io/infra":""},"tolerations":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/infra","operator":"Exists"}]}}'
   ```

1. Check the Registry Operator is starting `pods` on the new `infra` nodes

   ```bash
   oc -n openshift-image-registry get pods -l "docker-registry" -o wide
   ```

    ```
    NAME                              READY   STATUS    RESTARTS   AGE     IP           NODE                                                    NOMINATED NODE   READINESS GATES
    image-registry-84cbd76d5d-cfsw7   1/1     Running   0          3h46m   10.128.6.7   cz-cluster-hsmtw-infra-aro-machinesets-eastus-2-kljml   <none>           <none>
    image-registry-84cbd76d5d-p2jf9   1/1     Running   0          3h46m   10.129.6.7   cz-cluster-hsmtw-infra-aro-machinesets-eastus-3-l6dqw   <none>           <none>
    ```

### Cluster Monitoring

1. Configure the cluster monitoring stack to use the `infra` nodes

   > Note: This will override any other customizations to the cluster monitoring stack, so you may want to merge your existing customizations into this before running the command.

   ```bash
   cat << EOF | oc apply -f -
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: cluster-monitoring-config
     namespace: openshift-monitoring
   data:
     config.yaml: |+
       alertmanagerMain:
         nodeSelector:
           node-role.kubernetes.io/infra: ""
         tolerations:
           - effect: "NoSchedule"
             key: "node-role.kubernetes.io/infra"
             operator: "Exists"
       prometheusK8s:
         nodeSelector:
           node-role.kubernetes.io/infra: ""
         tolerations:
           - effect: "NoSchedule"
             key: "node-role.kubernetes.io/infra"
             operator: "Exists"
       prometheusOperator: {}
       grafana:
         nodeSelector:
           node-role.kubernetes.io/infra: ""
         tolerations:
           - effect: "NoSchedule"
             key: "node-role.kubernetes.io/infra"
             operator: "Exists"
       k8sPrometheusAdapter:
         nodeSelector:
           node-role.kubernetes.io/infra: ""
         tolerations:
           - effect: "NoSchedule"
             key: "node-role.kubernetes.io/infra"
             operator: "Exists"
       kubeStateMetrics:
         nodeSelector:
           node-role.kubernetes.io/infra: ""
         tolerations:
           - effect: "NoSchedule"
             key: "node-role.kubernetes.io/infra"
             operator: "Exists"
       telemeterClient:
         nodeSelector:
           node-role.kubernetes.io/infra: ""
         tolerations:
           - effect: "NoSchedule"
             key: "node-role.kubernetes.io/infra"
             operator: "Exists"
       openshiftStateMetrics:
         nodeSelector:
           node-role.kubernetes.io/infra: ""
         tolerations:
           - effect: "NoSchedule"
             key: "node-role.kubernetes.io/infra"
             operator: "Exists"
       thanosQuerier:
         nodeSelector:
           node-role.kubernetes.io/infra: ""
         tolerations:
           - effect: "NoSchedule"
             key: "node-role.kubernetes.io/infra"
             operator: "Exists"
   EOF
   ```

1. Check the OpenShift Monitoring Operator is starting `pods` on the new `infra` nodes

   > some Pods like `prometheus-operator` will remain on `master` nodes.

   ```bash
   oc -n openshift-monitoring get pods -o wide
   ```

    ```
    NAME                                           READY   STATUS    RESTARTS   AGE     IP            NODE                                                    NOMINATED NODE   READINESS GATES
    alertmanager-main-0                            6/6     Running   0          2m14s   10.128.6.11   cz-cluster-hsmtw-infra-aro-machinesets-eastus-2-kljml   <none>           <none>
    alertmanager-main-1                            6/6     Running   0          2m46s   10.131.4.11   cz-cluster-hsmtw-infra-aro-machinesets-eastus-1-vr56r   <none>           <none>
    cluster-monitoring-operator-5bbfd998c6-m9w62   2/2     Running   0          28h     10.128.0.23   cz-cluster-hsmtw-master-1                               <none>           <none>
    grafana-599d4b948c-btlp2                       3/3     Running   0          2m48s   10.131.4.10   cz-cluster-hsmtw-infra-aro-machinesets-eastus-1-vr56r   <none>           <none>
    kube-state-metrics-574c5bfdd7-f7fjk            3/3     Running   0          2m49s   10.131.4.8    cz-cluster-hsmtw-infra-aro-machinesets-eastus-1-vr56r   <none>           <none>
    ...
    ...
    ```
