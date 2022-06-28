# Accessing the Internal Registry from ARO

**Kevin Collins**

*06/28/2022*

One of the advantages of using OpenShift is the internal registry that comes with OpenShfit to build, deploy and manage container images locally.  By default, access to the registry is limited to the cluster ( by design ) but can be extended to usage outside of the cluster.  This guide will go through the steps required to access the OpenShift Registry on an ARO cluster outside of the cluster.

## Prerequisites

* an ARO Cluster
* oc cli 
* podman or docker cli

## Expose the Registry
1. Expose the registry service
   ```bash
   oc create route reencrypt --service=image-registry -n openshift-image-registry 
   ```

1. Annotate the route
   ```bash
   oc annotate route image-registry haproxy.router.openshift.io/balance=source -n openshift-image-registry
   ```

1.  Get the route host name
    ```bash
    HOST=$(oc get route image-registry -n openshift-image-registry --template='{{ .spec.host }}')
    ```
1. Log into the image registry
   ```bash
   podman docker login -u $(oc whoami) -p $(oc whoami -t) $HOST
   ```
## Test it out
   ```bash
   podman pull openshift/hello-openshift
   
   podman images 
   ``` 

   expected output
   ```bash
    openshift/hello-openshift                                   latest    7af3297a3fb4   4 years ago    6.09MB
   ```