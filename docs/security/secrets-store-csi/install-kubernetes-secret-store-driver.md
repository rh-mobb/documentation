## Installing the Kubernetes Secret Store CSI

1. Check you have permission to create resources in `kube-system`

    ```bash
    kubectl auth can-i -n kube-system create daemonset
    ```

    you should see the response

    ```bash
    yes
    ```

1. Set SecurityContextConstraints to allow the CSI driver to run (otherwise the DaemonSet will not be able to create Pods)

    ```bash
    oc adm policy add-scc-to-user privileged \
      system:serviceaccount:kube-system:secrets-store-csi-driver
    ```

1. Add the Secrets Store CSI Driver to your Helm Repositories

    ```bash
    helm repo add secrets-store-csi-driver \
      https://raw.githubusercontent.com/kubernetes-sigs/secrets-store-csi-driver/master/charts
    ```

1. Update your Helm Repositories

    ```bash
    helm repo update
    ```

1. Install the secrets store csi driver

    ```bash
    helm install -n kube-system csi-secrets-store \
      secrets-store-csi-driver/secrets-store-csi-driver
    ```

1. Check that the Daemonsets is running

    ```bash
    kubectl --namespace=kube-system get pods -l "app=secrets-store-csi-driver"
    ```

    You should see the following

    ```bash
    NAME                                               READY   STATUS    RESTARTS   AGE
    csi-secrets-store-secrets-store-csi-driver-cl7dv   3/3     Running   0          57s
    csi-secrets-store-secrets-store-csi-driver-gbz27   3/3     Running   0          57s
    ```
