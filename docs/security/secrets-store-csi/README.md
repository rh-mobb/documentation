# Installing the Kubernetes Secret Store CSI on OpenShift

The Kubernetes Secret Store CSI is a storage driver that allows you to mount secrets from external secret management systems like HashiCorp Vault and AWS Secrets.

It comes in two parts, the Secret Store CSI, and a Secret provider driver. This document covers just the CSI itself.

## Prerequisites

1. An OpenShift Cluster (ROSA, ARO, OSD, and OCP 4.x all work)
1. kubectl
1. helm v3

{% include_relative install-kubernetes-secret-store-driver.md %}


{% include_relative uninstall-kubernetes-secret-store-driver.md %}

## Provider Specifics

[HashiCorp Vault](./hashicorp-vault)