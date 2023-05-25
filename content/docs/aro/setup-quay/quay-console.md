---
date: '2022-09-19'
title: Setting up Quay on an ARO cluster via Console
aliases: ['/docs/aro/setup-quay/quay-cli.md']
tags: ["ARO", "Azure"]
---

![Quay Logo](../images/redhat-quay-logo.png)

## Red Hat Quay setup on ARO (Azure Openshift)
A guide to deploying an Azure Red Hat OpenShift Cluster with Red Hat Quay.

Author: [Kristopher White x Connor Wooley]

## Video Walkthrough

If you prefer a more visual medium, you can watch [Kristopher White] walk through Quay Registry Storage Setup on [YouTube]([https://youtu.be/iifsB-uuEFc](https://youtu.be/yMmSrx4hN70)).

<iframe width="560" height="315" src="https://www.youtube.com/embed/yMmSrx4hN70" title="YouTube video player" frameborder="0" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>

## Red Hat Quay Setup

### Backend Storage Setup

1. Login to [Azure](https://portal.azure.com/)

1. Search/Click **Create Resource Groups**

1. **Name** Resource Group > Click **Review + Create** > Click **Create**

1. Search/Click **Create Storage Accounts**

1. Choose Resource Group > Name Storage Account > Choose Region > Choose Performance > Choose Redundancy > Click **Review + Create** > Click **Create** Click **Go To Resource**

1. ![Storage Account View](../images/storage-account-viewv2.PNG)

1. Go to **Data Storage** > Click **Container** > Click **New Container** > **Name** Container > Set Privacy to **Public Access Blob** > Click **Create**

1. Go to **Storage Account** > Click **Access Keys** > Go to key 1 > Click **Show Key**

1. **Storage Account Name**, **Container Name**, and **Access Keys** will be used to configure quay registry storage.

### Red Hat Quay Operator Install
![Admin View](../images/admin-view.png)

1. Log into the OpenShift web console with your OpenShift cluster admin credentials.

1. Make sure you have selected the **Administrator** view.

1. Click **Operators > OperatorHub > Red Hat Quay**.

1. Search for and click the tile for the **Red Hat Quay** operator.

1. Click **Install**.

1. In the Install Operator pane:

1. Select the latest update channel.

1. Select the option to install Red Hat Quay in one namespace or for **all namespaces on your cluster**. If in doubt, choose the All namespaces on the cluster installation mode, and accept the default **Installed Namespace**.

1. Select the **Automatic** approval strategy.

1. Click **Install**.

### Successful Install

![Red Hat Quay Operator](../images/successful-quay-installv2.PNG)

### Redhat Quay Registry Deployment

1. Make sure you have selected the **Administrator** view.

1. Click **Operators > Installed Operators > Red Hat Quay > Quay Registry > Create QuayRegistry**.

1. Form View ![Red Hat Quay Form View](../images/quay-form-view.PNG)

1. YAML View ![Red Hat Quay YAML View](../images/quay-yaml-view.PNG)

1. Click **Create** > Click **Registry**

1. Successful Registry Deployment ![Pre Storage](../images/quay-pre-storage-view.PNG)

1. Click **Config Editor Credentials Secret**

1. Go to **Data** > **Reveal Values** (These values are used to login to **Config Editor Endpoint**)

1. Go to **Registry Console** > Click **Config Editor Endpoint** >

1. ![Registry Config Editor Login](../images/registry-config-editor-sign-in.PNG)

1. Scroll down to **Registry Storage** > Click **Edit Fields** > Go to **Storage Engine** click the drop down and select **Azure Blob Storage** > Fill in **Azure Storage Container** with **Storage Container Name** > Fill in **Azure Account Name** with **Azure Storage Account Name** > Fill in **Azure Account Key** with **Azure Storage Account Access Key**

1. ![Quay Registry Storage Config](../images/quay-registry-storagev2.png)

1. Click **Validate Configuration Changes**

1. Click **Reconfigure Quay** ![Reconfiure Quay](../images/reconfig-quay.PNG)

1. Go to **Registry Console** > Click **Registry Endpoint**

1. ![Quay Registry Login](../images/quay-registry-login.PNG)

1. Click **Create Account**

1. Login to **Quay**.

1. Click **Create Repository**

1. ![New Quay Repo](../images/quay-new-repo.PNG)
