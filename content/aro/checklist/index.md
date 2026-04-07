---
date: '2026-03-26'
title: Azure Red Hat OpenShift - Day 1 & Day 2 Operations Checklist
tags: ["ARO"]
authors:
  - Kevin Collins
  - Kumudu Herath
---

This comprehensive checklist covers critical planning and operational tasks for Azure Red Hat OpenShift (ARO) clusters, from initial planning through ongoing operations.

## Best Practices Summary

**Recommended for Production Environments:**

- ✅ **Private Clusters**: Deploy with `--apiserver-visibility Private --ingress-visibility Private` for better security
- ✅ **Managed Identity**: Use Azure managed identities instead of service principals (no credential rotation required)
- ✅ **BYO NSG**: Pre-create Network Security Groups for compliance and security control
- ✅ **Custom Domains**: Use organization domains with trusted TLS certificates
- ✅ **Infrastructure Nodes**: Dedicate nodes for cluster infrastructure workloads
- ✅ **OpenShift Data Foundation**: For self-managed persistent storage
- ✅ **Multi-AZ**: Leverage Azure Availability Zones for high availability
- ✅ **Azure Key Vault CSI**: For centralized secret management
- ✅ **cert-manager**: Automate TLS certificate lifecycle
- ✅ **GitOps**: Use OpenShift GitOps (ArgoCD) for declarative deployments
- ✅ **Azure Monitor Integration**: Forward logs and metrics to Azure Monitor/Log Analytics

## Day 0: Pre-Deployment Planning

### Azure Subscription & Quotas

- [ ] Verify Azure subscription has sufficient quota for:
  - [ ] vCPUs (minimum 40 vCPUs for standard cluster)
  - [ ] Standard_D8s_v3 or better VM SKUs
  - [ ] Public IP addresses (if using public clusters)
- [ ] Confirm ARO is available in your target Azure region
- [ ] Verify subscription has ARO resource provider registered:
  ```bash
  az provider register -n Microsoft.RedHatOpenShift --wait
  az provider register -n Microsoft.Compute --wait
  az provider register -n Microsoft.Storage --wait
  az provider register -n Microsoft.Authorization --wait
  ```

### Networking Architecture

- [ ] **VNet Design**
  - [ ] Decide: New VNet or existing VNet?
  - [ ] VNet CIDR sizing (recommend /16 or larger)
  - [ ] Master subnet: minimum /27 (32 IPs)
  - [ ] Worker subnet: minimum /27, recommend /24 or larger for scaling
  - [ ] Ensure subnets do not overlap with:
    - [ ] Azure reserved ranges
    - [ ] On-premises networks (if using VPN/ExpressRoute)
    - [ ] Pod network (default: 10.128.0.0/14)
    - [ ] Service network (default: 172.30.0.0/16)

- [ ] **Network Connectivity**
  - [ ] **Cluster Visibility (RECOMMENDED: Private)**
    - [ ] **Private cluster** (recommended for production):
      - [ ] API server accessible only from VNet or peered networks
      - [ ] Ingress accessible only from VNet or peered networks
      - [ ] Requires VPN, ExpressRoute, or jumphost for management
      - [ ] Better security posture and compliance
    - [ ] **Public cluster**:
      - [ ] API server accessible from Internet
      - [ ] Ingress accessible from Internet
      - [ ] Easier for initial testing and development
      - [ ] Consider NSG restrictions and Azure Front Door for production
  - [ ] Plan ExpressRoute/VPN connectivity (required for private cluster management)
  - [ ] Plan Azure Firewall or NVA placement
  - [ ] Document required egress endpoints for ARO
  - [ ] Plan DNS resolution strategy (Azure DNS, custom DNS, or hybrid)

- [ ] **Network Security Groups (NSG)**
  - [ ] **Decide: ARO-managed NSG or Bring Your Own NSG (BYO NSG)?**
    - [ ] ARO-managed: ARO creates and manages NSGs automatically (recommended for most deployments)
    - [ ] BYO NSG: You pre-create and manage NSGs (required for compliance/security requirements)

  - [ ] **If using BYO NSG:**
    - [ ] Pre-create NSGs before cluster deployment
    - [ ] Attach NSGs to master and worker subnets (not individual NICs)
    - [ ] Configure required ARO service tags and rules
    - [ ] **CRITICAL: Do not delete or significantly modify ARO-required rules**
    - [ ] Plan for NSG rule priority ranges (ARO uses 500-3000)
    - [ ] Document all custom rules and their purpose
    - [ ] Assign Network Contributor role to ARO service principal on NSGs
      ```bash
      az role assignment create \
        --assignee <service-principal-id> \
        --role "Network Contributor" \
        --scope /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/networkSecurityGroups/<nsg-name>
      ```

  - [ ] **Required NSG Rules for ARO** (if BYO NSG):
    - [ ] **Master Subnet Inbound:**
      - [ ] Allow TCP 6443 from worker subnet (API server)
      - [ ] Allow TCP 22623 from worker subnet (Machine Config Server)
      - [ ] Allow TCP 2379-2380 from master subnet (etcd)
      - [ ] Allow all traffic from master subnet (inter-master communication)
      - [ ] Allow Service Tag: AzureLoadBalancer (health probes)

    - [ ] **Master Subnet Outbound:**
      - [ ] Allow all outbound (or specific egress rules per compliance requirements)
      - [ ] Minimum required: Azure service endpoints, container registries, RHCOS updates

    - [ ] **Worker Subnet Inbound:**
      - [ ] Allow TCP 443 from AzureLoadBalancer (ingress health probes)
      - [ ] Allow TCP 80 from Internet/VirtualNetwork (if public ingress)
      - [ ] Allow TCP 443 from Internet/VirtualNetwork (if public ingress)
      - [ ] Allow all traffic from worker subnet (inter-worker communication)
      - [ ] Allow all traffic from master subnet (kubelet communication)

    - [ ] **Worker Subnet Outbound:**
      - [ ] Allow all outbound (or specific egress rules per compliance requirements)
      - [ ] Allow TCP 6443 to master subnet (API server access)
      - [ ] Allow TCP 22623 to master subnet (Machine Config Server)

  - [ ] **NSG Best Practices:**
    - [ ] Use service tags where possible (AzureLoadBalancer, Internet, VirtualNetwork)
    - [ ] Implement least privilege for custom application rules
    - [ ] Reserve priority range 100-499 for critical security rules
    - [ ] Use priorities 3001+ for application-specific rules
    - [ ] Enable NSG flow logs for audit and troubleshooting
    - [ ] Document rule change management process

### Security & Identity

- [ ] **Azure AD Integration**
  - [ ] Decide: Azure AD, Azure AD + LDAP, or other IdP?
  - [ ] Plan Azure AD group mappings for cluster roles
  - [ ] Create Azure AD application registration (if using AAD auth)
  - [ ] Document admin group membership

- [ ] **Azure Identity** (RECOMMENDED: Managed Identity)
  - [ ] **Option 1: Managed Identity (RECOMMENDED)**
    - [ ] Create user-assigned managed identity for ARO
      ```bash
      az identity create \
        --name <cluster-name>-identity \
        --resource-group <rg>
      ```
    - [ ] Assign Contributor role to VNet resource group
      ```bash
      az role assignment create \
        --assignee <identity-principal-id> \
        --role Contributor \
        --scope /subscriptions/<sub-id>/resourceGroups/<vnet-rg>
      ```
    - [ ] Assign Network Contributor to route table (if BYO route table)
    - [ ] **Benefits**:
      - No credential rotation required
      - Better security with no exposed secrets
      - Automatic credential management by Azure
      - Recommended for production environments

  - [ ] **Option 2: Service Principal** (legacy, not recommended)
    - [ ] Create Azure AD service principal for ARO
      ```bash
      az ad sp create-for-rbac \
        --name <cluster-name>-sp \
        --role Contributor \
        --scopes /subscriptions/<sub-id>/resourceGroups/<rg>
      ```
    - [ ] Assign Contributor role to VNet resource group
    - [ ] Assign Network Contributor to route table (if BYO route table)
    - [ ] Securely store credentials in Azure Key Vault
    - [ ] **Set up credential rotation process** (service principals expire)
    - [ ] **Drawbacks**:
      - Requires manual credential rotation
      - Credentials can be leaked if not properly secured
      - More operational overhead

- [ ] **Encryption**
  - [ ] Decide: Platform-managed keys or customer-managed keys?
  - [ ] If CMK: Create Azure Key Vault and encryption key
  - [ ] Plan disk encryption strategy (Azure Disk Encryption vs. platform encryption)
  - [ ] Document encryption at rest and in transit requirements

### Cluster Sizing & Configuration

- [ ] **Master Nodes**
  - [ ] Verify: 3 master nodes (standard, not configurable)
  - [ ] Default VM size: Standard_D8s_v3
  - [ ] Document high availability expectations

- [ ] **Worker Nodes**
  - [ ] Initial worker node count (minimum 3 recommended)
  - [ ] VM size selection (Standard_D4s_v3 minimum, D8s_v3+ recommended)
  - [ ] Plan for autoscaling (min/max node counts)
  - [ ] Decide: Single machine pool or multiple pools?
  - [ ] Plan for specialized workloads (GPU, memory-optimized, etc.)
  - [ ] **Infrastructure Nodes** (optional):
    - [ ] Plan dedicated nodes for cluster infrastructure workloads
    - [ ] Size appropriately for monitoring, logging, registry
    - [ ] Configure node selectors for infrastructure components
  - [ ] **GPU Workloads** (if applicable):
    - [ ] Select GPU-enabled VM SKUs (NC-series)
    - [ ] Plan for Nvidia GPU operator installation
    - [ ] Document AI/ML workload requirements

- [ ] **OpenShift Version**
  - [ ] Choose OpenShift version (4.x.y)
  - [ ] Verify version compatibility with workloads
  - [ ] Plan upgrade cadence (Day 2)

### Domain & Certificates

- [ ] **Cluster Domain**
  - [ ] Decide: Default Azure domain or custom domain?
  - [ ] If custom: Purchase/prepare domain
  - [ ] Plan DNS delegation strategy
  - [ ] Document DNS record requirements:
    - [ ] API endpoint: `api.<cluster-name>.<domain>`
    - [ ] Apps wildcard: `*.apps.<cluster-name>.<domain>`

- [ ] **TLS Certificates**
  - [ ] Decide: Self-signed or trusted CA certificates?
  - [ ] If custom certs: Obtain certificates for:
    - [ ] API server
    - [ ] Default ingress controller (apps wildcard)
  - [ ] Plan certificate rotation process (Day 2)

### Compliance & Governance

- [ ] **Azure Policy**
  - [ ] Review applicable Azure Policies for ARO
  - [ ] Plan for policy exemptions if needed
  - [ ] Consider Azure Policy integration with OpenShift
  - [ ] Document compliance requirements (PCI-DSS, HIPAA, etc.)

- [ ] **Tagging Strategy**
  - [ ] Define resource tags (cost center, environment, owner, etc.)
  - [ ] Plan tag inheritance from resource group
  - [ ] Tag for cost allocation and chargeback

- [ ] **Backup & Disaster Recovery**
  - [ ] Document RPO/RTO requirements
  - [ ] Plan etcd backup strategy
  - [ ] Choose backup solution (OADP/Velero, Azure Backup)
  - [ ] Plan for multi-region DR (if applicable)
  - [ ] Consider Advanced Cluster Management (ACM) for multi-cluster DR
  - [ ] Document DR runbook requirements

### Advanced Features Planning

- [ ] **Storage Solutions**
  - [ ] Plan for persistent storage needs
  - [ ] Decide: Azure Disk CSI, Azure Files CSI, or OpenShift Data Foundation (ODF)?
  - [ ] Consider Azure NetApp Files with Trident (for high-performance requirements)
  - [ ] Plan for Azure Blob Storage CSI (if applicable)
  - [ ] Document storage class requirements and retention policies

- [ ] **Container Registry**
  - [ ] Decide: Internal OpenShift registry, Azure Container Registry (ACR), or Quay?
  - [ ] Plan for private registry connectivity (if private cluster)
  - [ ] Document image scanning and security requirements
  - [ ] Plan for registry replication (if multi-region)

- [ ] **AI/ML Workloads** (if applicable)
  - [ ] Plan for Red Hat OpenShift AI (RHOAI) deployment
  - [ ] Consider OpenShift Lightspeed with Azure AI Foundry integration
  - [ ] Document GPU requirements and model sizes
  - [ ] Plan for vector database and model storage

- [ ] **Multi-Cluster Architecture** (if applicable)
  - [ ] Plan for Advanced Cluster Management (ACM) hub cluster
  - [ ] Document multi-cluster networking requirements (Submariner?)
  - [ ] Plan for cross-cluster service mesh (if needed)
  - [ ] Consider disaster recovery cluster topology

- [ ] **Azure Service Integration**
  - [ ] Plan Azure Service Operator (ASO) deployment for managing Azure resources
  - [ ] Document which Azure services will be consumed (databases, storage, etc.)
  - [ ] Plan for managed identity usage vs. service principals
  - [ ] Consider Azure Arc integration for unified management

- [ ] **CI/CD Integration**
  - [ ] Decide: OpenShift Pipelines (Tekton), Azure DevOps, or GitHub Actions?
  - [ ] Plan for build agent placement (in-cluster vs. external)
  - [ ] Document artifact storage strategy
  - [ ] Plan for GitOps with ArgoCD/OpenShift GitOps

- [ ] **Developer Experience**
  - [ ] Consider OpenShift Dev Spaces for cloud IDEs
  - [ ] Plan for custom domains for developer workspaces
  - [ ] Document self-service namespace provisioning
  - [ ] Plan for developer onboarding automation

## Day 1: Cluster Deployment

### Pre-Deployment Verification

- [ ] Verify Azure CLI version (2.30.0+)
- [ ] Verify `az aro` extension is installed and updated
- [ ] Test Azure authentication: `az account show`
- [ ] Verify target subscription: `az account set --subscription <id>`
- [ ] Pre-create resource group with appropriate tags

### VNet & Subnet Creation

- [ ] Create Virtual Network
  ```bash
  az network vnet create \
    --resource-group <rg> \
    --name <vnet-name> \
    --address-prefixes 10.0.0.0/16
  ```

- [ ] Create master subnet with required service endpoints
  ```bash
  az network vnet subnet create \
    --resource-group <rg> \
    --vnet-name <vnet-name> \
    --name master-subnet \
    --address-prefixes 10.0.0.0/24 \
    --service-endpoints Microsoft.ContainerRegistry
  ```

- [ ] Disable private link policies on master subnet
  ```bash
  az network vnet subnet update \
    --name master-subnet \
    --resource-group <rg> \
    --vnet-name <vnet-name> \
    --disable-private-link-service-network-policies true
  ```

- [ ] Create worker subnet
  ```bash
  az network vnet subnet create \
    --resource-group <rg> \
    --vnet-name <vnet-name> \
    --name worker-subnet \
    --address-prefixes 10.0.1.0/24 \
    --service-endpoints Microsoft.ContainerRegistry
  ```

### Network Security Configuration

- [ ] **If using ARO-managed NSGs:**
  - [ ] Skip NSG creation - ARO will create them automatically
  - [ ] Verify no pre-existing NSGs on subnets
  - [ ] Document that NSGs will be created in the cluster resource group

- [ ] **If using BYO NSG (pre-created NSGs):**

  - [ ] **Create Master Subnet NSG:**
    ```bash
    az network nsg create \
      --resource-group <rg> \
      --name <cluster-name>-master-nsg \
      --location <location>
    ```

  - [ ] **Create required master NSG rules:**
    ```bash
    # Allow API server from workers
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-master-nsg \
      --name AllowAPIServer \
      --priority 500 \
      --source-address-prefixes 10.0.1.0/24 \
      --destination-port-ranges 6443 \
      --protocol Tcp \
      --access Allow \
      --direction Inbound

    # Allow Machine Config Server from workers
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-master-nsg \
      --name AllowMCS \
      --priority 501 \
      --source-address-prefixes 10.0.1.0/24 \
      --destination-port-ranges 22623 \
      --protocol Tcp \
      --access Allow \
      --direction Inbound

    # Allow etcd between masters
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-master-nsg \
      --name AllowEtcd \
      --priority 502 \
      --source-address-prefixes 10.0.0.0/24 \
      --destination-port-ranges 2379-2380 \
      --protocol Tcp \
      --access Allow \
      --direction Inbound

    # Allow Azure Load Balancer health probes
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-master-nsg \
      --name AllowAzureLB \
      --priority 503 \
      --source-address-prefixes AzureLoadBalancer \
      --destination-port-ranges '*' \
      --protocol '*' \
      --access Allow \
      --direction Inbound

    # Allow all outbound (or customize per your requirements)
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-master-nsg \
      --name AllowAllOutbound \
      --priority 100 \
      --destination-address-prefixes '*' \
      --destination-port-ranges '*' \
      --protocol '*' \
      --access Allow \
      --direction Outbound
    ```

  - [ ] **Create Worker Subnet NSG:**
    ```bash
    az network nsg create \
      --resource-group <rg> \
      --name <cluster-name>-worker-nsg \
      --location <location>
    ```

  - [ ] **Create required worker NSG rules:**
    ```bash
    # Allow HTTPS ingress from Internet (public cluster)
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-worker-nsg \
      --name AllowHTTPS \
      --priority 500 \
      --source-address-prefixes Internet \
      --destination-port-ranges 443 \
      --protocol Tcp \
      --access Allow \
      --direction Inbound

    # Allow HTTP ingress from Internet (public cluster)
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-worker-nsg \
      --name AllowHTTP \
      --priority 501 \
      --source-address-prefixes Internet \
      --destination-port-ranges 80 \
      --protocol Tcp \
      --access Allow \
      --direction Inbound

    # Allow Azure Load Balancer health probes
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-worker-nsg \
      --name AllowAzureLB \
      --priority 502 \
      --source-address-prefixes AzureLoadBalancer \
      --destination-port-ranges '*' \
      --protocol '*' \
      --access Allow \
      --direction Inbound

    # Allow all from master subnet
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-worker-nsg \
      --name AllowMaster \
      --priority 503 \
      --source-address-prefixes 10.0.0.0/24 \
      --destination-port-ranges '*' \
      --protocol '*' \
      --access Allow \
      --direction Inbound

    # Allow all outbound (or customize per your requirements)
    az network nsg rule create \
      --resource-group <rg> \
      --nsg-name <cluster-name>-worker-nsg \
      --name AllowAllOutbound \
      --priority 100 \
      --destination-address-prefixes '*' \
      --destination-port-ranges '*' \
      --protocol '*' \
      --access Allow \
      --direction Outbound
    ```

  - [ ] **Attach NSGs to subnets:**
    ```bash
    # Attach master NSG
    az network vnet subnet update \
      --resource-group <rg> \
      --vnet-name <vnet-name> \
      --name master-subnet \
      --network-security-group <cluster-name>-master-nsg

    # Attach worker NSG
    az network vnet subnet update \
      --resource-group <rg> \
      --vnet-name <vnet-name> \
      --name worker-subnet \
      --network-security-group <cluster-name>-worker-nsg
    ```

  - [ ] **Grant ARO service principal Network Contributor on NSGs:**
    ```bash
    az role assignment create \
      --assignee <service-principal-id> \
      --role "Network Contributor" \
      --scope /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/networkSecurityGroups/<cluster-name>-master-nsg

    az role assignment create \
      --assignee <service-principal-id> \
      --role "Network Contributor" \
      --scope /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/networkSecurityGroups/<cluster-name>-worker-nsg
    ```

  - [ ] **Enable NSG Flow Logs (recommended):**
    ```bash
    # Create storage account for flow logs
    az storage account create \
      --name <storage-account-name> \
      --resource-group <rg> \
      --location <location> \
      --sku Standard_LRS

    # Enable flow logs for master NSG
    az network watcher flow-log create \
      --location <location> \
      --name <cluster-name>-master-flow-log \
      --nsg <cluster-name>-master-nsg \
      --storage-account <storage-account-name> \
      --resource-group <rg> \
      --enabled true

    # Enable flow logs for worker NSG
    az network watcher flow-log create \
      --location <location> \
      --name <cluster-name>-worker-flow-log \
      --nsg <cluster-name>-worker-nsg \
      --storage-account <storage-account-name> \
      --resource-group <rg> \
      --enabled true
    ```

- [ ] **General NSG Validation:**
  - [ ] Verify no conflicting route tables
  - [ ] Test connectivity between master and worker subnets
  - [ ] Document network topology diagram
  - [ ] Document all custom NSG rules and their purpose

### ARO Cluster Creation

- [ ] **Choose Deployment Method:**
  - [ ] Azure CLI (`az aro create`)
  - [ ] Azure Portal
  - [ ] **Terraform** (Infrastructure as Code - recommended for repeatability)
  - [ ] ARM templates

- [ ] **Recommended Production Deployment (Private Cluster with Managed Identity)**
  ```bash
  # Get managed identity details
  IDENTITY_ID=$(az identity show \
    --name <cluster-name>-identity \
    --resource-group <rg> \
    --query id -o tsv)

  IDENTITY_CLIENT_ID=$(az identity show \
    --name <cluster-name>-identity \
    --resource-group <rg> \
    --query clientId -o tsv)

  # Create private ARO cluster with managed identity
  az aro create \
    --resource-group <rg> \
    --name <cluster-name> \
    --vnet <vnet-name> \
    --master-subnet master-subnet \
    --worker-subnet worker-subnet \
    --apiserver-visibility Private \
    --ingress-visibility Private \
    --pull-secret @pull-secret.txt \
    --domain <custom-domain> \
    --assign-identity ${IDENTITY_ID} \
    --tags "Environment=Production" "CostCenter=IT" "Visibility=Private"
  ```

- [ ] **Alternative: Public Cluster** (development/testing only)
  ```bash
  # Public cluster (not recommended for production)
  az aro create \
    --resource-group <rg> \
    --name <cluster-name> \
    --vnet <vnet-name> \
    --master-subnet master-subnet \
    --worker-subnet worker-subnet \
    --pull-secret @pull-secret.txt \
    --assign-identity ${IDENTITY_ID}
    # Omit --apiserver-visibility and --ingress-visibility for public access
  ```

- [ ] **Legacy: Using Service Principal** (not recommended)
  ```bash
  # Only use if managed identity is not an option
  az aro create \
    --resource-group <rg> \
    --name <cluster-name> \
    --vnet <vnet-name> \
    --master-subnet master-subnet \
    --worker-subnet worker-subnet \
    --client-id <service-principal-app-id> \
    --client-secret <service-principal-password> \
    --pull-secret @pull-secret.txt
  ```

- [ ] **Terraform Deployment** (alternative)
  - [ ] Configure azurerm provider
  - [ ] Define cluster resources in .tf files
  - [ ] Run `terraform plan` and `terraform apply`
  - [ ] Store state file securely (Azure Storage backend recommended)

- [ ] Monitor deployment progress (30-45 minutes typical)
- [ ] Document cluster creation output (API server URL, console URL)

### Optional: VPN Setup for Private Clusters

- [ ] **Point-to-Site VPN** (if private cluster):
  - [ ] Create VPN gateway in VNet
  - [ ] Configure OpenVPN client certificates
  - [ ] Distribute VPN client configuration
  - [ ] Test connectivity from VPN client to API server
  - [ ] Document VPN access procedures

### Post-Deployment Validation

- [ ] Retrieve cluster credentials
  ```bash
  az aro list-credentials --name <cluster-name> --resource-group <rg>
  ```

- [ ] Test console access (https://console-openshift-console.apps...)
- [ ] Test API server access
  ```bash
  oc login <api-server-url> -u kubeadmin
  ```

- [ ] Verify cluster version: `oc get clusterversion`
- [ ] Verify cluster operators: `oc get co`
- [ ] Check node status: `oc get nodes`
- [ ] Verify default storage class exists

### Custom Domain Configuration (if applicable)

- [ ] Create DNS CNAME records for:
  - [ ] `api.<cluster>.<domain>` → Azure-provided API endpoint
  - [ ] `*.apps.<cluster>.<domain>` → Azure-provided apps endpoint

- [ ] Update API server certificate
  ```bash
  oc create secret tls api-cert \
    --cert=api.crt \
    --key=api.key \
    -n openshift-config

  oc patch apiserver cluster \
    --type=merge \
    --patch='{"spec":{"servingCerts":{"namedCertificates":[{"names":["api.<domain>"],"servingCertificate":{"name":"api-cert"}}]}}}'
  ```

- [ ] Update default ingress certificate
  ```bash
  oc create secret tls apps-cert \
    --cert=apps.crt \
    --key=apps.key \
    -n openshift-ingress

  oc patch ingresscontroller default \
    -n openshift-ingress-operator \
    --type=merge \
    --patch='{"spec":{"defaultCertificate":{"name":"apps-cert"}}}'
  ```

- [ ] Verify certificate: `curl -v https://api.<domain>:6443`

### Azure Integration

- [ ] Verify Azure disk CSI driver: `oc get csidrivers`
- [ ] Verify Azure file CSI driver (if needed)
- [ ] Test persistent volume provisioning
- [ ] Configure Azure Container Registry integration (if using ACR)

## Day 2: Ongoing Operations

### Identity & Access Management

- [ ] **Azure AD Integration**
  - [ ] Configure OAuth identity provider
    ```bash
    oc create secret generic aad-client-secret \
      --from-literal=clientSecret=<secret> \
      -n openshift-config

    oc apply -f oauth-aad.yaml
    ```

  - [ ] Create OAuth configuration YAML
  - [ ] Test Azure AD login
  - [ ] Verify group sync (if using group-based RBAC)

- [ ] **Cluster RBAC Configuration**
  - [ ] Remove default kubeadmin user (after confirming admin access)
    ```bash
    oc delete secret kubeadmin -n kube-system
    ```

  - [ ] Create cluster-admin role bindings
    ```bash
    oc adm policy add-cluster-role-to-user cluster-admin <user>@<domain>
    ```

  - [ ] Create namespace-specific role bindings
  - [ ] Document role/rolebinding strategy
  - [ ] Implement least-privilege principle

- [ ] **Group-Based Access Control**
  - [ ] Create OpenShift groups mapped to Azure AD groups
    ```bash
    oc adm groups new developers
    oc adm groups add-users developers user1@domain.com
    ```

  - [ ] Assign roles to groups (not individual users)
  - [ ] Document group membership and purposes

### Cluster Configuration

- [ ] **Node Configuration**
  - [ ] Create additional machine pools for specialized workloads
    ```bash
    az aro machinepool create \
      --resource-group <rg> \
      --cluster-name <cluster> \
      --name gpu-pool \
      --vm-size Standard_NC6s_v3 \
      --replicas 2
    ```

  - [ ] Configure node selectors and taints/tolerations
  - [ ] Enable cluster autoscaler (if using)
  - [ ] Set up node tuning operator (if needed)

- [ ] **Registry Configuration**
  - [ ] Configure image registry storage (Azure Blob)
    ```bash
    oc patch configs.imageregistry.operator.openshift.io/cluster \
      --type=merge \
      --patch='{"spec":{"storage":{"azure":{"accountName":"<storage>","container":"registry"}}}}'
    ```

  - [ ] Expose registry route (if needed)
  - [ ] Configure pull secrets for private registries
  - [ ] Set up image pruning policies

- [ ] **Ingress Configuration**
  - [ ] Create additional ingress controllers (if needed)
    ```bash
    oc create -f additional-ingress-controller.yaml
    ```
  - [ ] Configure ingress controller replicas for HA
  - [ ] Set up custom routes and edge termination
  - [ ] Configure rate limiting (if needed)
  - [ ] **Azure Front Door Integration** (optional):
    - [ ] Create Azure Front Door profile
    - [ ] Configure backend pools pointing to ARO ingress
    - [ ] Set up WAF policies
    - [ ] Configure custom domains and SSL certificates
    - [ ] Test failover and health probes

- [ ] **Infrastructure Nodes** (if planned)
  - [ ] Create infrastructure machine pool
    ```bash
    az aro machinepool create \
      --resource-group <rg> \
      --cluster-name <cluster> \
      --name infra \
      --vm-size Standard_D8s_v3 \
      --replicas 3 \
      --labels node-role.kubernetes.io/infra=
    ```
  - [ ] Move infrastructure workloads to infra nodes:
    - [ ] Image registry
    - [ ] Monitoring stack
    - [ ] Logging stack
    - [ ] Ingress controllers
  - [ ] Configure node selectors and tolerations for infrastructure pods

### Monitoring & Logging

- [ ] **Cluster Monitoring**
  - [ ] Enable user workload monitoring
    ```bash
    oc apply -f - <<EOF
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: cluster-monitoring-config
      namespace: openshift-monitoring
    data:
      config.yaml: |
        enableUserWorkload: true
    EOF
    ```

  - [ ] Configure monitoring retention
  - [ ] Set up PVC for Prometheus (if persistent storage needed)
  - [ ] Configure alerting rules

- [ ] **Azure Monitor Integration**
  - [ ] Enable Container Insights (if using)
  - [ ] Configure log forwarding to Log Analytics workspace
  - [ ] Set up Azure Monitor alerts for cluster health
  - [ ] Configure diagnostic settings for ARO resources

- [ ] **Logging Stack**
  - [ ] Deploy cluster logging operator
    ```bash
    oc create -f cluster-logging-operator-subscription.yaml
    ```

  - [ ] Create ClusterLogging instance
  - [ ] **Configure log forwarding to Azure Monitor/Log Analytics:**
    ```yaml
    apiVersion: logging.openshift.io/v1
    kind: ClusterLogForwarder
    metadata:
      name: instance
      namespace: openshift-logging
    spec:
      outputs:
        - name: azure-monitor
          type: azureMonitor
          azureMonitor:
            customerId: <workspace-id>
            sharedKey:
              name: azure-monitor-secret
              key: shared-key
      pipelines:
        - name: forward-to-azure
          inputRefs:
            - application
            - infrastructure
          outputRefs:
            - azure-monitor
    ```
  - [ ] Configure log retention policies
  - [ ] Forward logs to external SIEM (if required)

- [ ] **Cluster Observability Operator (COO)** (alternative to built-in monitoring)
  - [ ] Deploy COO for standalone monitoring stacks
  - [ ] Configure metrics persistence to Azure Blob Storage
  - [ ] Set up Thanos for long-term metrics storage
  - [ ] Configure separate monitoring instances per namespace/team

### Networking & Connectivity

- [ ] **BYO NSG Management** (if using custom NSGs)
  - [ ] **Regular Auditing:**
    - [ ] Review NSG flow logs for anomalies
      ```bash
      # Query flow logs in storage account
      az storage blob list \
        --account-name <storage-account> \
        --container-name insights-logs-networksecuritygroupflowevent
      ```
    - [ ] Verify no unauthorized rule changes
    - [ ] Audit rule effectiveness (allow/deny ratios)
    - [ ] Review and clean up unused rules

  - [ ] **Adding Application-Specific Rules:**
    - [ ] Use priority range 3001+ for application rules
    - [ ] Document each custom rule's purpose
    - [ ] Test rule effectiveness before production deployment
    - [ ] Example: Allow specific application ports
      ```bash
      az network nsg rule create \
        --resource-group <rg> \
        --nsg-name <cluster-name>-worker-nsg \
        --name AllowApp8080 \
        --priority 3001 \
        --source-address-prefixes 10.0.0.0/16 \
        --destination-port-ranges 8080 \
        --protocol Tcp \
        --access Allow \
        --direction Inbound
      ```

  - [ ] **NSG Rule Troubleshooting:**
    - [ ] Enable NSG diagnostic logs
      ```bash
      az monitor diagnostic-settings create \
        --name nsg-diagnostics \
        --resource /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/networkSecurityGroups/<nsg-name> \
        --logs '[{"category":"NetworkSecurityGroupEvent","enabled":true},{"category":"NetworkSecurityGroupRuleCounter","enabled":true}]' \
        --workspace /subscriptions/<sub-id>/resourcegroups/<rg>/providers/microsoft.operationalinsights/workspaces/<workspace>
      ```
    - [ ] Use Azure Network Watcher IP flow verify for connectivity issues
    - [ ] Review effective security rules on NICs
      ```bash
      az network nic list-effective-nsg \
        --resource-group <cluster-rg> \
        --name <nic-name>
      ```
    - [ ] Document common connectivity issues and resolutions

  - [ ] **Change Management:**
    - [ ] Implement approval process for NSG rule changes
    - [ ] Test changes in non-production first
    - [ ] Maintain NSG rule change log
    - [ ] Create rollback procedures

  - [ ] **Monitoring & Alerts:**
    - [ ] Set up Azure Monitor alerts for:
      - [ ] NSG rule changes
      - [ ] High deny rates
      - [ ] Unusual traffic patterns
    - [ ] Create dashboards for NSG metrics
    - [ ] Document alert response procedures

  - [ ] **Critical Warnings for BYO NSG:**
    - [ ] ⚠️ **NEVER delete ARO-required rules** (priorities 500-3000)
    - [ ] ⚠️ **DO NOT modify master-to-worker or worker-to-master rules**
    - [ ] ⚠️ **DO NOT remove AzureLoadBalancer service tag rules**
    - [ ] ⚠️ **Verify changes don't break cluster operations before applying**
    - [ ] ⚠️ **Maintain Network Contributor role for ARO service principal**

- [ ] **Network Policies**
  - [ ] Implement namespace network isolation
  - [ ] Create allow-list policies for inter-namespace communication
  - [ ] Test network policy effectiveness
  - [ ] Document network policy matrix

- [ ] **Egress Control**
  - [ ] Configure egress IPs for predictable outbound traffic
  - [ ] Set up egress firewall rules
  - [ ] Document allowed egress destinations
  - [ ] Test application egress connectivity

- [ ] **Load Balancer Configuration**
  - [ ] Review default service load balancer settings
  - [ ] Create internal load balancers (if needed)
  - [ ] Configure Azure Front Door or App Gateway (if using)
  - [ ] Set up WAF policies

- [ ] **Consistent Egress IP** (optional)
  - [ ] Configure egress IP for specific namespaces/pods
    ```bash
    oc patch namespace <namespace> \
      --type=merge \
      --patch '{"metadata":{"annotations":{"egress-ip":"<ip-address>"}}}'
    ```
  - [ ] Assign egress IPs to nodes
  - [ ] Test and verify egress IP assignment
  - [ ] Document egress IP allocation for security teams

### Advanced Storage Configuration

- [ ] **OpenShift Data Foundation (ODF)**
  - [ ] Deploy ODF operator
  - [ ] Create StorageCluster in internal mode
  - [ ] Configure Ceph pools and storage classes
  - [ ] Set up block, file, and object storage
  - [ ] Configure replication and disaster recovery
  - [ ] Test PVC provisioning with ODF

- [ ] **Azure Blob Storage CSI Driver**
  - [ ] Deploy Azure Blob CSI driver
    ```bash
    oc create -f azure-blob-csi-driver.yaml
    ```
  - [ ] Create storage class for blob mounting
  - [ ] Configure lifecycle management policies
  - [ ] Test blob volume mounting in pods
  - [ ] Document use cases (large object storage, backup targets)

- [ ] **Azure NetApp Files Integration** (if high-performance storage needed)
  - [ ] Deploy NetApp Trident operator
  - [ ] Configure backend for Azure NetApp Files
  - [ ] Create storage classes for different service levels
  - [ ] Test NFS volume provisioning
  - [ ] Configure snapshots and clones

- [ ] **Azure Files CSI Configuration**
  - [ ] Review default azurefile-csi storage class
  - [ ] Create additional storage classes with different SKUs
  - [ ] Configure private endpoint for Azure Files (if private cluster)
  - [ ] Test RWX (ReadWriteMany) access mode
  - [ ] Document file share backup strategy

### Azure Service Integration

- [ ] **Azure Service Operator (ASO)**
  - [ ] Deploy ASO v2 operator
    ```bash
    oc create -f azure-service-operator-subscription.yaml
    ```
  - [ ] Configure Azure credentials (managed identity or service principal)
  - [ ] Create sample Azure resources via CRDs
    - [ ] Azure SQL Database
    - [ ] Azure Cache for Redis
    - [ ] Azure Service Bus
  - [ ] Test resource lifecycle management
  - [ ] Document ASO usage patterns for developers

- [ ] **Azure Container Registry (ACR) Integration**
  - [ ] Configure ACR pull secrets
    ```bash
    oc create secret docker-registry acr-secret \
      --docker-server=<acr-name>.azurecr.io \
      --docker-username=<sp-id> \
      --docker-password=<sp-password>
    ```
  - [ ] Set up ACR private endpoint (if private cluster)
  - [ ] Configure imagePullSecrets in default service accounts
  - [ ] Enable ACR vulnerability scanning
  - [ ] Test image pull from ACR

- [ ] **Azure Key Vault CSI Driver**
  - [ ] Deploy Secrets Store CSI driver
  - [ ] Configure Azure Key Vault provider
  - [ ] Create SecretProviderClass resources
    ```yaml
    apiVersion: secrets-store.csi.x-k8s.io/v1
    kind: SecretProviderClass
    metadata:
      name: azure-keyvault-sync
    spec:
      provider: azure
      parameters:
        usePodIdentity: "false"
        useVMManagedIdentity: "true"
        userAssignedIdentityID: <identity-id>
        keyvaultName: <keyvault-name>
        objects: |
          array:
            - |
              objectName: secret1
              objectType: secret
    ```
  - [ ] Test secret mounting in pods
  - [ ] Configure auto-rotation
  - [ ] Document secret management workflow

- [ ] **Azure Arc Integration** (optional)
  - [ ] Enable Azure Arc for Kubernetes on ARO
  - [ ] Configure GitOps with Arc
  - [ ] Set up Azure Policy for Arc
  - [ ] Test centralized management from Azure Portal

- [ ] **OpenShift Cluster Manager (OCM) Integration**
  - [ ] Register cluster with Red Hat OpenShift Cluster Manager
  - [ ] Configure telemetry and insights
  - [ ] Enable remote health monitoring
  - [ ] Test upgrade scheduling via OCM

### AI/ML and Advanced Workloads

- [ ] **Red Hat OpenShift AI (RHOAI)**
  - [ ] Deploy RHOAI operator
  - [ ] Configure data science projects and workbenches
  - [ ] Set up Jupyter notebook servers
  - [ ] Configure model serving infrastructure
  - [ ] Test ML pipeline execution
  - [ ] Document AI/ML workflow for data scientists

- [ ] **OpenShift Lightspeed**
  - [ ] Deploy OpenShift Lightspeed operator
  - [ ] Configure Azure AI Foundry integration
  - [ ] Set up LLM backend (Azure OpenAI)
  - [ ] Test AI-powered cluster assistance
  - [ ] Train team on Lightspeed capabilities

- [ ] **GPU Workloads**
  - [ ] Deploy Nvidia GPU operator
    ```bash
    oc create -f nvidia-gpu-operator-subscription.yaml
    ```
  - [ ] Verify GPU discovery on NC-series nodes
  - [ ] Create GPU-enabled machine pool (if not done in Day 0)
  - [ ] Test GPU workload scheduling
  - [ ] Configure GPU sharing and time-slicing (if needed)
  - [ ] Document GPU resource requests for developers

- [ ] **OpenShift Virtualization**
  - [ ] Deploy OpenShift Virtualization operator
  - [ ] Configure storage for VM disks
  - [ ] Create VM templates
  - [ ] Test VM migration from Azure VMs
  - [ ] Configure networking for VMs (bridge, masquerade)
  - [ ] Set up VM backup and snapshots
  - [ ] Document VM lifecycle management

### Container Registry

- [ ] **Internal Registry Configuration** (completed in Day 1, enhance here)
  - [ ] Configure registry size and retention
  - [ ] Set up image pruning automation
  - [ ] Configure registry metrics and monitoring
  - [ ] Test registry high availability

- [ ] **Quay Registry** (alternative/additional registry)
  - [ ] Deploy Quay operator
  - [ ] Configure Quay registry with Azure Blob backend
  - [ ] Set up Quay security scanning (Clair)
  - [ ] Configure image mirroring
  - [ ] Set up geo-replication (if multi-region)
  - [ ] Document image promotion workflow

### Multi-Cluster and Disaster Recovery

- [ ] **Advanced Cluster Management (ACM)**
  - [ ] Deploy ACM hub cluster
  - [ ] Import ARO clusters as managed clusters
  - [ ] Configure cluster sets and placement policies
  - [ ] Set up application deployment across clusters
  - [ ] Configure observability across managed clusters
  - [ ] Test disaster recovery failover

- [ ] **Submariner for Multi-Cluster Networking**
  - [ ] Deploy Submariner broker on hub cluster
  - [ ] Join ARO clusters to Submariner
  - [ ] Configure service discovery across clusters
  - [ ] Test cross-cluster pod communication
  - [ ] Document multi-cluster networking topology

- [ ] **Skupper for Service Interconnect**
  - [ ] Deploy Skupper in namespaces
  - [ ] Create service network across clusters
  - [ ] Test database replication (e.g., PostgreSQL HA)
  - [ ] Configure secure service-to-service communication
  - [ ] Document service mesh topology

### Security Hardening

- [ ] **Security Context Constraints (SCC)**
  - [ ] Review default SCC policies
  - [ ] Create custom SCCs for specific workloads
  - [ ] Audit SCC usage: `oc get scc`
  - [ ] Document SCC assignment strategy

- [ ] **Pod Security Standards**
  - [ ] Set namespace security levels
    ```bash
    oc label namespace <namespace> \
      pod-security.kubernetes.io/enforce=restricted \
      pod-security.kubernetes.io/audit=restricted \
      pod-security.kubernetes.io/warn=restricted
    ```

  - [ ] Review pod security violations
  - [ ] Create exemptions as needed

- [ ] **Secrets Management**
  - [ ] Encrypt etcd data at rest (verify enabled)
  - [ ] Integrate with Azure Key Vault (if using external secrets)
  - [ ] Configure External Secrets Operator or CSI Secret Store
  - [ ] Audit secret access patterns

- [ ] **Certificate Management**

  - [ ] **Option 1: cert-manager Operator (Recommended for automated certificate management)**
    - [ ] Deploy cert-manager operator from OperatorHub
      ```bash
      oc create -f - <<EOF
      apiVersion: operators.coreos.com/v1alpha1
      kind: Subscription
      metadata:
        name: openshift-cert-manager-operator
        namespace: cert-manager-operator
      spec:
        channel: stable-v1
        name: openshift-cert-manager-operator
        source: redhat-operators
        sourceNamespace: openshift-marketplace
      EOF
      ```

    - [ ] Wait for operator installation to complete
      ```bash
      oc get csv -n cert-manager-operator
      ```

    - [ ] **Configure Let's Encrypt Issuers:**
      ```yaml
      # Production issuer
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: letsencrypt-prod
      spec:
        acme:
          server: https://acme-v02.api.letsencrypt.org/directory
          email: admin@example.com
          privateKeySecretRef:
            name: letsencrypt-prod
          solvers:
          - http01:
              ingress:
                class: openshift-default
      ---
      # Staging issuer for testing
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: letsencrypt-staging
      spec:
        acme:
          server: https://acme-staging-v02.api.letsencrypt.org/directory
          email: admin@example.com
          privateKeySecretRef:
            name: letsencrypt-staging
          solvers:
          - http01:
              ingress:
                class: openshift-default
      ```

    - [ ] **Configure Azure DNS Issuer (for DNS-01 challenge):**
      ```yaml
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: letsencrypt-dns
      spec:
        acme:
          server: https://acme-v02.api.letsencrypt.org/directory
          email: admin@example.com
          privateKeySecretRef:
            name: letsencrypt-dns
          solvers:
          - dns01:
              azureDNS:
                subscriptionID: <subscription-id>
                resourceGroupName: <dns-zone-rg>
                hostedZoneName: <domain.com>
                managedIdentity:
                  clientID: <managed-identity-client-id>
      ```

    - [ ] **Issue certificates for routes:**
      ```yaml
      apiVersion: route.openshift.io/v1
      kind: Route
      metadata:
        name: myapp
        annotations:
          cert-manager.io/issuer: letsencrypt-prod
          cert-manager.io/issuer-kind: ClusterIssuer
      spec:
        host: myapp.apps.cluster.domain.com
        to:
          kind: Service
          name: myapp
        tls:
          termination: edge
      ```

    - [ ] **Test certificate issuance:**
      ```bash
      oc get certificate -A
      oc describe certificate <cert-name> -n <namespace>
      oc get certificaterequest -A
      ```

    - [ ] **Configure certificate renewal alerts:**
      ```yaml
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: cert-manager-webhook
        namespace: cert-manager
      data:
        renewal-webhook-url: <slack-or-teams-webhook>
      ```

    - [ ] **Create certificates for API server and ingress:**
      ```yaml
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: api-server-cert
        namespace: openshift-config
      spec:
        secretName: api-server-tls
        duration: 2160h # 90 days
        renewBefore: 360h # 15 days
        subject:
          organizations:
          - Example Org
        commonName: api.cluster.domain.com
        dnsNames:
        - api.cluster.domain.com
        issuerRef:
          name: letsencrypt-prod
          kind: ClusterIssuer
      ```

  - [ ] **Option 2: Manual Certificate Management**
    - [ ] Obtain certificates from your CA
    - [ ] Create secrets in openshift-config namespace
    - [ ] Patch API server and ingress controllers
    - [ ] Set up renewal reminders (certificates expire)

  - [ ] **Certificate Monitoring:**
    - [ ] Monitor certificate expiration dates
      ```bash
      oc get certificates -A
      oc get certificate <name> -o jsonpath='{.status.renewalTime}'
      ```
    - [ ] Set up alerts for expiring certificates (< 30 days)
    - [ ] Create dashboard for certificate status
    - [ ] Document certificate renewal procedures

  - [ ] **HashiCorp Vault CSI Integration** (optional alternative for secrets)
    - [ ] Deploy Vault CSI provider
    - [ ] Configure Vault authentication method (Kubernetes auth)
    - [ ] Create SecretProviderClass for Vault
    - [ ] Test secret injection into pods
    - [ ] Document Vault secret management workflow

### Backup & Disaster Recovery

- [ ] **etcd Backup**
  - [ ] Configure automated etcd snapshots
  - [ ] Test etcd restore procedure
  - [ ] Store backups in separate Azure region
  - [ ] Document backup retention policy

- [ ] **Application Backup**
  - [ ] Deploy Velero or OADP (OpenShift API for Data Protection)
  - [ ] Configure backup schedules
  - [ ] Test restore procedures
  - [ ] Document backup/restore runbooks

- [ ] **Persistent Volume Backup**
  - [ ] Enable Azure Backup for managed disks (if applicable)
  - [ ] Configure PV snapshot schedules
  - [ ] Test PV restore
  - [ ] Document PV recovery procedures

### Compliance & Auditing

- [ ] **Audit Logging**
  - [ ] Enable Kubernetes audit logging
  - [ ] Configure audit log retention
  - [ ] Forward audit logs to SIEM
  - [ ] Set up audit log analysis

- [ ] **Compliance Scanning**
  - [ ] Deploy OpenShift Compliance Operator
  - [ ] Run compliance scans (CIS, PCI-DSS, etc.)
  - [ ] Review and remediate findings
  - [ ] Schedule regular compliance scans

- [ ] **Vulnerability Scanning**
  - [ ] Integrate image scanning (Quay, ACR scanning, or third-party)
  - [ ] Scan running containers
  - [ ] Set up vulnerability alerting
  - [ ] Document remediation SLAs

### Cluster Maintenance

- [ ] **Upgrade Planning**
  - [ ] Review OpenShift release notes
  - [ ] Test upgrades in non-production environment
  - [ ] Schedule maintenance window
  - [ ] Document upgrade runbook
  - [ ] Configure upgrade channel: `oc adm upgrade channel <channel>`

- [ ] **Node Maintenance**
  - [ ] Plan node rotation strategy
  - [ ] Drain and cordon nodes before maintenance
    ```bash
    oc adm drain <node> --ignore-daemonsets --delete-emptydir-data
    ```

  - [ ] Monitor node resource utilization
  - [ ] Scale machine pools as needed

- [ ] **Operator Lifecycle Management**
  - [ ] Review installed operators: `oc get csv -A`
  - [ ] Configure operator update approvals
  - [ ] Monitor operator health
  - [ ] Document operator upgrade procedures

### Cost Optimization

- [ ] **Resource Optimization**
  - [ ] Enable cluster autoscaler
  - [ ] Configure pod resource requests and limits
  - [ ] Implement horizontal pod autoscaling
  - [ ] Review and right-size worker node VM SKUs

- [ ] **Cost Monitoring**
  - [ ] Tag resources for cost allocation
  - [ ] Enable Azure Cost Management integration
  - [ ] Set up cost alerts
  - [ ] Review and optimize storage costs

- [ ] **Resource Quotas**
  - [ ] Implement namespace resource quotas
    ```bash
    oc create quota compute-quota \
      --hard=pods=10,requests.cpu=4,requests.memory=8Gi,limits.cpu=8,limits.memory=16Gi \
      -n <namespace>
    ```

  - [ ] Configure limit ranges
  - [ ] Monitor quota usage
  - [ ] Document quota allocation strategy

### Cost Optimization

- [ ] **OpenShift Cost Management**
  - [ ] Enable cost management operator
  - [ ] Configure cost reporting to Azure Cost Management
  - [ ] Create cost allocation tags
  - [ ] Set up chargeback reports by namespace/team
  - [ ] Review cost trends monthly

### GitOps & CI/CD

- [ ] **GitOps Setup**
  - [ ] Deploy OpenShift GitOps (ArgoCD) operator
    ```bash
    oc create -f openshift-gitops-operator-subscription.yaml
    ```
  - [ ] Configure Git repository connections (GitHub, GitLab, Azure Repos)
  - [ ] Create AppProjects for team isolation
  - [ ] Set up application sync policies
  - [ ] Configure SSO with Azure AD for ArgoCD
  - [ ] **Cross-tenant GitOps** (if applicable):
    - [ ] Configure ArgoCD to deploy across multiple clusters
    - [ ] Set up cluster secrets for managed clusters
  - [ ] Document GitOps workflow and promotion process

- [ ] **CI/CD Pipelines**
  - [ ] Deploy OpenShift Pipelines (Tekton) operator
    ```bash
    oc create -f openshift-pipelines-operator-subscription.yaml
    ```
  - [ ] Create pipeline templates for common workflows
    - [ ] Build → Test → Scan → Deploy
    - [ ] Container image builds
    - [ ] Helm chart deployments
  - [ ] Configure webhook triggers (GitHub, GitLab)
  - [ ] Set up pipeline service accounts with appropriate RBAC
  - [ ] **Azure DevOps Integration:**
    - [ ] Deploy Azure DevOps agents in ARO
    - [ ] Configure agent pools
    - [ ] Set up pipelines to deploy to ARO
    - [ ] Configure Azure Container Registry integration
  - [ ] **GitHub Actions Integration:**
    - [ ] Create OIDC provider for GitHub Actions
    - [ ] Configure secrets for cluster access
    - [ ] Set up deployment workflows
  - [ ] Document pipeline best practices

### Developer Tools & Experience

- [ ] **OpenShift Dev Spaces** (cloud-based IDEs)
  - [ ] Deploy Dev Spaces operator
  - [ ] Configure custom domains for workspaces
    ```yaml
    apiVersion: org.eclipse.che/v2
    kind: CheCluster
    metadata:
      name: devspaces
      namespace: openshift-devspaces
    spec:
      networking:
        domain: <custom-domain>
        tlsSecretName: <tls-secret>
    ```
  - [ ] Create devfile templates for common stacks
  - [ ] Configure workspace resource limits
  - [ ] Set up persistent storage for workspaces
  - [ ] Integrate with Git repositories
  - [ ] Document Dev Spaces onboarding for developers

- [ ] **Developer Sandbox/Self-Service**
  - [ ] Create namespace provisioning automation
  - [ ] Set up developer portal or self-service UI
  - [ ] Configure default resource quotas for new namespaces
  - [ ] Provide sample applications and templates
  - [ ] Document self-service procedures

- [ ] **Developer Training & Documentation**
  - [ ] Create getting started guides
  - [ ] Provide sample pipelines and workflows
  - [ ] Document best practices for containerization
  - [ ] Set up internal knowledge base
  - [ ] Schedule regular developer workshops

### Enterprise Applications & Platforms

- [ ] **Ansible Automation Platform**
  - [ ] Deploy Ansible Automation Platform operator
  - [ ] Configure automation controller
  - [ ] Set up automation hub for content management
  - [ ] Connect to Azure resources via service principal or managed identity
  - [ ] Create automation workflows for cluster management
  - [ ] Document playbook repository structure

- [ ] **IBM Maximo Application Suite** (if applicable)
  - [ ] Plan storage requirements for Maximo
  - [ ] Deploy Maximo operator
  - [ ] Configure database backend (Azure SQL or in-cluster)
  - [ ] Set up asset monitoring and predictive maintenance
  - [ ] Configure IoT connectors
  - [ ] Document Maximo deployment topology

- [ ] **Red Hat Integration** (if applicable)
  - [ ] Deploy Red Hat Integration operator (Fuse, AMQ, 3scale)
  - [ ] Configure message brokers (AMQ Streams/Kafka)
  - [ ] Set up API management (3scale)
  - [ ] Configure service connectivity with Azure services
  - [ ] Document integration patterns

- [ ] **SAP Data Intelligence** (if applicable)
  - [ ] Validate ARO cluster meets SAP requirements
  - [ ] Configure storage for SAP DI
  - [ ] Deploy SAP Data Intelligence
  - [ ] Connect to Azure data sources
  - [ ] Document SAP deployment and architecture

### Documentation & Training

- [ ] **Operational Documentation**
  - [ ] Document cluster architecture and design decisions
  - [ ] Create runbooks for common operations
  - [ ] Document escalation procedures
  - [ ] Maintain configuration change log

- [ ] **User Training**
  - [ ] Provide developer onboarding documentation
  - [ ] Create self-service guides for common tasks
  - [ ] Document support channels
  - [ ] Schedule regular training sessions

## Day N: Operational Excellence

### Regular Maintenance Tasks

**Daily**
- [ ] Review cluster operator status
- [ ] Monitor critical alerts
- [ ] Check backup job status
- [ ] Review security events

**Weekly**
- [ ] Analyze resource utilization trends
- [ ] Review certificate expiration dates
- [ ] Scan for vulnerable container images
- [ ] Review and prune unused resources
- [ ] Review NSG flow logs and audit NSG rule changes (if BYO NSG)

**Monthly**
- [ ] Review and test DR procedures
- [ ] Update documentation
- [ ] Review RBAC assignments
- [ ] Analyze cost trends and optimize
- [ ] Review and update compliance scans

**Quarterly**
- [ ] Plan and execute cluster upgrades
- [ ] Review and update security policies
- [ ] Conduct disaster recovery drills
- [ ] Review and optimize architecture

## Common Issues & Troubleshooting

### BYO NSG Troubleshooting

**Issue: Cluster creation fails with NSG-related errors**

*Symptoms:*
- Cluster deployment hangs or fails during provisioning
- Error messages reference network connectivity issues

*Resolution:*
```bash
# Verify NSG is attached to subnets
az network vnet subnet show \
  --resource-group <rg> \
  --vnet-name <vnet-name> \
  --name master-subnet \
  --query networkSecurityGroup.id

# Check ARO service principal has Network Contributor on NSGs
az role assignment list \
  --assignee <service-principal-id> \
  --scope /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/networkSecurityGroups/<nsg-name>

# Review effective NSG rules
az network nsg show \
  --resource-group <rg> \
  --name <nsg-name> \
  --query securityRules
```

**Issue: Nodes not registering or in NotReady state**

*Symptoms:*
- `oc get nodes` shows nodes in NotReady state
- Master or worker VMs cannot communicate

*Resolution:*
```bash
# Verify critical NSG rules exist
# Check master-to-worker API access (port 6443)
# Check worker-to-master MCS access (port 22623)
# Verify AzureLoadBalancer rules are present

# Test connectivity from worker to master
az network watcher connectivity test \
  --source-resource <worker-vm-id> \
  --dest-resource <master-vm-id> \
  --dest-port 6443 \
  --protocol Tcp
```

**Issue: Ingress traffic not reaching applications**

*Symptoms:*
- Applications unreachable from outside cluster
- Load balancer health probes failing

*Resolution:*
```bash
# Verify worker NSG allows traffic from AzureLoadBalancer
az network nsg rule show \
  --resource-group <rg> \
  --nsg-name <worker-nsg> \
  --name AllowAzureLB

# Check ingress controller service
oc get svc -n openshift-ingress

# Verify NSG allows ports 80/443 from Internet (if public cluster)
az network nsg rule list \
  --resource-group <rg> \
  --nsg-name <worker-nsg> \
  --query "[?direction=='Inbound' && (destinationPortRange=='80' || destinationPortRange=='443')]"
```

**Issue: ARO unable to modify NSG rules during operations**

*Symptoms:*
- Cluster operators degraded
- Events show permission errors

*Resolution:*
```bash
# Verify service principal permissions
az role assignment create \
  --assignee <service-principal-id> \
  --role "Network Contributor" \
  --scope /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/networkSecurityGroups/<nsg-name>

# Check service principal is not expired
az ad sp show --id <service-principal-id> --query passwordCredentials
```

**Issue: NSG flow logs showing unexpected denies**

*Symptoms:*
- Legitimate traffic being blocked
- High deny counts in NSG metrics

*Resolution:*
```bash
# Download and analyze flow logs
az storage blob download \
  --account-name <storage-account> \
  --container-name insights-logs-networksecuritygroupflowevent \
  --name <blob-name> \
  --file flowlog.json

# Review denied flows
cat flowlog.json | jq '.records[] | select(.properties.flows[].flows[].flowTuples[] | contains("D"))'

# Check effective NSG rules on specific VM
az network nic show-effective-route-table \
  --resource-group <cluster-rg> \
  --name <nic-name>
```

### General ARO Troubleshooting

**Issue: Cluster operators degraded**

*Resolution:*
```bash
oc get co
oc describe co <operator-name>
oc logs -n <operator-namespace> <pod-name>
```

**Issue: Nodes not scaling**

*Resolution:*
```bash
# Check machine sets
oc get machineset -n openshift-machine-api

# Check machine controller logs
oc logs -n openshift-machine-api -l api=clusterapi
```

**Issue: Authentication failures after Azure AD configuration**

*Resolution:*
```bash
# Verify OAuth configuration
oc get oauth cluster -o yaml

# Check OAuth pod logs
oc logs -n openshift-authentication -l app=oauth-openshift
```

## References

- [ARO Documentation](https://docs.openshift.com/aro/4/welcome/index.html)
- [Azure ARO Best Practices](https://learn.microsoft.com/azure/openshift/)
- [OpenShift 4.x Documentation](https://docs.openshift.com/container-platform/4.14/)
- [ARO Network Requirements](https://learn.microsoft.com/azure/openshift/concepts-networking)
- [ARO Support Policies](https://learn.microsoft.com/azure/openshift/support-policies-v4)
- [Azure NSG Overview](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview)
- [NSG Flow Logs](https://learn.microsoft.com/azure/network-watcher/network-watcher-nsg-flow-logging-overview)
