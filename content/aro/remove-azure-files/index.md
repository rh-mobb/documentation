---
date: '2025-06-28T22:07:09.774151'
title: Remove the default azure-files storage class
tags: ["ARO", "Azure"]
authors:
  - Kevin Collins
  - Kumudu Herath
---

Azure Red Hat OpenShift (ARO) clusters, while offering a robust application platform for containerized applications, come with a default storage class named azure-files. This default storage class is provided for user convenience, allowing for immediate persistent storage provisioning using Azure Files without additional configuration. However, it's crucial to understand that this azure-files storage class, by default, does not leverage a private endpoint. This can introduce a significant security vulnerability, as data traffic to and from Azure Files shares a public endpoint, potentially exposing sensitive information. Therefore, for environments with stringent security requirements, removing or replacing this default azure-files storage class and implementing a solution that utilizes private endpoints is a critical step in securing your ARO deployment.

## Pre Requisites

- ARO cluster logged into
- oc cli

## Remove the default azure-files storage class

To remove the default azure-files storage class that comes with ARO, we first need to change the file.csi.azure.com cluster csi driver to not be managed.

After that, we can now delete the azure-files storage class.

```bash
oc patch clustercsidriver  file.csi.azure.com --type=merge -p '{"spec":{"storageClassState":"Removed"}}'

oc delete sc azure-files
```

## (Optional) Re-create the Azure Files Storage class with a private endpoint

Follow this [guide](/experts/aro/private_endpoint/) to create an azure files storage class with a private endpoint.

