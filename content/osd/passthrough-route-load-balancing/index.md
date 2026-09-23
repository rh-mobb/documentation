---
date: '2026-09-23'
title: Fixing Uneven Load Distribution with Passthrough Routes and Persistent Connections
tags: ["OSD"]
authors:
  - Kevin Collins
  - Kumudu Herath
validated_version: "4.22"
---

Applications that use SSL passthrough routes or ClusterIP Services with persistent HTTP connections often experience uneven request distribution across pods. This guide explains why that happens, how to reproduce the problem, and how to fix it using a headless Service with client-side load balancing.

## The Problem

OpenShift handles passthrough routes at Layer 4 (TCP). HAProxy balances **TCP connections**, not individual HTTP requests. When a client opens a persistent (keep-alive) connection, all requests on that connection go to the same backend pod.

The same behavior applies to internal traffic through a ClusterIP Service. OVN-Kubernetes uses a 5-tuple hash (source IP, source port, destination IP, destination port, protocol) to select a backend. A single persistent connection always produces the same hash, so every request on that connection reaches the same pod.

With a small number of long-lived clients (connection pools, sidecar proxies, or batch jobs), only a few pods handle the bulk of traffic while others sit idle.

## Why This Matters

Setting `haproxy.router.openshift.io/balance: roundrobin` and `haproxy.router.openshift.io/disable_cookies: "true"` on a passthrough route does not help. These annotations control how new TCP connections are assigned, not how requests within a connection are routed. Under sustained load with connection pooling, the imbalance grows: some pods can receive 50% more requests than others.

## Prerequisites

* An OpenShift Dedicated cluster (or any OpenShift cluster)
* `oc` CLI logged in with permissions to create namespaces, deployments, services, and routes

## Reproduce the Problem

### Deploy an Echo Server

Create a namespace and deploy a simple HTTP server with 10 replicas. Each pod returns its hostname in the response so you can see which pod handled the request.

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
              import http.server, os, threading
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
              http.server.HTTPServer(("0.0.0.0", 8443), Handler).serve_forever()
          ports:
            - containerPort: 8443
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
              port: 8443
            initialDelaySeconds: 2
            periodSeconds: 5
EOF
```

Wait for the rollout to complete:

```bash
oc rollout status deployment/echo-server -n lb-test --timeout=120s
```

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
    - port: 8443
      targetPort: 8443
      name: http
  type: ClusterIP
  sessionAffinity: None
EOF
```

### Run the Load Test (Persistent Connections)

This job runs 5 parallel clients that each send 2,000 requests over a single persistent HTTP/1.1 connection through the ClusterIP Service. The client uses a raw socket to guarantee that the same TCP connection (and therefore the same OVN-K 5-tuple hash) is used for every request:

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
              port = 8443
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

Wait for the job and check the results:

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

## The Fix: Headless Service with Client-Side Load Balancing

A headless Service (`clusterIP: None`) does not proxy traffic. Instead, DNS returns the IP addresses of all backing pods. The client resolves these IPs and distributes requests across them directly.

### Create a Headless Service

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
    - port: 8443
      targetPort: 8443
      name: http
  sessionAffinity: None
EOF
```

### Reset the Echo Server and Run the Headless Load Test

Restart the deployment to reset request counters, then run the headless load test:

```bash
oc rollout restart deployment/echo-server -n lb-test
oc rollout status deployment/echo-server -n lb-test --timeout=120s
```

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
              port = 8443
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
Resolved 10 pod IPs from headless DNS: ['10.131.0.60', '10.131.0.62', '10.128.2.77', ...]
=== Client loadtest-headless-9ntbg: 2000 requests via HEADLESS service ===
  echo-server-69c48fcf7c-b8jmq                          200 ( 10.0%) #####
  echo-server-69c48fcf7c-fspdw                          200 ( 10.0%) #####
  echo-server-69c48fcf7c-dwfst                          200 ( 10.0%) #####
  echo-server-69c48fcf7c-7xk8g                          200 ( 10.0%) #####
  echo-server-69c48fcf7c-kjml6                          200 ( 10.0%) #####
  echo-server-69c48fcf7c-sl74m                          200 ( 10.0%) #####
  echo-server-69c48fcf7c-6q2k2                          200 ( 10.0%) #####
  echo-server-69c48fcf7c-wj2q7                          200 ( 10.0%) #####
  echo-server-69c48fcf7c-kbjgd                          200 ( 10.0%) #####
  echo-server-69c48fcf7c-6hhwr                          200 ( 10.0%) #####
...
```

Each of the 5 clients shows the same perfectly even distribution across all 10 pods.

## What Changed

| Approach | Service type | Balancing layer | Distribution |
|----------|-------------|-----------------|--------------|
| Persistent connection | ClusterIP | Per TCP connection (L4) | Uneven: some pods idle |
| Headless + client round-robin | Headless (`clusterIP: None`) | Per HTTP request (client) | Even: all pods active |

The headless Service shifts load balancing from the kernel (iptables/OVN) to the application. The client resolves pod IPs via DNS and opens a new connection to a different pod for each request (or group of requests), achieving per-request distribution.

{{% alert state="info" %}}This approach requires the client application to implement DNS-based service discovery and round-robin logic. For Java applications, libraries like Netflix Ribbon, Spring Cloud LoadBalancer, or gRPC's built-in name resolver support this pattern natively.{{% /alert %}}

## Cleanup

```bash
oc delete namespace lb-test
```
