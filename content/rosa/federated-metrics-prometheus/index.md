---
date: '2021-10-21'
title: Federating Metrics to a centralized Prometheus Cluster
tags: ["AWS", "ROSA"]
authors:
  - Paul Czarkowski
---

This document has been removed as it was written for older ROSA clusters which did not allow for custom Alert Manager configs as a way to provide a second Prometheus with a configurable Alert Manager.

If you want to configure custom Alerts, you can upgrade your cluster and follow the steps found at [Custom Alerts in ROSA 4.11.x](../custom-alertmanager).

If you want to federate your metrics to a central location we recommend using one of the following:

1. [Federating System and User metrics to S3 in Red Hat OpenShift for AWS](../federated-metrics/)
2. [Using the AWS Cloud Watch agent to publish metrics to CloudWatch in ROSA](../metrics-to-cloudwatch-agent)

If you wish to view the old (likely no longer functional) document you can find it in the [git history of the mobb.ninja site](https://github.com/rh-mobb/documentation/blob/c72f39d1ca82436cc2188b94cd659a01bf88b2a6/content/experts/rosa/federated-metrics-prometheus/_index.md).
