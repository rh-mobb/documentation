# Upgrade a disconnected ARO cluster

**Aaron Green & Kevin Collins**

*03/02/2022*

## Background
One of the great features of ARO is that you can create 'disconnected' clusters with no connectivity to the Internet.  Out of the box, the ARO service mirrors all the code repositories to build OpenShift clusters to Azure Container Registry.  This means ARO is built without having to reach out to the Internet as the images to build OpenShift are pulled via the Azure private network.

When you upgrade a cluster, OpenShift needs to call out to the Internet to get an upgrade graph to see what options you have to upgrade the cluster.  This of course breaks the concept of having a disconnected cluster.  This guide goes through how to upgrade ARO without having the cluster reach out to the Internat and maintaining the disconnected nature of an ARO cluster.

## Prerequisites

  * a Private Azure Red Hat OpenShift cluster with no Internet Connectivity

## Get Started

1. Determine which version you want to upgrade to:

  If you already know which version you want to upgrade to, you can skip this part.

  First check which version your cluster is at:
  ```bash
  oc get clusterversion version
  ```

  Note the server version. 
 ```
 NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.10.40   True        False         14h     Cluster version is 4.10.40
  ```

  Verify you are selecting a valid version to upgrade to.  Go to https://access.redhat.com/labsinfo/ocpupgradegraph

  Under Channel, select the stable minor version that you want to upgrade the cluster to.  In this example, we have 4.10 cluster that is at patch level 40 and we want to upgrade it to 4.11.  Note that you can also update patch versions.

  On the next screen, start by selecting the version your cluster is at.  4.10.40 in this example.
  Then select the version you want to upgrade to ensuring there is a green line showing the upgrade path is recommended.  In this example, we will select the latest 4.11 version 4.11.28.

  ![Upgrade Graph](./graph.png)

1. Retrieve the image digest of the OpenShift version you want to upgrade to:
  

   ```bash
   curl  --silent https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.11.28/release.txt | grep "Pull From:"
   ```

   > replace 4.11.28 with the version you want to upgrade to

   Expected Output:
   ```
     Pull From: quay.io/openshift-release-dev/ocp-release@sha256:85238bc3eddb88e958535597dbe8ec6f2aa88aa1713c2e1ee7faf88d1fefdac0
   ``` 
1. Perform the Upgrade

    > Set the image to the desired values from the above command.

   ```bash
   oc adm upgrade --allow-explicit-upgrade --to-image=quay.io/openshift-release-dev/ocp-release@sha256:1c3913a65b0a10b4a0650f54e545fe928360a94767acea64c0bd10faa52c945a --force
   ```
1. Check the status of the scheduled upgrade

   ```bash
   oc get clusterversion version
   ```

   When the upgrade is complete you will see the following:


   ```
   NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
   version   4.11.28    True        False         161m    Cluster version is 4.11.28
   ```
