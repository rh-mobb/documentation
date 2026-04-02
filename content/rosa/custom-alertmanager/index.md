---
date: '2026-04-02'
title: Custom Alerts on ROSA Classic
tags: ["ROSA", "ROSA Classic", "Observability", "OSD"]
authors:
  - Paul Czarkowski
validated_version: "4.18"
---

This guide shows how to create custom alerts on a ROSA Classic cluster. To keep it grounded in something you actually hit in the field, we focus on a common pain point: high-traffic workloads such as ingress controllers or API gateways that pile onto too few nodes can exhaust **nf_conntrack** capacity on those workers. The steps that follow show how to **observe** that pressure with platform metrics, evaluate alerting rules in the **user workload monitoring** path, and send notifications through **user Alertmanager**.

Every Kubernetes object in this guide is applied with `oc apply -f - <<'EOF'` (or equivalent). Use a shell where `oc login` already targets your cluster as a user who can edit `openshift-user-workload-monitoring` and create namespaces (for example `cluster-admin`).

Linux **netfilter** tracks connections in a fixed-size **nf_conntrack** table on each node. Ingress controllers, API gateways, and similar edge components terminate or proxy many short-lived or long-lived connections. That volume maps to **per-node** conntrack state, and busy edge stacks are often where pressure shows up first. The effect is worse if pods lack appropriate anti-affinity (or other spreading rules) and bunch on one or two workers, concentrating connection churn and table usage that would be tolerable if spread across the fleet. Symptoms include timeouts, packet loss, and errors localized to specific nodes, which are easy to misattribute to the network or security groups.

Use alerting here as a **signal**, not a substitute for capacity and placement work: review scheduling (pod anti-affinity, topology spread constraints, replica counts, and node capacity) so ingress and gateway traffic spreads across workers.

**Metrics:** OpenShift **node_exporter** exposes gauges such as `node_nf_conntrack_entries`, `node_nf_conntrack_entries_limit`, and kernel stat counters like `node_nf_conntrack_stat_drop`. They are scraped by platform Prometheus in `openshift-monitoring`.

## Why the platform alert is not enough on ROSA Classic

OpenShift ships a platform rule roughly equivalent to **high conntrack utilization** when:

`node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.75`

(alert name `NodeHighNumberConntrackEntriesUsed` in `node-exporter-rules`).

On **ROSA Classic**, customers cannot configure receivers on the **platform** Alertmanager. Platform alerts follow Red Hat’s managed path; you do not get Slack, PagerDuty, or similar from that stack the way you would on a self-managed cluster.

If you need **your own notification channels**, evaluate equivalent (or stricter) rules in the **user workload monitoring** path and send them to **user Alertmanager** (and related config).

**Overlap is OK:** duplicating the 75% condition under user monitoring is normal on ROSA Classic. You are not double paging from platform Alertmanager; customer paging should come from **user** Alertmanager only.

## How the pieces fit together

| Piece | Role |
|--------|------|
| `node-exporter` | Exposes `node_nf_conntrack_*` from each node (platform scrape). |
| Platform Prometheus + Thanos sidecars | Store those series. |
| `thanos-querier` in `openshift-monitoring` | Merges queries across platform and user-workload Prometheus backends. |
| `thanos-ruler-user-workload` | Evaluates `PrometheusRule` objects that are **not** scoped to `leaf-prometheus`, running PromQL **against Thanos Querier**, so expressions can see **cluster** metrics (including conntrack) **and** user metrics. |
| `namespacesWithoutLabelEnforcement` | In `user-workload-monitoring-config`, lists namespaces (here `custom-alert`) where Thanos Ruler must **not** force every query to match `namespace="<project>"`, which would otherwise hide `openshift-monitoring` series. |
| User Alertmanager | Receives alerts from the user monitoring stack so **you** can set receivers (Slack, PagerDuty, etc.). |

**Do not** set `openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus` on these rules: that path uses user-workload Prometheus only, whose TSDB **does not** contain `node_nf_conntrack_*` by default.

## Prerequisites

* `oc` logged in (for example `cluster-admin`).
* **User workload monitoring** enabled:
  * `cluster-monitoring-config` in `openshift-monitoring` must include `enableUserWorkload: true`
  * (ROSA and OSD usually already satisfy this when UWM is on).

## Configure the namespace and user workload monitoring

Use project name `custom-alert` below. If you change it, update both the `Namespace` and `namespacesWithoutLabelEnforcement` consistently.

### Create the namespace

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: custom-alert
  labels:
    openshift.io/user-monitoring: "true"
EOF
```

### User workload monitoring ConfigMap

#### Inspect what is already there

```bash
oc get configmap user-workload-monitoring-config \
  -n openshift-user-workload-monitoring -o yaml
```

Check whether `data.config.yaml` has any content:

```bash
oc get configmap user-workload-monitoring-config \n
  -n openshift-user-workload-monitoring -o jsonpath='{.data.config\.yaml}' \n
  2>/dev/null | wc -c
```

Interpret the result:

| Situation | What it means | What to do |
|-----------|----------------|------------|
| `Error from server (NotFound)` | ConfigMap not present yet. | Use the full `oc apply` heredoc below (creates the object). |
| `data:` missing, or `data: {}`, or `wc -c` prints `0` | The object exists but there is no `config.yaml` (or it is empty). | Use the full `oc apply` heredoc below. It only adds `data.config.yaml`. |
| `wc -c` is greater than `0` | `config.yaml` already has body text. | **Merge** into that YAML by hand (or export, edit, re-apply). **Do not** paste the heredoc blindly or you will **replace** the entire `config.yaml` and drop existing settings. |

Optional: list keys under `data` (requires `jq`):

```bash
oc get configmap user-workload-monitoring-config \
  -n openshift-user-workload-monitoring -o json | \
  jq -r '.data | keys? // []'
```

#### Empty or missing `config.yaml`: apply full ConfigMap

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
  labels:
    app.kubernetes.io/managed-by: cluster-monitoring-operator
    app.kubernetes.io/part-of: openshift-monitoring
data:
  config.yaml: |
    alertmanager:
      enabled: true
    namespacesWithoutLabelEnforcement:
      - custom-alert
EOF
```

#### Non-empty `config.yaml`: merge by hand

Edit the live object so `config.yaml` keeps your existing keys, and add or extend:

* `namespacesWithoutLabelEnforcement`: include `custom-alert` (append to the list if the key already exists).
* `alertmanager.enabled: true` if you need user Alertmanager and it is not already enabled there.

Then apply your merged file, for example:

```bash
oc apply -f your-merged-configmap.yaml
```

Wrong shape will be rejected by the admission webhook (for example `prometheus: enabled: true` under `user-workload-monitoring-config` on 4.18+).

Wait **1 to 3 minutes** for the cluster monitoring operator to reconcile Thanos Ruler and Alertmanager pods in `openshift-user-workload-monitoring`.

```bash
oc get pods -n openshift-user-workload-monitoring \
  -l 'app.kubernetes.io/name in (thanos-ruler,alertmanager)'
```

## Demo: always-firing lab alerts

Use this to prove Thanos Ruler can see `node_nf_conntrack_*` and that **Observe → Alerting** with **Source: User** shows **Firing** (typically one series per node).

*The following `PrometheusRule` creates two **lab-only** alerts in `custom-alert`. Both use conditions that are always true on a healthy cluster (`entries >= 0` and `limit > 0`). They do not detect a real incident; they only confirm that Thanos Ruler can query `node_exporter` conntrack series through Thanos Querier. Labels use `severity: none` so you can tell them apart from production alerts.*

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: conntrack-test
  namespace: custom-alert
  labels:
    role: alert-rules
    app.kubernetes.io/part-of: conntrack-monitoring-lab
spec:
  groups:
    - name: conntrack.lab.custom-alert
      interval: 30s
      rules:
        - alert: ConntrackEntriesNonNegative
          annotations:
            summary: "Lab alert: node_nf_conntrack_entries visible via Thanos Ruler / thanos-querier."
            description: |
              Fires when node_nf_conntrack_entries >= 0 for job=node-exporter.
              If Pending, check namespacesWithoutLabelEnforcement and that this rule is NOT leaf-prometheus.
          expr: node_nf_conntrack_entries{job="node-exporter"} >= 0
          labels:
            severity: none
            test: conntrack-lab
        - alert: ConntrackLimitPositive
          annotations:
            summary: "Lab alert: node_nf_conntrack_entries_limit visible."
            description: Fires when table limit metric is > 0.
          expr: node_nf_conntrack_entries_limit{job="node-exporter"} > 0
          labels:
            severity: none
            test: conntrack-lab
EOF
```

**Expect:** within a couple of evaluation intervals, open **Administrator → Observe → Alerting → Alerting rules**, filter **Source: User**, and find `ConntrackEntriesNonNegative` and `ConntrackLimitPositive` in state **Firing** with count approximately equal to node count.

## Production: real thresholds

Remove the lab rules first (optional but avoids noise), then apply utilization and drop or insert-failure alerts.

### Remove demo rules

```bash
oc delete prometheusrule conntrack-test -n custom-alert --ignore-not-found
```

### Apply production-style rules

*The next `PrometheusRule` replaces the lab checks with **threshold and failure** rules: **warning** and **critical** alerts when the conntrack table is above 75% or 90% full (with `for` delays to reduce noise), and **critical** alerts when kernel counters show packets dropped, early drops, or insert failures (rates over five minutes). Together those cover high utilization and signs the table is already failing traffic.*

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: conntrack-recommended
  namespace: custom-alert
  labels:
    role: alert-rules
    app.kubernetes.io/part-of: conntrack-monitoring
spec:
  groups:
    - name: conntrack.node.rules
      interval: 30s
      rules:
        - alert: NodeConntrackTableUtilizationWarning
          annotations:
            summary: Conntrack table use is high on {{ $labels.instance }}
            description: |
              {{ $value | humanizePercentage }} of nf_conntrack entries are in use (above 75%).
              Investigate connection churn, NAT/proxy load, or co-located ingress gateways.
          expr: |
            (
              node_nf_conntrack_entries{job="node-exporter"}
              /
              node_nf_conntrack_entries_limit{job="node-exporter"}
            ) > 0.75
          for: 15m
          labels:
            severity: warning
        - alert: NodeConntrackTableUtilizationCritical
          annotations:
            summary: Conntrack table nearly full on {{ $labels.instance }}
            description: |
              {{ $value | humanizePercentage }} of nf_conntrack entries are in use (above 90%).
          expr: |
            (
              node_nf_conntrack_entries{job="node-exporter"}
              /
              node_nf_conntrack_entries_limit{job="node-exporter"}
            ) > 0.90
          for: 5m
          labels:
            severity: critical
        - alert: NodeConntrackPacketsDropped
          annotations:
            summary: Conntrack is dropping packets on {{ $labels.instance }}
            description: node_nf_conntrack_stat_drop rate > 0 over 5m.
          expr: |
            rate(node_nf_conntrack_stat_drop{job="node-exporter"}[5m]) > 0
          for: 2m
          labels:
            severity: critical
        - alert: NodeConntrackEarlyDrop
          annotations:
            summary: Conntrack early_drop events on {{ $labels.instance }}
            description: nf_conntrack early_drop counter increasing (rate > 0 over 5m).
          expr: |
            rate(node_nf_conntrack_stat_early_drop{job="node-exporter"}[5m]) > 0
          for: 2m
          labels:
            severity: critical
        - alert: NodeConntrackInsertFailed
          annotations:
            summary: Conntrack insert failures on {{ $labels.instance }}
            description: insert_failed counter increasing; table may be full or under pressure.
          expr: |
            rate(node_nf_conntrack_stat_insert_failed{job="node-exporter"}[5m]) > 0
          for: 2m
          labels:
            severity: critical
EOF
```

### Tuning thresholds

* **Warning ratio:** change `0.75` or lengthen `for: 15m` if too noisy.
* **Critical ratio:** change `0.90` or `for: 5m`.
* **Drops:** `rate(...[5m]) > 0` with `for: 2m` ignores single-scrape blips; tighten or loosen as needed.
* If the UI warns that `stat_*` metrics are **not counters**, confirm types for your `node_exporter` build; `increase(...[10m]) > 0` is a common alternative for counter-like series.

### Notifications (user Alertmanager)

User Alertmanager reads its configuration from `Secret/alertmanager-user-workload` in `openshift-user-workload-monitoring` (key `alertmanager.yaml`). For enabling user Alertmanager, Slack webhooks, and updating that Secret, see [Custom Alerts in ROSA 4.11.x](/experts/rosa/custom-alertmanager-4.11/).

> **Note:** User Alertmanager configuration is **not** a fully managed ROSA surface. Toggling User Workload Monitoring in OpenShift Cluster Manager can overwrite related configuration. Keep a copy of your `alertmanager.yaml` and re-apply after changes.

**Prerequisites:** Create a Slack **Incoming Webhook** and set the URL in your shell (do not commit it):

```bash
export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/T000/B000/XXXXXXXX'
```

**Example Slack receiver** (unquoted `EOF` so the shell substitutes `${SLACK_WEBHOOK_URL}`; change `#openshift-alerts` to your channel):

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-user-workload
  namespace: openshift-user-workload-monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      receiver: slack-notifications
      group_by: ['namespace', 'alertname']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
    receivers:
    - name: slack-notifications
      slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#openshift-alerts'
        send_resolved: true
        title: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }} ({{ .CommonLabels.namespace }})'
        text: |-
          {{ range .Alerts }}
          *Alert:* {{ .Labels.alertname }}
          *Severity:* {{ .Labels.severity }}
          *Summary:* {{ .Annotations.summary }}
          *Description:* {{ .Annotations.description }}
          {{ end }}
EOF
```

If you prefer not to expand a variable in the shell, use a literal placeholder in `api_url:` and replace it before `oc apply`, or use `--from-file=alertmanager.yaml=...` as in the linked guide.

After applying, wait for user Alertmanager pods to pick up the Secret (typically within about a minute). Firing **User** alerts (for example the lab rules `ConntrackEntriesNonNegative` or `ConntrackLimitPositive` from the demo section) should then appear in Slack.

For `AlertmanagerConfig` CRs, multiple receivers, or release-specific details, follow your OpenShift version documentation in addition to the Cloud Experts article.

## Verify

```bash
oc get prometheusrule -n custom-alert
oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=thanos-ruler
```

In the console: **Administrator → Observe → Alerting**, filter **Source: User** and search for alert names.

**Optional platform check** (confirms metrics exist at source):

```bash
PROM=$(oc get pod -n openshift-monitoring -l 'app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=k8s' -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-monitoring "$PROM" -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=node_nf_conntrack_entries' | head -c 500
echo
```

## Cleanup

```bash
oc delete prometheusrule conntrack-recommended -n custom-alert --ignore-not-found
oc delete prometheusrule conntrack-test -n custom-alert --ignore-not-found
```

Remove `custom-alert` from `namespacesWithoutLabelEnforcement` (edit the ConfigMap and re-apply), then optionally delete the namespace:

```bash
oc delete namespace custom-alert --ignore-not-found
```

## Troubleshooting

| Symptom | Things to check |
|--------|------------------|
| Lab rules **never** fire as User | `namespacesWithoutLabelEnforcement` includes `custom-alert`; wait for operator reconcile; rule must **not** have `leaf-prometheus` scope. |
| `oc apply` ConfigMap **Forbidden / unknown field** | On **4.18+**, remove `prometheus.enabled` from `user-workload-monitoring-config`. |
| `custom-alert` not eligible | Namespace needs `openshift.io/user-monitoring: "true"`; avoid `openshift.io/cluster-monitoring: "true"` on that namespace for this pattern. |
| `oc exec` into Prometheus fails | Use **Observe → Metrics** in the console or fix admission webhooks blocking exec. |
| Duplicate 75% in platform UI | Expected on ROSA Classic; customer paging should come from user Alertmanager only. |

## Optional further reading

* ROSA Classic [Managing alerts](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws_classic_architecture/4/html/monitoring/managing-alerts) (user-defined projects, cross-project rules, and related administrator tasks).
* You can keep the same manifests as files and run `oc apply -f` instead of heredocs if that fits your GitOps workflow.

This guide aligns with OpenShift **4.18** validation of `user-workload-monitoring-config` and Thanos Ruler and Querier behavior observed on ROSA Classic.
