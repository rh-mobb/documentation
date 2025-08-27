---
date: '2025-08-04'
title: Configuring oTEL to collect OpenShift Logs
tags: ["Observability", "OCP", "oTEL"]
authors:
  - Paul Czarkowski
---

{{% alert state="warning" %}}
The Filelog and JournalD Receivers are a Technology Preview feature only. Technology Preview features are not supported with Red Hat production service level agreements (SLAs) and might not be functionally complete. Red Hat does not recommend using them in production. These features provide early access to upcoming product features, enabling customers to test functionality and provide feedback during the development process.

For more information about the support scope of Red Hat Technology Preview features, see [Technology Preview Features Support Scope](https://access.redhat.com/support/offerings/techpreview/?extIdCarryOver=true&sc_cid=701f2000001Css5AAC).
{{% /alert %}}

OpenShift's **Cluster Log Forwarder (CLF)** is the traditional way to collect the cluster's **Audit**, **Infrastructure**, and **Application** logs and forward them to a SIEMs or other central system for log aggregation and visibility.  However the **oTEL Operator** is a bit more flexible, especially when it comes to the output options, for instance the CLF system does not support exporting to **AWS S3**.

In this guide we'll explore configuring the **oTEL Operator** to collect these three log streams. For the sake of brevity, we'll be using the `debug` exporter, which simply prints details on the logs to the collector's own logs. Future guides will add various exporters such as **AWS S3** or **OCP's LokiStack**.

## Prerequisites

* A [ROSA HCP cluster](https://cloud.redhat.com/experts/rosa/terraform/hcp/) with Cluster Admin access (ROSA Classic or OCP on AWS should also work, but this is only tested on HCP).
* Helm CLI

1. Add the MOBB chart repository to your Helm

    ```
    helm repo add mobb https://rh-mobb.github.io/helm-charts/
    ```

1. Update your repositories

    ```
    helm repo update
    ```

## Deploy Operators

1. Deploy the OTEL Operator

    ```bash
    oc create namespace openshift-telemetry-operator
    helm upgrade -n openshift-telemetry-operator otel-operator \
    mobb/operatorhub --install \
    --values https://raw.githubusercontent.com/rh-mobb/helm-charts/refs/heads/main/charts/ocp-otel/files/otel-operator.yaml
    ```

1. Wait a few moments and then validate the operator is installed

    ```bash
    oc -n openshift-telemetry-operator rollout status \
      deployment/opentelemetry-operator-controller-manager
    ```

    ```
    ...
    deployment "opentelemetry-operator-controller-manager" successfully rolled out
    ```

## Create and Configure the oTEL Collector

1. Create a values file

    ```bash
    cat <<EOF > /tmp/otel-values.yaml
    uiPlugin:
      enabled: false
    collector:
      inputs:
        application:
          enabled: true
        infrastructure:
          enabled: true
        audit:
          enabled: false
        otlp:
          enabled: false
        fluentforward:
          enabled: false
      outputs:
        debug:
          enabled: true
          verbosity: basic
        s3:
          enabled: false
        lokistack:
          enabled: false
      pipelines:
        - name: Application
          inputRef: application
          outputRefs: [debug]
        - name: Infrastructure
          inputRef: infrastructure
          outputRefs: [debug]
    EOF
    ```

1. Create an OTEL Collector

    ```bash
    helm upgrade -n opentelemetry-logging ocp-otel \
    mobb/ocp-otel --create-namespace --install \
    --values /tmp/otel-values.yaml
    ```

1. Verify the Pods are running

    ```bash
    oc -n opentelemetry-logging rollout status ds/ocp-otel-logging-collector

    ```
    daemon set "ocp-otel-logging-collector" successfully rolled out    ```
    ```

1. Check the collector is collecting logs

    ```bash
    oc logs -n opentelemetry-logging ds/ocp-otel-logging-collector
    ```

    ```
    ...
    ...
    2025-08-27T16:39:26.493Z        info    Logs    {"resource": {"service.instance.id": "c229fe2d-f475-49ef-893c-276797a53b1b", "service.name": "otelcol", "service.version": "v0.132.0"}, "otelcol.component.id": "debug", "otelcol.component.kind": "exporter", "otelcol.signal": "logs", "resource logs": 1, "log records": 2}
    2025-08-27T16:39:26.493Z        info    Logs    {"resource": {"service.instance.id": "c229fe2d-f475-49ef-893c-276797a53b1b", "service.name": "otelcol", "service.version": "v0.132.0"}, "otelcol.component.id": "debug", "otelcol.component.kind": "exporter", "otelcol.signal": "logs", "resource logs": 3, "log records": 6}
    ```

## Conclusion

Logs are being pulled from the worker nodes, both for the Applications and Infrastructure tenants.  Of course apart from showing some debug messages the logs are not flowing anywhere.

Next steps are to pick a destination such as the OpenShift LokiStack system, or AWS S3 (or both!). Examples of deploying these are coming soon!