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

In this guide we'll explore configuring the **oTEL Operator** to collect these three log streams. For the sake of brevity, we'll be using the `debug` exporter, which simply prints details on the logs to the collector's own logs. Future guides will add various exporters such as **AWS S3**.

## Prerequisites

* An OpenShift cluster with Cluster Admin access.

## Install the oTEL Operator

Assuming you have an existing OpenShift cluster and you

1. Deploy the oTEL Operator

```
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-opentelemetry-operator
---
# create operator group
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-opentelemetry-operator-group
  namespace: openshift-opentelemetry-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-product
  namespace: openshift-opentelemetry-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: opentelemetry-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: opentelemetry-operator.v0.127.0-2
EOF
```

1. Verify the oTEL Operator is installed

```
oc rollout status -n openshift-opentelemetry-operator \
  deployment/opentelemetry-operator-controller-manager
```

## Create and Configure the oTEL Collector

{{% alert state="warning" %}}
In order for OpenTelemetry to access their hosts file systems we must enable
certain levels of privilege via SecurityContextConstraints (SCC).  You should review these and ensure you're comfortable with the access given to the collector.
{{% /alert %}}

1. Create SecurityContextConstraints (SCC) for opentelemetry logging.

```yaml
cat << EOF | oc apply -f -
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: opentelemetry-logging-scc
allowHostDirVolumePlugin: true
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities: null
apiVersion: security.openshift.io/v1
defaultAddCapabilities: null
defaultAllowPrivilegeEscalation: false
forbiddenSysctls:
- '*'
fsGroup:
  type: RunAsAny
groups: []
priority: null
readOnlyRootFilesystem: true
requiredDropCapabilities:
- CHOWN
- DAC_OVERRIDE
- FSETID
- FOWNER
- SETGID
- SETUID
- SETPCAP
- NET_BIND_SERVICE
- KILL
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: RunAsAny
seccompProfiles:
- runtime/default
supplementalGroups:
  type: RunAsAny
users: []
volumes:
- configMap
- emptyDir
- hostPath
- projected
- secret
EOF

```

1. Create ClusterRole for opentelemetry logging.

```yaml
cat << EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: opentelemetry-logging
rules:
- apiGroups: ["config.openshift.io"]
  resources: ["infrastructures", "infrastructures/status"]
  verbs: ["get", "watch", "list"]
- apiGroups: [""]
  resources: ["pods", "nodes", "namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["config.openshift.io"]
  resources: ["infrastructures", "infrastructures/status"]
  verbs: ["get", "list", "watch"]
EOF
```


1. Create an OpenTelemetry Collector


```yaml
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: opentelemetry-logging
---
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: opentelemetry-logging
  namespace: opentelemetry-logging  #?
spec:
  managementState: managed
  mode: daemonset
  config:
    exporters:
      debug:
        verbosity: basic
    extensions:
      file_storage:
        directory: /var/lib/otelcol
    processors:
      batch:
        send_batch_max_size: 1500
        send_batch_size: 1000
        timeout: 1s
      resourcedetection/openshift:
        detectors: [env,openshift]
        timeout: 2s
        override: false
      k8sattributes:
        auth_type: "serviceAccount"
    receivers:
      filelog/infrastructure:
        include:
        - /var/log/pods/openshift-*/*/*.log
        - /var/log/pods/kube-system/*/*.log
        start_at: end
        include_file_name: false
        include_file_path: true
        operators:
        - id: container-parser
          type: container
          retry_on_failure:
            enabled: true
          storage: file_storage
      filelog/application:
        include:
        - /var/log/pods/*/*/*.log
        exclude:
        - /var/log/pods/openshift-*/*/*.log
        - /var/log/pods/kube-system/*/*.log
        start_at: end
        include_file_name: false
        include_file_path: true
        operators:
        - id: container-parser
          type: container
          retry_on_failure:
            enabled: true
          storage: file_storage
      filelog/audit:
        include:
        - /var/log/openshift-apiserver/audit*.log
        start_at: end
        include_file_name: false
        include_file_path: true
        operators:
        - id: container-parser
          type: container
          retry_on_failure:
            enabled: true
          storage: file_storage
      journald:
        files: /var/log/journal/*/*
        priority: info
        units:
          - kubelet
          - crio
          - init.scope
          - dnsmasq
        all: true
        retry_on_failure:
          enabled: true
          initial_interval: 1s
          max_interval: 30s
          max_elapsed_time: 5m
    service:
      extensions:
      - file_storage
      pipelines:
        logs/application:
          exporters:
          - debug
          processors:
          - batch
          - resourcedetection/openshift
          - k8sattributes
          receivers:
          - filelog/application
        logs/infrastructure:
          exporters:
          - debug
          processors:
          - batch
          - resourcedetection/openshift
          - k8sattributes
          receivers:
          - filelog/infrastructure
          - journald
        logs/audit:
          exporters:
          - debug
          processors:
          - batch
          - resourcedetection/openshift
          - k8sattributes
          receivers:
          - filelog/audit
  imagePullPolicy: IfNotPresent
  upgradeStrategy: automatic
  terminationGracePeriodSeconds: 30
  resources:
    limits:
      cpu: 200m
      memory: 500Mi
    requests:
      cpu: 100m
      memory: 250Mi
  targetAllocator:
    enabled: false
  volumeMounts:
  - name: varlogpods
    mountPath: /var/log/pods
    readOnly: true
  - name: auditlog
    mountPath: /var/log/openshift-apiserver
    readOnly: true
  - name: varlibotelcol
    mountPath: /var/lib/otelcol
  - name: journal-logs
    mountPath: /var/log/journal/
    readOnly: true
  env:
  - name: KUBERNETES_SERVICE_HOST
    value: "kubernetes.default.svc.cluster.local"
  - name: KUBERNETES_SERVICE_PORT
    value: "443"
  - name: OTEL_K8S_NODE_NAME
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName
  - name: OTEL_K8S_NODE_IP
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
  - name: OTEL_K8S_NAMESPACE
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: metadata.namespace
  - name: OTEL_K8S_POD_NAME
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: metadata.name
  - name: OTEL_K8S_POD_IP
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: status.podIP
  volumes:
  - name: varlogpods
    hostPath:
      path: /var/log/pods
  - name: auditlog
    hostPath:
      path: /var/log/openshift-apiserver
  - name: varlibotelcol
    hostPath:
      path: /var/lib/otelcol
      type: DirectoryOrCreate
  - name: journal-logs
    hostPath:
      path: /var/log/journal
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
      - FSETID
      - KILL
      - NET_BIND_SERVICE
      - SETGID
      - SETPCAP
      - SETUID
    readOnlyRootFilesystem: true
    runAsGroup: 0
    runAsNonRoot: false
    runAsUser: 0
    seLinuxOptions:
      type: spc_t
    seccompProfile:
      type: RuntimeDefault
  tolerations:
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule
    - effect: NoSchedule
      key: node-role.kubernetes.io/infra
      value: reserved
    - effect: NoExecute
      key: node-role.kubernetes.io/infra
      value: reserved
EOF
```

1. Assign the SecurityContextConstraints (SCC) and ClusterRole to the ServiceAccount

    ```bash
    oc adm policy add-cluster-role-to-user opentelemetry-logging \
      -z opentelemetry-logging-collector \
      -n opentelemetry-logging
    ```

    ```bash
    oc adm policy add-scc-to-user opentelemetry-logging-scc \
      -n opentelemetry-logging \
      -z opentelemetry-logging-collector
    ```

1. Verify the Pods are running

    ```bash
    oc -n opentelemetry-logging rollout status ds/opentelemetry-logging-collector
    ```

    ```
    daemon set "opentelemetry-logging-collector" successfully rolled out
    ```

1. Check the collector is collecting logs

    ```bash
    oc logs ds/opentelemetry-logging-collector
    Found 3 pods, using pod/opentelemetry-logging-collector-6pw44
    2025-08-06T16:28:18.230Z        info    service@v0.127.0/service.go:199 Setting up own telemetry...{"resource": {}}
    2025-08-06T16:28:18.231Z        info    builders/builders.go:26 Development component. May change in the future.   {"resource": {}, "otelcol.component.id": "debug", "otelcol.component.kind": "exporter", "otelcol.signal": "logs"}
    2025-08-06T16:28:18.233Z        info    service@v0.127.0/service.go:266 Starting otelcol...     {"resource": {}, "Version": "0.127.0", "NumCPU": 4}
    2025-08-06T16:28:18.233Z        info    extensions/extensions.go:41     Starting extensions...  {"resource": {}}
    2025-08-06T16:28:18.233Z        info    extensions/extensions.go:45     Extension is starting...  {"resource": {}, "otelcol.component.id": "file_storage", "otelcol.component.kind": "extension"}
    ...
    ...
    2025-08-06T16:34:55.832Z        info    Logs    {"resource": {}, "otelcol.component.id": "debug", "otelcol.component.kind": "exporter", "otelcol.signal": "logs", "resource logs": 1, "log records": 1}
    2025-08-06T16:34:56.636Z        info    Logs    {"resource": {}, "otelcol.component.id": "debug", "otelcol.component.kind": "exporter", "otelcol.signal": "logs", "resource logs": 2, "log records": 2}
    ```