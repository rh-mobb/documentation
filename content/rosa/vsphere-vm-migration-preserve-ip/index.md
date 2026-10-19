---
date: '2026-10-19'
title: Migrating vSphere VMs to ROSA HCP with Migration Toolkit for Virtualization while preserving the VM IP address
tags: ["ROSA HCP", "Virtualization"]
authors:
  - Ken Moini
  - Diana Sari
  - Kevin Collins
validated_version: "4.22"
---

When you lift a virtual machine out of vSphere and onto OpenShift Virtualization, the thing that most often breaks is not the disk, it is the address. Firewall rules, DNS records, load balancer members, licence servers, and monitoring targets are all pinned to the IP the VM had in vSphere. Renumbering a VM turns a one hour migration into a multi team change request.

This guide walks through migrating a VM from vSphere to Red Hat OpenShift Service on AWS (ROSA) with hosted control planes, using the Migration Toolkit for Virtualization (MTV), and keeping the VM on its original IP address after the move.

The address is preserved end to end: across the migration itself, across VM restarts, and across live migration between worker nodes.

## What makes IP preservation work

Four pieces have to line up. Missing any one of them produces a VM that either boots with the wrong address or cannot live migrate.

| Piece | Role |
|---|---|
| **BGP Cloud Connector operator** | Advertises the VM network into the AWS VPC route table so the address is reachable from outside the cluster |
| **ClusterUserDefinedNetwork (CUDN)** with `ipam.lifecycle: Persistent` | A primary Layer 2 network whose IP allocations survive restart and live migration. You do not create this by hand, the `BGPRouting` resource generates it |
| **IPAMClaim** | Pins one specific address to one specific VM, so you choose the address rather than accepting whatever IPAM offers |
| **`l2bridge` network binding** | Gives the guest the real network address (not a NAT address) while remaining live migratable |

{{< alert state="info" >}}
The ROSA advanced networking documentation uses `bridge: {}` binding for VMs on an advertised CUDN, and warns that `masquerade` installs nftables rules that drop inbound traffic. Both points hold. This guide uses the **`l2bridge` binding plugin** instead, because plain `bridge` reports `LIVE-MIGRATABLE=False`: KubeVirt requires masquerade or a migration aware binding plugin. If you do not need live migration, `bridge` is the simpler choice.
{{< /alert >}}

### How the layers fit together

It is easy to read "Layer 2 network" and "BGP" together and assume one of them is wrong. Both are accurate, they just describe different halves of the path.

| Where | Layer | What it does |
|---|---|---|
| Inside the cluster | **Layer 2** | The CUDN is a flat broadcast domain for the VM subnet, encapsulated between nodes. This is what lets a VM keep its address when it live migrates, because it never leaves the segment |
| Cluster to AWS | **Layer 3** | BGP advertises the VM subnet as a route into the VPC route table, with a node address as the next hop |

No Layer 2 is extended into AWS, and none needs to be. You can see the split in a ping: traffic between two VMs on the CUDN stays on the same subnet, while a ping from an EC2 instance to a VM arrives with a decremented TTL, because it was routed.

## Prerequisites

* A ROSA cluster with hosted control planes, version 4.22 or later
* The **OpenShift Virtualization** operator installed, with a healthy `HyperConverged` resource. See [Deploying OpenShift Virtualization on ROSA](/experts/rosa/ocp-virt/basic/) if you have not done this yet
* At least **two bare metal worker nodes**. Live migration requires a second eligible node, and only bare metal instance types expose `devices.kubevirt.io/kvm`
* Network connectivity from the cluster to your vSphere environment, for example an AWS Site to Site VPN or Direct Connect
* `oc`, `virtctl`, and the `aws` CLI available locally
* Cluster administrator access

{{< alert state="info" >}}
Check which of your nodes can actually run VMs before you start. Only nodes reporting a `devices.kubevirt.io/kvm` value are eligible:

```bash
oc get nodes -o json | jq -r '.items[] | "\(.metadata.name)  kvm=\(.status.allocatable["devices.kubevirt.io/kvm"] // "none")"'
```
{{< /alert >}}

## 1. Prepare AWS for the BGP Cloud Connector

The BGP Cloud Connector peers your ROSA compute nodes with an **AWS Route Server**, so the VM network is reachable from the VPC without NAT. The Operator generates `FRRConfiguration` resources and disables the source and destination check on the compute node network interfaces.

This section follows the [ROSA advanced networking documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/advanced_networking/index). Refer to it for the authoritative IAM policy contents.

1. Capture the cluster OIDC provider and your account ID:

    ```bash
    OIDC_PROVIDER=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|https://||')
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    ```

1. Create an IAM permission policy for the Operator. It needs `sts:GetCallerIdentity`, `ec2:DescribeRouteServers`, `ec2:DescribeRouteServerEndpoints`, `ec2:DescribeSubnets`, `ec2:DescribeRouteServerPeers`, `ec2:CreateRouteServerPeer`, `ec2:DeleteRouteServerPeer`, `ec2:CreateTags`, `ec2:DescribeInstances`, and `ec2:ModifyNetworkInterfaceAttribute`:

    ```bash
    POLICY_ARN=$(aws iam create-policy \
      --policy-name bgp-cloud-connector-operator-policy \
      --policy-document file://operator-permission-policy.json \
      --query 'Policy.Arn' --output text)
    ```

1. Create a role whose trust policy allows `sts:AssumeRoleWithWebIdentity` from the cluster OIDC provider, scoped to the Operator service account:

    ```json
    "${OIDC_PROVIDER}:sub": "system:serviceaccount:bgp-cloud-connector:openshift-bgp-cloud-connector-controller-manager"
    ```

    ```bash
    aws iam create-role --role-name bgp-cloud-connector-operator \
      --assume-role-policy-document file://operator-trust-policy.json
    aws iam attach-role-policy --role-name bgp-cloud-connector-operator \
      --policy-arn ${POLICY_ARN}
    ```

    {{< alert state="warning" >}}
The Operator cannot create its own IAM role. On ROSA, which always uses STS, you must create this role in advance and pass its ARN to the Operator subscription in step 2.
    {{< /alert >}}

1. Create a security group for BGP peering traffic, and allow TCP 179 outbound and inbound, plus the ephemeral port range `32768-60999` for TCP and UDP. The ephemeral range is needed because return traffic can arrive on a different node:

    ```bash
    BGP_SG_ID=$(aws ec2 create-security-group \
      --group-name "bgp-peering-sg" \
      --description "BGP Cloud Connector peering traffic" \
      --vpc-id <vpc-id> \
      --query 'GroupId' --output text)
    ```

1. Create a machine pool that carries both the security group and the `bgp_router` label. These are the nodes that peer with the Route Server, so use the same bare metal nodes that will run your VMs:

    ```bash
    rosa create machinepool --cluster <cluster-name> \
      --name bgp-workers \
      --availability-zone <az> \
      --additional-security-group-ids ${BGP_SG_ID} \
      --labels "bgp_router=true" \
      --instance-type <bare-metal-type> \
      --replicas 2

    oc get nodes -l bgp_router=true
    ```

    {{< alert state="info" >}}
Apply `bgp_router=true` to **every** node your VMs can land on, not only the nodes you expect to carry ingress traffic. Those nodes act as the next hop and have their source and destination check disabled.
    {{< /alert >}}

1. Create the Route Server, associate it with the VPC, and create an endpoint in each private subnet holding BGP nodes:

    ```bash
    aws ec2 create-route-server --amazon-side-asn <amazon-asn>
    aws ec2 associate-route-server --route-server-id <rs-id> --vpc-id <vpc-id>
    aws ec2 create-route-server-endpoint --route-server-id <rs-id> --subnet-id <subnet-id>
    ```

    AWS permits a maximum of two Route Server endpoints per subnet.

1. Enable route propagation on the route tables for your compute node subnets, and on any subnets providing external connectivity:

    ```bash
    aws ec2 enable-route-server-propagation \
      --route-server-id <rs-id> --route-table-id <route-table-id>
    ```

1. Confirm the subnet network ACLs allow TCP 179 in both directions. Network ACLs are stateless, so a missing return rule silently breaks peering:

    ```bash
    aws ec2 describe-network-acls \
      --filters "Name=association.subnet-id,Values=<subnet-id>" \
      --query "NetworkAcls[].Entries"
    ```

## 2. Install the BGP Cloud Connector Operator

1. Create the namespace and operator group:

    ```bash
    oc create namespace bgp-cloud-connector
    ```

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
      name: bgp-cloud-connector-operatorgroup
      namespace: bgp-cloud-connector
    spec:
      targetNamespaces:
        - bgp-cloud-connector
    EOF
    ```

1. Create the subscription, passing the IAM role ARN from step 1 through the `ROLEARN` environment variable:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
      name: bgp-cloud-connector-operator
      namespace: bgp-cloud-connector
    spec:
      channel: stable
      name: bgp-cloud-connector
      source: redhat-operators
      sourceNamespace: openshift-marketplace
      config:
        env:
          - name: ROLEARN
            value: arn:aws:iam::${AWS_ACCOUNT_ID}:role/bgp-cloud-connector-operator
    EOF
    ```

1. Wait for the Operator to report `Succeeded`:

    ```bash
    oc get csv -n bgp-cloud-connector
    ```

## 3. Configure BGP and create the VM network

The `BGPCloudConfiguration` resource is a cluster scoped singleton and **must** be named `cluster`.

1. Create the BGP configuration. `localASN` must differ from the Amazon side ASN, which is discovered automatically:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: networking.openshift.io/v1beta1
    kind: BGPCloudConfiguration
    metadata:
      name: cluster
    spec:
      platform: AWS
      bgp:
        localASN: 65001
        livenessDetection: bgp-keepalive
      routerNodeSelector:
        bgp_router: "true"
      aws:
        region: <region>
        routeServerIDs:
          - <rs-id>
    EOF
    ```

1. Create the namespace that will hold your VMs. **Both labels must be present when the namespace is created**, because admission rejects adding the user defined network label to an existing namespace:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      name: vms
      labels:
        k8s.ovn.org/primary-user-defined-network: ""
        cluster-udn: my-cudn
    EOF
    ```

    {{< alert state="warning" >}}
Do not use `oc new-project` followed by `oc label` here. The label has to be set at creation time, and retrofitting it fails.
    {{< /alert >}}

1. Create the `BGPRouting` resource. This **generates** the ClusterUserDefinedNetwork for you, so you do not create the CUDN by hand. The `name` under `spec.network` must match the `cluster-udn` label on the namespace:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: networking.openshift.io/v1beta1
    kind: BGPRouting
    metadata:
      name: my-cudn
    spec:
      network:
        name: my-cudn
        subnets:
          - 10.100.0.0/16
    EOF
    ```

    {{< alert state="warning" >}}
Choose a subnet that does **not** overlap your VPC CIDR, and that contains the addresses of the VMs you intend to migrate. In this guide the VM being migrated has `10.100.0.50`, so the subnet is `10.100.0.0/16`. A Layer 2 CUDN permits one IPv4 and one IPv6 CIDR per subnet.
    {{< /alert >}}

1. Verify. The generated network is named `cluster-udn-<network_name>`, and it is created as a primary Layer 2 network with `ipam.lifecycle: Persistent`, which is what allows an address to survive restart and live migration:

    ```bash
    oc get bgpcloudconfiguration cluster -o jsonpath='{.status.phase}{"\n"}'
    oc get bgprouting my-cudn -o jsonpath='{.status.phase}{"\n"}'
    oc get clusteruserdefinednetwork
    oc get routeadvertisements
    oc get frrconfiguration -n openshift-frr-k8s
    ```

    ```output
    Ready
    Ready
    NAME                   AGE
    cluster-udn-my-cudn    1m
    ```

1. Confirm the subnet now appears in the VPC route table:

    ```bash
    aws ec2 describe-route-tables --route-table-id <private-rtb-id> --region <region> \
      --query 'RouteTables[0].Routes[?DestinationCidrBlock==`10.100.0.0/16`]' --output table
    ```
## 4. Install the Migration Toolkit for Virtualization

```yaml
cat << EOF | oc apply -f -
apiVersion: project.openshift.io/v1
kind: Project
metadata:
  name: openshift-mtv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: migration
  namespace: openshift-mtv
spec:
  targetNamespaces:
    - openshift-mtv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mtv-operator
  namespace: openshift-mtv
spec:
  channel: release-v2.12
  installPlanApproval: Automatic
  name: mtv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

Then create the controller:

```yaml
cat << EOF | oc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: ForkliftController
metadata:
  name: forklift-controller
  namespace: openshift-mtv
spec:
  olm_managed: true
EOF
```

Wait for the MTV pods to come up:

```bash
oc get pods -n openshift-mtv
```

## 5. Add the vSphere provider

1. Retrieve your vCenter CA certificate. From the vCenter appliance, or by downloading `https://<vcenter>/certs/download.zip`.

1. Create the credentials secret:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: v1
    kind: Secret
    metadata:
      name: vcenter-credentials
      namespace: openshift-mtv
      labels:
        createdForResourceType: providers
        createdForProviderType: vsphere
    type: Opaque
    stringData:
      user: 'administrator@vsphere.local'
      password: '<password>'
      insecureSkipVerify: 'true'
      url: 'https://vcenter.example.com/sdk'
      cacert: |
        -----BEGIN CERTIFICATE-----
        <your vCenter CA certificate>
        -----END CERTIFICATE-----
    EOF
    ```

    {{< alert state="warning" >}}
**Why `insecureSkipVerify: 'true'`.** When no VDDK image is configured, MTV falls back to downloading the VMDK over HTTPS using `nbdkit` and `curl`. In that path the CA certificate from the secret is mounted into the conversion pod but is not applied to the `curl` transport, and guest conversion fails with:

```text
virt-v2v: error: downloading https://vcenter.example.com/folder/...vmdk:
external command 'curl ...': exited with error 60
```

`curl` exit code 60 means the peer certificate could not be verified. Setting `insecureSkipVerify` adds `?no_verify=1` to the `vpx://` URL that virt-v2v builds, which clears the failure. Configuring a VDDK image avoids both this issue and the slow transfer described in step 7.
    {{< /alert >}}

1. Create the provider:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: forklift.konveyor.io/v1beta1
    kind: Provider
    metadata:
      name: vcenter
      namespace: openshift-mtv
    spec:
      type: vsphere
      url: https://vcenter.example.com/sdk
      settings:
        sdkEndpoint: vcenter
      secret:
        name: vcenter-credentials
        namespace: openshift-mtv
    EOF
    ```

    {{< alert state="warning" >}}
**Consider building a VDDK image before you migrate anything.** This guide does not use one, which is why the transfer in step 7 is slow and why the TLS workaround above is needed at all. The MTV documentation is firm on the point: creating the image is optional but "highly recommended", and "using MTV without VDDK is not recommended and could result in significantly lower migration speeds."

It is not always optional. **You must use a VDDK image if the source VMs are backed by VMware vSAN.**

To use one, build and push the image per the MTV documentation, then set it on the provider:

```yaml
spec:
  settings:
    sdkEndpoint: vcenter
    vddkInitImage: <registry_path>/vddk:<tag>
```

Note that storing the VDDK image in a public registry might violate VMware licence terms.
    {{< /alert >}}

1. Confirm the provider connects and populates its inventory:

    ```bash
    oc get provider -n openshift-mtv
    ```

    ```output
    NAME      TYPE        STATUS   READY   CONNECTED   INVENTORY
    host      openshift   Ready    True    True        True
    vcenter   vsphere     Ready    True    True        True
    ```

## 6. Record the VM address you intend to preserve

Query the MTV inventory for the source VM. The guest address comes from VMware Tools, so capture it **before** powering the VM off.

```bash
PROVIDER_UID=$(oc get provider vcenter -n openshift-mtv -o jsonpath='{.metadata.uid}')
TOKEN=$(oc whoami -t)

oc exec -n openshift-mtv deploy/forklift-controller -- \
  curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://forklift-inventory.openshift-mtv.svc:8443/providers/vsphere/${PROVIDER_UID}/vms?detail=4" \
  | jq -r '.[] | select(.name=="my-vm") | .guestNetworks[]? | "\(.ip)/\(.prefix) mac=\(.mac)"'
```

```output
10.100.0.50/16 mac=00:50:56:bc:09:a3
```

Record that address. It is the value you pin in step 9.

## 7. Create the network and storage maps, and run the migration

{{< alert state="warning" >}}
**Migrate into a namespace that does _not_ have the CUDN label.**

This is counterintuitive, but it matters. In a namespace selected by a **primary** CUDN, every pod receives the CUDN as its default route, including the MTV guest conversion pod. That pod needs to reach vCenter, and the CUDN has no path to your vSphere network, so conversion fails with a connection timeout after roughly two minutes.

Migrate into an ordinary namespace first, then move the disk onto the CUDN in step 8.
{{< /alert >}}

1. Create a staging namespace:

    ```bash
    oc new-project vm-staging
    ```

1. Create the maps. Map the source network to `pod`, and the source datastore to a storage class:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: forklift.konveyor.io/v1beta1
    kind: NetworkMap
    metadata:
      name: my-vm-network-map
      namespace: openshift-mtv
    spec:
      provider:
        source:
          name: vcenter
          namespace: openshift-mtv
        destination:
          name: host
          namespace: openshift-mtv
      map:
        - source:
            name: <source-port-group>
          destination:
            type: pod
    ---
    apiVersion: forklift.konveyor.io/v1beta1
    kind: StorageMap
    metadata:
      name: my-vm-storage-map
      namespace: openshift-mtv
    spec:
      provider:
        source:
          name: vcenter
          namespace: openshift-mtv
        destination:
          name: host
          namespace: openshift-mtv
      map:
        - source:
            name: <source-datastore>
          destination:
            storageClass: gp3-csi
            accessMode: ReadWriteOnce
            volumeMode: Block
    EOF
    ```

1. Power off the source VM in vSphere. Cold migration requires it.

1. Create the plan. Set `targetPowerState: "off"` so you can pin the address before the VM ever boots. The accepted values are `off`, `on`, and `auto`, where `auto` preserves the power state of the source VM. It can also be set per VM under `spec.vms` if a single plan carries VMs that should end up in different states:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: forklift.konveyor.io/v1beta1
    kind: Plan
    metadata:
      name: my-vm-plan
      namespace: openshift-mtv
    spec:
      type: cold
      targetNamespace: vm-staging
      targetPowerState: "off"
      targetNodeSelector:
        mobb.redhat.com/virtualization: "true"
      preserveStaticIPs: false
      provider:
        source:
          name: vcenter
          namespace: openshift-mtv
        destination:
          name: host
          namespace: openshift-mtv
      map:
        network:
          name: my-vm-network-map
          namespace: openshift-mtv
        storage:
          name: my-vm-storage-map
          namespace: openshift-mtv
      vms:
        - name: my-vm
    EOF
    ```

1. Start the migration:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: forklift.konveyor.io/v1beta1
    kind: Migration
    metadata:
      name: my-vm-migration
      namespace: openshift-mtv
    spec:
      plan:
        name: my-vm-plan
        namespace: openshift-mtv
    EOF
    ```

1. Watch progress:

    ```bash
    oc get migration my-vm-migration -n openshift-mtv -o json | \
      jq -r '.status.vms[]? | "phase=\(.phase)", (.pipeline[]? | "  \(.name): \(.phase)")'
    ```

<details>
<summary>Why this takes so long, and how to speed it up</summary>

Cold migration pulls the entire disk across your link to vSphere. Two phases dominate:

| Phase | What it does | Typical rate over a VPN |
|---|---|---|
| `ConvertGuest` | Inspects the guest filesystem and rebuilds the initramfs with virtio drivers using `dracut` | Very slow, it is latency bound rather than bandwidth bound, because it issues many small random reads across the link |
| `CopyDisksVirtV2V` | Sequential copy of the converted disk | Closer to your link bandwidth |

On a 16 GiB Fedora VM across a Site to Site VPN with around 72 ms round trip, conversion ran at roughly 0.13 MB/s for 40 minutes, and the disk copy at roughly 1.75 MB/s, for about 85 minutes in total.

**Configuring a VDDK image is the single biggest improvement.** Without it MTV uses the `nbdkit` curl transport over HTTPS, which is markedly slower, especially during the random access conversion phase. Building a VDDK init image is a one time task that pays back on every migration afterwards.

</details>

## 8. Clone the converted disk onto the CUDN namespace

The converted disk now lives in the staging namespace. Clone it into the CUDN namespace, and take the opportunity to place it on RWX storage so the VM can live migrate.

```yaml
cat << EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: my-vm-root
  namespace: vms
spec:
  source:
    pvc:
      namespace: vm-staging
      name: <migrated-pvc-name>
  storage:
    accessModes: [ReadWriteMany]
    volumeMode: Filesystem
    resources:
      requests:
        storage: 16Gi
    storageClassName: trident-csi
EOF
```

{{< alert state="info" >}}
`ReadWriteMany` is required for live migration. On ROSA, Amazon FSx for NetApp ONTAP with the Trident CSI driver provides RWX. See [Deploying OpenShift Virtualization on ROSA with NetApp FSx storage](/experts/rosa/ocp-virt/with-fsx/) for how to set that up.
{{< /alert >}}

Wait for the clone:

```bash
oc get dv my-vm-root -n vms -w
```

## 9. Pin the IP address with an IPAMClaim

Persistent IPAM records each allocation in an `IPAMClaim` named `<vm-name>.<interface-name>`. Create that claim yourself, before the VM first boots, and the VM receives exactly the address you choose.

1. Create the VM in a stopped state:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: my-vm
      namespace: vms
    spec:
      runStrategy: Halted
      template:
        metadata:
          labels:
            kubevirt.io/domain: my-vm
        spec:
          nodeSelector:
            mobb.redhat.com/virtualization: "true"
          domain:
            cpu:
              cores: 2
            memory:
              guest: 2Gi
            firmware:
              bootloader:
                efi:
                  secureBoot: false
            devices:
              disks:
                - name: rootdisk
                  bootOrder: 1
                  disk:
                    bus: virtio
              interfaces:
                - name: default
                  binding:
                    name: l2bridge
          networks:
            - name: default
              pod: {}
          volumes:
            - name: rootdisk
              persistentVolumeClaim:
                claimName: my-vm-root
    EOF
    ```

    Two fields in that manifest are easy to miss and both will cost you time:

    {{< alert state="warning" >}}
**Match the firmware to the source VM.** If the vSphere VM booted with UEFI and you omit the `firmware.bootloader.efi` stanza, the VM falls back to legacy BIOS and hangs at `SeaBIOS: Booting from Hard Disk...` with no further output. Check what MTV detected on the VM it generated in the staging namespace:

```bash
oc get vm my-vm -n vm-staging -o jsonpath='{.spec.template.spec.domain.firmware}{"\n"}'
```

**Use the `l2bridge` binding, not `bridge`.** Plain `bridge: {}` gives the guest the correct address but reports `LIVE-MIGRATABLE=False`, because KubeVirt requires masquerade or a migration aware binding plugin. `masquerade` is migratable but hides the real address behind NAT inside the guest. The `l2bridge` binding plugin gives you both.
    {{< /alert >}}

1. Create the IPAMClaim and pin the address.

    The `network` value is `cluster_udn_` followed by the **full generated CUDN name**, which itself begins with `cluster-udn-`. For a `BGPRouting` named `my-cudn`, the CUDN is `cluster-udn-my-cudn`, so the value is `cluster_udn_cluster-udn-my-cudn`. Confirm it rather than assuming:

    ```bash
    oc get clusteruserdefinednetwork -o name
    ```

    ```bash
    VM_UID=$(oc get vm my-vm -n vms -o jsonpath='{.metadata.uid}')

    cat << EOF | oc apply -f -
    apiVersion: k8s.cni.cncf.io/v1alpha1
    kind: IPAMClaim
    metadata:
      name: my-vm.default
      namespace: vms
      finalizers:
        - kubevirt.io/persistent-ipam
      ownerReferences:
        - apiVersion: kubevirt.io/v1
          kind: VirtualMachine
          name: my-vm
          uid: ${VM_UID}
          controller: true
          blockOwnerDeletion: true
    spec:
      interface: ""
      network: cluster_udn_cluster-udn-my-cudn
    EOF

    oc patch ipamclaim my-vm.default -n vms --subresource=status --type=merge \
      -p '{"status":{"ips":["10.100.0.50/16"]}}'
    ```

1. Start the VM:

    ```bash
    oc patch vm my-vm -n vms --type=merge -p '{"spec":{"runStrategy":"Always"}}'
    ```

## 10. Verify

1. The VM should come up on the original address:

    ```bash
    oc get vmi my-vm -n vms -o wide
    ```

    ```output
    NAME    PHASE     IP            NODENAME       READY   LIVE-MIGRATABLE
    my-vm   Running   10.100.0.50   worker-1       True    True
    ```

1. Confirm the address from **inside** the guest, not just from the OVN port configuration. If `infoSource` includes `guest-agent`, the guest itself is reporting it:

    ```bash
    oc get vmi my-vm -n vms -o json | \
      jq -r '.status.interfaces[] | "ip=\(.ipAddress) mac=\(.mac) src=\(.infoSource)"'
    ```

    ```output
    ip=10.100.0.50 mac=0a:58:0a:64:00:32 src=domain, guest-agent
    ```

    {{< alert state="info" >}}
OVN derives the MAC address from the IP address on a Layer 2 CUDN. Here `0a:58:` is the OVN prefix and `0a:64:00:32` is `10.100.0.50` in hexadecimal. The guest MAC therefore changes from the vSphere value, while the IP address is preserved.
    {{< /alert >}}

1. Confirm the VM is reachable from elsewhere in the VPC, which proves the BGP advertisement is working:

    ```bash
    ping 10.100.0.50
    ```

1. Live migrate, and confirm the address survives:

    ```bash
    virtctl migrate my-vm -n vms
    ```

    Run a continuous ping from another host in the VPC while the migration happens. A successful run shows the node change with no packet loss and no change to the IP or MAC:

    ```output
    PRE : node=worker-2  ip=10.100.0.50  mac=0a:58:0a:64:00:32
    POST: node=worker-1  ip=10.100.0.50  mac=0a:58:0a:64:00:32
    60 packets transmitted, 60 received, 0% packet loss
    ```

## 11. Enable outbound internet access with an EgressIP

Out of the box, a VM on an advertised CUDN cannot reach the internet, although cluster DNS and east to west traffic both work. The reason is worth understanding before you fix it.

When OVN-Kubernetes advertises a network over BGP, it **disables SNAT** for that network. That is deliberate: the point of advertising the network is that the VM's real address is routable, so masquerading it would defeat the purpose. The VM therefore sends packets to the internet with a source address of `10.100.0.50`, which leaves the node (the BGP operator disables the EC2 source and destination check for exactly this reason) and reaches the VPC route for `0.0.0.0/0`, pointing at the NAT gateway.

An AWS NAT gateway only translates traffic whose source falls inside the VPC CIDR. `10.100.0.50` is outside `10.20.0.0/16`, so the NAT gateway discards it.

This also explains the apparent contradiction where DNS works but the internet does not: cluster DNS lives on the service network and is resolved inside the OVN overlay, so it never reaches the VPC or the NAT gateway at all.

The fix is an **EgressIP** from the VPC CIDR. Outbound traffic is then SNATed to an address the NAT gateway will translate, while inbound traffic to the VM address continues to work unchanged.

1. Pick an unused address inside the subnet your worker nodes sit in, and confirm it is free:

    ```bash
    aws ec2 describe-network-interfaces --region <region> \
      --filters "Name=addresses.private-ip-address,Values=10.20.15.200" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
    ```

1. Label the nodes allowed to host egress addresses. Using your general worker nodes keeps the virtualization nodes free:

    ```bash
    oc label node <worker-node> k8s.ovn.org/egress-assignable=""
    ```

1. Create the `EgressIP`, selecting the namespace holding your VMs:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: k8s.ovn.org/v1
    kind: EgressIP
    metadata:
      name: vms-egress
    spec:
      egressIPs:
        - 10.20.15.200
      namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: vms
    EOF
    ```

1. Confirm it was assigned to a node:

    ```bash
    oc get egressip
    ```

    ```output
    NAME         EGRESSIPS      ASSIGNED NODE   ASSIGNED EGRESSIPS
    vms-egress   10.20.15.200   worker-2        10.20.15.200
    ```

1. Confirm the cloud network config controller attached it to the node network interface in AWS:

    ```bash
    aws ec2 describe-network-interfaces --region <region> \
      --filters "Name=addresses.private-ip-address,Values=10.20.15.200" \
      --query 'NetworkInterfaces[].[NetworkInterfaceId,Attachment.InstanceId]' --output text
    ```

1. From inside the VM, outbound traffic now works, and the source address seen by the internet is your NAT gateway public address:

    ```bash
    curl -4 -s -o /dev/null -w '%{http_code}\n' https://1.1.1.1/
    curl -4 -s https://ifconfig.me
    ```

Inbound reachability, DNS, east to west traffic, and live migration are all unaffected by this change.

## Known limitations

| Behaviour | Detail |
|---|---|
| **Conversion pods cannot run in a CUDN namespace** | As described in step 7, pods in a primary CUDN namespace lose their route to external networks including vSphere. This is why the migration targets a staging namespace |
| **Guest MAC address changes** | OVN derives the MAC from the IP on a Layer 2 CUDN. If your workload is licensed against a MAC address, test this before committing to a migration window |
| **Serial console may be unavailable** | VMs installed from an ISO in vSphere typically lack `console=ttyS0` on the kernel command line, so `virtctl console` shows nothing. Use `virtctl vnc`, or the VNC screenshot API, to see the guest console |

{{< alert state="info" >}}
The VNC screenshot API is useful for non interactive troubleshooting, for example confirming whether a VM is actually booting:

```bash
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  "$(oc whoami --show-server)/apis/subresources.kubevirt.io/v1/namespaces/vms/virtualmachineinstances/my-vm/vnc/screenshot?moveCursor=false" \
  -o screenshot.png
```
{{< /alert >}}

## Cleanup

Once you are satisfied the migrated VM is healthy, remove the staging copy:

```bash
oc delete vm my-vm -n vm-staging
oc delete project vm-staging
```
