## Uninstalling the Kubernetes Secret Store CSI

1. Delete the secrets store csi driver

    ```bash
    helm delete -n kube-system csi-secrets-store
    ```

1. Delete the SecurityContextConstraints

    ```bash
    oc adm policy remove-scc-from-user privileged \
      system:serviceaccount:kube-system:secrets-store-csi-driver
    ```