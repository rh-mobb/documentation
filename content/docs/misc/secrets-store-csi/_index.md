---
date: '2022-09-14T22:07:09.804151'
title: Installing the Kubernetes Secret Store CSI on OpenShift
alias: /docs/security/secrets-store-csi
tags: ["ARO", "ROSA", "OSD", "OCP"]
---

The Kubernetes Secret Store CSI is a storage driver that allows you to mount secrets from external secret management systems like HashiCorp Vault and AWS Secrets.

It comes in two parts, the Secret Store CSI, and a Secret provider driver. This document covers just the CSI itself.

## Prerequisites

1. An OpenShift Cluster (ROSA, ARO, OSD, and OCP 4.x all work)
1. kubectl
1. helm v3

{{< readfile file="/docs/misc/secrets-store-csi/install-kubernetes-secret-store-driver.md" markdown="true" >}}

{{< readfile file="/docs/misc/secrets-store-csi/uninstall-kubernetes-secret-store-driver.md" markdown="true" >}}

## Provider Specifics

[HashiCorp Vault](./hashicorp-vault)
