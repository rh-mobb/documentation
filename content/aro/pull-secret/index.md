---
date: '2026-02-26'
title: Add or Update a Red Hat Pull Secret on ARO
tags: ["ARO", "Azure"]
authors:
  - Paul Czarkowski
---


## Why add a Red Hat pull secret?

If you create an Azure Red Hat OpenShift (ARO) cluster **without** providing a Red Hat pull secret, ARO still creates a pull secret automatically, however, it is **not fully populated**. Adding your Red Hat pull secret enables your cluster to:

- Access Red Hat container registries and related content
- Install operators from **OperatorHub** (for example, OpenShift Virtualization and other Red Hat operators)
- Use additional Red Hat and partner operator-backed capabilities (for example, OpenShift Data Foundation)

For Microsoft's official documentation on managing pull secrets for ARO, see [Add or update your Red Hat pull secret on an Azure Red Hat OpenShift 4 cluster](https://learn.microsoft.com/en-us/azure/openshift/howto-add-update-pull-secret).


## Prerequisites

* Helm CLI

## Prepare Environment

1. Add the MOBB chart repository to your Helm

    ```bash
    helm repo add mobb https://rh-mobb.github.io/helm-charts/
    ```

1. Update your repositories

    ```bash
    helm repo update
    ```

## Deploy the Helm Chart

1. Before Deploying the chart you need it to adopt the existing pull secret

   ```bash
   kubectl -n openshift-config annotate secret \
    pull-secret meta.helm.sh/release-name=pull-secret
   kubectl -n openshift-config annotate secret \
     pull-secret meta.helm.sh/release-namespace=openshift-config
   kubectl -n openshift-config label secret \
     pull-secret app.kubernetes.io/managed-by=Helm
   ```

1. Download your pull secret from **https://console.redhat.com/openshift/downloads -> Tokens -> Pull secret** and save it to values.yaml

    ```bash
    echo "pullSecret: '`cat ~/Downloads/pull-secret.txt`' > /tmp/values.yaml
    ```

1. Update the pull secret

   ```
   helm upgrade --install pull-secret mobb/aro-pull-secret \
     -n openshift-config --values /tmp/values.yaml
   ```

1. Optionally enable Operator Hub

   ```bash
   oc patch configs.samples.operator.openshift.io cluster --type=merge \
         -p='{"spec":{"managementState":"Managed"}}'
   oc patch operatorhub cluster --type=merge \
         -p='{"spec":{"sources":[
           {"name":"redhat-operators","disabled":false},
           {"name":"certified-operators","disabled":false},
           {"name":"community-operators","disabled":false},
           {"name":"redhat-marketplace","disabled":false}
         ]}}'
   ```
