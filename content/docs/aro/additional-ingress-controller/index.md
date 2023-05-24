---
date: '2022-09-14T22:07:08.574151'
title: Adding an additional ingress controller to an ARO cluster
tags: ["ARO", "Azure"]
authors:
  - Paul Czarkowski
  - Stuart Kirk
  - Anton Nesterov
  - Connor Wooley
---

## Prerequisites

* an Azure Red Hat OpenShift cluster
* a DNS zone that you can easily modify

## Get Started

1. Create some environment variables

   ```bash
   DOMAIN=custom.azure.mobb.ninja
   EMAIL=example@email.com
   SCRATCH_DIR=/tmp/aro
   ```

1. Create a certificate for the ingress controller

   ```bash
   certbot certonly --manual \
     --preferred-challenges=dns \
     --email $EMAIL \
     --server https://acme-v02.api.letsencrypt.org/directory \
     --agree-tos \
     --manual-public-ip-logging-ok \
     -d "*.$DOMAIN" \
     --config-dir "$SCRATCH_DIR/config" \
     --work-dir "$SCRATCH_DIR/work" \
     --logs-dir "$SCRATCH_DIR/logs"
   ```

1. Create a secret for the certificate

   ```bash
   oc create secret tls custom-tls \
     -n openshift-ingress \
     --cert=$SCRATCH_DIR/config/live/$DOMAIN/fullchain.pem \
     --key=$SCRATCH_DIR/config/live/$DOMAIN/privkey.pem
   ```

1. Create an ingress controller

   ```yaml
   cat <<EOF | oc apply -f -
   apiVersion: operator.openshift.io/v1
   kind: IngressController
   metadata:
     name: custom
     namespace: openshift-ingress-operator
   spec:
     domain: $DOMAIN
     nodePlacement:
       nodeSelector:
         matchLabels:
           node-role.kubernetes.io/worker: ""
     routeSelector:
       matchLabels:
         type: custom
     defaultCertificate:
       name: custom-tls
     httpEmptyRequestsPolicy: Respond
     httpErrorCodePages:
       name: ""
     replicas: 3
   EOF
   ```

    > NOTE: By default the ingress controller is created with `external` scope. This means that the corresponding Azure Load Balancer will have a public frontend IP. If you wish to deploy a privately visible ingress controller add the following lines to the `spec`:

    ```yaml
    spec:
      ...
      endpointPublishingStrategy:
        loadBalancer:
          scope: Internal
        type: LoadBalancerService
      ...
    ```


1. Wait a few moments then get the `EXTERNAL-IP` of the new ingress controller

   ```bash
   oc get -n openshift-ingress svc router-custom
   ```

    In case of an Externally (publicly) scoped ingress controller the output should look like:

   ```
    NAME            TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)                      AGE
    router-custom   LoadBalancer   172.30.90.84   20.120.48.78   80:32160/TCP,443:32511/TCP   49s
   ```

    In case of an Internal (private) one:

    ```
    NAME            TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)                      AGE
    router-custom   LoadBalancer   172.30.55.36     10.0.2.4     80:30475/TCP,443:30249/TCP   10s

    ```

1. Optionally verify in the Azure portal or using CLI that the Load Balancer Service has gotten the new Frontend IP and two Load Balancing Rules - one for port 80 and another one for port 443. In case of an Internally scoped Ingress Controller the changes are to be observed within the Load Balancer that has the `-internal` suffix.

1. Create a wildcard DNS record pointing at the `EXTERNAL-IP`

1. Test that the Ingress is working

    > NOTE: For the Internal ingress controller, make sure that the test host has the necessary reachability to the VPC/subnet as well as the DNS resolver.

   ```bash
   curl -s https://test.$DOMAIN | head
   ```

   ```
    <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
   ```

1. Create a new project to deploy an application to

   ```bash
   oc new-project demo
   ```

1. Create a new application

   ```bash
   oc new-app --docker-image=docker.io/openshift/hello-openshift
   ```

1. Expose

   ```yaml
   cat << EOF | oc apply -f -
   apiVersion: route.openshift.io/v1
   kind: Route
   metadata:
     labels:
       app: hello-openshift
       app.kubernetes.io/component: hello-openshift
       app.kubernetes.io/instance: hello-openshift
       type: custom
     name: hello-openshift-tls
   spec:
     host: hello.$DOMAIN
     port:
       targetPort: 8080-tcp
     tls:
       termination: edge
       insecureEdgeTerminationPolicy: Redirect
     to:
       kind: Service
       name: hello-openshift
   EOF
   ```

1. Verify it works

   ```bash
   curl https://hello.custom.azure.mobb.ninja
   ```

   ```bash
    Hello OpenShift!
   ```
