## Installing the Kubernetes Secret Store CSI

1. Create an OpenShift Project to deploy the CSI into

    ```bash
    oc new-project k8s-secrets-store-csi
    ```

1. Set SecurityContextConstraints to allow the CSI driver to run (otherwise the DaemonSet will not be able to create Pods)

    ```bash
    oc adm policy add-scc-to-user privileged \
      system:serviceaccount:k8s-secrets-store-csi:secrets-store-csi-driver
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
    helm install -n k8s-secrets-store-csi csi-secrets-store \
      secrets-store-csi-driver/secrets-store-csi-driver \
      --set "linux.providersDir=/var/run/secrets-store-csi-providers"
    ```

1. Check that the Daemonsets is running

    ```bash
    kubectl --namespace=k8s-secrets-store-csi get pods -l "app=secrets-store-csi-driver"
    ```

    You should see the following

    ```bash
    NAME                                               READY   STATUS    RESTARTS   AGE
    csi-secrets-store-secrets-store-csi-driver-cl7dv   3/3     Running   0          57s
    csi-secrets-store-secrets-store-csi-driver-gbz27   3/3     Running   0          57s
    ```
