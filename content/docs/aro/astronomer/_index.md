---
date: '2022-09-14T22:07:08.554151'
title: Installing Astronomer on a private ARO cluster
---
# Installing Astronomer on a private ARO cluster

> see [here](./README-public) for public clusters.

This assumes you've already got a private ARO cluster installed. You could also follow the same instructions to create a public Astronomer, just use a regular DNS zone and skip the private parts.

A default 3-node cluster is a bit small for Astronomer, If you have a three node cluster you can increase it by updating the replicas count machinesets in the `openshift-machine-api` namespace.

## Create a private DNS

1. Log into Azure and click to [private dns](https://portal.azure.com/#blade/HubsExtension/BrowseResource/resourceType/Microsoft.Network%2FprivateDnsZones)

1. Click **+ Add**

1. Set the **Resource Group** to match your ARO Resource Group

1. Set **Name** to your TLD (astro.mobb.ninja in the example)

1. Click **Review and Create** and create the Zone

1. Inside the Domain settings click **Virtual network links** -> **+ Add**

1. **Link Name**: astro-aro

1. Select the correct **Subscription** and **Network** from the dropdown boxes

1. Click **OK**


## Create TLS Secret

1. Next we need a TLS Secret to use. You could create a self-signed certificate using a CA that you own, or use certbot (if you have a valid DNS provider, note records don't need to be public)

    ```
    certbot certonly --manual \
          --preferred-challenges=dns \
          --email username.taken@gmail.com \
          --server https://acme-v02.api.letsencrypt.org/directory \
          --agree-tos \
          --manual-public-ip-logging-ok \
          -d "*.astro.mobb.ninja"
    ```

1. Follow certbot's instructions (something like ):

    ```
    - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    Please deploy a DNS TXT record under the name
    _acme-challenge.astro.mobb.ninja with the following value:

    8d2HNuZ8rn9McPTzpo2evJsAJI8K4eJuVLaZlz6d-kc

    Before continuing, verify the record is deployed.
    - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
    ```

1. Create a Secret from the Cert (use the paths provided from the above command):

    ```
    oc new-project astronomer
    oc create secret tls astronomer-tls --cert=/etc/letsencrypt/live/astro.mobb.ninja/fullchain.pem --key=/etc/letsencrypt/live/astro.mobb.ninja/privkey.pem
    ```

## Deploy Astronomer

1. update the `values.yaml` and set `baseDomain: astro.mobb.ninja`


1. Install

    ```
    helm repo add astronomer https://helm.astronomer.io/

    helm repo update

    helm install -f values.yaml --version=0.25.2 \
      --namespace=astronomer astronomer \
      astronomer/astronomer
    ```

## While that's running add our DNS

1. In another shell run

    ```
    kubectl get svc -n astronomer astronomer-nginx
    ```

1. Go back to your private DNS zone in Azure and create a record set `*` and copy the contents of `EXTERNAL-IP` from the above command.

## Fix SCCs for elasticsearch

```
oc adm policy add-scc-to-user privileged -z astronomer-elasticsearch

oc patch deployment astronomer-elasticsearch-client -p '{"spec":{"template":{"spec":{ "containers": [{"name": "es-client","securityContext":{"privileged": true,"runAsUser": 0}}]}}}}'
```

## Validate the Install

1. Check the Helm install has finished

    ```
    NAME: astronomer
    LAST DEPLOYED: Mon May 24 18:03:05 2021
    NAMESPACE: astronomer
    STATUS: deployed
    REVISION: 1
    TEST SUITE: None
    NOTES:
    Thank you for installing Astronomer!

    Your release is named astronomer.

    The platform components may take a few minutes to spin up.

    You can access the platform at:

    - Astronomer dashboard:        https://app.astro.mobb.ninja
    - Grafana dashboard:           https://grafana.astro.mobb.ninja
    - Kibana dashboard:            https://kibana.astro.mobb.ninja

    Now that you've installed the platform, you are ready to get started and create your first airflow deployment.

    Download the CLI:

            curl -sSL https://install.astro.mobb.ninja | sudo bash

    We have guides available at https://www.astronomer.io/guides/ and are always available to help.
    ```

1. Since this is a private LB you'll need to access it from inside the network. The quick hacky way to do this is

    ```
    kubectl exec -ti astronomer-cli-install-6f899c87d5-2c84f -- wget -O -  https://install.astro.mobb.ninja
    ```

    and you should see

    ```
    #! /usr/bin/env bash

    TAG=${1:-v0.20.0}

    if (( EUID != 0 )); then
        echo "Please run command as root."
        exit
    fi

    DOWNLOADER="https://raw.githubusercontent.com/astronomer/astro-cli/main/godownloader.sh"
    ```