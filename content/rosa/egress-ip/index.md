---
date: '2023-02-28'
title: Assign Consistent Egress IP for External Traffic
tags: ["OSD", "ROSA", "ARO"]
authors:
  - 'Dustin Scott'
  - 'Paul Czarkowski'
---

It may be desirable to assign a consistent IP address for traffic that leaves
the cluster when configuring items such as security groups or other sorts of
security controls which require an IP-based configuration.  By default,
Kubernetes via the OVN-Kubernetes CNI will assign random IP addresses from a pool
which will make configuring security lockdowns unpredictable or
unnecessarily open.  This guide shows you how to configure a set of predictable
IP addresses for egress cluster traffic to meet common security standards and
guidance and other potential use cases.

See the [OpenShift documentation on this topic](https://docs.openshift.com/container-platform/4.12/networking/ovn_kubernetes_network_provider/configuring-egress-ips-ovn.html)
for more information.

## Prerequisites

* ROSA Cluster 4.14 or newer
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
export ROSA_MACHINE_POOL_NAME=worker
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

### Label the worker nodes

To allow for assignment, we need to assign a specific label to the nodes.  The
egress IP rule that you created in [a previous step](#create-the-egress-ip-rule)
only applies to nodes with the `k8s.ovn.org/egress-assignable` label.  We want
to ensure that label exists on only a specific machinepool as set via
an environment variable in the [set environment variables](#set-environment-variables)
step.

For ROSA clusters, you can assign labels via the following `rosa` command:

> **WARNING:** if you are reliant upon any node labels for your machinepool,
this command will replace those labels.  Be sure to input your desired labels
into the `--labels` field to ensure your node labels persist.

To complete the egress IP assignment, we need to assign a specific label to the nodes.  The
egress IP rule that you created in [a previous step](#create-the-egress-ip-rule)
only applies to nodes with the `k8s.ovn.org/egress-assignable` label.  We want
to ensure that label exists on only a specific machinepool as set via
an environment variable in the [set environment variables](#set-environment-variables)
step.

For ROSA clusters, you can assign labels via either of the following `rosa` command:

#### Option 1 - Update an existing Machine Pool

> **WARNING:** if you are reliant upon any node labels for your machinepool,
this command will replace those labels.  Be sure to input your desired labels
into the `--labels` field to ensure your node labels persist.

```bash
rosa update machinepool ${ROSA_MACHINE_POOL_NAME} \
  --cluster="${ROSA_CLUSTER_NAME}" \
  --labels "k8s.ovn.org/egress-assignable="
```

#### Option 2 - Create a new Machine Pool

> **NOTE:** set the replicas to 3 if its a multi-az cluster.

```bash
rosa create machinepool --name ${ROSA_MACHINE_POOL_NAME} \
  --cluster="${ROSA_CLUSTER_NAME}" \
  --labels "k8s.ovn.org/egress-assignable=" \
  --replicas 2
```

### Wait until the Nodes have been labelled

```bash
watch 'oc get nodes -l "k8s.ovn.org/egress-assignable="'
```

### Create the Egress IP Rule(s)

#### Identify the Egress IPs

Before creating the rules, we should identify which egress IPs that we will use.  It should be noted
that the egress IPs that you select should exist as a part of the subnets in which the worker
nodes are provisioned into.

#### Reserve the Egress IPs

It is recommended, but not required, to reserve the egress IPs that you have requested to avoid
conflicts with the AWS VPC DHCP service. To do so, you can request
explicit IP reservations by [following the AWS documentation for CIDR reservations](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-cidr-reservation.html).

#### Example: Assign Egress IP to a Namespace

Create a project to demonstrate assigning egress IP addresses based on a
namespace selection:

```bash
oc new-project demo-egress-ns
```

Create the egress rule.  This rule will ensure that egress traffic will
be applied to all pods within the namespace that we just created
via the `spec.namespaceSelector` field:

```bash
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: demo-egress-ns
spec:
  # NOTE: these egress IPs are within the subnet range(s) in which my worker nodes
  #       are deployed.
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
  # NOTE: these egress IPs are within the subnet range(s) in which my worker nodes
  #       are deployed.
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

Expose the pod as a service, limiting the ingress (via the `.spec.loadBalancerSourceRanges`
field) to the service to only the egress IP addresses in which we
specified our pods should be using:

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
  # NOTE: this limits the source IPs that are allowed to connect to our service.  It
  #       is being used as part of this demo, restricting connectivity to our egress
  #       IP addresses only.
  # NOTE: these egress IPs are within the subnet range(s) in which my worker nodes
  #       are deployed.
  loadBalancerSourceRanges:
    - 10.10.100.254/24
    - 10.10.150.254/24
    - 10.10.200.254/24
EOF
```

Retrieve the load balancer hostname as the `LOAD_BALANCER_HOSTNAME` environment
variable which you can copy and use for following steps:

```bash
export LOAD_BALANCER_HOSTNAME=$(oc get svc -n default demo-service -o json | jq -r '.status.loadBalancer.ingress[].hostname')
echo $LOAD_BALANCER_HOSTNAME
```

#### Test Namespace Egress

Test the [namespace egress rule](#example-assign-egress-ip-to-a-namespace) which
was created previously.  The following starts an interactive shell which
allows you to run curl against the demo service:

```bash
oc run \
  demo-egress-ns \
  --namespace=demo-egress-ns \
  --env=LOAD_BALANCER_HOSTNAME=$LOAD_BALANCER_HOSTNAME \
  --image=registry.access.redhat.com/ubi9/ubi -- \
  sleep 64000
```

Once the pod has started, you can send a request to the load balancer, ensuring
that you can successfully connect:

```bash
oc debug -n demo-egress-ns demo-egress-ns -- curl -s http://$LOAD_BALANCER_HOSTNAME
```

You should see output similar to the following, indicating a successful
connection.  It should be noted that that `client_address` below is the
internal IP address of the load balancer rather than our egress IP.  Successful
connectivity (by limiting the service to `.spec.loadBalancerSourceRanges`)
is what provides a successful demonstration:

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
connection.  It should be noted that that `client_address` below is the
internal IP address of the load balancer rather than our egress IP.  Successful
connectivity (by limiting the service to `.spec.loadBalancerSourceRanges`)
is what provides a successful demonstration:

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
successfully blocked when the egress rules do not apply. Unsuccessful
connectivity (by limiting the service to `.spec.loadBalancerSourceRanges`)
is what provides a successful demonstration in this scenario:

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

You can cleanup the assigned node labels by running the following commands:

> **WARNING:** if you are reliant upon any node labels for your machinepool,
this command will replace those labels.  Be sure to input your desired labels
into the `--labels` field to ensure your node labels persist.

```bash
rosa update machinepool ${ROSA_MACHINE_POOL_NAME} \
  --cluster="${ROSA_CLUSTER_NAME}" \
  --labels ""
```
