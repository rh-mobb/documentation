---
date: "2026-10-09"
title: "Connect ARO Classic CUDNs to Azure with BGP Cloud Connector and workload identity"
tags: ["ARO", "ARO Classic", "Virtualization"]
authors:
  - Diana Sari
validated_version: "4.21"
---

## Overview

This guide shows how to connect a ClusterUserDefinedNetwork (CUDN) on Azure Red Hat OpenShift (ARO) Classic to an Azure virtual network through Azure Route Server. It uses the engineering BGP Cloud Connector implementation with Azure managed identities and workload identity (MIWI).

The procedure was functionally validated with:

- ARO Classic and OpenShift 4.21.22
- Azure CLI 2.90.0
- OpenShift Virtualization 4.21.17
- BGP Cloud Connector commit [`d317567b54e6d4457246032f952fa6c6b80973c7`](https://github.com/openshift/bgp-cloud-connector/commit/d317567b54e6d4457246032f952fa6c6b80973c7)
- Operator image `quay.io/redhat-user-workloads/bgp-cloud-connector-tenant/bgp-cloud-connector/bgp-cloud-connector-operator@sha256:1acd2ea1727ba868e4cd324730d76b3bdb12d48357b73cdf2b8b67fd80140bc5`

The operator discovers the Route Server addresses and ASN, creates one Azure BGP peer for each selected router worker, enables IP forwarding on those workers' network interfaces, and renders the required FRR configuration. A `BGPRouting` resource then creates and advertises the CUDN.

{{% alert state="warning" %}}
This guide documents functional validation of the current engineering implementation. The additive federated credential on the ARO `machine-api` identity remains subject to product and support guidance. This guide does not make a support-policy determination or present that identity arrangement as final product architecture.
{{% /alert %}}

This guide does not validate ARO with hosted control planes, production scale, production readiness, upgrade behavior, or every failure scenario.

## Architecture

The example uses local ASN `65001`, the fixed Azure Route Server ASN `65515`, and CUDN subnet `10.100.0.0/16`. Replace all other example names and addresses with values for your environment.

{{< mermaid >}}
flowchart LR
    VM[OpenShift Virtualization VM<br/>CUDN 10.100.0.0/16]
    W[Three selected ARO workers<br/>FRR ASN 65001]
    RS[Azure Route Server<br/>ASN 65515]
    AVM[Azure test VM<br/>VNet subnet]

    VM -->|l2bridge| W
    W <-->|eBGP, two sessions per worker| RS
    RS --> AVM
{{< /mermaid >}}

Azure requires the Route Server subnet to be named exactly `RouteServerSubnet`. Follow current Azure sizing guidance and use `/26` or larger for a new deployment.

## Identity model

The validated MIWI path separates Azure operations between two identities:

| Operation | Identity |
|:---|:---|
| Discover Route Server endpoints and manage BGP peers | Dedicated BGP Cloud Connector identity |
| Read and update selected worker network interfaces | ARO `machine-api` platform identity |

The BGP Cloud Connector ServiceAccount is federated to both identities. Its primary Cloud Credential Operator (CCO) credential names the dedicated identity. The `networkInterfaceClientID` field tells the operator to request a separate token for `machine-api` only when operating on worker NICs.

CCO creates `bgp-cloud-connector-azure-credentials` after the operator creates `CredentialsRequest/bgp-cloud-connector-azure`. The generated credential uses `azure_federated_token_file` and contains no `azure_client_secret`.

## Prerequisites

You need:

- An Azure subscription where you can create ARO clusters, managed identities, federated credentials, role assignments, networking, and test VMs.
- Azure CLI with `az aro identity get-required`, `az aro identity create-required`, and `az aro create --enable-managed-identity`. This guide was validated with Azure CLI 2.90.0.
- `oc`, `git`, `make`, `jq`, and `envsubst`.
- A Red Hat pull secret stored outside source control.
- An existing resource group, VNet, empty control-plane and worker subnets, and any required NSG.
- An Azure Route Server in a subnet named `RouteServerSubnet`.
- An Azure VM or another endpoint in a routed VNet subnet for connectivity testing.
- OpenShift 4.21 or newer.

Do not manually configure Route Server peers. Peer lifecycle is part of the behavior being validated.

Set environment variables. The values below are placeholders unless explicitly described as examples.

```bash
export SUBSCRIPTION_ID="<subscription-id>"
export TENANT_ID="<tenant-id>"
export LOCATION="<azure-region>"

export RESOURCE_GROUP="<aro-and-network-resource-group>"
export CLUSTER_NAME="<aro-cluster-name>"
export MANAGED_RESOURCE_GROUP="<aro-managed-resource-group>"

export VNET_NAME="<vnet-name>"
export MASTER_SUBNET="<control-plane-subnet-name>"
export WORKER_SUBNET="<worker-subnet-name>"
export NSG_NAME="<preconfigured-nsg-name>"

export ROUTE_SERVER_NAME="<route-server-name>"
export AZURE_TEST_VM_IP="<azure-test-vm-private-ip>"
export OPENSHIFT_VERSION="4.21.22"
export PULL_SECRET_PATH="<path-to-pull-secret>"

export BGP_IDENTITY_NAME="${CLUSTER_NAME}-bgp-cloud-connector"
export BGP_OPERATOR_NAMESPACE="openshift-bgp-cloud-connector"
export BGP_OPERATOR_SERVICE_ACCOUNT="openshift-bgp-cloud-connector-controller-manager"
export BGP_OPERATOR_SUBJECT="system:serviceaccount:${BGP_OPERATOR_NAMESPACE}:${BGP_OPERATOR_SERVICE_ACCOUNT}"
```

Confirm that the ARO subnets are empty and review any attached NSG, route table, or NAT gateway before creating identities:

```bash
az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$MASTER_SUBNET" \
  --query '{ipConfigurations:length(ipConfigurations),nsg:networkSecurityGroup.id,routeTable:routeTable.id,natGateway:natGateway.id}'

az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$WORKER_SUBNET" \
  --query '{ipConfigurations:length(ipConfigurations),nsg:networkSecurityGroup.id,routeTable:routeTable.id,natGateway:natGateway.id}'
```

## Create ARO managed identities and base RBAC

Ask the current CLI to calculate the requirements for your exact cluster version and network before it creates anything:

```bash
az aro identity get-required \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --version "$OPENSHIFT_VERSION" \
  --vnet "$VNET_NAME" \
  --vnet-resource-group "$RESOURCE_GROUP" \
  --master-subnet "$MASTER_SUBNET" \
  --worker-subnet "$WORKER_SUBNET"
```

Review the generated identities, roles, and scopes. Then create the base identities and assignments:

```bash
az aro identity create-required \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --version "$OPENSHIFT_VERSION" \
  --vnet "$VNET_NAME" \
  --vnet-resource-group "$RESOURCE_GROUP" \
  --master-subnet "$MASTER_SUBNET" \
  --worker-subnet "$WORKER_SUBNET" \
  --yes
```

The validated flow created these nine user-assigned managed identities:

- `aro-cluster`
- `aro-operator`
- `cloud-controller-manager`
- `cloud-network-config`
- `disk-csi-driver`
- `file-csi-driver`
- `image-registry`
- `ingress`
- `machine-api`

Use the helper output as the source of truth for the base roles. The validated topology produced 20 base assignments, including the eight assignments that allow `aro-cluster` to create federated credentials on the platform identities.

## Add BYO NSG role assignments where required

The identity helper calculates assignments for the VNet and ARO subnets. When the control-plane and worker subnets use a preconfigured NSG, current ARO guidance also requires four NSG-scoped assignments.

```bash
export NSG_ID="$(az network nsg show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NSG_NAME" \
  --query id --output tsv)"

assign_nsg_role() {
  identity_name="$1"
  role_name="$2"
  principal_id="$(az identity show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$identity_name" \
    --query principalId --output tsv)"

  az role assignment create \
    --assignee-object-id "$principal_id" \
    --assignee-principal-type ServicePrincipal \
    --role "$role_name" \
    --scope "$NSG_ID"
}

assign_nsg_role cloud-controller-manager "Azure Red Hat OpenShift Cloud Controller Manager"
assign_nsg_role machine-api "Azure Red Hat OpenShift Machine API Operator"
assign_nsg_role aro-operator "Azure Red Hat OpenShift Service Operator"
assign_nsg_role file-csi-driver "Azure Red Hat OpenShift File Storage Operator"
```

If your topology also brings a route table, NAT gateway, or other linked network resource, use `az aro identity get-required` and current ARO documentation to determine the additional scoped assignments. Do not copy assignments from a different topology.

## Create the ARO Classic MIWI cluster

Create the cluster using the nine existing identities. `--enable-preconfigured-nsg` tells ARO that the NSG is managed outside the cluster deployment.

```bash
az aro create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --location "$LOCATION" \
  --cluster-resource-group "$MANAGED_RESOURCE_GROUP" \
  --vnet-resource-group "$RESOURCE_GROUP" \
  --vnet "$VNET_NAME" \
  --master-subnet "$MASTER_SUBNET" \
  --worker-subnet "$WORKER_SUBNET" \
  --version "$OPENSHIFT_VERSION" \
  --worker-count 3 \
  --outbound-type Loadbalancer \
  --apiserver-visibility Public \
  --ingress-visibility Public \
  --enable-preconfigured-nsg true \
  --enable-managed-identity \
  --assign-cluster-identity aro-cluster \
  --assign-platform-workload-identity file-csi-driver file-csi-driver \
  --assign-platform-workload-identity cloud-controller-manager cloud-controller-manager \
  --assign-platform-workload-identity ingress ingress \
  --assign-platform-workload-identity image-registry image-registry \
  --assign-platform-workload-identity machine-api machine-api \
  --assign-platform-workload-identity cloud-network-config cloud-network-config \
  --assign-platform-workload-identity aro-operator aro-operator \
  --assign-platform-workload-identity disk-csi-driver disk-csi-driver \
  --pull-secret "@${PULL_SECRET_PATH}"
```

Wait for the cluster to report `Succeeded`, then log in and verify cluster health:

```bash
az aro show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query '{state:provisioningState,identity:identity.type,platformIdentities:platformWorkloadIdentityProfile}'

oc get nodes
oc get clusteroperators
```

## Create the dedicated BGP Cloud Connector identity

Create a user-assigned identity for normal operator Azure operations and scope its permission to the resource group containing the Route Server:

```bash
az identity create \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --name "$BGP_IDENTITY_NAME"

export BGP_CLIENT_ID="$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$BGP_IDENTITY_NAME" \
  --query clientId --output tsv)"

export BGP_PRINCIPAL_ID="$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$BGP_IDENTITY_NAME" \
  --query principalId --output tsv)"

export NETWORK_RESOURCE_GROUP_ID="$(az group show \
  --name "$RESOURCE_GROUP" \
  --query id --output tsv)"

az role assignment create \
  --assignee-object-id "$BGP_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Network Contributor" \
  --scope "$NETWORK_RESOURCE_GROUP_ID"
```

## Configure workload identity federation

Read the ServiceAccount issuer from the live cluster and create a federated credential for the operator ServiceAccount on the dedicated identity:

```bash
export SERVICE_ACCOUNT_ISSUER="$(oc get authentication cluster \
  -o jsonpath='{.spec.serviceAccountIssuer}')"

az identity federated-credential create \
  --resource-group "$RESOURCE_GROUP" \
  --identity-name "$BGP_IDENTITY_NAME" \
  --name bgp-cloud-connector \
  --issuer "$SERVICE_ACCOUNT_ISSUER" \
  --subject "$BGP_OPERATOR_SUBJECT" \
  --audiences openshift
```

Create an additive credential for the same subject on the existing ARO `machine-api` identity:

```bash
az identity federated-credential create \
  --resource-group "$RESOURCE_GROUP" \
  --identity-name machine-api \
  --name bgp-cloud-connector \
  --issuer "$SERVICE_ACCOUNT_ISSUER" \
  --subject "$BGP_OPERATOR_SUBJECT" \
  --audiences openshift

export MACHINE_API_CLIENT_ID="$(az identity show \
  --resource-group "$RESOURCE_GROUP" \
  --name machine-api \
  --query clientId --output tsv)"
```

Do not replace or remove the ARO-managed federated credential whose subject is `system:serviceaccount:openshift-machine-api:machine-api-controllers`.

## Install BGP Cloud Connector

This procedure reproduces the functionally validated engineering implementation at the exact source commit and image digest below. It is not final production installation guidance. Recheck the upstream project and applicable product guidance before selecting an installation path or using a newer build.

```bash
export BGP_CC_COMMIT="d317567b54e6d4457246032f952fa6c6b80973c7"
export BGP_CC_IMAGE="quay.io/redhat-user-workloads/bgp-cloud-connector-tenant/bgp-cloud-connector/bgp-cloud-connector-operator@sha256:1acd2ea1727ba868e4cd324730d76b3bdb12d48357b73cdf2b8b67fd80140bc5"

git clone https://github.com/openshift/bgp-cloud-connector.git
git -C bgp-cloud-connector checkout "$BGP_CC_COMMIT"
make -C bgp-cloud-connector kustomize

(
  cd bgp-cloud-connector/config/manager
  ../../bin/kustomize edit set image controller="$BGP_CC_IMAGE"
)

bgp-cloud-connector/bin/kustomize build \
  bgp-cloud-connector/config/default > bgp-cloud-connector-operator.yaml
```

Review the rendered namespace, CRDs, RBAC, ServiceAccount, services, webhooks, and Deployment. Apply the reviewed render, then set the workload-identity inputs on the manager Deployment:

```bash
oc apply -f bgp-cloud-connector-operator.yaml

oc set env deployment/openshift-bgp-cloud-connector-controller-manager \
  --namespace "$BGP_OPERATOR_NAMESPACE" \
  CLIENTID="$BGP_CLIENT_ID" \
  TENANTID="$TENANT_ID" \
  SUBSCRIPTIONID="$SUBSCRIPTION_ID"

oc rollout status deployment/openshift-bgp-cloud-connector-controller-manager \
  --namespace "$BGP_OPERATOR_NAMESPACE"
```

At this validated commit, the operator does not create its `CredentialsRequest` until a `BGPCloudConfiguration` is reconciled. Its absence at this point is expected.

## Select router workers

Label the current workers and each owning MachineSet template. Template labels ensure a replacement Node inherits the router role.

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  machine_name="$(oc get "$node" -o jsonpath='{.metadata.annotations.machine\.openshift\.io/machine}')"
  machine_namespace="${machine_name%%/*}"
  machine_name="${machine_name##*/}"
  machineset_name="$(oc get machine "$machine_name" \
    --namespace "$machine_namespace" \
    -o jsonpath='{.metadata.labels.machine\.openshift\.io/cluster-api-machineset}')"

  oc patch machineset "$machineset_name" \
    --namespace "$machine_namespace" \
    --type merge \
    --patch '{"spec":{"template":{"spec":{"metadata":{"labels":{"bgp_router":"true"}}}}}}'

  oc label "$node" bgp_router=true
done
```

Confirm that only the intended workers are selected and remain Ready:

```bash
oc get nodes -l bgp_router=true -o wide
oc get machinesets -n openshift-machine-api \
  -o custom-columns='NAME:.metadata.name,ROUTER:.spec.template.spec.metadata.labels.bgp_router,READY:.status.readyReplicas'
```

## Configure `BGPCloudConfiguration`

Apply the singleton resource. The `networkInterfaceClientID` value is the `machine-api` identity client ID, not the dedicated operator client ID.

```bash
envsubst <<'EOF' | oc apply -f -
apiVersion: networking.openshift.io/v1beta1
kind: BGPCloudConfiguration
metadata:
  name: cluster
spec:
  platform: Azure
  routerNodeSelector:
    bgp_router: "true"
  bgp:
    localASN: 65001
    livenessDetection: bgp-keepalive
  azure:
    subscriptionID: ${SUBSCRIPTION_ID}
    resourceGroup: ${RESOURCE_GROUP}
    routeServerName: ${ROUTE_SERVER_NAME}
    networkInterfaceClientID: ${MACHINE_API_CLIENT_ID}
EOF
```

Validate the workload-identity credential without printing its contents:

```bash
oc get credentialsrequest bgp-cloud-connector-azure \
  -n openshift-cloud-credential-operator

oc get secret bgp-cloud-connector-azure-credentials \
  -n "$BGP_OPERATOR_NAMESPACE" \
  -o jsonpath='{range $k,$v := .data}{$k}{"\n"}{end}'
```

The key list should include `azure_federated_token_file` and should not include `azure_client_secret`.

Wait for the configuration to become Ready:

```bash
oc get bgpcloudconfiguration cluster -w
oc get bgpcloudconfiguration cluster \
  -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" reason="}{.reason}{"\n"}{end}'
```

Expected healthy conditions are:

- `NetworkOperatorPatched=True`
- `FRRNamespaceReady=True`
- `CloudEndpointsDiscovered=True`
- `FRRConfigurationApplied=True`
- `CompleteNodeInventory=True`
- `CloudResourcesReconciled=True`

## Validate Route Server peers and NIC forwarding

Inspect the generated peer plan and FRR configuration:

```bash
oc get bgpcloudconfiguration cluster -o yaml
oc get frrconfiguration bgp-cc-1 -n openshift-frr-k8s -o yaml

az network routeserver peering list \
  --resource-group "$RESOURCE_GROUP" \
  --routeserver "$ROUTE_SERVER_NAME" \
  --query '[].{name:name,peerIp:peerIp,peerAsn:peerAsn,provisioningState:provisioningState}' \
  --output table
```

For three selected workers, expect three Azure peers and six Established sessions because Azure Route Server exposes two endpoints. The operator should discover the Route Server addresses and ASN `65515`; do not enter neighbor addresses manually.

Map each selected Node to its Azure NIC and verify `enableIPForwarding` is `true`. Use Azure Activity Logs to confirm the split identity behavior:

- NIC writes are attributed to `machine-api`.
- Route Server peer writes are attributed to the dedicated BGP Cloud Connector identity.

## Configure `BGPRouting` and the CUDN

Create the namespace with both required labels at creation time. Admission prevents adding the primary UDN label later.

```bash
export CUDN_NAMESPACE="<cudn-test-namespace>"
export CUDN_NETWORK_NAME="<cudn-network-name>"
export BGP_ROUTING_NAME="<bgp-routing-name>"
export CUDN_SUBNET="10.100.0.0/16"

envsubst <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${CUDN_NAMESPACE}
  labels:
    k8s.ovn.org/primary-user-defined-network: ""
    cluster-udn: ${CUDN_NETWORK_NAME}
---
apiVersion: networking.openshift.io/v1beta1
kind: BGPRouting
metadata:
  name: ${BGP_ROUTING_NAME}
spec:
  network:
    name: ${CUDN_NETWORK_NAME}
    subnets:
      - ${CUDN_SUBNET}
EOF
```

Do not manually create the CUDN or `RouteAdvertisements`. Verify the operator-generated resources:

```bash
oc get bgprouting "$BGP_ROUTING_NAME" -o yaml
oc get clusteruserdefinednetwork "cluster-udn-${CUDN_NETWORK_NAME}" -o yaml
oc get routeadvertisements bgp-cc-route-advertisements -o yaml
```

## Create an OpenShift Virtualization test VM

Install an OpenShift Virtualization release compatible with the cluster. The validation used channel `stable` and CSV `kubevirt-hyperconverged-operator.v4.21.17` on OpenShift 4.21.22.

Use a non-shared test public key. Do not commit the rendered key or private key:

```bash
export CUDN_VM_NAME="cudn-connectivity-test"
export SSH_PUBLIC_KEY="$(cat /path/to/test-public-key)"
```

Create a minimal VM using the `l2bridge` binding. Do not use masquerade for this routed UDN interface.

```bash
envsubst <<'EOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${CUDN_VM_NAME}
  namespace: ${CUDN_NAMESPACE}
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/domain: cudn-connectivity-test
    spec:
      domain:
        resources:
          requests:
            memory: 1Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          interfaces:
            - name: default
              model: virtio
              binding:
                name: l2bridge
      networks:
        - name: default
          pod: {}
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora@sha256:1571d49ee43106e9c7cc4e9f487f6f885ee7c156dc5834fad87ad1e38768b778
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |-
              #cloud-config
              user: cloud-user
              ssh_authorized_keys:
                - ${SSH_PUBLIC_KEY}
EOF
```

Wait for the VM and VMI to become Running and Ready.

## Validate routed connectivity

From the guest, inspect addressing and routing before testing connectivity:

```bash
ip addr
ip route
ip rule
ip neigh show
ping -c 4 "$AZURE_TEST_VM_IP"
```

For the example `10.100.0.0/16` network, the validated guest received `10.100.0.3/16`, gateway `10.100.0.1`, and MTU 1400. These host addresses are observations, not required static values.

Check the routes learned from every peer:

```bash
export PEER_NAME="<route-server-peer-name>"

az network routeserver peering list-learned-routes \
  --resource-group "$RESOURCE_GROUP" \
  --routeserver "$ROUTE_SERVER_NAME" \
  --name "$PEER_NAME" \
  --output json
```

The validated Route Server learned `10.100.0.0/16` from all three router workers across both Route Server instances. Each path reported origin `EBgp` and AS path `65001`. The guest reached the Azure VM with four replies from four packets and zero packet loss.

## Optional: validate worker replacement reconciliation

Ensure every selected worker's owning MachineSet template contains `bgp_router: "true"`. Record the current Machine, Node, NIC, peer, learned routes, and guest connectivity before replacement.

Delete only one Machine through the OpenShift Machine API:

```bash
export ROUTER_MACHINE_NAME="<router-machine-name>"
oc delete machine "$ROUTER_MACHINE_NAME" -n openshift-machine-api
```

Do not delete the Azure VM directly. Observe until:

1. The old Machine, Node, and Route Server peer disappear.
2. The MachineSet creates a replacement.
3. The replacement Node becomes Ready and inherits `bgp_router=true`.
4. The operator enables IP forwarding on the replacement NIC.
5. A Route Server peer appears for the replacement worker.
6. Both new sessions become Established.
7. `BGPCloudConfiguration/cluster` is Ready.
8. Azure learns the CUDN prefix through the replacement worker.

Azure Activity Logs should attribute the replacement NIC write to `machine-api` and the replacement peer write to the dedicated operator identity.

In the functional validation, the router address changed from `10.0.2.5` to `10.0.2.7`. The MachineSet returned to its desired replica count, all six sessions returned to Established, and no manual Azure or RBAC repair was required.

## Troubleshooting and known observations

### CCO waits for credentials

If `CloudEndpointsDiscovered=False` reports `WaitingForCloudCredentials`, verify that `CLIENTID`, `TENANTID`, and `SUBSCRIPTIONID` are all set on the operator Deployment. Check the `CredentialsRequest` status and confirm that the federated credential's issuer, subject, and audience match exactly.

### Azure denies NIC writes

ARO protects the managed resource group with an Azure deny assignment. If Azure rejects worker NIC writes, confirm that `networkInterfaceClientID` names the ARO `machine-api` client ID and that the additive operator ServiceAccount FIC exists on that identity. Do not grant broader access to the dedicated operator identity as a workaround.

### FRR webhook startup race

Initial reconciliation can report `FRRConfigurationApplied=False` while `frr-k8s-webhook-service` has no healthy endpoint. The validated environment recovered through normal reconciliation without configuration changes. Check webhook endpoints and operator conditions before intervening.

### `disableMP` warning

The generated FRR configuration can emit a deprecation warning for `disableMP`. At the validated commit, the operator intentionally sets this field to satisfy OCP 4.21 RouteAdvertisements validation. Do not edit operator-generated FRR resources.

### `virtctl` WebSocket close 1006

An initial client and server version mismatch produced WebSocket close 1006. Matching `virtctl` v1.7.4 to the cluster enabled the initial guest test, but the streaming issue later recurred. The VM remained Running and Ready, and no evidence indicated a BGP or CUDN failure.

Using a matching client is a diagnostic step, not a guaranteed fix for every WebSocket 1006 failure. Diagnose OpenShift Virtualization streaming separately from the BGP dataplane.

### Azure effective-route output

The Azure test NIC effective-route API did not show an exact `10.100.0.0/16` entry during validation, even though Route Server learned the prefix and dataplane connectivity succeeded. Evaluate Route Server learning, FRR state, and guest connectivity together.

### Engineering documentation gap

At the validated commit, `docs/azure-integration-test-plan.md` was absent. The implementation, CRD schema, current Azure authentication guide, and other engineering documentation were used as the source of truth.

## Service-principal comparison

ARO Classic with a service principal uses CCO passthrough. The operator receives the cluster service principal credential and that principal needs permission on the resource group containing Route Server.

The MIWI path in this guide instead uses a dedicated operator workload identity for Route Server operations, the ARO `machine-api` identity for worker NIC operations, `spec.azure.networkInterfaceClientID` to select that identity, and a CCO-generated operator credential without a client secret.

## Cleanup

Delete dependent routing resources before the shared configuration so finalizers can remove operator-owned cloud state:

```bash
oc delete virtualmachine "$CUDN_VM_NAME" -n "$CUDN_NAMESPACE"
oc delete bgprouting "$BGP_ROUTING_NAME"

oc wait --for=delete \
  clusteruserdefinednetwork/"cluster-udn-${CUDN_NETWORK_NAME}" \
  --timeout=10m

oc delete namespace "$CUDN_NAMESPACE"
oc delete bgpcloudconfiguration cluster
```

Wait until the `BGPCloudConfiguration` finalizer removes the generated FRR configuration and every Route Server peer. Do not force-remove the finalizer or manually delete peers while normal cleanup is running.

Then remove the operator installation, its dedicated identity and role assignment, and only the additive `bgp-cloud-connector` FIC from `machine-api`. Preserve the ARO-managed `machine-api-controllers` FIC until the cluster is deleted.

Before deleting RBAC, distinguish MIWI-specific role assignments and FICs from pre-existing network permissions or ARO resource-provider permissions that may be shared with other resources.

Delete the ARO cluster through `az aro delete`, wait for its managed resource group to disappear, and then remove the nine user-assigned identities and their cluster-specific role assignments. Finally remove Route Server, test infrastructure, and network resources according to their ownership model.

## References

- [BGP Cloud Connector engineering repository](https://github.com/openshift/bgp-cloud-connector)
- [Validated BGP Cloud Connector commit](https://github.com/openshift/bgp-cloud-connector/commit/d317567b54e6d4457246032f952fa6c6b80973c7)
- [Azure authentication in BGP Cloud Connector](https://github.com/openshift/bgp-cloud-connector/blob/d317567b54e6d4457246032f952fa6c6b80973c7/docs/azure-authentication.md)
- [BGP Cloud Connector custom resources](https://github.com/openshift/bgp-cloud-connector/blob/d317567b54e6d4457246032f952fa6c6b80973c7/docs/custom-resources.md)
- [Create ARO with managed identities](https://learn.microsoft.com/azure/openshift/howto-create-openshift-cluster?pivots=aro-deploy-az-cli)
- [Understand ARO managed identities](https://learn.microsoft.com/azure/openshift/howto-understand-managed-identities)
- [Azure Route Server overview](https://learn.microsoft.com/azure/route-server/overview)
- [ARO Classic BGP Cloud Connector lab](https://github.com/diana-sari/aro-virt-bgp)
