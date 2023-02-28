---
date: '2023-02-23T08:00:00.000000'
title: Assign Consistent Egress IP for External Traffic
tags: ["OSD", "ROSA", "ARO"]
---

It may be desirable to assign a consistent IP address for traffic that leaves 
the cluster when configuring items such as security groups or other sorts of 
security controls which require an IP-based configuration.  By default, 
Kubernetes via the OVN-Kubernetes CNI will assign random IP addresses from a pool 
which will make configuring security lockdowns unpredictable or 
unnecessarily open.  This guide shows you how to configure a set of predictable 
IP addresses for egress cluster traffic to meet common security standards and 
guidance and other potential use cases.

See the [OpenShfit documentation on this topic](https://docs.openshift.com/container-platform/4.12/networking/ovn_kubernetes_network_provider/configuring-egress-ips-ovn.html) 
for more information.

## Prerequisites

* ROSA, ARO, or OSD Cluster
* openshift-cli (`oc`)
* rosa-cli (`rosa`)
* jq

## Demo

### Set Environment Variables

This sets environment variables for the demo so that you do not need to 
copy/paste in your own.  Be sure to replace the values for your desired 
values for this step:

```bash
export ROSA_CLUSTER_NAME=cluster
export ROSA_MACHINE_POOL_NAME=Default
```

### Ensure Capacity

For each public cloud provider, there is a limit on the number of IP addresses 
that may be assigned per node.  This may affect the ability to assign an egress IP 
address.  To verify sufficient capacity, you can run the following command to 
print out the currently assigned IP addresses versus the total capacity in order 
to identify any nodes which may affected:

```bash
oc get node -o json | \
    jq '.items[] | 
        {
            "name": .metadata.name, 
            "ips": (.status.addresses | map(select(.type == "InternalIP") | .address)), 
            "capacity": (.metadata.annotations."cloud.network.openshift.io/egress-ipconfig" | fromjson[] | .capacity.ipv4)
        }'
```

**Example Output:**

```json
{
  "name": "ip-10-10-145-88.ec2.internal",
  "ips": [
    "10.10.145.88"
  ],
  "capacity": 14
}
{
  "name": "ip-10-10-154-175.ec2.internal",
  "ips": [
    "10.10.154.175"
  ],
  "capacity": 14
}

...
```

> **NOTE:** the above example uses `jq` as a friendly filter.  If you do not have `jq` 
installed, you can review the `metadata.annotations['cloud.network.openshift.io/egress-ipconfig']` 
field of each node manually to verify node capacity.

### Create the Egress IP Rule

> **NOTE:** generally speaking it would be ideal to [label the nodes](#label-the-nodes) prior to assigning 
the egress IP addresses, however there is a bug that exists which needs to 
be fixed first.  Once this is fixed, the process and documentation will
be re-ordered to address this.  See https://issues.redhat.com/browse/OCPBUGS-4969

#### Example: Assign Egress IP to a Namespace

Create a project to demonstrate assigning egress IP addresses based on a 
namespace selection:

```bash
oc new-project demo-egress-ns
```

Create the egress Rule.  This rule will ensure that egress traffic will 
be applied to all pods within the namespace that we just created 
via the `spec.namespaceSelector` field:

```bash
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: demo-egress-ns
spec:
  egressIPs:
    - 10.10.100.253
    - 10.10.150.253
    - 10.10.200.253    
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: demo-egress-ns
EOF
```

#### Example: Assign Egress IP to a Pod

Create a project to demonstrate assigning egress IP addresses based on a 
pod selection:

```bash
oc new-project demo-egress-pod
```

Create the egress Rule.  This rule will ensure that egress traffic will 
be applied to the pod which we just created using the `spec.podSelector`
field.  It should be noted that `spec.namespaceSelector` is a 
mandatory field:

```bash
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: demo-egress-pod
spec:
  egressIPs:
    - 10.10.100.254
    - 10.10.150.254
    - 10.10.200.254    
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: demo-egress-pod
  podSelector:
    matchLabels:
      run: demo-egress-pod
EOF
```

### Label the Nodes

You can run `oc get egressips` and see that the egress IP assignments are 
pending.  This is due to bug https://issues.redhat.com/browse/OCPBUGS-4969 and 
will not be an issue once fixed:

```bash
NAME              EGRESSIPS       ASSIGNED NODE   ASSIGNED EGRESSIPS
demo-egress-ns    10.10.100.253                   
demo-egress-pod   10.10.100.254                   
```

To complete the egress IP assignment, we need to assign a specific label to the nodes.  The egress IP rule that you created in [a previous step](#create-the-egress-ip-rule) 
only applies to nodes with the `k8s.ovn.org/egress-assignable` label.  We want 
to ensure that label exists on only a specific machinepool as set via 
an environment variable in the [set environment variables](#set-environment-variables) 
step.

#### Non-ROSA Clusters

ROSA has an admission webhook which prevents assigning node labels via the `oc` 
command.  On a non-ROSA cluster, you can assign labels with the following:

```bash
for NODE in $(oc get nodes -o json | jq -r '.items[] | select(.metadata.labels."node-role.kubernetes.io/worker" == "" and .metadata.labels."node-role.kubernetes.io/infra" == "") | .metadata.name'); do
  oc label node ${NODE} "k8s.ovn.org/egress-assignable"=""
done
```

#### ROSA Clusters

For ROSA clusters, you can assign labels via the following `rosa` command:

> **WARNING:** if you are reliant upon any node labels for your machinepool, 
this command will replace those labels.  Be sure to input your desired labels 
into the `--labels` field to ensure your node labels persist.

```bash
rosa update machinepool ${ROSA_MACHINE_POOL_NAME} \
  --cluster="${ROSA_CLUSTER_NAME}" \
  --labels "k8s.ovn.org/egress-assignable="
```

### Review the Egress IPs

You can review the egress IP assignments by running `oc get egressips` which
will produce output as follows:

```bash
NAME              EGRESSIPS       ASSIGNED NODE                   ASSIGNED EGRESSIPS
demo-egress-ns    10.10.100.253   ip-10-10-156-122.ec2.internal   10.10.150.253
demo-egress-pod   10.10.100.254   ip-10-10-156-122.ec2.internal   10.10.150.254
```

### Test the Egress IP Rule

#### Create the Demo Service

To test the rule, we will create a service which is locked down only to the 
egress IP addresses in which we have specified.  This will simulate 
an external service which is expecting a small subset of IP addresses

Run the echoserver which gives us some helpful information:

```bash
oc -n default run demo-service --image=gcr.io/google_containers/echoserver:1.4
```

Expose the pod as a service, limiting the ingress (via the `.spec.loadBalancerSourceRanges` field) to the service to only the egress
IP addresses in which we specified our pods should be using:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: demo-service
  namespace: default
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
spec:
  selector:
    run: demo-service
  ports:
    - port: 80
      targetPort: 8080
  type: LoadBalancer
  externalTrafficPolicy: Local
  loadBalancerSourceRanges:
    - 10.10.100.254/32
    - 10.10.150.254/32
    - 10.10.200.254/32
    - 10.10.100.253/32
    - 10.10.150.253/32
    - 10.10.200.253/32
EOF
```

Retrieve the load balancer hostname as the `LOAD_BALANCER_HOSTNAME` environment 
variable which you can copy and use for following steps:

```bash
export LOAD_BALANCER_HOSTNAME=$(oc get svc -n default demo-service -o json | jq -r '.status.loadBalancer.ingress[].hostname')
```

#### Test Namespace Egress

Test the [namespace egress rule](#example-assign-egress-ip-to-a-namespace) which 
was created previously.  The following starts an interactive shell which 
allows you to run curl against the demo service:

```bash
oc run \
  demo-egress-ns \
  -it \
  --namespace=demo-egress-ns \
  --env=LOAD_BALANCER_HOSTNAME=$LOAD_BALANCER_HOSTNAME \
  --image=registry.access.redhat.com/ubi9/ubi -- \
  bash
```

Once inside the pod, you can send a request to the load balancer, ensuring 
that you can successfully connect:

```bash
curl -s http://$LOAD_BALANCER_HOSTNAME
```

You should see output similar to the following, indicating a successful 
connection:

```bash
CLIENT VALUES:
client_address=10.10.207.247
command=GET
real path=/
query=nil
request_version=1.1
request_uri=http://internal-a3e61de18bfca4a53a94a208752b7263-148284314.us-east-1.elb.amazonaws.com:8080/

SERVER VALUES:
server_version=nginx: 1.10.0 - lua: 10001

HEADERS RECEIVED:
accept=*/*
host=internal-a3e61de18bfca4a53a94a208752b7263-148284314.us-east-1.elb.amazonaws.com
user-agent=curl/7.76.1
BODY:
-no body in request-
```

You can safely exit the pod once you are done:

```bash
exit
```

#### Test Pod Egress

Test the [pod egress rule](#example-assign-egress-ip-to-a-pod) which 
was created previously.  The following starts an interactive shell which 
allows you to run curl against the demo service:

```bash
oc run \
  demo-egress-pod \
  -it \
  --namespace=demo-egress-pod \
  --env=LOAD_BALANCER_HOSTNAME=$LOAD_BALANCER_HOSTNAME \
  --image=registry.access.redhat.com/ubi9/ubi -- \
  bash
```

Once inside the pod, you can send a request to the load balancer, ensuring 
that you can successfully connect:

```bash
curl -s http://$LOAD_BALANCER_HOSTNAME
```

You should see output similar to the following, indicating a successful 
connection:

```bash
CLIENT VALUES:
client_address=10.10.207.247
command=GET
real path=/
query=nil
request_version=1.1
request_uri=http://internal-a3e61de18bfca4a53a94a208752b7263-148284314.us-east-1.elb.amazonaws.com:8080/

SERVER VALUES:
server_version=nginx: 1.10.0 - lua: 10001

HEADERS RECEIVED:
accept=*/*
host=internal-a3e61de18bfca4a53a94a208752b7263-148284314.us-east-1.elb.amazonaws.com
user-agent=curl/7.76.1
BODY:
-no body in request-
```

You can safely exit the pod once you are done:

```bash
exit
```

#### Test Blocked Egress

Alternatively to a successful connection, you can see that the traffic is 
successfully blocked when the egress rules do not apply:

```bash
oc run \
  demo-egress-pod-fail \
  -it \
  --namespace=demo-egress-pod \
  --env=LOAD_BALANCER_HOSTNAME=$LOAD_BALANCER_HOSTNAME \
  --image=registry.access.redhat.com/ubi9/ubi -- \
  bash
```

Once inside the pod, you can send a request to the load balancer:

```bash
curl -s http://$LOAD_BALANCER_HOSTNAME
```

The above command should hang.  You can safely exit the pod once you are done:

```bash
exit
```

### Cleanup

You can cleanup your cluster by running the following commands:

```bash
oc delete svc demo-service -n default; \
oc delete pod demo-service -n default; \
oc delete project demo-egress-ns; \
oc delete project demo-egress-pod; \
oc delete egressip demo-egress-ns; \
oc delete egressip demo-egress-pod
```

#### Cleanup Node Labels: Non-ROSA Clusters

```bash
for NODE in $(oc get nodes -o json | jq -r '.items[] | select(.metadata.labels."node-role.kubernetes.io/worker" == "" and .metadata.labels."node-role.kubernetes.io/infra" == "") | .metadata.name'); do
  oc label node ${NODE} "k8s.ovn.org/egress-assignable-"
done
```

#### Cleanup Node Labels: ROSA Clusters

> **WARNING:** if you are reliant upon any node labels for your machinepool, 
this command will replace those labels.  Be sure to input your desired labels 
into the `--labels` field to ensure your node labels persist.

```bash
rosa update machinepool ${ROSA_MACHINE_POOL_NAME} \
  --cluster="${ROSA_CLUSTER_NAME}" \
  --labels ""
```
