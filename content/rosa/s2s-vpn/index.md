---
date: '2025-10-10'
title: Ingress to ROSA Virt VMs with Certificate-Based Site-to-Site (S2S) IPsec VPN and Libreswan
tags: ["AWS", "ROSA"]
authors:
  - Diana Sari
  - Daniel Axelrod
---


## Introduction

In this guide, we build a [Site-to-Site (S2S) VPN](https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html) so an Amazon [VPC](https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html) can reach VM IPs on a ROSA OpenShift Virtualization [User-Defined Network (UDN/CUDN)](https://www.redhat.com/en/blog/user-defined-networks-red-hat-openshift-virtualization)—with **no per-VM NAT or load balancers**. We deploy a small CentOS VM inside the cluster running [Libreswan](https://github.com/libreswan/libreswan) that establishes [IPsec/IKEv2 tunnel](https://aws.amazon.com/what-is/ipsec/) to an AWS [Transit Gateway (TGW)](https://docs.aws.amazon.com/whitepapers/latest/aws-vpc-connectivity-options/aws-transit-gateway.html).

We use [certificate-based authentication](https://docs.aws.amazon.com/vpn/latest/s2svpn/vpn-tunnel-authentication-options.html#certificate): the AWS [Customer Gateway (CGW)](https://docs.aws.amazon.com/vpn/latest/s2svpn/your-cgw.html) references a certificate issued by [ACM Private CA](https://docs.aws.amazon.com/privateca/latest/userguide/PcaWelcome.html), and the cluster VM uses the matching device certificate. Because identities are verified by certificates—not a fixed public IP—the VM can **initiate** the VPN **from behind NAT** (worker → NAT Gateway) and still form stable tunnels.

On AWS, the **TGW** terminates **two redundant tunnels** (two “outside” IPs). We associate the **VPC attachment(s)** and the **VPN attachment** with a TGW route table and enable **propagation** as needed. In the VPC, route tables send traffic for the CUDN prefix (e.g., `192.168.1.0/24`) **to the TGW**. On the cluster side, the CUDN has **IPAM disabled**; you can optionally add a **return route** on other CUDN workloads to use the IPsec VM as next hop when those workloads need to reach the VPC.

NAT specifics: when the VM egresses, it traverses the [NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html). If that NAT uses multiple EIPs, AWS may select different EIPs per connection; this is fine because the VPN authenticates via certificates, not source IP.


![s2svpn-v0](images/s2svpn-v0.png)
<br />


## Why this approach

* **Direct, routable access to VMs**: UDN/CUDN addresses are reachable from the VPC without per-VM LBs or port maps, so existing tools (SSH/RDP/agents) work unmodified.
* **Cert-based, NAT-friendly**: The cluster peer authenticates with a **device certificate**, so it can sit **behind NAT**; no brittle dependence on a static egress IP, and **no PSKs** to manage.I
* **AWS-native and minimally invasive**: Uses TGW, CGW (certificate), and standard route tables—no changes to managed ROSA networking, and no inbound exposure (no NLB/NodePorts) because the **VM initiates**.
* **Scales and hardens cleanly**: Add a second IPsec VM in another AZ for HA, advertise additional prefixes, or introduce dynamic routing later. As BGP-based UDN routing matures, you can evolve without re-architecting.

In short: this is a practical and maintainable way to reach ROSA-hosted VMs **without PSKs**, **without a static public IP**, and **without a fleet of load balancers**.


## 0. Prerequisites

* A classic or HCP ROSA cluster v4.14 and above.
* The oc CLI # logged in.


## 1. Install bare metal instance

You can install the bare metal instance via Red Hat Hybrid Cloud Console. Alternatively, you can follow this step to install via CLI.  

First, export the variables. Replace the region and cluster name values with your own.

```bash
export REGION=YOUR-CLUSTER-REGION
export CLUSTER=YOUR-CLUSTER-NAME
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
SUBNETS=$(aws ec2 describe-subnets --region $REGION \
  --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned,shared" \
  --query 'join(`,`, Subnets[?MapPublicIpOnLaunch==`false`].SubnetId)' \
  --output text)
echo "INFRA_ID=$INFRA_ID"
echo "SUBNETS=$SUBNETS"
```

Then create the machinepool. You can also use another supported metal instance if you like.

```bash
rosa create machinepool \
  --cluster $CLUSTER \
  --name cnv-bm \
  --replicas 2 \
  --instance-type m5.metal \
  --subnet-ids "$SUBNETS" \
  --labels kubevirt.io/schedulable=true,workload=cnv \
  --taints dedicated=cnv:NoSchedule
```

Wait for nodes, then verify KVM on one of the new nodes:

```bash
oc get nodes -l workload=cnv -o wide
oc debug node/$(oc get nodes -l workload=cnv -o name | head -1 | cut -d/ -f2) -- chroot /host bash -c 'ls -l /dev/kvm && lsmod | egrep "^kvm"'
```


## 2. Install OpenShift Virtualization (CNV)

You can install the operator via OperatorHub. Alternatively, you can follow this step to install via CLI.

```bash
cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces: [openshift-cnv]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: stable
EOF
```

Once the operator is installed, create the HyperConverged object.


```bash
cat << 'EOF' | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
  annotations:
    deployOVS: "false"
  labels:
    app: kubevirt-hyperconverged
spec:
  enableApplicationAwareQuota: false
  enableCommonBootImageImport: true
  deployVmConsoleProxy: false
  applicationAwareConfig:
    allowApplicationAwareClusterResourceQuota: false
    vmiCalcConfigName: DedicatedVirtualResources
  certConfig:
    ca: {duration: 48h0m0s, renewBefore: 24h0m0s}
    server: {duration: 24h0m0s, renewBefore: 12h0m0s}
  evictionStrategy: LiveMigrate
  infra: {}
  liveMigrationConfig:
    allowAutoConverge: false
    allowPostCopy: false
    completionTimeoutPerGiB: 800
    parallelMigrationsPerCluster: 5
    parallelOutboundMigrationsPerNode: 2
    progressTimeout: 150
  resourceRequirements:
    vmiCPUAllocationRatio: 10
  uninstallStrategy: BlockUninstallIfWorkloadsExist
  virtualMachineOptions:
    disableFreePageReporting: false
    disableSerialConsoleLog: true
  workloadUpdateStrategy:
    batchEvictionInterval: 1m0s
    batchEvictionSize: 10
    workloadUpdateMethods: [LiveMigrate]
  workloads: {}
EOF
```


## 3. Create the project and secondary network (CUDN)

Create `vpn-infra` project and the ClusterUserDefinedNetwork (CUDN) object.

```bash
oc new-project vpn-infra
cat << 'EOF' | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: vm-network
spec:
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: In
      values: [vpn-infra, vm-workloads]
  network:
    layer2:
      role: Secondary
      ipam:
        mode: Disabled
    topology: Layer2
EOF
```

(Optional but handy on some versions): create a **reference NAD** so Multus can resolve `vm-network` by name in the namespace:

```bash
cat <<'EOF' | oc -n vpn-infra apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vm-network
spec:
  reference: k8s.ovn.org/v1/ClusterUserDefinedNetwork/vm-network
EOF
```


## 4. Create ipsec VM (cert-based IPsec, NAT-initiated)

First, create the cloud-init Secret object that will be referenced by the VM.

```bash
cat > /tmp/ipsec-cloudinit-userdata <<'EOD'
#cloud-config
ssh_pwauth: false
write_files:
  - path: /etc/sysctl.d/99-ipsec-forwarding.conf
    permissions: '0644'
    content: |
      net.ipv4.ip_forward=1
      net.ipv4.conf.all.rp_filter=2
      net.ipv4.conf.default.rp_filter=2
      net.ipv4.conf.all.accept_redirects=0
      net.ipv4.conf.default.accept_redirects=0
      net.ipv4.conf.all.send_redirects=0
      net.ipv4.conf.default.send_redirects=0
  - path: /root/left-cert.p12.b64
    permissions: '0600'
    content: |
      <BASE64_PKCS12_DEVICE_CERT_AND_KEY>
  - path: /etc/ipsec.d/aws-ca.pem
    permissions: '0644'
    content: |
      <AWS_VPN_CA_PEM>
  - path: /etc/ipsec.conf
    permissions: '0644'
    content: |
      config setup
        uniqueids=no
      conn aws-tun-1
        ikev2=insist
        authby=rsa
        leftrsasigkey=%cert
        rightrsasigkey=%cert
        left=%defaultroute
        leftid=@<LEFT_ID_FQDN_OR_DN>
        leftcert=<LEFT_CERT_NICKNAME>
        leftsubnet=<CUDN_SUBNET>
        right=<AWS_TUNNEL_1_PUBLIC_IP>
        rightid=%fromcert
        rightsubnet=<AWS_VPC_CIDR>
        ike=aes256-sha2_256-modp2048
        phase2alg=aes256-sha2_256
        dpdaction=restart
        dpddelay=15s
        dpdtimeout=120s
        auto=add
      conn aws-tun-2
        also=aws-tun-1
        right=<AWS_TUNNEL_2_PUBLIC_IP>
runcmd:
  - [ bash, -lc, "dnf -y install libreswan nss-tools NetworkManager iproute" ]
  - [ bash, -lc, "sysctl --system" ]
  - [ bash, -lc, "pif=$(ip r s default|awk '{print $5}'|head -1||true); for d in $(ls /sys/class/net|grep -v lo); do [ $d = $pif ] && continue; ip -4 a s $d|grep -q 'inet ' && continue; nmcli con add type ethernet ifname $d con-name cudn; nmcli con mod cudn ipv4.addresses <CUDN_VM_IP/24> ipv4.method manual autoconnect yes 802-3-ethernet.mtu 1400; nmcli con up cudn || true; done" ]
  - [ bash, -lc, "certutil -A -d sql:/etc/ipsec.d -n aws-ca -t 'C,,' -a -i /etc/ipsec.d/aws-ca.pem" ]
  - [ bash, -lc, "base64 -d /root/left-cert.p12.b64 > /root/left-cert.p12" ]
  - [ bash, -lc, "pk12util -i /root/left-cert.p12 -d sql:/etc/ipsec.d -W '<P12_PASSWORD_OR_EMPTY>' -n '<LEFT_CERT_NICKNAME>' || true" ]
  - [ bash, -lc, "rm -f /root/left-cert.p12 /root/left-cert.p12.b64" ]
  - [ bash, -lc, "systemctl enable --now ipsec" ]
EOD

oc -n vpn-infra create secret generic ipsec-cloudinit --from-file=userData=/tmp/ipsec-cloudinit-userdata
```

Next, create the `ipsec` VM referencing the above Secret.

```bash
cat << 'EOF' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ipsec
  namespace: vpn-infra
  labels:
    app: ipsec
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: ipsec
        kubevirt.io/domain: ipsec
    spec:
      nodeSelector:
        workload: "cnv"
      tolerations:
      - key: "dedicated"
        operator: "Equal"
        value: "cnv"
        effect: "NoSchedule"
      domain:
        cpu:
          cores: 2
        resources:
          requests:
            memory: 2Gi
        devices:
          interfaces:
          - name: default
            masquerade: {}
          - name: cudn
            bridge: {}
          disks:
          - name: root
            disk:
              bus: virtio
          - name: cloudinit
            disk:
              bus: virtio
      networks:
      - name: default
        pod: {}
      - name: cudn
        multus:
          networkName: vm-network
      volumes:
      - name: root
        containerDisk:
          image: quay.io/containerdisks/centos-stream:9
      - name: cloudinit
        cloudInitNoCloud:
          secretRef:
            name: ipsec-cloudinit
EOF
```

Run the following quick checks before we move on to AWS Console for next steps.

```bash
oc -n vpn-infra get vmi,pod -l app=ipsec -o wide
oc -n vpn-infra virt console vm/ipsec
# inside VM:
ip a
ip r
ss -uap | egrep ':(500|4500)\s' || true
```


## 5. Create a Private CA (ACM PCA)

This step involved a console path and quick CLI blocks so your CGW can use a cert and your VM gets a PKCS#12.

* Console (one-time):

  * Certificate Manager → **Private CAs** → **Create** → **Root** → RSA-2048 / SHA256 → fill subject → **Create & activate**.
  * Copy the **CA ARN** (you’ll use it below).
* Device cert & PKCS#12 for the VM (paste as a code block under this section):

  * “Block A — Issue device cert & make PKCS#12 (for VM)”
  * “Block B — Import same cert into ACM (for CGW selection)”


asdf (WIP)

[SCREENSHOT HERE]


## 6. Create a Customer Gateway (CGW) 

Go to VPC console → **VPN → Customer gateways → Create** → **Certificate** option → choose your ACM-PCA–issued cert. Note that `leftid` in the VM must match the certificate identity you issued.

[SCREENSHOT HERE]

With certificate-auth, AWS doesn’t require a fixed public IP on the CGW; that’s why this pattern works behind NAT. 


## 7. Create (or use) a Transit Gateway (TGW)

VPC console → **Transit Gateways → Create** (set ASN, DNS support on). 

[SCREENSHOT HERE]


## 8. Attach the VPC(s) to the TGW

VPC console → **Transit Gateway attachments → Create attachment → VPC** (pick the VPC/subnets you want reachable from the cluster). 

[SCREENSHOT HERE]


## 9. Create the Site-to-Site VPN (Target = TGW)

VPC console → **VPN connections → Create**

* **Target**: your TGW
* **Customer gateway**: the certificate-based CGW from previous step.
* **Tunnel options**: prefer **IKEv2** and **2 tunnels**; leave defaults unless you need specific ciphers.

[SCREENSHOT HERE]


## 10. Associate VPC to TGW route tables

* **Associate** your VPC attachment(s) to a TGW route table.
* **Associate** the new **VPN attachment** to the same TGW route table.
* **Enable propagation** from the **VPN** into that TGW route table (and from VPCs if you want their CIDRs to auto-show up).
  This lets BGP (if you enable it) or static routes populate the TGW RT. 

  [SCREENSHOT HERE]


## 11. Modify VPC route tables

In each VPC that should reach the cluster overlay (your CUDN), add a route:

* **Destination**: your CUDN subnet (e.g., `192.168.1.0/24`)
* **Target**: the **TGW attachment**
  (BGP can also advertise it if you prefer dynamic routing.) 

  [SCREENSHOT HERE]


## 12. Network policy & test access

* **Security groups**

  * **Test EC2 SG (in the VPC you attached):**

    * Inbound: ICMP from your **CUDN** (e.g., `192.168.1.0/24`)
    * (Optional) TCP 22/80 from `192.168.1.0/24` for SSH/curl tests

[SCREENSHOT HERE]

  
* **Optional “return route” for other CUDN workloads**

  * Only if **other** VMs/pods on the CUDN must reach the VPC **via the ipsec VM**:

    ```bash
    sudo ip route add <VPC_CIDR> via 192.168.1.10
    nmcli connection modify cudn +ipv4.routes "<VPC_CIDR> 192.168.1.10"
    nmcli connection up cudn
    ```


## 13. Download the VPN device config (for reference)

VPN connection → **Download configuration** → **Libreswan / Generic**.
You’ll copy the **tunnel outside IPs** into `right=` and confirm IKE params.

[SCREENSHOT HERE]


## 14. Egress sanity

Ensure cluster egress allows UDP **500/4500** to the **two tunnel outside IPs**.

[SCREENSHOT HERE]


## 15. Bring up tunnels & verify

* On the ipsec VM:

  ```bash
  sudo ipsec up aws-tun-1
  sudo ipsec status
  ```
* Quick tests:

  ```bash
  # from AWS EC2 (e.g., 10.10.0.10) to CUDN:
  ping -c3 192.168.1.10
  # from ipsec VM to EC2:
  ping -I 192.168.1.10 -c3 10.10.0.10
  ```
* Deep-dive:

  ```bash
  sudo ip xfrm policy
  sudo ip xfrm state
  sudo ipsec whack --trafficstatus
  sudo timeout 6 sh -c "tcpdump -ni any 'udp port 4500 or esp' & ping -c3 -W2 -I 192.168.1.10 10.10.0.10 >/dev/null"
  ```
* Failover:

  ```bash
  sudo ipsec down aws-tun-1
  sudo ipsec up aws-tun-2
  sudo ipsec status
  ```

[SCREENSHOT HERE]


## 16. Troubleshooting quick hits (optional)

These are some troubleshooting steps if needed.

```bash
# remove accidental static next-hop on the ipsec VM (traffic should match xfrm SAs)
sudo ip route del <VPC_CIDR> || true

# normalize perms/labels
sudo sed -i -e 's/\r$//' /etc/ipsec.conf /etc/ipsec.d/*.conf /etc/ipsec.d/*.secrets 2>/dev/null
sudo chmod 644 /etc/ipsec.d/*.conf 2>/dev/null || true
sudo chmod 600 /etc/ipsec.secrets /etc/ipsec.d/*.secrets 2>/dev/null || true
sudo restorecon -Rv /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d >/dev/null

# temporarily relax RPF during asymmetry debug
echo -e "net.ipv4.conf.all.rp_filter=0\nnet.ipv4.conf.default.rp_filter=0" | sudo tee /etc/sysctl.d/99-ipsec-debug.conf
sudo sysctl -p /etc/sysctl.d/99-ipsec-debug.conf
```
