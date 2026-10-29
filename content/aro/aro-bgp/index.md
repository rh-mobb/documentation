---
date: '2026-10-28'
title: Deploying BGP Cloud Connector on ARO
tags: ["ARO", "ARO Classic", "Virtualization"]
authors:
  - Kevin Collins
  - Diana Sari
  - Kumudu Herath
validated_version: "4.22"
---

The official Red Hat BGP Cloud Connector Operator provides direct Layer 3 connectivity between Cluster User Defined Networks (CUDNs) and the Azure virtual network that hosts an Azure Red Hat OpenShift (ARO) cluster. It uses Azure Route Server to advertise CUDN routes into the virtual network's effective routes.

This guide configures BGP Cloud Connector on an existing ARO cluster, creates a primary Layer 2 CUDN, and confirms that an ordinary Azure VM can reach an OpenShift Virtualization VM at its CUDN address without inbound NAT, a load balancer, or a NodePort Service.

This is the Azure counterpart to [Deploying BGP Cloud Connector on ROSA HCP](/experts/rosa/bgp-cloud-connector/). The Operator is the same; the cloud integration differs in several ways that are called out throughout.

{{% alert state="danger" header="Today this requires ARO Classic with a service principal" %}}
The Operator's Azure integration needs IP forwarding enabled on each router node's network interface. Where a deny assignment applies to the managed resource group, it blocks `Microsoft.Network/networkInterfaces/write` and `loadBalancers/backendAddressPools/join/action` for any identity it does not exempt, and an applicable deny takes precedence over an RBAC grant. The write is refused with `LinkedAuthorizationFailed`. Switching the Operator to workload identity does not bypass this on its own, because it is an authorization decision rather than an authentication one.

Managed-identity clusters do have exempt platform identities; the problem is that an identity you create for this Operator is not one of them. The [upstream Azure authentication guidance](https://github.com/openshift/bgp-cloud-connector/blob/main/docs/azure-authentication.md) states that ARO Classic with managed identities is unsupported, and that reusing a platform workload's managed identity is prohibited.

Support for **ARO Classic MIWI** and **ARO HCP** is expected to come from the platform enabling IP forwarding when it provisions the nodes, rather than the Operator modifying protected NICs afterwards. Treat that as an unverified expectation rather than a committed roadmap; check the [upstream repository](https://github.com/openshift/bgp-cloud-connector) for current status. Until then, use ARO Classic with a service principal.
{{% /alert %}}

## Architecture

![BGP Cloud Connector on ARO architecture](/experts/aro/aro-bgp/azure-bgp-cloud-connector.png)

The traffic path has four steps, in two phases -- route distribution (1--2) and the data path (3--4):

1. FRR on selected ARO compute nodes establishes BGP sessions with the Azure Route Server's redundant pair of addresses.
1. BGP Cloud Connector advertises the CUDN prefix. Route Server propagates the learned route into the virtual network's effective routes.
1. An Azure VM sends traffic for the VM address to the selected compute node's network interface.
1. OVN-Kubernetes forwards the packet from that node to the VM on the primary CUDN.

The Azure Route Server distributes routes. It is not in the application data path.

### How Azure differs from AWS

| | AWS | Azure |
|---|---|---|
| Resource | VPC Route Server, one endpoint per Availability Zone | Route Server, modeled as a Virtual Hub; one per virtual network |
| Peer groups | One `FRRConfiguration` per Availability Zone | Exactly one `FRRConfiguration`; the same redundant pair is presented to every node |
| Remote ASN | Configurable per Route Server | Fixed at **65515** by the hub, not configurable |
| Node interface | Operator disables SourceDestCheck on the ENI | Operator sets `enableIPForwarding` on the NIC, **before** peering |
| Peer identity | Peers are tagged | No tags; the connection **name** is the lifecycle marker, `<infrastructureName>-bgp-<node-ip>` |
| Hop count | Direct | Multi-hop is forced, because the Route Server sits in its own subnet rather than on the node's link |

The recorded lab environment ran ARO Classic 4.22.20 (installed at 4.21.22 and upgraded in place), OpenShift Virtualization 4.22.12, and BGP Cloud Connector 1.1.0 installed from the `stable` channel of the stock `redhat-operators` catalog (`bgp-cloud-connector.v1.1.0`, image `registry.redhat.io/bgpcc/bgp-cloud-connector-rhel9-operator@sha256:36bbbd780ff4933a9060422b52f3f35c41062181e161228276320aac13862632`). It used one `Standard_D8s_v6` router node, CUDN `10.200.0.0/16`, VM `10.200.0.7`, and an Azure tester at `10.30.5.4`. This single-router topology is sufficient for a functional test but is not highly available. A production design should use multiple eligible nodes.

## Prerequisites

You need:

* An existing **ARO Classic** cluster created with a **service principal**, and `cluster-admin` access.
* OpenShift 4.22 or later. In October 2026 the newest version ARO Classic offered for new installs was 4.21, so this meant creating a 4.21 cluster and upgrading it. Check `az aro get-versions` for your own region. See [Upgrading to 4.22](#upgrading-to-422) below.
* OpenShift Virtualization installed, with its dedicated machine sets already created. Follow [Deploying OpenShift Virtualization on ARO](/experts/aro/aro-virt/) first. That guide creates one Azure Boost machine set per availability zone, named from `VIRT_MACHINESET_NAME` (default `virt-worker`), and installs the Operator and `HyperConverged` resource. This guide reuses those machine sets as the BGP router nodes.
* A virtual network you control, with room for a dedicated Route Server subnet.
* Azure CLI credentials with permission to manage Route Servers, role assignments, and virtual network subnets.
* A CUDN CIDR that does not overlap the virtual network, cluster networks, peered networks, ExpressRoute, VPN, or on-premises networks.
* An Azure VM in the same virtual network to test from.
* Current `az`, `oc`, `jq`, and `virtctl` clients, and `python3` on the workstation (the verification step uses it for a CIDR membership check).

{{% alert state="warning" header="Costs and ownership" %}}
Route Server, VM-series nodes, Azure VMs, and VM storage incur charges. A Route Server is billed per hour whether or not traffic flows, and it takes roughly 20--30 minutes to create and a similar time to delete. Record the owner and provisioning method for each resource before creating it. Do not delete shared resources during cleanup.
{{% /alert %}}

Set the values used repeatedly:

```bash
export RG="<resource-group-holding-the-vnet>"
export CLUSTER="<aro-cluster-name>"
export VNET="<vnet-name>"
export LOCATION="<azure-region>"
export SUB_ID="$(az account show --query id -o tsv)"
export ROUTE_SERVER="<route-server-name>"
export TESTER_VM="<azure-vm-to-test-from>"
export LOCAL_ASN=65001
export CUDN_CIDR=10.200.0.0/16
export RS_SUBNET_CIDR=10.30.4.0/26
export VIRT_MACHINESET_NAME="virt-worker"
```

`VIRT_MACHINESET_NAME` must match the value used in the [ARO virtualization guide](/experts/aro/aro-virt/). It is used here to find the machine sets that should become BGP routers.  Adjust this value to match your environment if you are using something else.

The local ASN must differ from the Route Server ASN of 65515.

`RS_SUBNET_CIDR` must be a free `/26` or larger inside the cluster's virtual network. `CUDN_CIDR` must not overlap it, the virtual network, or any connected network.

### Upgrading to 4.22

In October 2026, `az aro get-versions` returned nothing newer than 4.21.22 in the regions checked for this guide (`eastus`, `eastus2`, `westus3`, `centralus`, `uksouth`, `westeurope`, `northeurope`), so the cluster was created at 4.21 and upgraded. Confirm the current list for your region. The 4.22 releases are reachable from 4.21 on the standard upgrade graph.

## 1. Prepare Azure and the router nodes

### Create the Route Server subnet

Azure requires the Route Server to sit in a dedicated subnet named **exactly** `RouteServerSubnet`, sized `/26` or larger. Any other name is rejected.

```bash
az network vnet subnet create \
  -g "${RG}" --vnet-name "${VNET}" \
  -n RouteServerSubnet \
  --address-prefixes "${RS_SUBNET_CIDR}"
```

### Identify the cluster service principal

ARO grants its service principal Contributor on the cluster's managed resource group and Network Contributor on the virtual network, but **not** on the Route Server. Record its object ID now; the next check and the grant in step 2 both use it.

```bash
CLIENT_ID=$(oc -n kube-system get secret azure-credentials \
  -o jsonpath='{.data.azure_client_id}' | base64 -d)
OBJECT_ID=$(az ad sp show --id "${CLIENT_ID}" --query id -o tsv)
echo "OBJECT_ID=${OBJECT_ID}"
```

### Confirm the deny assignment excludes your service principal

This check is what separates a cluster that will work from one that will not. On the ARO Classic cluster used for this guide, the managed resource group carried a system-protected deny assignment that listed the cluster service principal in `excludePrincipals`. Confirm the same on your own cluster rather than assuming it; exclusion lists vary by cluster type and are not established here for ARO HCP or ARO Classic MIWI.

```bash
MANAGED_RG=$(oc get infrastructure cluster \
  -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')

az rest --method GET \
  --url "https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${MANAGED_RG}/providers/Microsoft.Authorization/denyAssignments?api-version=2022-04-01" \
  --query 'value[].{name:properties.denyAssignmentName,exclude:properties.excludePrincipals}'
```

`${OBJECT_ID}` must appear in `excludePrincipals`. If it does not, the Operator cannot enable IP forwarding on the router nodes and this procedure will fail.

### Mark the virtualization machine sets as BGP routers

Every node that can host a directly routed workload must match the Operator's `routerNodeSelector`. VM traffic exits through the network interface of the node hosting the VM, so a VM scheduled onto an unselected node is unreachable.

Because the virtualization machine sets from the [ARO virtualization guide](/experts/aro/aro-virt/) are exactly the nodes that will run VMs, label those. Patch every machine set whose name contains `${VIRT_MACHINESET_NAME}` so future machines get the label, and label any nodes those machine sets have already created:

```bash
for MS in $(oc get machineset -n openshift-machine-api -o name | grep "${VIRT_MACHINESET_NAME}"); do
  oc patch "${MS}" -n openshift-machine-api --type=merge \
    -p '{"spec":{"template":{"spec":{"metadata":{"labels":{"bgp_router":"true"}}}}}}'

  for NODE in $(oc get machine -n openshift-machine-api \
      -l "machine.openshift.io/cluster-api-machineset=${MS##*/}" \
      -o jsonpath='{.items[*].status.nodeRef.name}'); do
    oc label node "${NODE}" bgp_router=true --overwrite
  done
done
```


{{% alert state="info" header="Why both the machine set and the nodes" %}}
Patching a machine set changes only its template, so it affects **machines created from that point on**. Existing nodes keep their current labels. The loop does both, which makes it safe to run against machine sets that are already scaled up.

The label goes at `spec.template.spec.metadata.labels`, which labels the **Node**. This is not the same as `spec.template.metadata.labels` directly above it, which labels the **Machine**. The Operator's `routerNodeSelector` matches Nodes, so putting the label in the wrong block produces a running machine that the Operator ignores.
{{% /alert %}}

Verify that `oc get nodes -l bgp_router=true` returns every virtualization node. If a machine is `Running` but its node is absent from that list, the label landed on the Machine rather than the Node.

The ARO virtualization guide defaults `ARO_BOOST_INSTANCE` to a Dsv5 size. This lab used `Standard_D8s_v6`. Both the v5 and v6 families are Azure Boost capable and expose hardware virtualization directly:

```bash
NODE=$(oc get nodes -l bgp_router=true -o jsonpath='{.items[0].metadata.name}')
oc debug node/${NODE} -q -- chroot /host sh -c \
  'ls -l /dev/kvm; grep -o -m1 -E "vmx|svm" /proc/cpuinfo'
```

The lab node reported `/dev/kvm` present and the `vmx` flag on an Intel Xeon Platinum 8573C. If you are not running VMs on the router node, a smaller general-purpose size is sufficient.

## 2. Create the Azure Route Server

```bash
az network public-ip create \
  -g "${RG}" -n "${ROUTE_SERVER}-pip" \
  --sku Standard --version IPv4 --allocation-method Static

RS_SUBNET_ID=$(az network vnet subnet show \
  -g "${RG}" --vnet-name "${VNET}" -n RouteServerSubnet --query id -o tsv)

az network routeserver create \
  -g "${RG}" -n "${ROUTE_SERVER}" \
  --hosted-subnet "${RS_SUBNET_ID}" \
  --public-ip-address "${ROUTE_SERVER}-pip"
```

This takes roughly 20--30 minutes. The `virtualHubs` resource reports `Succeeded` well before the data plane is ready; the reliable readiness signal is `virtualRouterIps` becoming populated:

```bash
az network routeserver show -g "${RG}" -n "${ROUTE_SERVER}" \
  --query '{asn:virtualRouterAsn,ips:virtualRouterIps,state:provisioningState}'
```

```json
{
  "asn": 65515,
  "ips": [ "10.30.4.5", "10.30.4.4" ],
  "state": "Succeeded"
}
```

Those two addresses are the redundant pair presented to the whole virtual network. You do not configure them on the cluster; the Operator discovers them, along with the ASN, by reading the hub.

### Grant the service principal access to the Route Server

Now that the resource exists, scope the grant to it rather than to a whole resource group:

```bash
RS_ID=$(az network routeserver show -g "${RG}" -n "${ROUTE_SERVER}" --query id -o tsv)

az role assignment create \
  --assignee-object-id "${OBJECT_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "${RS_ID}"
```

Network Contributor is the role because no narrower built-in role covers the required `join` actions; see [`hack/azure/grant-route-server-role.sh`](https://github.com/openshift/bgp-cloud-connector/blob/main/hack/azure) upstream. Propagation can take a few minutes, and the Operator retries meanwhile.

## 3. Install the Operator

Enable the FRR routing provider:

```bash
oc patch network.operator.openshift.io/cluster --type=merge -p '{
  "spec": {
    "additionalRoutingCapabilities": {
      "providers": ["FRR"]
    }
  }
}'

oc get pods -n openshift-frr-k8s
```

Install the Operator:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: bgp-cloud-connector
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: bgp-cloud-connector-operatorgroup
  namespace: bgp-cloud-connector
spec:
  targetNamespaces:
    - bgp-cloud-connector
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: bgp-cloud-connector-operator
  namespace: bgp-cloud-connector
spec:
  channel: stable
  installPlanApproval: Automatic
  name: bgp-cloud-connector
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

oc get csv -n bgp-cloud-connector
```

Wait for the ClusterServiceVersion to report `Succeeded`.

### Confirm the Azure credential

The Operator creates a `CredentialsRequest` named `bgp-cloud-connector-azure`. On ARO Classic with a service principal the cloud credential operator runs in passthrough mode and writes the secret for you:

```bash
oc get credentialsrequest bgp-cloud-connector-azure \
  -n openshift-cloud-credential-operator -o jsonpath='{.status.provisioned}{"\n"}'
oc get secret bgp-cloud-connector-azure-credentials -n bgp-cloud-connector
```

Wait for `provisioned: true` and the secret to appear. Nothing is created by hand.

## 4. Configure BGP and the primary CUDN

Create the cluster-scoped singleton. For Azure, `spec.azure` requires `resourceGroup`, `routeServerName`, and `subscriptionID`. **`resourceGroup` is the group holding the Route Server, not the cluster's managed resource group.**

```bash
cat <<EOF | oc apply -f -
apiVersion: networking.openshift.io/v1beta1
kind: BGPCloudConfiguration
metadata:
  name: cluster
spec:
  platform: Azure
  bgp:
    localASN: ${LOCAL_ASN}
    livenessDetection: bgp-keepalive
  routerNodeSelector:
    bgp_router: "true"
  azure:
    resourceGroup: ${RG}
    routeServerName: ${ROUTE_SERVER}
    subscriptionID: ${SUB_ID}
EOF

oc get bgpcloudconfiguration cluster -o jsonpath='{.status.phase}{"\n"}'
```

Wait for `Ready`. All six conditions should be `True`:

```bash
oc get bgpcloudconfiguration cluster \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

```
NetworkOperatorPatched=True Patched
FRRNamespaceReady=True Ready
CloudEndpointsDiscovered=True Discovered
FRRConfigurationApplied=True Applied
CompleteNodeInventory=True Complete
CloudResourcesReconciled=True Reconciled
```

`CloudEndpointsDiscovered` reports `Discovered 1 peer group(s)` on Azure. AWS reports one per Availability Zone.

Create the workload namespace with both labels present at creation time, and the `BGPRouting` that advertises `${CUDN_CIDR}`:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: bgp-test-vms
  labels:
    cluster-udn: bgp-test-cudn
    k8s.ovn.org/primary-user-defined-network: ""
---
apiVersion: networking.openshift.io/v1beta1
kind: BGPRouting
metadata:
  name: bgp-test-cudn
spec:
  network:
    name: bgp-test-cudn
    subnets:
      - ${CUDN_CIDR}
EOF

oc get bgprouting bgp-test-cudn -o jsonpath='{.status.phase}{"\n"}'
oc get clusteruserdefinednetwork cluster-udn-bgp-test-cudn
oc get routeadvertisements
```

The namespace labels must exist when the namespace is created; adding the primary-UDN label afterwards does not work.

`BGPRouting` owns the generated Layer 2 CUDN and route advertisements. Do not create or edit that generated CUDN separately. Wait for both BGP custom resources to report `Ready`.

## 5. Test connectivity with a VM

This example uses a `containerDisk` rather than a `DataVolume`. Once a network is advertised, OVN-Kubernetes stops masquerading its traffic so that pods keep their real CUDN address -- which is the whole point of BGP here -- and Azure has no outbound path for that prefix. Pods in the advertised namespace therefore cannot reach a registry, so the CDI importer fails. A `containerDisk` is pulled by the node's container runtime instead, which still masquerades normally. An unadvertised primary CUDN is not affected.

Create the VM. The manifest is applied inline with a quoted heredoc so nothing in the cloud-init block is expanded by the local shell:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: bgp-test-vm
  namespace: bgp-test-vms
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: bgp-test-vm
    spec:
      nodeSelector:
        bgp_router: "true"
      domain:
        cpu:
          cores: 2
        memory:
          guest: 4Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
          interfaces:
            - name: default
              bridge: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora@sha256:1217dcc8c58dbc3ca08e0323929b86f609506121adb01d0fd892232f2c0544f6
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              write_files:
                - path: /var/tmp/bgp-test/index.html
                  permissions: "0644"
                  content: "BGP Cloud Connector VM endpoint on ARO\n"
                - path: /etc/systemd/system/bgp-test-http.service
                  permissions: "0644"
                  content: |
                    [Unit]
                    Description=BGP connectivity test endpoint
                    After=network-online.target
                    Wants=network-online.target

                    [Service]
                    ExecStart=/usr/bin/python3 -m http.server 8080 --directory /var/tmp/bgp-test
                    Restart=on-failure

                    [Install]
                    WantedBy=multi-user.target
              runcmd:
                - [systemctl, daemon-reload]
                - [systemctl, enable, --now, bgp-test-http.service]
EOF
```

The image is pinned to the digest tested here. The guest must provide cloud-init, systemd, and Python 3. The upstream [`kubevirt-testing.md`](https://github.com/openshift/bgp-cloud-connector/blob/main/docs/kubevirt-testing.md) example uses `binding: {name: l2bridge}`; its binding table also lists `bridge`, which is what was tested here.

```bash
oc wait vm/bgp-test-vm -n bgp-test-vms --for=condition=Ready --timeout=15m
oc get vmi -n bgp-test-vms -o wide
```

The reported address should fall inside the CUDN prefix, for example `10.200.0.7`. Reading the address immediately after `Ready` can return an empty string, because `Ready` means the VM is running, not that the guest agent has reported its addresses.

## 6. Confirm BGP and direct connectivity

Confirm the generated resources and BGP sessions:

```bash
oc get bgpcloudconfiguration cluster
oc get bgprouting bgp-test-cudn
oc get frrconfiguration -n openshift-frr-k8s
oc get bgpsessionstate -n openshift-frr-k8s
```

Both peers must report `Established`. One router node and the Route Server's redundant pair produce two sessions:

```
NAME             NODE                     PEER        BGP
...-7mblf        ...-bgp-router-eastus1   10.30.4.5   Established
...-csrtt        ...-bgp-router-eastus1   10.30.4.4   Established
```

Confirm the CUDN prefix is advertised, and that Azure learned it:

Derive the values the remaining checks need:

```bash
NODE=$(oc get nodes -l bgp_router=true -o jsonpath='{.items[0].metadata.name}')
ROUTER_IP=$(oc get nodes -l bgp_router=true \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
INFRA=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
MANAGED_RG=$(oc get infrastructure cluster \
  -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
RS_PEER=$(az network routeserver show -g "${RG}" -n "${ROUTE_SERVER}" \
  --query 'virtualRouterIps[0]' -o tsv)

# The Operator names each BGP connection <infrastructureName>-bgp-<node-ip-with-dashes>.
PEER_NAME="${INFRA}-bgp-${ROUTER_IP//./-}"

echo "node=${NODE} ip=${ROUTER_IP} peer=${PEER_NAME} rs=${RS_PEER}"
```

```bash
POD=$(oc get pods -n openshift-frr-k8s -o wide --no-headers \
  | awk -v n="${NODE}" '$7==n && $1 ~ /^frr-k8s-[a-z0-9]+$/ {print $1}' | head -1)

oc exec -n openshift-frr-k8s "${POD}" -c frr -- \
  vtysh -c "show bgp ipv4 unicast neighbors ${RS_PEER} advertised-routes"

az network routeserver peering list-learned-routes \
  --routeserver "${ROUTE_SERVER}" -g "${RG}" \
  -n "${PEER_NAME}" \
  --query 'RouteServiceRole_IN_0[].{net:network,nextHop:nextHop,asPath:asPath,origin:origin}' \
  -o table
```

```
Net            NextHop    AsPath    Origin
-------------  ---------  --------  --------
10.200.0.0/16  10.30.2.7  65001     EBgp
```

Confirm the Operator enabled IP forwarding on the router node's interface. This is the step that fails on ARO HCP:

```bash
az network nic list -g "${MANAGED_RG}" \
  --query "[?ipConfigurations[0].privateIPAddress=='${ROUTER_IP}'].{name:name,ipfwd:enableIPForwarding}" \
  -o table
```

Confirm the route reached the tester's effective routes. Azure reports Route Server routes with source `VirtualNetworkGateway`:

```bash
NIC=$(az vm show -g "${RG}" -n "${TESTER_VM}" \
  --query 'networkProfile.networkInterfaces[0].id' -o tsv)

az network nic show-effective-route-table --ids "${NIC}" \
  --query "value[?contains(to_string(addressPrefix),'${CUDN_CIDR%%/*}')]"
```

```json
{
  "source": "VirtualNetworkGateway",
  "addressPrefix": [ "10.200.0.0/16" ],
  "nextHopType": "VirtualNetworkGateway",
  "nextHopIpAddress": [ "10.30.2.7" ],
  "state": "Active"
}
```

Finally, test from the Azure VM:

```bash
oc wait vmi/bgp-test-vm -n bgp-test-vms --for=condition=AgentConnected --timeout=5m

VM_IP=""
for _ in $(seq 1 30); do
  VM_IP=$(oc get vmi bgp-test-vm -n bgp-test-vms \
    -o jsonpath="{.status.interfaces[?(@.name=='default')].ipAddress}")
  python3 -c "import ipaddress,sys; sys.exit(0 if '${VM_IP}' and \
    ipaddress.ip_address('${VM_IP}') in ipaddress.ip_network('${CUDN_CIDR}') else 1)" && break
  VM_IP=""; sleep 10
done

if [ -z "${VM_IP}" ]; then
  echo "No address in ${CUDN_CIDR}. Interfaces reported:" >&2
  oc get vmi bgp-test-vm -n bgp-test-vms -o jsonpath='{.status.interfaces}' >&2
  exit 1
fi
echo "VM_IP=${VM_IP}"

RESULT=$(az vm run-command invoke -g "${RG}" -n "${TESTER_VM}" \
  --command-id RunShellScript \
  --scripts "ping -c 4 ${VM_IP} && BODY=\$(curl -fsS --max-time 10 http://${VM_IP}:8080/) \
    && printf '%s' \"\$BODY\" | grep -q 'BGP Cloud Connector' && echo PASS" \
  --query 'value[0].message' -o tsv)

echo "${RESULT}" | grep -Fxq 'PASS' \
  || { echo "FAIL"; echo "${RESULT}" | tail -5; exit 1; }
echo "PASS"
```

The shell expands `${VM_IP}` locally before the script is sent, so the address does not need to exist on the tester.

The lab observed four ICMP replies at `ttl 62` and the expected HTTP body between Azure VM `10.30.5.4` and VM `10.200.0.7`. No inbound NAT, load balancer, or NodePort was used.

## Troubleshooting

### BGP sessions do not establish

Check that `virtualRouterIps` is populated, that `localASN` differs from 65515, that the `bgp_router=true` node label is applied, that FRR pods are running, and that the Network Contributor assignment on the Route Server resource has propagated.

### `CloudEndpointsDiscovered` stays False

* `WaitingForCloudCredentials` -- the secret has not been written yet. Check `oc get credentialsrequest bgp-cloud-connector-azure -n openshift-cloud-credential-operator -o yaml` and the `cloud-credential-operator` logs; do not create the secret by hand.
* `CloudCredentialsInvalid` -- the service principal secret is wrong or expired.
* `CloudDiscoveryFailed` -- the credential is valid but the API call failed. Usually the Network Contributor assignment on the Route Server resource is missing or still propagating, or a deny assignment applies. Check that `routeServerName` and `resourceGroup` name the Route Server, not the cluster.

```bash
oc get bgpcloudconfiguration cluster -o jsonpath='{.status.conditions}' | jq .
```

### `CloudResourcesReconciled` fails with `LinkedAuthorizationFailed`

The Operator could not write the router node's network interface. Azure has no PATCH for a network interface, so every write is a whole-object PUT that pulls the subnet and load balancer backend pool in as linked scopes. Where a deny assignment applies to the managed resource group and does not exempt the identity in use, granting a role will not clear this. On ARO Classic, confirm your service principal appears in the deny assignment's `excludePrincipals`.

### BGP is established but the route is missing

Confirm `BGPRouting` is `Ready`, its generated CUDN and `RouteAdvertisements` exist, and the prefix does not overlap the virtual network. Check the tester's effective route table for a more specific competing route.

### The route exists but traffic fails

Check that `enableIPForwarding` is `true` on the router node's NIC, that the VM runs on a node matching `routerNodeSelector`, that it uses `bridge: {}` on the primary CUDN, and that network security groups allow the test protocol. If ICMP succeeds but HTTP fails, troubleshoot the guest service separately -- BGP routing does not start the service or open the guest firewall.

### The VM never becomes Ready

If you swapped the `containerDisk` for a `DataVolume` and the import stays in `ImportInProgress` with the importer pod in `CrashLoopBackOff`, the importer cannot reach the registry. Traffic from an advertised network is no longer masqueraded, so it leaves with a CUDN source address that Azure has no outbound path for. Use a `containerDisk`, import in an unadvertised namespace and clone the PVC in, or provide an outbound route for the CUDN prefix.

## Cleanup

Remove temporary resources through the same provisioning method used to create them. Verify ownership and dependencies first, and do not delete shared ARO, virtual network, or identity resources solely because they were used in this example.

1. Delete the disposable VM.
1. Delete `BGPRouting` and wait for its CUDN and route advertisements to disappear.
1. Delete `BGPCloudConfiguration` and wait for the Operator-created BGP connections to be removed from the Route Server.
1. Delete the `bgp-test-vms` namespace, then the Operator `Subscription`, `OperatorGroup`, and `bgp-cloud-connector` namespace if nothing else uses them. The `bgp-cloud-connector-azure-credentials` secret is removed with the namespace; the `CredentialsRequest` goes with the Operator.
1. Delete the Route Server, then its public IP. Deletion takes roughly as long as creation.

   ```bash
   az network routeserver delete -g "${RG}" -n "${ROUTE_SERVER}" --yes
   az network public-ip delete -g "${RG}" -n "${ROUTE_SERVER}-pip"
   ```

1. Remove the BGP router label. The virtualization machine sets belong to the [ARO virtualization guide](/experts/aro/aro-virt/), so unless you also want to remove virtualization, un-label them rather than deleting them.

   ```bash
   for MS in $(oc get machineset -n openshift-machine-api -o name | grep "${VIRT_MACHINESET_NAME}"); do
     oc patch "${MS}" -n openshift-machine-api --type=json \
       -p '[{"op":"remove","path":"/spec/template/spec/metadata/labels/bgp_router"}]'
   done

   oc label nodes -l bgp_router=true bgp_router-
   ```

1. Remove the `RouteServerSubnet` and the Network Contributor role assignment if they were created solely for this procedure.

## References

* [Deploying BGP Cloud Connector on ROSA HCP](/experts/rosa/bgp-cloud-connector/)
* [Official BGP Cloud Connector source](https://github.com/openshift/bgp-cloud-connector)
* [BGP Cloud Connector Azure authentication](https://github.com/openshift/bgp-cloud-connector/blob/main/docs/azure-authentication.md)
* [BGP Cloud Connector cloud integration](https://github.com/openshift/bgp-cloud-connector/blob/main/docs/cloud-integration.md)
* [Azure Route Server documentation](https://learn.microsoft.com/en-us/azure/route-server/overview)
* [Azure Route Server prerequisites and limits](https://learn.microsoft.com/en-us/azure/route-server/route-server-faq)
* [Azure deny assignments](https://learn.microsoft.com/en-us/azure/role-based-access-control/deny-assignments)
