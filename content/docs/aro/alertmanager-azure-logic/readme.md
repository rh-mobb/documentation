Prerequisites:
USING CLUSTER LOGGING FORWARDER IN ARO WITH AZURE MONITOR: https://mobb.ninja/docs/aro/clf-to-azure/ 
Once log forwarder is configured. Logs can be seen via dashboard or az cli.


Configuring alert manager:
Modify alertmanager.yaml which is in openshift-monitoring namespace. Using following command
oc -n openshift-monitoring get secret alertmanager-main --template='{{ index .data "alertmanager.yaml" }}' | base64 --decode > alertmanager.yaml



Add a new receiver inside receiver’s section
- name: 'azure-webhook'
  webhook_configs:
    - url: 'https://logic-app-webhook-url'

Add a new receiver below default with routing rules
  receiver: azure-webhook
  routes:
  - matchers:
    - "severity=critical"
    receiver: azure-webhook



final file should look like this
global:
  resolve_timeout: 5m
route:
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  receiver: default
  routes:
  - matchers:
    - "alertname=Watchdog"
    repeat_interval: 5m
    receiver: watchdog
  receiver: azure-webhook
  routes:
  - matchers:
    - "severity=critical"
    receiver: azure-webhook
receivers:
- name: default
- name: watchdog
- name: 'azure-webhook'
  webhook_configs:
  - url: 'https://logic-app-webhook-url'



Apply the yaml file.
oc apply -f alertmanager.yaml -n openshift-monitoring
