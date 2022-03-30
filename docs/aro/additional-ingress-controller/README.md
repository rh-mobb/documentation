# Adding an additional ingress controller to an ARO cluster

**Paul Czarkowski, Stuart Kirk**

*03/30/2022*

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
    ````

1. Create a secret for the certificate

    ```bash
oc create secret tls custom-tls \
  --cert=$SCRATCH_DIR/config/live/$DOMAIN/fullchain.pem \
  --key=$SCRATCH_DIR/config/live/$DOMAIN/privkey.pem
    ```

1. Create an ingress controller

    ```bash
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

1. Wait a few moments then get the `EXTERNAL-IP` of the new ingress controller

    ```bash
oc get -n openshift-ingress svc router-custom
    ```

    The output should look like:

    ```
    NAME            TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)                      AGE
    router-custom   LoadBalancer   172.30.90.84   20.120.48.78   80:32160/TCP,443:32511/TCP   49s
    ```

1. Create a wildcard DNS record pointing at the `EXTERNAL-IP`

1. Test that the Ingress is working

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

    ```bash
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
