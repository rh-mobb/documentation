---
date: '2022-09-14T22:07:08.584151'
title: Shipping logs to Azure Log Analytics
tags: ["Observability", "Azure"]
---

This document follows the steps outlined by Microsoft in [their documentation](https://docs.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-azure-redhat4-setup)

Follow docs.

Step 4, needs additional command of:
```bash
az resource list --resource-type Microsoft.RedHatOpenShift/OpenShiftClusters -o json
```
to capture resource ID of ARO cluster as well, needed for export in step 6

`bash enable-monitoring.sh --resource-id $azureAroV4ClusterResourceId --workspace-id $logAnalyticsWorkspaceResourceId` works successfully

can verify pods starting

Verify logs flowing with container solutions showing in log analytics workbook?

## Configure Prometheus metric scraping

following steps outlined here: https://docs.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-prometheus-integration

It looks like config maps are not set in the previous step despite what the article says. This may actually be an OpenShift v3 thing and not a v4 thing. I had to do the apply process after downloading the config.

Afterward pods did not restart on their own and had to be manually deleted. Automatic recreation pulls in new config and should begins shipping metrics

Verify metrics with a query: (from https://docs.microsoft.com/en-us/azure/azure-monitor/containers/container-insights-log-search#query-prometheus-metrics-data)

```
InsightsMetrics
| where TimeGenerated > ago(1h)
| where Name == 'reads'
| extend Tags = todynamic(Tags)
| extend HostName = tostring(Tags.hostName), Device = Tags.name
| extend NodeDisk = strcat(Device, "/", HostName)
| order by NodeDisk asc, TimeGenerated asc
| serialize
| extend PrevVal = iif(prev(NodeDisk) != NodeDisk, 0.0, prev(Val)), PrevTimeGenerated = iif(prev(NodeDisk) != NodeDisk, datetime(null), prev(TimeGenerated))
| where isnotnull(PrevTimeGenerated) and PrevTimeGenerated != TimeGenerated
| extend Rate = iif(PrevVal > Val, Val / (datetime_diff('Second', TimeGenerated, PrevTimeGenerated) * 1), iif(PrevVal == Val, 0.0, (Val - PrevVal) / (datetime_diff('Second', TimeGenerated, PrevTimeGenerated) * 1)))
| where isnotnull(Rate)
| project TimeGenerated, NodeDisk, Rate
| render timechart
```
