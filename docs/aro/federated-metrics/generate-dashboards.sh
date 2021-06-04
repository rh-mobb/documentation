#!/bin/bash

for dashboard in `kubectl -n openshift-monitoring get cm | grep grafana-dashboard- | awk '{print $1}'`; do

  json=`kubectl get cm $dashboard -o json | jq '.data | values[]'`

  cat << EOF >> dashboards.yaml
---
apiVersion: integreatly.org/v1alpha1
kind: GrafanaDashboard
metadata:
  name: $dashboard
  namespace: custom-grafana
  labels:
    app: grafana
spec:
  json: $json
EOF

done