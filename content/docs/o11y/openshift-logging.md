---
date: '2022-09-14T22:07:08.584151'
title: OpenShift Logging
tags: ["Observability", "OCP"]
authors:
  - Aaron Aldrich
  - Connor Wooley
---

A guide to shipping logs and metrics on OpenShift

## Prerequisites

1. OpenShift CLI (oc)
1. Rights to install operators on the cluster

## Setup OpenShift Logging

This is for setup of centralized logging on OpenShift making use of Elasticsearch OSS edition. This largely follows the processes outlined in the [OpenShift documentation here](https://docs.openshift.com/container-platform/4.7/logging/cluster-logging-deploying.html). Retention and storage considerations are reviewed in Red Hat's primary source documentation.

This setup is primarily concerned with simplicity and basic log searching. Consequently it is insufficient for long-lived retention or for advanced visualization of logs. For more advanced observability setups, you'll want to look at [Forwarding Logs to Third Party Systems](https://docs.openshift.com/container-platform/4.7/logging/cluster-logging-external.html)

1. Create a namespace for the OpenShift Elasticsearch Operator.

    > This is necessary to avoid potential conflicts with community operators that could send similarly named metrics/logs into the stack.

    ```bash
    oc create -f - <<EOF
    apiVersion: v1
    kind: Namespace
    metadata:
    name: openshift-operators-redhat
    annotations:
      openshift.io/node-selector: ""
    labels:
      openshift.io/cluster-monitoring: "true"
    EOF
    ```

1. Create a namespace for the OpenShift Logging Operator

    ```bash
    oc create -f - <<EOF
    apiVersion: v1
    kind: Namespace
    metadata:
    name: openshift-logging
    annotations:
      openshift.io/node-selector: ""
    labels:
      openshift.io/cluster-monitoring: "true"
    EOF
    ```

1. Install the OpenShift Elasticsearch Operator by creating the following objects:

    1. Operator Group for OpenShift Elasticsearch Operator

        ```bash
        oc create -f - <<EOF
        apiVersion: operators.coreos.com/v1
        kind: OperatorGroup
        metadata:
          name: openshift-operators-redhat
          namespace: openshift-operators-redhat
        spec: {}
        EOF
        ```

    1. Subscription object to subscribe a Namespace to the OpenShift Elasticsearch Operator

        ```bash
        oc create -f - <<EOF
        apiVersion: operators.coreos.com/v1alpha1
        kind: Subscription
        metadata:
          name: "elasticsearch-operator"
          namespace: "openshift-operators-redhat"
        spec:
          channel: "stable"
          installPlanApproval: "Automatic"
          source: "redhat-operators"
          sourceNamespace: "openshift-marketplace"
          name: "elasticsearch-operator"
        EOF
        ```

    1. Verify Operator Installation

        ```bash
        oc get csv --all-namespaces
        ```

        > Example Output
        ```
        NAMESPACE                                               NAME                                            DISPLAY                  VERSION               REPLACES   PHASE
        default                                                 elasticsearch-operator.5.0.0-202007012112.p0    OpenShift Elasticsearch Operator   5.0.0-202007012112.p0               Succeeded
        kube-node-lease                                         elasticsearch-operator.5.0.0-202007012112.p0    OpenShift Elasticsearch Operator   5.0.0-202007012112.p0               Succeeded
        kube-public                                             elasticsearch-operator.5.0.0-202007012112.p0    OpenShift Elasticsearch Operator   5.0.0-202007012112.p0               Succeeded
        kube-system                                             elasticsearch-operator.5.0.0-202007012112.p0    OpenShift Elasticsearch Operator   5.0.0-202007012112.p0               Succeeded
        openshift-apiserver-operator                            elasticsearch-operator.5.0.0-202007012112.p0    OpenShift Elasticsearch Operator   5.0.0-202007012112.p0               Succeeded
        openshift-apiserver                                     elasticsearch-operator.5.0.0-202007012112.p0    OpenShift Elasticsearch Operator   5.0.0-202007012112.p0               Succeeded
        openshift-authentication-operator                       elasticsearch-operator.5.0.0-202007012112.p0    OpenShift Elasticsearch Operator   5.0.0-202007012112.p0               Succeeded
        openshift-authentication                                elasticsearch-operator.5.0. 0-202007012112.p0    OpenShift Elasticsearch Operator   5.0.0-202007012112.p0               Succeeded
        ...
        ```

1. Install the Red Hat OpenShift Logging Operator by creating the following objects:

    1. The Cluster Logging OperatorGroup

        ```bash
        oc create -f - <<EOF
        apiVersion: operators.coreos.com/v1
        kind: OperatorGroup
        metadata:
          name: cluster-logging
          namespace: openshift-logging
        spec:
          targetNamespaces:
          - openshift-logging
        EOF
        ```

    1. Subscription Object to subscribe a Namespace to the Red Hat OpenShift Logging Operator

        ```bash
        oc create -f - <<EOF
        apiVersion: operators.coreos.com/v1alpha1
        kind: Subscription
        metadata:
          name: cluster-logging
          namespace: openshift-logging
        spec:
          channel: "stable"
          name: cluster-logging
          source: redhat-operators
          sourceNamespace: openshift-marketplace
        EOF
        ```

    1. Verify the Operator installation, the `PHASE` should be `Succeeded`

    ```bash
    oc get csv -n openshift-logging
    ```

    > Example Output
    ```
    NAME                              DISPLAY                            VERSION    REPLACES   PHASE
    cluster-logging.5.0.5-11          Red Hat OpenShift Logging          5.0.5-11              Succeeded
    elasticsearch-operator.5.0.5-11   OpenShift Elasticsearch Operator   5.0.5-11              Succeeded
    ```

1. Create an OpenShift Logging instance:

    > **NOTE**: For the `storageClassName` below, you will need to adjust for the platform on which you're running OpenShift. `managed-premium` as listed below is for Azure Red Hat OpenShift (ARO). You can verify your available storage classes with `oc get storageClasses`

    ```bash
    oc create -f - <<EOF
    apiVersion: "logging.openshift.io/v1"
    kind: "ClusterLogging"
    metadata:
      name: "instance"
      namespace: "openshift-logging"
    spec:
      managementState: "Managed"
      logStore:
        type: "elasticsearch"
        retentionPolicy:
          application:
            maxAge: 1d
          infra:
            maxAge: 7d
          audit:
            maxAge: 7d
        elasticsearch:
          nodeCount: 3
          storage:
            storageClassName: "managed-premium"
            size: 200G
          resources:
            requests:
              memory: "8Gi"
          proxy:
            resources:
              limits:
                memory: 256Mi
              requests:
                memory: 256Mi
          redundancyPolicy: "SingleRedundancy"
      visualization:
        type: "kibana"
        kibana:
          replicas: 1
      curation:
        type: "curator"
        curator:
          schedule: "30 3 * * *"
      collection:
        logs:
          type: "fluentd"
          fluentd: {}
    EOF
    ```

1. It will take a few minutes for everything to start up. You can monitor this progress by watching the pods.

    ```bash
    watch oc get pods -n openshift-logging
    ```

1. Your logging instances are now configured and recieving logs. To view them, you will need to log into your Kibana instance and create the appropriate index patterns. For more information on index patterns, see the [Kibana documentation.](https://www.elastic.co/guide/en/kibana/6.8/index-patterns.html)

    > **NOTE**: The following restrictions and notes apply to index patterns:
    > - All users can view the `app-` logs for namespaces they have access to
    > - Only cluster-admins can view the `infra-` and `audit-` logs
    > - For best accuracy, use the `@timestamp` field for determining chronology
