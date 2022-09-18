---
date: '2022-09-14T22:07:08.564151'
title: Registering an ARO cluster to OpenShift Cluster Manager
---
# Registering an ARO cluster to OpenShift Cluster Manager 

ARO clusters do not come connected to OpenShift Cluster Manager by default,
because Azure would like customers to specifically opt-in to connections / data
sent outside of Azure. This is the case with registering to OpenShift cluster
manager, which enables a telemetry service in ARO. 

## Prerequisites

* An Red Hat account. If you have any subscriptions with Red Hat, you will have
  a Red Hat account. If not, then you can create an account easily at
  https://cloud.redhat.com. 

## Steps

1. Login to https://console.redhat.com with you Red Hat account. 

2. Go to https://console.redhat.com/openshift/downloads and download your
pull-secret file. This is a file that includes an authentication for
cloud.openshift.com which is used by OpenShift Cluster Manager.

3. Follow the [Update pull secret instructions](https://docs.microsoft.com/en-us/azure/openshift/howto-add-update-pull-secret) to merge your pull-secret (in particular cloud.openshift.com) in your ARO pull secret. Be careful not to overwrite the ARO cluster pull secrets that come by default - it explains how in that article.

4. After waiting a few minutes (but it could be up to an hour), your 
   cluster should be automatically registered in this list in OpenShift Cluster 
   Manager; https://console.redhat.com/openshift

   You can check the cluster ID within the Cluster Overview section of the
   admin console with the ID of the cluster in OCM to make sure the right cluster is registered.

5. The cluster will appear as a 60-day self-supported evaluation cluster. However, again,
wait about an hour (but in this case, it can take up to 24 hours), and the
cluster will be automatically updated to an ARO type cluster, with full
support. You don't need to change the support level yourself. 

This makes the cluster a fully supported cluster within the Red Hat cloud
console, with access to raise support tickets, also.