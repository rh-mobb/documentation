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
| **ClusterUserDefinedNetwork (CUDN)** with `ipam.lifecycle: Persistent` | A primary Layer 2 network whose IP allocations survive restart and live migration |
| **IPAMClaim** | Pins one specific address to one specific VM, so you choose the address rather than accepting whatever IPAM offers |
| **`l2bridge` network binding** | Gives the guest the real network address (not a NAT address) while remaining live migratable |

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

## 1. Install the BGP Cloud Connector operator

The BGP Cloud Connector advertises your VM network into the AWS VPC route table, so workloads elsewhere in the VPC (and anything reachable through your VPN) can route to the VM address directly.

1. Create the operator namespace and subscription:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      name: bgp-cloud-connector
    ---
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
      name: bgp-cloud-connector
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
      source: redhat-operators
      sourceNamespace: openshift-marketplace
      name: bgp-cloud-connector
      channel: stable
    EOF
    ```

1. Wait for the operator to report `Succeeded`:

    ```bash
    oc get csv -n bgp-cloud-connector -w
    ```

1. Create an **AWS Route Server** in the VPC that hosts your cluster, and associate it with the VPC. Note the route server ID, you need it in the next step.

    ```bash
    aws ec2 create-route-server --amazon-side-asn 65000 --region <region>
    aws ec2 associate-route-server --route-server-id <rs-id> --vpc-id <vpc-id> --region <region>
    ```

1. Label the nodes that will act as BGP routers. These should be your bare metal virtualization nodes:

    ```bash
    oc label node <node-name> bgp_router=true
    ```

1. Create the `BGPCloudConfiguration`:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: networking.openshift.io/v1
    kind: BGPCloudConfiguration
    metadata:
      name: cluster
    spec:
      platform: AWS
      aws:
        region: <region>
        routeServerIDs:
          - <rs-id>
      bgp:
        localASN: 65001
        livenessDetection: bgp-keepalive
      routerNodeSelector:
        bgp_router: "true"
    EOF
    ```

1. Confirm it reaches `Ready`:

    ```bash
    oc get bgpcloudconfigurations.networking.openshift.io cluster \
      -o jsonpath='{.status.phase}{"\n"}'
    ```

## 2. Create the ClusterUserDefinedNetwork

The CUDN is the network your migrated VM will live on. Three properties matter:

* **`role: Primary`** means this network replaces the default pod network for namespaces that match the selector. A VM attached with plain `pod: {}` networking lands on the CUDN automatically, with no Multus or NetworkAttachmentDefinition reference in the VM manifest.
* **`topology: Layer2`** gives a flat broadcast domain across nodes, which is what allows an address to follow a VM between hosts.
* **`ipam.lifecycle: Persistent`** is the critical one. Without it, the VM is handed a fresh address on every restart.

{{< alert state="warning" >}}
Choose a CUDN subnet that does **not** overlap your VPC CIDR, and that contains the addresses of the VMs you intend to migrate. In this guide the VM being migrated has `10.100.0.50`, so the CUDN subnet is `10.100.0.0/16`.
{{< /alert >}}

1. Create the namespace that will hold your VMs, and label it so the CUDN selects it:

    ```bash
    oc new-project vms
    oc label namespace vms cluster-udn=my-cudn
    ```

1. Create the CUDN:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: k8s.ovn.org/v1
    kind: ClusterUserDefinedNetwork
    metadata:
      name: my-cudn
    spec:
      namespaceSelector:
        matchLabels:
          cluster-udn: my-cudn
      network:
        topology: Layer2
        layer2:
          role: Primary
          ipam:
            lifecycle: Persistent
          subnets:
            - 10.100.0.0/16
    EOF
    ```

1. Verify it was created and allocated:

    ```bash
    oc get clusteruserdefinednetwork my-cudn \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
    ```

    ```output
    NetworkCreated=True
    NetworkAllocationSucceeded=True
    ```

1. Advertise the CUDN subnet through BGP:

    ```yaml
    cat << EOF | oc apply -f -
    apiVersion: networking.openshift.io/v1
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

1. Confirm the route appears in your VPC route table:

    ```bash
    aws ec2 describe-route-tables --route-table-id <private-rtb-id> --region <region> \
      --query 'RouteTables[0].Routes[?DestinationCidrBlock==`10.100.0.0/16`]' --output table
    ```

## 3. Install the Migration Toolkit for Virtualization

```yaml
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
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
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: mtv-operator
  channel: release-v2.12
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

## 4. Add the vSphere provider

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
        createdForResource: vcenter
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

`curl` exit code 60 means the peer certificate could not be verified. Setting `insecureSkipVerify` adds `?no_verify=1` to the `vpx://` URL that virt-v2v builds, which clears the failure. Configuring a VDDK image avoids both this issue and the slow transfer described in step 6.
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

1. Confirm the provider connects and populates its inventory:

    ```bash
    oc get provider -n openshift-mtv
    ```

    ```output
    NAME      TYPE        STATUS   READY   CONNECTED   INVENTORY
    host      openshift   Ready    True    True        True
    vcenter   vsphere     Ready    True    True        True
    ```

## 5. Record the VM address you intend to preserve

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

Record that address. It is the value you pin in step 8.

## 6. Create the network and storage maps, and run the migration

{{< alert state="warning" >}}
**Migrate into a namespace that does _not_ have the CUDN label.**

This is counterintuitive, but it matters. In a namespace selected by a **primary** CUDN, every pod receives the CUDN as its default route, including the MTV guest conversion pod. That pod needs to reach vCenter, and the CUDN has no path to your vSphere network, so conversion fails with a connection timeout after roughly two minutes.

Migrate into an ordinary namespace first, then move the disk onto the CUDN in step 7.
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

1. Create the plan. Set `targetPowerState: "off"` so you can pin the address before the VM ever boots:

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

## 7. Clone the converted disk onto the CUDN namespace

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

## 8. Pin the IP address with an IPAMClaim

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

1. Create the IPAMClaim and pin the address. The `network` value is `cluster_udn_` followed by the CUDN name:

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
      network: cluster_udn_my-cudn
    EOF

    oc patch ipamclaim my-vm.default -n vms --subresource=status --type=merge \
      -p '{"status":{"ips":["10.100.0.50/16"]}}'
    ```

1. Start the VM:

    ```bash
    oc patch vm my-vm -n vms --type=merge -p '{"spec":{"runStrategy":"Always"}}'
    ```

## 9. Verify

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

## Known limitations

| Behaviour | Detail |
|---|---|
| **No outbound internet access from the VM** | A VM on a primary Layer 2 CUDN has no north to south egress. Cluster DNS resolution works (the guest resolves through the cluster CoreDNS service address), and east to west traffic to other CUDN workloads works, but outbound connections to the internet time out. Plan for an egress path if your workload needs one |
| **Conversion pods cannot run in a CUDN namespace** | As described in step 6, pods in a primary CUDN namespace lose their route to external networks including vSphere. This is why the migration targets a staging namespace |
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
