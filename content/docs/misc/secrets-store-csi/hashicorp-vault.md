---
date: '2021-08-18'
title: Installing the HashiCorp Vault Secret CSI Driver
aliases: ['/docs/security/secrets-store-csi/hashicorp-vault']
tags: ["ROSA", "ARO", "OSD", "OCP"]
authors:
  - Connor Wooley
---

The HashiCorp Vault Secret CSI Driver allows you to access secrets stored in HashiCorp Vault as Kubernetes Volumes.

## Prerequisites

1. An OpenShift Cluster (ROSA, ARO, OSD, and OCP 4.x all work)
1. kubectl
1. helm v3

{{< readfile file="/docs/misc/secrets-store-csi/install-kubernetes-secret-store-driver.md" markdown="true" >}}

## Install HashiCorp Vault with CSI driver enabled

1. Add the HashiCorp Helm Repository

    ```bash
    helm repo add hashicorp https://helm.releases.hashicorp.com
    ```

1. Update your Helm Repositories

    ```bash
    helm repo update
    ```

1. Create a namespace for Vault

    ```bash
    oc new-project hashicorp-vault
    ```

1. Create a SCC for the CSI driver

    ```bash
    oc adm policy add-scc-to-user privileged \
      system:serviceaccount:hashicorp-vault:vault-csi-provider
    ```

1. Create a values file for Helm to use

    ```bash
    cat << EOF > values.yaml
    global:
      openshift: true
    csi:
      enabled: true
      daemonSet:
        providersDir: /var/run/secrets-store-csi-providers
    injector:
      enabled: false
    server:
      image:
        repository: "registry.connect.redhat.com/hashicorp/vault"
        tag: "1.8.0-ubi"
      dev:
        enabled: true
    EOF
    ```

1. Install Hashicorp Vault with CSI enabled

    ```bash
    helm install -n hashicorp-vault vault \
      hashicorp/vault --values values.yaml
    ```

1. Patch the CSI daemonset

    > Currently the CSI has a bug in its manifest which we need to patch

    ```bash
    kubectl patch daemonset vault-csi-provider --type='json' \
        -p='[{"op": "add", "path": "/spec/template/spec/containers/0/securityContext", "value": {"privileged": true} }]'
    ```

## Configure Hashicorp Vault

1. Get a bash prompt inside the Vault pod

    ```bash
    oc exec -it vault-0 -- bash
    ```

1. Create a Secret in Vault

    ```bash
    vault kv put secret/db-pass password="hunter2"
    ```

1. Configure Vault to use Kubernetes Auth

    ```bash
    vault auth enable kubernetes
    ```

1. Check your Cluster's token issuer

    ```bash
    oc get authentication.config cluster \
      -o json | jq -r .spec.serviceAccountIssuer
    ```

1. Configure Kubernetes auth method

    > If the issuer here does not match the above, update it.

    ```bash
    vault write auth/kubernetes/config \
    issuer="https://kubernetes.default.svc.cluster.local" \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    ```

1. Create a policy for our app

    ```bash
    vault policy write internal-app - <<EOF
    path "secret/data/db-pass" {
      capabilities = ["read"]
    }
    EOF
    ```

1. Create an auth role to access it

    ```bash
    vault write auth/kubernetes/role/database \
      bound_service_account_names=webapp-sa \
      bound_service_account_namespaces=default \
      policies=internal-app \
      ttl=20m
    ```

1. exit from the vault-0 pod

    ```bash
    exit
    ```

## Deploy a sample application

1. Create a SecretProviderClass in the default namespace

    ```bash
    cat <<EOF | kubectl apply -f -
    apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
    kind: SecretProviderClass
    metadata:
      name: vault-database
      namespace: default
    spec:
      provider: vault
      parameters:
        vaultAddress: "http://vault.hashicorp-vault:8200"
        roleName: "database"
        objects: |
          - objectName: "db-password"
            secretPath: "secret/data/db-pass"
            secretKey: "password"
    EOF
    ```

1. Create a service account `webapp-sa`

    ```bash
    kubectl create serviceaccount -n default webapp-sa
    ```

1. Create a Pod to use the secret

    ```bash
    cat << EOF | kubectl apply -f -
    kind: Pod
    apiVersion: v1
    metadata:
      name: webapp
      namespace: default
    spec:
      serviceAccountName: webapp-sa
      containers:
      - image: jweissig/app:0.0.1
        name: webapp
        volumeMounts:
        - name: secrets-store-inline
          mountPath: "/mnt/secrets-store"
          readOnly: true
      volumes:
        - name: secrets-store-inline
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "vault-database"
    EOF
    ```

1. Check the Pod has the secret

    ```bash
    kubectl -n default exec webapp \
      -- cat /mnt/secrets-store/db-password
    ```

    The output should match

    ```bash
    hunter2
    ```

## Uninstall HashiCorp Vault with CSI driver enabled

1. Delete the pod and

    ```bash
    kubectl delete -n default pod webapp
    kubectl delete -n default secretproviderclass vault-database
    kubectl delete -n default serviceaccount webapp-sa
    ```

1. Delete the Hashicorp Vault Helm

    ```bash
    helm delete -n hashicorp-vault vault
    ```

1. Delete the SCC for Hashicorp Vault

    ```bash
    oc adm policy remove-scc-from-user privileged \
      system:serviceaccount:hashicorp-vault:vault-csi-provider
    ```

1. Delete the Hashicorp vault project

    ```bash
    oc delete project hashicorp-vault
    ```

{{< readfile file="/docs/misc/secrets-store-csi/uninstall-kubernetes-secret-store-driver.md" markdown="true" >}}
