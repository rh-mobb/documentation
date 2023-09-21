---
date: '2022-06-22'
title: Stop default router from serving custom domain routes
aliases: [/experts/ingress/default-router-custom-domain/README.md]
tags: ["OSD", "ROSA"]
authors:
  - Connor Wooley
---

OSD and ROSA supports [custom domain operator](https://docs.openshift.com/rosa/applications/deployments/osd-config-custom-domains-applications.html) to serve application custom domain, which provisions openshift ingress controller and cloud load balancers. However, when a route with custom domain is created, both default router and custom domain router serve routes. This article describes how to use route labels to stop default router from serving custom domain routes.

## Prerequisites

* Rosa or OSD Cluster
* [Custom Domain](https://docs.openshift.com/rosa/applications/deployments/osd-config-custom-domains-applications.html) Deployed

## Problem Demo

### Deploy A Custom Domain

```bash
oc create secret tls example-tls --cert=[cert_file] --key=[key_file]

cat << EOF | oc apply -f -
apiVersion: managed.openshift.io/v1alpha1
kind: CustomDomain
metadata:
  name: example
spec:
  domain: example.com
  scope: External
  certificate:
    name: example-tls
    namespace: default
EOF
```

### Create a sample application and Route

```bash
oc new-app --image=openshift/hello-openshift
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  labels:
    app: hello-openshift
    app.kubernetes.io/component: hello-openshift
    app.kubernetes.io/instance: hello-openshift
  name: helloworld
spec:
  host: helloworld-openshift.example.com
  port:
    targetPort: 8080-tcp
  tls:
    termination: edge
  to:
    kind: ""
    name: hello-openshift
EOF
```

### Both default router and custom router serve the routes

```
oc get route -o yaml
....
  status:
    ingress:
    - conditions:
      - lastTransitionTime: "2022-06-02T20:30:39Z"
        status: "True"
        type: Admitted
      host: helloworld-openshift.example.com
      routerCanonicalHostname: router-default.apps.mobb-infra-gcp.e8e4.p2.openshiftapps.com
      routerName: default
      wildcardPolicy: None
    - conditions:
      - lastTransitionTime: "2022-06-02T20:30:39Z"
        status: "True"
        type: Admitted
      host: helloworld-openshift.example.com
      routerCanonicalHostname: router-example.example.mobb-infra-gcp.e8e4.p2.openshiftapps.com
      routerName: example
      wildcardPolicy: None
```

### End user can access the app from both ingress controllers' cloud load balancer

```
oc get svc -n openshift-ingress
NAME                      TYPE           CLUSTER-IP       EXTERNAL-IP    PORT(S)                      AGE
router-default            LoadBalancer   172.30.39.254    34.73.154.84   80:32108/TCP,443:30332/TCP   39d
router-example            LoadBalancer   172.30.209.51    34.138.159.7   80:32477/TCP,443:31383/TCP   9m51s

curl -k -H "Host: helloworld-openshift.example.com" https://34.73.154.84
Hello OpenShift!
shading@shading-mac gcp_domain % curl -k -H "Host: helloworld-openshift.example.com" https://34.138.159.7
Hello OpenShift!
```

## Stop the default router from serving custom domain routes

### Delete the route

```bash
oc delete route helloworld
```

### Custom Domain only serve routes with corresponding custom domain label

```bash
oc patch \
  -n openshift-ingress-operator \
  IngressController/example \
  --type='merge' \
  -p '{"spec":{"routeSelector":{"matchLabels": {"domain": "example.com"}}}}'
```

### Exclude default router with corresponding custom domain label

```bash
oc patch \
  -n openshift-ingress-operator \
  IngressController/default \
  --type='merge' \
  -p '{"spec":{"routeSelector":{"matchExpressions":[{"key":"domain","operator":"NotIn","values":["example.com"]}]}}}'
```

### Create route with custom domain label

```bash
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  labels:
    app: hello-openshift
    domain: example.com
    app.kubernetes.io/component: hello-openshift
    app.kubernetes.io/instance: hello-openshift
  name: helloworld
spec:
  host: helloworld-openshift.example.com
  port:
    targetPort: 8080-tcp
  tls:
    termination: edge
  to:
    kind: ""
    name: hello-openshift
EOF
```

### Only Custom Domain router route the traffic

```bash
oc get route -o yaml
....
  status:
    ingress:
    - conditions:
      - lastTransitionTime: "2022-06-02T20:30:39Z"
        status: "True"
        type: Admitted
      host: helloworld-openshift.example.com
      routerCanonicalHostname: router-example.example.mobb-infra-gcp.e8e4.p2.openshiftapps.com
      routerName: example
      wildcardPolicy: None

oc get svc -n openshift-ingress
NAME                      TYPE           CLUSTER-IP       EXTERNAL-IP    PORT(S)                      AGE
router-default            LoadBalancer   172.30.39.254    34.73.154.84   80:32108/TCP,443:30332/TCP   39d
router-example            LoadBalancer   172.30.209.51    34.138.159.7   80:32477/TCP,443:31383/TCP   9m51s

curl -k -H "Host: helloworld-openshift.example.com" https://34.73.154.84
....
The application is currently not serving requests at this endpoint. It may not have been started or is still starting.
...

curl -k -H "Host: helloworld-openshift.example.com" https://34.138.159.7
Hello OpenShift!
```
