---
date: '2022-06-28'
title: Accessing the Internal Registry from ARO
tags: ["ARO", "Azure"]
authors:
  - Kevin Collins
  - Connor Wooley
  - Thatcher Hubbard
---

**Kevin Collins**

*06/28/2022*

One of the advantages of using OpenShift is the internal registry that comes with OpenShfit to build, deploy and manage container images locally.  By default, access to the registry is limited to the cluster ( by design ) but can be extended to usage outside of the cluster.  This guide will go through the steps required to access the OpenShift Registry on an ARO cluster outside of the cluster.

## Prerequisites

* an ARO Cluster
* oc cli
* podman or docker cli

## Expose the Registry
1. Expose the registry service
   ```bash
   oc patch config.imageregistry.operator.openshift.io/cluster --patch='{"spec":{"defaultRoute":true}}' --type=merge
   oc patch config.imageregistry.operator.openshift.io/cluster --patch='[{"op": "add", "path": "/spec/disableRedirect", "value": true}]' --type=json
   ```

1.  Get the route host name
    ```bash
    HOST=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
    ```
1. Log into the image registry
   ```bash
   podman login -u $(oc whoami) -p $(oc whoami -t) $HOST
   ```
## Test it out
   ```bash
   podman pull $HOST/openshift/cli

   podman images
   ```

   Expected output:

   ```bash
   default-route-openshift-image-registry.apps.<domain>/openshift/cli                latest      aa85757767cb  3 weeks ago    615 MB
   ```
