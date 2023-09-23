---
date: '2023-08-01'
title: Patch token-refresher to use a cluster proxy
tags: ["OSD", "ROSA"]
authors:
  - Andy Repton
  - Paul Czarkowski
---

Currently, if you deploy a ROSA or OSD cluster with a proxy, the token-refresher pod in the openshift-monitoring namespace will be in crashloopbackoff. There is an RFE open to resolve this, but until then this can affect the ability of the cluster to report telemetry and potentially update. This article provides a workaround on how to patch the token-refresher deployment until that RFE has been fixed using the patch-operator.

## Prerequisites

* A logged in user with `cluster-admin` rights to a ROSA or OSD Cluster deployed using a cluster wide proxy

    > You can use the `--http-proxy`, `--https-proxy`, `--no-proxy` and `--additional-trust-bundle-file` arguments to configure a ROSA cluster to use a proxy.

## Problem Demo

1. Check your pods in the openshift-monitoring namespace

    ```bash
    oc get pods -n openshift-monitoring | grep token-refresher
    ```
    
    ```bash
    token-refresher-74ff5d9f96-2mm4v                         1/1     CrashLoopBackOff     5             5m
    ```

## Install the patch-operator from the console

1. Log into your cluster as a user able to install Operators and browse to Operator Hub
![install patch operator](/experts/misc/token-refresher-proxy/images/install-patch-operator.png)

    *Accept the warning about community operators*

    ![accept community warning](/experts/misc/token-refresher-proxy/images/accept-community-operator.png)

2. Install the Patch Operator

![install patch operator](/experts/misc/token-refresher-proxy/images/install-patch-operator-2.png)

## Create the patch resource

1. Create the service account, cluster role, and cluster role binding required for the patch operator to access the resources to be patched.

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: token-refresher-patcher
      namespace: patch-operator
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: token-refresher-patcher
    rules:
    - apiGroups: ["config.openshift.io"]
      resources: ["proxies"]
      verbs: ["list","watch"]
    - apiGroups: ["config.openshift.io"]
      resources: ["proxies"]
      resourceNames: ["cluster"]
      verbs: ["get","list","watch"]
    - apiGroups: ["apps"]
      resources: ["deployments"]
      verbs: ["list","watch"]
    - apiGroups: ["apps"]
      resources: ["deployments"]
      resourceNames: ["token-refresher"]
      verbs: ["get","list","watch","patch","update"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: token-refresher-patcher
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: token-refresher-patcher
    subjects:
    - kind: ServiceAccount
      name: token-refresher-patcher
      namespace: patch-operator
    EOF
    ```

2. Create the patch Custom Resource for the operator

    > Note: This tells the Patch operator to fetch proxy configuration from the cluster and patch them into the token-refresher Deployment.

    ```bash
    cat <<EOF | oc apply -f -
    apiVersion: redhatcop.redhat.io/v1alpha1
    kind: Patch
    metadata:
    name: patch-token-refresher
    namespace: patch-operator
    spec:
      serviceAccountRef:
        name: token-refresher-patcher
      patches:
        tokenRefresherProxy:
          patchType: application/strategic-merge-patch+json
          patchTemplate: |
            spec:
              template:
                spec:
                  containers:
                    - name: token-refresher
                      env:
                        - name: HTTP_PROXY
                          value: "{{ (index . 1).spec.httpProxy }}"
                        - name: HTTPS_PROXY
                          value: "{{ (index . 1).spec.httpsProxy }}"
                        - name: NO_PROXY
                          value: "{{ (index . 1).spec.noProxy }}"
          targetObjectRef:
            apiVersion: apps/v1
            kind: Deployment
            name: token-refresher
            namespace: openshift-monitoring
          sourceObjectRefs:
          - apiVersion: config.openshift.io/v1
            kind: Proxy
            name: cluster
    EOF
    ```

## Check that the pod has been patched correctly

   ```bash
   oc get pods -n openshift-monitoring | grep token-refresher
   ```

   ```bash
   token-refresher-5c5dcb6587-ncrzj                         1/1     Running     0             5s
   ```
