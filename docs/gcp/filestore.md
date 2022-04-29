# Create Filestore Storage for OSD in GCP

Author: [Roberto Carratalá](https://github.com/rcarrata), [Paul Czarkowski](https://twitter.com/pczarkowski), [Andrea Bozzoni](https://github.com/abozzoni)

By default, within OSD in GCP only the [GCE-PD StorageClass](https://kubernetes.io/docs/concepts/storage/storage-classes/#gce-pd) is available in the cluster. With this StorageClass, only ReadWriteOnce mode is permitted, and the gcePersistentDisks can only be mounted by a [single consumer in read-write mode](https://kubernetes.io/docs/concepts/storage/volumes/#gcepersistentdisk).

Because of that, and for provide Storage with Shared Access (RWX) Access Mode to our OpenShift clusters a [GCP Filestore](https://cloud.google.com/filestore/docs) could be used.

> GCP Filestore is not managed neither supported by Red Hat or Red Hat SRE team.

## Prerequisites

* [gcloud CLI](https://cloud.google.com/sdk/gcloud)
* [jq](https://stedolan.github.io/jq/download/)
* [oc CLI](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html)

> The [GCP Cloud Shell](https://cloud.google.com/shell) can be used as well and have all the prerequisites installed already.

## Steps

1. From the CLI or GCP Cloud Shell, login within your account and your GCP project:

    ```sh
    gcloud auth login <google account user>
    gcloud config set project <google project name>
    ```

2. Create a Filestore instance in GCP:

    ```sh
    export ZONE_FS="us-west1-a"
    export NAME_FS="nfs-server"
    export TIER_FS="BASIC_HDD"
    export VOL_NAME_FS="osd4"
    export CAPACITY="1TB"
    export VPC_NETWORK="projects/my-project/global/networks/demo-vpc"

    gcloud filestore instances create $NAME_FS --zone=$ZONE_FS --tier=$TIER_FS --file-share=name="$VOL_NAME_FS",capacity=$CAPACITY --network=name="$VPC_NETWORK"
    ```

> Due to the Static Provisioning through the creation of the PV/PVC the Filestore for the RWX storage needs to be created upfront.

3. After the creation, check the Filestore instance generated in the GCP project:

    ```sh
    gcloud filestore instances describe $NAME_FS --zone=$ZONE_FS
    ```

4. Extract the ipAddresses from the NFS share for use them into the PV definition:

    ```sh
    NFS_IP=$(gcloud filestore instances describe $NAME_FS --zone=$ZONE_FS --format=json | jq -r .networks[0].ipAddresses[0])

    echo $NFS_IP
    ```

5. Login your OSD in GCP cluster

6. Create a Persistent Volume using the NFS_IP of the Filestore as the nfs server into the PV definition, specifying the path of the shared Filestore:


    ```sh
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: nfs
    spec:
      capacity:
        storage: 500Gi
      accessModes:
        - ReadWriteMany
      nfs:
        server: $NFS_IP
        path: "/$VOL_NAME_FS"
    EOF
    ```

> As you can check the PV is generated with the accessMode of ReadWriteMany (RWX)

7. Check that the PV is generated properly:

    ```sh
    $ oc get pv nfs
    NAME     CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   REASON   AGE
    nfs   500Gi      RWX            Retain           Available                                   12s
    ```

8. Create a PersistentVolumeClaim for this PersistentVolume:

    ```sh
    cat <<EOF | oc apply -f -
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: nfs
    spec:
      accessModes:
        - ReadWriteMany
      storageClassName: ""
      resources:
        requests:
          storage: 500Gi
    EOF
    ```

> As we can check the storageClassName is empty because we're using the Static Provisioning in this case.

9. Check that the PVC is generated properly and with the Bound status:

    ```sh
    oc get pvc nfs
    NAME      STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
    nfs  Bound    nfs   500Gi      RWX                           7s
    ```

10. Generate an example app with more than replicas sharing the same Filestore NFS volume share:

    ```sh
    cat <<EOF | oc apply -f -
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      creationTimestamp: null
      labels:
        app: nfs-web2
      name: nfs-web
    spec:
      replicas: 2
      selector:
        matchLabels:
          app: nfs-web
      strategy: {}
      template:
        metadata:
          creationTimestamp: null
          labels:
            app: nfs-web
        spec:
          containers:
          - image: nginxinc/nginx-unprivileged
            name: nginx-unprivileged
            ports:
              - name: web
                containerPort: 8080
            volumeMounts:
              - name: nfs
                mountPath: "/usr/share/nginx/html"
          volumes:
          - name: nfs
            persistentVolumeClaim:
              claimName: nfs
    EOF
    ```

12. Check that the pods are up && running:

    ```sh
    oc get pod
    NAME                        READY   STATUS    RESTARTS   AGE
    nfs-web2-54f9fb5cd8-8dcgh   1/1     Running   0          118s
    nfs-web2-54f9fb5cd8-bhmkw   1/1     Running   0          118s
    ```

13. Check that the pods mount the same volume provided by the Filestore NFS share:

    ```sh
    for i in $(oc get pod --no-headers | awk '{ print $1 }'); do echo "POD -> $i"; oc exec -ti $i -- df -h | grep nginx; echo ""; done

    POD -> nfs-web2-54f9fb5cd8-8dcgh
    10.124.186.98:/osd4 1007G     0  956G   0% /usr/share/nginx/html

    POD -> nfs-web2-54f9fb5cd8-bhmkw
    10.124.186.98:/osd4 1007G     0  956G   0% /usr/share/nginx/html
    ```

