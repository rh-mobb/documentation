---
date: '2025-04-09'
title: Add a Private Ingress Controller to a ROSA Cluster and add a Public ALB
tags: ["AWS", "ROSA"]
authors:
  - Kevin Collins
  - Paul Czarkowski
---

Starting with OpenShift 4.14, ROSA supports adding additional Ingress Controllers which can use used to configure a custom domain on a ROSA cluster without having to use the now deprecated Custom Domain Operator.  This guide shows how to add an additional Ingress Controller ( public or private ) to a ROSA cluster and optionally also configuring a custom domain.

## Prerequisites

* A Red Hat OpenShift on AWS (ROSA) cluster
* The oc CLI      #logged in.
* The aws CLI     #logged in.
* The rosa CLI    #logged in.
* (optional) A Public Route53 Hosted Zone, and the related Domain to use.


## Set up environment


1. Export few environment variables
> **Important**: The variables below can be customized to fit your needs for your ingress controller.

  ```bash
  export CLUSTER_NAME=<my cluster>
  export CLUSTER_REGION=$(rosa describe cluster -c $CLUSTER_NAME -o json | jq -r .region.id)
  # vpc id of rosa cluster

   #Custom Hosted Zone Domain for apps
  export DOMAIN=lab.domain.com
   #name of the new ingress controller
   export INGRESS_NAME=private-ingress #name of the new ingress controller
   export SCOPE="Internal"
   export AWS_PAGER=""
   export HOSTED_ZONE_ID=<FETCH FROM AWS CONSOLE>
   export HOSTED_ZONE_REGION=<FETCH FROM AWS CONSOLE>
   export SCRATCH_DIR=/tmp/scratch
   mkdir -p $SCRATCH_DIR
   ```

## Create the Ingress Controller.

   ```yaml
   envsubst  <<EOF | oc apply -f -
   apiVersion: operator.openshift.io/v1
   kind: IngressController
   metadata:
     annotations:
       ingress.operator.openshift.io/auto-delete-load-balancer: "true"
     finalizers:
     - ingresscontroller.operator.openshift.io/finalizer-ingresscontroller
     generation: 2
     name: $INGRESS_NAME
     namespace: openshift-ingress-operator
   spec:
     clientTLS:
       clientCA:
         name: ""
       clientCertificatePolicy: ""
     domain: $DOMAIN
     endpointPublishingStrategy:
       loadBalancer:
         dnsManagementPolicy: Unmanaged
         providerParameters:
           aws:
             networkLoadBalancer: {}
             type: NLB
           type: AWS
         scope: $SCOPE
       type: LoadBalancerService
     httpCompression: {}
     httpEmptyRequestsPolicy: Respond
     httpErrorCodePages:
       name: ""
     replicas: 2
     tuningOptions:
       reloadInterval: 0s
     unsupportedConfigOverrides: null
   EOF
   ```

  Describe the Ingress Controller to confirm it's ready.

   ```bash
   oc describe IngressController $INGRESS_NAME -n openshift-ingress-operator
   ```

   You should see an output that mentions that the ingress controller is Admitted.

   ```
   Normal   Admitted           2m16s  ingress_controller  ingresscontroller passed validation
   ```

   Also verify the router pods of the new ingress controller are running

   ```bash
   oc get pods -n openshift-ingress | grep $INGRESS_NAME
   ```

  Expected output is two pods in a Running state.
  ```bash
  router-public-7dd48fdcbb-bpdzc    1/1     Running   0          4m20s
router-public-7dd48fdcbb-cn7hb    1/1     Running   0          4m20s
  ```

  Verify the service of the new ingress controller is running.

  ```bash
  oc get svc -n openshift-ingress router-${INGRESS_NAME}
  ```

  Patch the service to add a healthcheck port:

  ```bash
  oc -n openshift-ingress patch svc router-${INGRESS_NAME} -p '{"spec":{"ports":[{"port":1936,"targetPort":1936,"protocol":"TCP","name":"httphealth"}]}}'
  ```

## Create an ALB

via aws console

## Test an application.

### Deploy a public application

1. Create a new project

   ```bash
   oc new-project my-public-app
   ```

1. Create a new application

   ```bash
   oc new-app --docker-image=docker.io/openshift/hello-openshift
   ```

1. Create a route for the application

   ```bash
   oc create route edge --service=hello-openshift hello-openshift-tls \
     --hostname hello.$DOMAIN
   ```

1. Check that you can access the application:

   ```bash
   curl https://hello.$DOMAIN
   ```

1. You should see the output

   ```
   Hello OpenShift!
   ```


