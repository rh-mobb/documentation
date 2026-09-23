---
date: '2026-09-23'
title: Fixing Uneven Load Distribution with Passthrough Routes and Persistent Connections
tags: ["ARO", "OSD", "ROSA"]
authors:
  - Kevin Collins
  - Kumudu Herath
validated_version: "4.22"
---

Applications that use SSL passthrough routes or ClusterIP Services with persistent HTTP connections often experience uneven request distribution across pods. This applies to all Red Hat managed OpenShift services, including ARO, ROSA, and OSD on GCP. This guide explains why that happens, reproduces the problem in two common scenarios, and demonstrates a fix for each.

## The Problem

OpenShift handles passthrough routes at Layer 4 (TCP). HAProxy balances **TCP connections**, not individual HTTP requests. When a client opens a persistent (keep-alive) connection through a passthrough route, all requests on that connection go to the same backend pod.

The same behavior applies to internal traffic through a ClusterIP Service. OVN-Kubernetes uses a 5-tuple hash (source IP, source port, destination IP, destination port, protocol) to select a backend. A single persistent connection always produces the same hash, so every request on that connection reaches the same pod.

With a small number of long-lived clients (connection pools, sidecar proxies, or batch jobs), only a few pods handle the bulk of traffic while others sit idle.

## Why This Matters

Setting `haproxy.router.openshift.io/balance: roundrobin` and `haproxy.router.openshift.io/disable_cookies: "true"` on a passthrough route does not help. These annotations control how new TCP connections are assigned, not how requests within a connection are routed. Under sustained load with connection pooling, the imbalance grows: some pods can receive 50% more requests than others.

## Prerequisites

* An ARO, ROSA, or OSD on GCP cluster (or any OpenShift cluster)
* `oc` CLI logged in with permissions to create namespaces, deployments, services, and routes

## Setup

Create a namespace and deploy two versions of an echo server: a plain HTTP server for the ClusterIP scenario and a TLS-enabled server for the passthrough route scenario. Both return the pod hostname in the response so you can see which pod handled each request.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: lb-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-server
  namespace: lb-test
spec:
  replicas: 10
  selector:
    matchLabels:
      app: echo-server
  template:
    metadata:
      labels:
        app: echo-server
    spec:
      containers:
        - name: echo
          image: registry.access.redhat.com/ubi9/python-311:latest
          command:
            - python3
            - -c
            - |
              import http.server, ssl, os, threading, tempfile
              counter = 0
              lock = threading.Lock()
              pod = os.environ.get("HOSTNAME", "unknown")
              class Handler(http.server.BaseHTTPRequestHandler):
                  protocol_version = "HTTP/1.1"
                  def do_GET(self):
                      global counter
                      with lock:
                          counter += 1
                          c = counter
                      body = f'{{"pod":"{pod}","count":{c}}}\n'
                      self.send_response(200)
                      self.send_header("Content-Type", "application/json")
                      self.send_header("Content-Length", str(len(body)))
                      self.end_headers()
                      self.wfile.write(body.encode())
                  def log_message(self, *args):
                      pass
              # Generate a self-signed certificate for TLS
              import subprocess
              cert = tempfile.NamedTemporaryFile(suffix=".pem", delete=False)
              key = tempfile.NamedTemporaryFile(suffix=".pem", delete=False)
              cert.close(); key.close()
              subprocess.run([
                  "openssl", "req", "-x509", "-newkey", "rsa:2048",
                  "-keyout", key.name, "-out", cert.name,
                  "-days", "1", "-nodes",
                  "-subj", "/CN=echo-server"
              ], capture_output=True)
              # Start TLS server on 8443
              tls_server = http.server.HTTPServer(("0.0.0.0", 8443), Handler)
              ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
              ctx.load_cert_chain(cert.name, key.name)
              tls_server.socket = ctx.wrap_socket(tls_server.socket, server_side=True)
              t = threading.Thread(target=tls_server.serve_forever, daemon=True)
              t.start()
              # Start plain HTTP server on 8080
              http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
          ports:
            - containerPort: 8443
              name: https
            - containerPort: 8080
              name: http
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
EOF
```

Wait for the rollout to complete:

```bash
oc rollout status deployment/echo-server -n lb-test --timeout=120s
```

## Scenario 1: External Traffic via Passthrough Route

### Create the Service and Passthrough Route

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: echo-server-tls
  namespace: lb-test
spec:
  selector:
    app: echo-server
  ports:
    - port: 8443
      targetPort: 8443
      name: https
  type: ClusterIP
  sessionAffinity: None
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: echo-server-passthrough
  namespace: lb-test
  annotations:
    haproxy.router.openshift.io/balance: roundrobin
    haproxy.router.openshift.io/disable_cookies: "true"
spec:
  to:
    kind: Service
    name: echo-server-tls
    weight: 100
  port:
    targetPort: https
  tls:
    termination: passthrough
  wildcardPolicy: None
EOF
```

### Reproduce the Problem

Get the route hostname and run 5 parallel clients, each sending 200 requests over a single persistent TLS connection:

```bash
ROUTE_HOST=$(oc get route echo-server-passthrough -n lb-test \
  -o jsonpath='{.spec.host}')

cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: loadtest-passthrough
  namespace: lb-test
spec:
  parallelism: 5
  completions: 5
  template:
    metadata:
      labels:
        app: loadtest-passthrough
    spec:
      restartPolicy: Never
      containers:
        - name: loadgen
          image: registry.access.redhat.com/ubi9/python-311:latest
          command:
            - python3
            - -c
            - |
              import http.client, ssl, json, os
              host = "${ROUTE_HOST}"
              total = 200
              client_id = os.environ.get("HOSTNAME", "unknown")
              ctx = ssl.create_default_context()
              ctx.check_hostname = False
              ctx.verify_mode = ssl.CERT_NONE
              counts = {}
              conn = http.client.HTTPSConnection(host, 443, context=ctx, timeout=10)
              for i in range(total):
                  try:
                      conn.request("GET", "/")
                      resp = conn.getresponse()
                      data = json.loads(resp.read())
                      p = data["pod"]
                      counts[p] = counts.get(p, 0) + 1
                  except Exception:
                      conn = http.client.HTTPSConnection(host, 443, context=ctx, timeout=10)
              print(f"=== Client {client_id}: {total} requests over PERSISTENT TLS connection (passthrough route) ===")
              for p in sorted(counts, key=counts.get, reverse=True):
                  pct = counts[p] / total * 100
                  bar = "#" * int(pct / 2)
                  print(f"  {p:50s} {counts[p]:6d} ({pct:5.1f}%) {bar}")
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
  backoffLimit: 0
EOF
```

Check the results:

```bash
oc wait --for=condition=complete job/loadtest-passthrough -n lb-test --timeout=300s

for pod in $(oc get pods -n lb-test -l app=loadtest-passthrough \
  --no-headers -o name); do
  oc logs "$pod" -n lb-test
done
```

Expected output: each client pins all requests to a single pod. With 5 clients, only 5 of 10 pods receive traffic.

```
=== Client loadtest-persistent-67p9v: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-wk5hf                         2000 (100.0%) ##################################################
=== Client loadtest-persistent-hcz82: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-wndrl                         2000 (100.0%) ##################################################
=== Client loadtest-persistent-jckp9: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-4p6rg                         2000 (100.0%) ##################################################
=== Client loadtest-persistent-nlgjs: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-5k44p                         2000 (100.0%) ##################################################
=== Client loadtest-persistent-s6jd5: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-kt9vv                         2000 (100.0%) ##################################################
```

### Fix: Switch to an Edge Route

An edge route terminates TLS at HAProxy and forwards plain HTTP to the backend. This lets HAProxy inspect HTTP traffic and balance at Layer 7, distributing individual requests across pods rather than pinning entire connections.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: echo-server-http
  namespace: lb-test
spec:
  selector:
    app: echo-server
  ports:
    - port: 8080
      targetPort: 8080
      name: http
  type: ClusterIP
  sessionAffinity: None
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: echo-server-edge
  namespace: lb-test
  annotations:
    haproxy.router.openshift.io/balance: roundrobin
    haproxy.router.openshift.io/disable_cookies: "true"
spec:
  to:
    kind: Service
    name: echo-server-http
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
```

Run the same load test against the edge route:

```bash
EDGE_HOST=$(oc get route echo-server-edge -n lb-test \
  -o jsonpath='{.spec.host}')

oc delete job loadtest-passthrough -n lb-test 2>/dev/null; true
oc rollout restart deployment/echo-server -n lb-test
oc rollout status deployment/echo-server -n lb-test --timeout=120s

cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: loadtest-edge
  namespace: lb-test
spec:
  parallelism: 5
  completions: 5
  template:
    metadata:
      labels:
        app: loadtest-edge
    spec:
      restartPolicy: Never
      containers:
        - name: loadgen
          image: registry.access.redhat.com/ubi9/python-311:latest
          command:
            - python3
            - -c
            - |
              import http.client, ssl, json, os
              host = "${EDGE_HOST}"
              total = 200
              client_id = os.environ.get("HOSTNAME", "unknown")
              ctx = ssl.create_default_context()
              ctx.check_hostname = False
              ctx.verify_mode = ssl.CERT_NONE
              counts = {}
              conn = http.client.HTTPSConnection(host, 443, context=ctx, timeout=10)
              for i in range(total):
                  try:
                      conn.request("GET", "/")
                      resp = conn.getresponse()
                      data = json.loads(resp.read())
                      p = data["pod"]
                      counts[p] = counts.get(p, 0) + 1
                  except Exception:
                      conn = http.client.HTTPSConnection(host, 443, context=ctx, timeout=10)
              print(f"=== Client {client_id}: {total} requests over PERSISTENT TLS connection (edge route) ===")
              for p in sorted(counts, key=counts.get, reverse=True):
                  pct = counts[p] / total * 100
                  bar = "#" * int(pct / 2)
                  print(f"  {p:50s} {counts[p]:6d} ({pct:5.1f}%) {bar}")
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
  backoffLimit: 0
EOF
```

```bash
oc wait --for=condition=complete job/loadtest-edge -n lb-test --timeout=300s

for pod in $(oc get pods -n lb-test -l app=loadtest-edge \
  --no-headers -o name); do
  oc logs "$pod" -n lb-test
done
```

Expected output: with an edge route, HAProxy balances at Layer 7. All 10 pods receive traffic from each client, compared to the passthrough test where each client pinned 100% to a single pod.

```
=== Client loadtest-edge-2grfs: 200 requests over PERSISTENT TLS connection (edge route) ===
  echo-server-9d5ddc49-smhks                             23 ( 11.5%) #####
  echo-server-9d5ddc49-h6ldz                             20 ( 10.0%) #####
  echo-server-9d5ddc49-zgrp5                             20 ( 10.0%) #####
  echo-server-9d5ddc49-wr57s                             20 ( 10.0%) #####
  echo-server-9d5ddc49-56xjw                             20 ( 10.0%) #####
  echo-server-9d5ddc49-tbkw2                             20 ( 10.0%) #####
  echo-server-9d5ddc49-kpcbw                             19 (  9.5%) ####
  echo-server-9d5ddc49-2xtkn                             19 (  9.5%) ####
  echo-server-9d5ddc49-6w6rp                             19 (  9.5%) ####
  echo-server-9d5ddc49-b4sc4                             19 (  9.5%) ####
...
```

The distribution is approximately even (7%-13% per pod) rather than mathematically perfect, because HAProxy's L7 roundrobin accounts for backend response times. The key difference is that all 10 pods are active.

{{% alert state="warning" %}}Switching from passthrough to edge means HAProxy terminates TLS and forwards plain HTTP to the backend pods. If your application requires end-to-end encryption (for example, mutual TLS between client and pod), use a reencrypt route with the backend CA certificate, or consider client-side load balancing or a service mesh.{{% /alert %}}

## Scenario 2: Internal Traffic via ClusterIP Service

### Create a ClusterIP Service

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: echo-server
  namespace: lb-test
spec:
  selector:
    app: echo-server
  ports:
    - port: 8080
      targetPort: 8080
      name: http
  type: ClusterIP
  sessionAffinity: None
EOF
```

### Reproduce the Problem

Reset the echo server and run 5 parallel clients that each send 2,000 requests over a single persistent HTTP/1.1 connection through the ClusterIP Service. The client uses a raw socket to guarantee that the same TCP connection (and therefore the same OVN-K 5-tuple hash) is used for every request:

```bash
oc rollout restart deployment/echo-server -n lb-test
oc rollout status deployment/echo-server -n lb-test --timeout=120s
```

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: loadtest-persistent
  namespace: lb-test
spec:
  parallelism: 5
  completions: 5
  template:
    metadata:
      labels:
        app: loadtest-persistent
    spec:
      restartPolicy: Never
      containers:
        - name: loadgen
          image: registry.access.redhat.com/ubi9/python-311:latest
          command:
            - python3
            - -c
            - |
              import socket, json, os
              host = "echo-server.lb-test.svc.cluster.local"
              port = 8080
              total = 2000
              client = os.environ.get("HOSTNAME", "unknown")
              counts = {}
              sock = socket.create_connection((host, port), timeout=10)
              buf = b""
              for i in range(total):
                  req = (
                      f"GET / HTTP/1.1\r\n"
                      f"Host: {host}\r\n"
                      f"Connection: keep-alive\r\n"
                      f"\r\n"
                  )
                  sock.sendall(req.encode())
                  while b"\r\n\r\n" not in buf:
                      buf += sock.recv(4096)
                  header_end = buf.index(b"\r\n\r\n") + 4
                  headers = buf[:header_end].decode()
                  clen = 0
                  for line in headers.split("\r\n"):
                      if line.lower().startswith("content-length:"):
                          clen = int(line.split(":")[1].strip())
                  body_start = buf[header_end:]
                  while len(body_start) < clen:
                      body_start += sock.recv(4096)
                  body = body_start[:clen]
                  buf = body_start[clen:]
                  data = json.loads(body)
                  p = data["pod"]
                  counts[p] = counts.get(p, 0) + 1
              sock.close()
              print(f"=== Client {client}: {total} requests over PERSISTENT connection ===")
              for p in sorted(counts, key=counts.get, reverse=True):
                  pct = counts[p] / total * 100
                  bar = "#" * int(pct / 2)
                  print(f"  {p:50s} {counts[p]:6d} ({pct:5.1f}%) {bar}")
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
  backoffLimit: 0
EOF
```

```bash
oc wait --for=condition=complete job/loadtest-persistent -n lb-test --timeout=300s

for pod in $(oc get pods -n lb-test -l app=loadtest-persistent \
  --no-headers -o name); do
  oc logs "$pod" -n lb-test
done
```

Expected output: each client sends all 2,000 requests to a **single pod**. With 5 clients and 10 pods, half the pods receive zero traffic.

```
=== Client loadtest-persistent-67p9v: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-wk5hf                         2000 (100.0%) ##################################################
=== Client loadtest-persistent-hcz82: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-wndrl                         2000 (100.0%) ##################################################
=== Client loadtest-persistent-jckp9: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-4p6rg                         2000 (100.0%) ##################################################
=== Client loadtest-persistent-nlgjs: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-5k44p                         2000 (100.0%) ##################################################
=== Client loadtest-persistent-s6jd5: 2000 requests over PERSISTENT connection ===
  echo-server-5b6c5b479d-kt9vv                         2000 (100.0%) ##################################################
```

### Fix: Headless Service with Client-Side Load Balancing

A headless Service (`clusterIP: None`) does not proxy traffic. Instead, DNS returns the IP addresses of all backing pods. The client resolves these IPs and distributes requests across them directly.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: echo-server-headless
  namespace: lb-test
spec:
  clusterIP: None
  selector:
    app: echo-server
  ports:
    - port: 8080
      targetPort: 8080
      name: http
  sessionAffinity: None
EOF
```

Reset the echo server and run the headless load test:

```bash
oc delete job loadtest-persistent -n lb-test 2>/dev/null; true
oc rollout restart deployment/echo-server -n lb-test
oc rollout status deployment/echo-server -n lb-test --timeout=120s
```

The following load test opens a new connection to a different pod IP for each request. This is the simplest way to demonstrate DNS-based distribution. In production, client-side load-balancing libraries (Spring Cloud LoadBalancer, gRPC name resolver, Netflix Ribbon) maintain a pool of persistent connections spread across all pod IPs, which achieves even distribution without the overhead of a new connection per request.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: loadtest-headless
  namespace: lb-test
spec:
  parallelism: 5
  completions: 5
  template:
    metadata:
      labels:
        app: loadtest-headless
    spec:
      restartPolicy: Never
      containers:
        - name: loadgen
          image: registry.access.redhat.com/ubi9/python-311:latest
          command:
            - python3
            - -c
            - |
              import http.client, json, os, socket
              headless = "echo-server-headless.lb-test.svc.cluster.local"
              port = 8080
              total = 2000
              pod = os.environ.get("HOSTNAME", "unknown")
              try:
                  ips = list(set(
                      info[4][0] for info in
                      socket.getaddrinfo(headless, port, socket.AF_INET)
                  ))
              except Exception as e:
                  print(f"DNS resolution failed: {e}")
                  ips = []
              print(f"Resolved {len(ips)} pod IPs from headless DNS: {ips}")
              counts = {}
              for i in range(total):
                  ip = ips[i % len(ips)]
                  try:
                      conn = http.client.HTTPConnection(ip, port, timeout=5)
                      conn.request("GET", "/")
                      resp = conn.getresponse()
                      data = json.loads(resp.read())
                      p = data["pod"]
                      counts[p] = counts.get(p, 0) + 1
                      conn.close()
                  except Exception:
                      pass
              print(f"=== Client {pod}: {total} requests via HEADLESS service ===")
              for p in sorted(counts, key=counts.get, reverse=True):
                  pct = counts[p] / total * 100
                  bar = "#" * int(pct / 2)
                  print(f"  {p:50s} {counts[p]:6d} ({pct:5.1f}%) {bar}")
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
  backoffLimit: 0
EOF
```

```bash
oc wait --for=condition=complete job/loadtest-headless -n lb-test --timeout=300s

for pod in $(oc get pods -n lb-test -l app=loadtest-headless \
  --no-headers -o name); do
  oc logs "$pod" -n lb-test
done
```

Expected output: every client distributes requests evenly, exactly 10.0% per pod across all 10 replicas.

```
Resolved 10 pod IPs from headless DNS: ['10.130.1.141', '10.130.1.145', '10.130.1.144', ...]
=== Client loadtest-headless-8jgfk: 2000 requests via HEADLESS service ===
  echo-server-69656d49b6-m4hzd                          200 ( 10.0%) #####
  echo-server-69656d49b6-6kdn6                          200 ( 10.0%) #####
  echo-server-69656d49b6-rvq5j                          200 ( 10.0%) #####
  echo-server-69656d49b6-skv7z                          200 ( 10.0%) #####
  echo-server-69656d49b6-8kk5c                          200 ( 10.0%) #####
  echo-server-69656d49b6-hccqf                          200 ( 10.0%) #####
  echo-server-69656d49b6-wg9zr                          200 ( 10.0%) #####
  echo-server-69656d49b6-6qqft                          200 ( 10.0%) #####
  echo-server-69656d49b6-n6dkb                          200 ( 10.0%) #####
  echo-server-69656d49b6-7brpm                          200 ( 10.0%) #####
...
```

Each of the 5 clients shows the same perfectly even distribution across all 10 pods.

## Scenario 3: Internal Traffic via an Internal IngressController

When internal services call a backend like a decision server, modifying the client application to use DNS-based round-robin (Scenario 2) is not always practical. An alternative is to route internal traffic through an internal IngressController with an edge route, so HAProxy handles L7 balancing without any client code changes.

### Create an Internal IngressController

{{% alert state="info" %}}Internal IngressControllers are supported on OSD, ROSA, and ARO. This creates a cluster-internal load balancer that is not accessible from outside the cluster.{{% /alert %}}

```bash
CLUSTER_DOMAIN=$(oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.status.domain}')

cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: internal-router
  namespace: openshift-ingress-operator
spec:
  domain: internal.${CLUSTER_DOMAIN}
  endpointPublishingStrategy:
    type: Private
  nodePlacement:
    nodeSelector:
      matchLabels:
        node-role.kubernetes.io/worker: ""
  routeSelector:
    matchLabels:
      router: internal
EOF
```

Wait for the IngressController to become available:

```bash
oc wait --for=condition=available ingresscontroller/internal-router \
  -n openshift-ingress-operator --timeout=180s
```

### Create an Internal Edge Route

Create an edge route with the `router: internal` label so it is served by the internal IngressController. The edge termination is critical: it lets HAProxy balance at Layer 7 per request instead of per connection.

{{% alert state="warning" %}}Do not use passthrough termination on this route. Passthrough forwards raw TCP connections to the backend, which produces the same per-connection pinning this guide is solving. Edge or reencrypt termination is required for per-request balancing.{{% /alert %}}

```bash
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: echo-server-internal
  namespace: lb-test
  labels:
    router: internal
  annotations:
    haproxy.router.openshift.io/balance: roundrobin
    haproxy.router.openshift.io/disable_cookies: "true"
spec:
  host: echo-server.internal.${CLUSTER_DOMAIN}
  to:
    kind: Service
    name: echo-server-http
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF
```

### Test Internal Traffic Through the Route

Internal callers send traffic to the route hostname instead of the ClusterIP Service name. The internal IngressController resolves within the cluster, so no external DNS or egress is needed.

Get the internal router's cluster IP and the route hostname:

```bash
INTERNAL_HOST=$(oc get route echo-server-internal -n lb-test \
  -o jsonpath='{.spec.host}')
INTERNAL_ROUTER_IP=$(oc get svc router-internal-internal-router \
  -n openshift-ingress -o jsonpath='{.spec.clusterIP}')
```

Reset the echo server and run the load test. The client resolves the route hostname via the internal router's IP to ensure traffic stays in-cluster:

```bash
oc delete job loadtest-persistent loadtest-headless -n lb-test 2>/dev/null; true
oc rollout restart deployment/echo-server -n lb-test
oc rollout status deployment/echo-server -n lb-test --timeout=120s

cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: loadtest-internal-route
  namespace: lb-test
spec:
  parallelism: 5
  completions: 5
  template:
    metadata:
      labels:
        app: loadtest-internal-route
    spec:
      restartPolicy: Never
      containers:
        - name: loadgen
          image: registry.access.redhat.com/ubi9/python-311:latest
          command:
            - python3
            - -c
            - |
              import http.client, ssl, json, os
              router_ip = "${INTERNAL_ROUTER_IP}"
              host_header = "${INTERNAL_HOST}"
              total = 200
              client_id = os.environ.get("HOSTNAME", "unknown")
              ctx = ssl.create_default_context()
              ctx.check_hostname = False
              ctx.verify_mode = ssl.CERT_NONE
              counts = {}
              conn = http.client.HTTPSConnection(router_ip, 443, context=ctx, timeout=10)
              for i in range(total):
                  try:
                      conn.request("GET", "/", headers={"Host": host_header})
                      resp = conn.getresponse()
                      data = json.loads(resp.read())
                      p = data["pod"]
                      counts[p] = counts.get(p, 0) + 1
                  except Exception:
                      conn = http.client.HTTPSConnection(router_ip, 443, context=ctx, timeout=10)
              print(f"=== Client {client_id}: {total} requests over PERSISTENT connection (internal edge route) ===")
              for p in sorted(counts, key=counts.get, reverse=True):
                  pct = counts[p] / total * 100
                  bar = "#" * int(pct / 2)
                  print(f"  {p:50s} {counts[p]:6d} ({pct:5.1f}%) {bar}")
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
  backoffLimit: 0
EOF
```

```bash
oc wait --for=condition=complete job/loadtest-internal-route -n lb-test --timeout=300s

for pod in $(oc get pods -n lb-test -l app=loadtest-internal-route \
  --no-headers -o name); do
  oc logs "$pod" -n lb-test
done
```

Expected output: all 10 pods receive traffic from each client, compared to the ClusterIP test where each client pinned 100% to a single pod.

```
=== Client loadtest-internal-route-mwjrt: 200 requests over PERSISTENT connection (internal edge route) ===
  echo-server-6dd64b69bb-n8k8d                           26 ( 13.0%) ######
  echo-server-6dd64b69bb-dsmxf                           22 ( 11.0%) #####
  echo-server-6dd64b69bb-drrd7                           22 ( 11.0%) #####
  echo-server-6dd64b69bb-mrcjj                           22 ( 11.0%) #####
  echo-server-6dd64b69bb-hpr8f                           21 ( 10.5%) #####
  echo-server-6dd64b69bb-mghd5                           21 ( 10.5%) #####
  echo-server-6dd64b69bb-s6lst                           21 ( 10.5%) #####
  echo-server-6dd64b69bb-nxq4l                           21 ( 10.5%) #####
  echo-server-6dd64b69bb-djgmn                           20 ( 10.0%) #####
  echo-server-6dd64b69bb-5h9cl                            1 (  0.5%)
...
```

As with the edge route in Scenario 1, the distribution is approximately even rather than perfect. The key result is that all 10 pods are active and receiving traffic. Internal callers get L7 per-request balancing without any changes to the client application.

## Summary

| Scenario | Problem | Fix | Balancing layer |
|----------|---------|-----|-----------------|
| External passthrough route | HAProxy pins TCP connections to one pod | Switch to edge (or reencrypt) route | L7 (HAProxy) |
| Internal ClusterIP Service (can modify client) | OVN-K 5-tuple hash pins connections to one pod | Headless Service + client-side round-robin | Application |
| Internal ClusterIP Service (cannot modify client) | OVN-K 5-tuple hash pins connections to one pod | Internal IngressController + edge route | L7 (HAProxy) |

{{% alert state="info" %}}The headless Service approach (Scenario 2) requires client application changes. If modifying the client is not feasible, the internal IngressController approach (Scenario 3) achieves the same result by routing internal traffic through HAProxy for L7 balancing.{{% /alert %}}

## Cleanup

```bash
oc delete namespace lb-test
oc delete ingresscontroller internal-router -n openshift-ingress-operator
```
