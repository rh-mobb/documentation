---
date: '2024-02-06'
title: Migrating ROSA Ingress Controllers from a CLB to NLB
tags: ["AWS", "ROSA"]
aliases: ['/experts/rosa/clb-to-nlb-migration']
authors:
  - Michael McNeill
---

This guide will show you how to migrate the default Red Hat OpenShift Service on AWS (ROSA) IngressController from an AWS Classic Load Balancer to an AWS Network Load Balancer. 

[In version 4.14 of ROSA, Red Hat introduced changes to IngressControllers to give customers more control over their workloads and configuration.](https://access.redhat.com/articles/7028653) The operation below requires a cluster running version 4.14 or higher. To request early access to this additional functionality in version 4.13, please [contact Red Hat support and open a case to request access](https://access.redhat.com/support/).

## Prerequisites

* A ROSA Cluster (Version 4.14 or higher [see note above for version 4.13 clusters])
* A logged in `rosa` CLI
* A logged in `aws` CLI

### Procedure

1. Run the following command, making sure to update the name of your ROSA cluster you wish to modify:

    ```bash
    export CLUSTER_NAME=my-rosa-cluster
    ```

1. Run the following command to list the ROSA ingresses:

    ```bash
    rosa list ingress -c ${CLUSTER_NAME}
    ```

    Your output may have one or more ingresses listed, as shown below:

    ```
    ID    APPLICATION ROUTER                                      PRIVATE  DEFAULT  ROUTE SELECTORS  LB-TYPE  EXCLUDED NAMESPACE  WILDCARD POLICY      NAMESPACE OWNERSHIP  HOSTNAME  TLS SECRET REF
    ab12  https://apps.my-rosa-cluster.fx4f.p1.openshiftapps.com  no       yes                       classic                      WildcardsDisallowed  Strict
    ```

    {{% alert state="danger" %}}If your `LB-TYPE` is set to `nlb`, do not follow the rest of this guide, your load balancer has already been upgraded.{{% /alert %}}

    Take note of the `ID`, which you will need in the next step.

1. Run the following command, making sure to update the ID of the ingress you wish to upgrade from the above step:

    ```bash
    export INGRESS_ID=<ID>
    rosa edit ingress -c ${CLUSTER_NAME} ${INGRESS_ID} --lb-type nlb
    ```

    Your command should look something like this:
    ```bash
    export INGRESS_ID=ab12
    rosa edit ingress -c ${CLUSTER_NAME} ${INGRESS_ID} --lb-type nlb
    ```

    Once you run the command, your output should look like this:

    ```text
    I: Updated ingress 'ab12' on cluster 'my-rosa-cluster'
    ```

    Congratulations! You have now updated your cluster IngressController from an AWS Classic Load Balancer to an AWS Network Load Balancer. Your cluster will update and propagate the necessary changes into AWS and update the DNS records to point to the new NLB.

    {{% alert state="warning" %}}There is a known issue when switching load balancer type where the original AWS Load Balancer that is being switched needs to be manually removed from AWS. This resource is cleaned up on cluster deletion, but will have to be manually deleted when upgrading from a CLB to an NLB to avoid extra charges.{{% /alert %}}