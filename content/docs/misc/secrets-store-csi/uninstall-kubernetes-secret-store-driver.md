## Uninstalling the Kubernetes Secret Store CSI

1. Delete the secrets store csi driver

    ```bash
    helm delete -n k8s-secrets-store-csi csi-secrets-store
    ```

1. Delete the SecurityContextConstraints

    ```bash
    oc adm policy remove-scc-from-user privileged \
      system:serviceaccount:k8s-secrets-store-csi:secrets-store-csi-driver
    ```
