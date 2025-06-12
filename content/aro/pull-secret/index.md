# Helm Chart to set up a Red Hat pull secret for your ARO cluster

## Prerequisites

* An ARO 4.10 cluster
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
