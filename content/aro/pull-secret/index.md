---
date: '2026-02-26'
title: Add or Update a Red Hat Pull Secret on ARO
tags: ["ARO"]
authors:
  - Paul Czarkowski
  - Diana Sari
---

When deploying an Azure Red Hat OpenShift (ARO) cluster, omitting a Red Hat pull secret results in a "limited" configuration. While this allows the cluster to function using core service images, it restricts access to the broader Red Hat ecosystem, including Red Hat container registries, along with other content like operators from OperatorHub.

Microsoft’s official guidance involves a manual process for updating these credentials. You can find those steps [here](https://learn.microsoft.com/en-us/azure/openshift/howto-add-update-pull-secret).

To eliminate the manual overhead of merging and updating secrets, we have developed a Helm Chart that automates the entire workflow. This tool intelligently concatenates your Red Hat pull secret with the existing cluster secret, ensuring seamless access to Red Hat resources without the risk of manual configuration errors.

## Prerequisites

* Helm CLI

## Prepare Environment

1. Add the Cloud Experts Helm Chart repository to your Helm environment:

    ```bash
    helm repo add mobb https://rh-mobb.github.io/helm-charts/
    ```

1. Update your Helm repositories to pull the latest content:

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

1. Download your pull secret from the [Red Hat OpenShift Cluster Manager](https://console.redhat.com/openshift/install/azure/aro-provisioned). 

    ```bash
    echo "pullSecret: '`cat ~/Downloads/pull-secret.txt`' > /tmp/values.yaml
    ```

1. Update the pull secret using the Helm Chart:

   ```
   helm upgrade --install pull-secret mobb/aro-pull-secret \
     -n openshift-config --values /tmp/values.yaml
   ```

1. Once the pull secret is updated, enable the OperatorHub sources:

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
