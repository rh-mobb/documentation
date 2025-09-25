---
date: '2025-05-16'
title: Integrating Service Mesh into a ROSA Cluster 
tags: ["AWS", "ROSA"]
authors:
  - Diana Sari
  - Daniel Axelrod
  - Kumudu Herath
---

This is a simple guide to integrate [Red Hat OpenShift Service Mesh](https://www.redhat.com/en/technologies/cloud-computing/openshift/what-is-openshift-service-mesh) into your ROSA cluster. In this scenario, we will install Service Mesh using a custom domain (optional) and expose an app to test it. The first half of the guide will be integrating [Service Mesh 2.x](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/service_mesh/service-mesh-2-x) and second half will be integrating [Service Mesh 3.x](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/service_mesh/service-mesh-3-x). 


### Prerequisites

* A [classic](https://cloud.redhat.com/experts/rosa/terraform/classic/) or [HCP](https://cloud.redhat.com/experts/rosa/terraform/hcp/) ROSA cluster v4.14 and above.
* The oc CLI      # logged in.
* A Domain Name in a public zone. These instructions assume Route 53, but can be adapted for any other DNS.
* An app to expose (alternatively, we will be creating a simple **Hello OpenShift** app in this guide)


### Set up environment

Install the necessary operators, i.e. Elasticsearch (optional), Jaeger (distributed tracing platform), Kiali, and Service Mesh (2 or 3 depends on your use case) from OpenShift console.  

Then log into your cluster via CLI and set up the following environment variables.

```bash
APP_NAMESPACE=my-public-app # change this to your app namespace if you have one already
DOMAIN=test.mobb.cloud  # change this to your custom domain
```

## Service Mesh 2.x

### Step 1 - Create the Service Mesh Control Plane

Let's first create a new project where the control plane resides.

```bash
oc new-project istio-system
```

And then the control plane. Note that here we are using Service Mesh 2.6.

```bash
cat << EOF | oc apply -f -
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
  namespace: istio-system
spec:
  version: v2.6
  security:
    identity:
      type: ThirdParty
  tracing:
    type: Jaeger
    sampling: 10000
  addons:
    jaeger:
      name: jaeger
      install:
        storage:
          type: Memory
    kiali:
      enabled: true
      name: kiali
    grafana:
      enabled: true
EOF
```


### Step 2 - Create the Service Mesh Member Roll

Here we will create [Service Mesh Member Roll](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/service_mesh/service-mesh-2-x#ossm-member-roll-create_ossm-create-mesh) to define which namespaces are part of the mesh and will have Istio functionality applied to them.

```bash
cat << EOF | oc apply -f -
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
  - $APP_NAMESPACE
EOF
```

### Step 3 - Configure namespace for mesh injection

Next, we will inject mesh which is essentially a process of annotating a namespace to automatically inject the Istio sidecar proxy into all pods created in that namespace.

```bash
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $APP_NAMESPACE
  annotations:
    maistra.io/inject: "true"
EOF
```

### Step 4 - Deploy Hello OpenShift app (optional)

Skip this step if you have already created an app.

```bash
oc new-project $APP_NAMESPACE
oc new-app --docker-image=docker.io/openshift/hello-openshift -n $APP_NAMESPACE
```

### Step 5 - Add sidecar injection to deployment

Sidecar injection is in essence the deployment of an Envoy proxy container alongside your application container to intercept and manage all network traffic.

```bash
cat << EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-openshift
  namespace: $APP_NAMESPACE
spec:
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "true"
EOF
```

Then restart deployment to trigger sidecar injection:

```bash
oc rollout restart deployment/hello-openshift -n $APP_NAMESPACE
```

And verify pods have sidecars (should show 2/2 ready):

```bash 
oc get pods -n $APP_NAMESPACE
```

### Step 6 - Create Istio Gateway

Istio Gateway is a load balancer operating at the edge of the mesh that manages inbound and outbound HTTP/TCP connections.

```bash
cat << EOF | oc apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: hello-gateway
  namespace: $APP_NAMESPACE
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "hello.$DOMAIN"
EOF
```

### Step 7 - Create Virtual Service

Virtual Service is a traffic routing rule that defines how requests sent to a service are routed within the mesh, enabling fine-grained traffic control.

```bash
cat << EOF | oc apply -f -
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: hello-vs
  namespace: $APP_NAMESPACE
spec:
  hosts:
  - "hello.$DOMAIN"
  gateways:
  - hello-gateway
  http:
  - route:
    - destination:
        host: hello-openshift
        port:
          number: 8080
EOF
```

Note that if you are using multiple domains, then you might want to wildcard the hosts, i.e. `*.com`, to preserve the domain all the way to the application. 

### Step 8 - Create OpenShift Route to Istio Ingress Gateway

In the context of Service Mesh, OpenShift Route is a way to expose the Istio Ingress Gateway to external traffic using OpenShift's built-in routing layer.

```bash
cat << EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: hello-mesh
  namespace: istio-system
spec:
  host: hello.$DOMAIN
  to:
    kind: Service
    name: istio-ingressgateway
  port:
    targetPort: http2
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
```

### Step 9 - Configure custom domain (optional)

If you're using custom domain, then go to AWS Console and change the record to point to the route hostname.

Get your canonical route hostname:

```bash
oc get route hello-mesh -n istio-system -o jsonpath='{.status.ingress[0].routerCanonicalHostname}'
```

This should give you an output like `router-default.apps.rosa.your-cluster-name.xxxx.px.openshiftapps.com`. Use this as the value of your domain.

![cname](images/cname.png)
<br />


### Step 10 - Verify the setup and access the application

Check if ingress gateway is running:

```bash
oc get pods -n istio-system | grep ingressgateway
```

Access your application by testing the route:

```bash
curl -k https://hello.$DOMAIN
```

You should see the output `Hello OpenShift!`. 

> **Note**: If you are accessing your browser, you might get **Not Secure** warning due to certificate mismatch. Since this is a testing environment, you can safely ignore this. However, for production environment, you might want to use a custom certificate for your route, or use Let's Encrypt with OpenShift's cert-manager, for example. 


## Service Mesh 3.x

### Step 1 - Create the Service Mesh Control Plane

Let's first create a new project where the control plane resides.

```bash
oc new-project istio-system
```

Unlike Service Mesh 2, Service Mesh 3 uses the `sailoperator.io/v1` API and is built on Istio's Helm chart APIs. 

```bash
cat << EOF | oc apply -f -
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: basic
  namespace: istio-system
spec:
  profiles:
  - default
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
  values:
    global:
      jwtPolicy: third-party-jwt
    cni:
      enabled: false
    pilot:
      traceSampling: 100.0
EOF
```

Next, verify that the control plane (istiod) is running correctly. First, wait for the control plane to be ready:

```bash
oc get istio basic -n istio-system
```

Next. check that all pods are running:

```bash
oc get pods -n istio-system
```

### Step 2 - Deploy Hello OpenShift app (optional)

Skip this step if you have already created an app.

```bash
oc new-project $APP_NAMESPACE
oc new-app --docker-image=docker.io/openshift/hello-openshift -n $APP_NAMESPACE
```

Note that unlike Service Mesh 2, we don't need to add this namespace to a `ServiceMeshMemberRoll` since Service Mesh 3 uses a different approach for namespace membership.

### Step 3 - Create Istio Gateway

Here we will be creating an Istio Gateway resource to define how traffic enters our mesh. This is conceptually similar to Service Mesh 2, but the implementation aligns more closely with upstream Istio.

```bash
cat << EOF | oc apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: hello-gateway
  namespace: $APP_NAMESPACE
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "hello.$DOMAIN"
EOF
```

### Step 4 - Create Virtual Service

Next, we will be creating a VirtualService to route traffic from the Gateway to our application. This defines the routing rules within the service mesh.

```bash
cat << EOF | oc apply -f -
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: hello-vs
  namespace: $APP_NAMESPACE
spec:
  hosts:
  - "hello.$DOMAIN"
  gateways:
  - hello-gateway
  http:
  - route:
    - destination:
        host: hello-openshift
        port:
          number: 8080
EOF
```

### Step 5 - Create OpenShift Route

```bash
oc create route edge hello-custom --service=hello-openshift --hostname=hello.$DOMAIN -n $APP_NAMESPACE
```

Note that unlike Service Mesh 2 where we created a route to the Istio ingressgateway, here we're creating a direct route to our application. In other word, we're skipping sidecar injection and using "external proxies" for service mesh functionality. 


### Step 6 - Configure custom domain (optional)

If you're using custom domain, then go to AWS Console and change the record to point to the route hostname.

Get your canonical route hostname:

```bash
oc get route hello-custom -n $APP_NAMESPACE -o jsonpath='{.status.ingress[0].routerCanonicalHostname}'
```

This should give you an output like `router-default.apps.rosa.your-cluster-name.xxxx.px.openshiftapps.com`. Use this as the value of your domain.

![cname](images/cname.png)
<br />

### Step 7 - Access the application

Access your application by testing the route:

```bash
curl -k https://hello.$DOMAIN
```

You should see the output `Hello OpenShift!`. 

> **Note**: If you are accessing your browser, you might get **Not Secure** warning due to certificate mismatch. Since this is a testing environment, you can safely ignore this. However, for production environment, you might want to use a custom certificate for your route, or use Let's Encrypt with OpenShift's cert-manager, for example. 
