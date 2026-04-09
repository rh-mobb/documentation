---
date: '2026-04-02'
title: ROSA Architecture Decision Checklist
tags: ["ROSA", "ROSA HCP", "Best practices", "Architecture"]
authors:
  - Red Hat Cloud Experts
---

Use this checklist when planning a new ROSA deployment or reviewing an existing one. Each item captures a key decision, a safe default, and a pointer to the full rationale in the [ROSA Best Practices and Recommendations](/experts/rosa/best-practices-recommendations/) guide.

Work through the phases in order. Phases 1 and 2 lock in decisions that are hard or impossible to change later; phases 3 and 4 can iterate as workloads evolve. The [quick-reference summary](#quick-reference-summary) at the end lists every decision point with its safe default on one page.

## Phase 1: Pre-provisioning (before `rosa create cluster`)

Decisions in this phase are difficult to reverse after cluster creation.

### 1. Cluster model

| | |
|---|---|
| **Decision** | ROSA with Hosted Control Planes (HCP) or ROSA Classic? |
| **Safe default** | HCP for new deployments. |
| **When to deviate** | Large existing Classic fleet mid-migration; Spot Instance machine pools (Classic only). |
| **Full rationale** | [Fundamental architecture and the paradigm shift](/experts/rosa/best-practices-recommendations/#fundamental-architecture-and-the-paradigm-shift) |

### 2. VPC, CIDR, and Availability Zones

{{% alert state="warning" %}}This is the most consequential network decision you will make. Machine, pod, and service CIDRs **cannot be changed after cluster creation**. Undersizing limits your maximum node count and pods-per-node ceiling for the life of the cluster. When a cluster runs out of address space the only remediation is standing up additional clusters, which introduces cross-cluster routing, split deployment decisions, service mesh or federation complexity, and operational overhead that compounds over time. Run the numbers with the [OpenShift Network Calculator](/experts/calculator/) and validate with your network team **before** you provision.{{% /alert %}}

| | |
|---|---|
| **Decision** | How many AZs? What CIDR ranges for machine, pod, and service networks? |
| **Safe default** | 3 AZs for production. Use ROSA defaults (machine `10.0.0.0/16`, pod `10.128.0.0/14`, service `172.30.0.0/16`, host prefix `23`) unless IPAM or federation requires otherwise. Plan `/22` or larger for machine CIDR when approaching 500 workers. Keep pod, service, and machine CIDRs unique across on-premises and cloud networks if you need routable connectivity later. |
| **When to deviate** | Dev/test can use fewer AZs. Existing enterprise IPAM may dictate non-default ranges, but never go below the HCP minimums (`/25` single-AZ, `/24` multi-AZ) and always leave headroom for growth beyond your day-1 node count. |
| **Full rationale** | [VPC and CIDR architecture](/experts/rosa/best-practices-recommendations/#vpc-and-cidr-architecture), [OpenShift Network Calculator](/experts/calculator/) |

### 3. Cluster API and network exposure

| | |
|---|---|
| **Decision** | Private or public API? Private or public application ingress? |
| **Safe default** | Private API, private default ingress. Add a dedicated edge VPC for internet-facing workloads. |
| **When to deviate** | Dev/sandbox where public API simplifies access; non-regulated workloads where public Routes are acceptable. |
| **Full rationale** | [Private clusters, landing-zone ingress, and application DNS/TLS](/experts/rosa/best-practices-recommendations/#private-clusters-landing-zone-ingress-and-application-dnstls) |

### 4. Egress model

| | |
|---|---|
| **Decision** | Zero-egress, proxy/firewall egress, or unrestricted NAT? |
| **Safe default** | Zero-egress or centralized firewall/proxy via Transit Gateway for regulated estates. |
| **When to deviate** | Teams that need full internet for rapid iteration (dev clusters, PoCs). |
| **Full rationale** | [Zero-Egress and Secure Egress architectures](/experts/rosa/best-practices-recommendations/#zero-egress-and-secure-egress-architectures) |

### 5. IAM, STS, and OIDC

| | |
|---|---|
| **Decision** | Have you created STS roles, OIDC config, and scoped IAM policies? |
| **Safe default** | Always STS mode. Create a reusable OIDC configuration shared across clusters. Scope every role to least privilege. |
| **When to deviate** | Rarely. Static IAM keys are a gap to close, not a design choice. |
| **Full rationale** | [Identity and Access Management through STS and OIDC](/experts/rosa/best-practices-recommendations/#identity-and-access-management-through-sts-and-oidc) |

### 6. Encryption at rest

| | |
|---|---|
| **Decision** | AWS-managed keys or customer-managed keys (CMK/BYOK) in KMS? |
| **Safe default** | CMK for regulated or multi-tenant estates; separate keys for data, backups, and audit. |
| **When to deviate** | Non-regulated, single-tenant environments where AWS-managed keys are acceptable. |
| **Full rationale** | [Security, identity, and encryption on AWS](/experts/rosa/best-practices-recommendations/#security-identity-and-encryption-on-aws) |

### 7. Instance types and machine pools

| | |
|---|---|
| **Decision** | Which EC2 family? Graviton (ARM) or x86? Multiple pool sizes? |
| **Safe default** | Current-gen general-purpose (e.g. m6i/m7g); evaluate Graviton when images are multi-arch. Use multiple pools to isolate noisy workloads (batch, GPU, ingress). |
| **When to deviate** | Memory- or compute-optimized families for specialized tiers (databases, ML). |
| **Full rationale** | [Instance Type Optimization and Graviton](/experts/rosa/best-practices-recommendations/#instance-type-optimization-and-graviton), [Worker memory, allocatable capacity, and mixed machine pools](/experts/rosa/best-practices-recommendations/#worker-memory-allocatable-capacity-and-mixed-machine-pools) |

### 8. AWS service quotas

| | |
|---|---|
| **Decision** | Have you reviewed and raised quotas for VPC, ELB, EC2, and ROSA limits in your target region? |
| **Safe default** | Review defaults during architecture review, not the day before cutover. |
| **Full rationale** | [Reliability scope, quotas, and backups](/experts/rosa/best-practices-recommendations/#reliability-scope-quotas-and-backups) |

---

## Phase 2: Day-1 cluster configuration (first hours after creation)

### 9. Identity provider and admin access

| | |
|---|---|
| **Decision** | Which external IdP (OIDC, LDAP, Entra ID, Okta)? Who gets `dedicated-admin`? How is break-glass handled? |
| **Safe default** | External IdP with MFA. Remove `kubeadmin` after validation. Store break-glass credentials in a managed vault. Reserve `cluster-admin` for exceptional, policy-reviewed grants. |
| **Full rationale** | [OIDC Configuration and Identity Providers](/experts/rosa/best-practices-recommendations/#oidc-configuration-and-identity-providers), [ROSA customer administration and break-glass](/experts/rosa/best-practices-recommendations/#rosa-customer-administration-and-break-glass) |

### 10. Security baselines (SCC and Pod Security)

| | |
|---|---|
| **Decision** | Which SCC for workloads? How do you enforce `restricted` as the default? |
| **Safe default** | `restricted` (or `restricted-v2`) SCC for all workloads unless a documented exception exists. Custom SCCs over granting `privileged`. Namespace Pod Security labels aligned with SCC admission. |
| **Full rationale** | [Security Context Constraints (SCC) and Pod Security](/experts/rosa/best-practices-recommendations/#security-context-constraints-scc-and-pod-security), [Pod security context baselines](/experts/rosa/best-practices-recommendations/#pod-security-context-baselines-complements-scc) |

### 11. Project templates and tenant defaults

| | |
|---|---|
| **Decision** | Do new Projects get baseline `ResourceQuota`, `LimitRange`, `NetworkPolicy`, and `EgressFirewall` automatically? |
| **Safe default** | Yes. Configure a project request template so every Project inherits deny-by-default network policy, quotas, and limit ranges. |
| **Full rationale** | [Projects, quotas, and project request templates](/experts/rosa/best-practices-recommendations/#projects-quotas-and-project-request-templates) |

### 12. Network isolation

| | |
|---|---|
| **Decision** | Default-deny `NetworkPolicy` per namespace? `EgressFirewall` for external destinations? |
| **Safe default** | Default-deny ingress and egress per namespace, with allow rules for the ingress controller and approved external APIs. |
| **Full rationale** | [Network isolation with NetworkPolicies and Egress Firewalls](/experts/rosa/best-practices-recommendations/#network-isolation-with-networkpolicies-and-egress-firewalls) |

### 13. Observability stack

| | |
|---|---|
| **Decision** | User workload monitoring enabled? Where do logs land (Loki, CloudWatch, SIEM)? Control plane log forwarding configured? |
| **Safe default** | Enable user workload monitoring. Forward cluster and control-plane logs to CloudWatch or your SIEM. Federate metrics to Amazon Managed Service for Prometheus or equivalent for long-term retention. |
| **Full rationale** | [Centralized logging and metrics federation](/experts/rosa/best-practices-recommendations/#centralized-logging-and-metrics-federation), [Application observability](/experts/rosa/best-practices-recommendations/#application-observability-logs-metrics-traces-and-slos) |

### 14. GitOps and CI/CD operators

| | |
|---|---|
| **Decision** | Install OpenShift GitOps (Argo CD) and/or OpenShift Pipelines (Tekton)? External CI integration? |
| **Safe default** | OpenShift GitOps for declarative desired state. OpenShift Pipelines or external CI for build/test/promote. Pin Subscriptions with Manual `installPlanApproval`. |
| **Full rationale** | [CI/CD and GitOps (platform-native)](/experts/rosa/best-practices-recommendations/#cicd-and-gitops-platform-native) |

### 15. Secret management

| | |
|---|---|
| **Decision** | How are secrets delivered to workloads? Manual `Secret` YAML, or automated sync from a central store? |
| **Safe default** | External Secrets Operator syncing from AWS Secrets Manager (or Vault) with IRSA-backed authentication. Namespace-scoped `SecretStore` with least-privilege IAM. |
| **Full rationale** | [Configuration, secrets, and external secret management](/experts/rosa/best-practices-recommendations/#configuration-secrets-and-external-secret-management) |

### 16. Compliance scanning

| | |
|---|---|
| **Decision** | Which compliance profiles (CIS, PCI-DSS, FedRAMP)? |
| **Safe default** | Install the Compliance Operator, select profiles matching your regulatory posture, and review scan results on a regular cadence. |
| **Full rationale** | [The OpenShift Compliance Operator](/experts/rosa/best-practices-recommendations/#the-openshift-compliance-operator) |

---

## Phase 3: Workload onboarding (per application or team)

### 17. Health probes

| | |
|---|---|
| **Decision** | Does every container define liveness, readiness, and (where needed) startup probes? |
| **Safe default** | Distinct liveness (`/livez`, narrow deadlock detection) and readiness (`/readyz`, dependency-aware) endpoints. Startup probes for slow-init apps. |
| **Don't** | Reuse the same heavy endpoint for both liveness and readiness; that causes restart loops under load. |
| **Full rationale** | [Health probes and the container lifecycle](/experts/rosa/best-practices-recommendations/#health-probes-and-the-container-lifecycle) |

### 18. Graceful shutdown

| | |
|---|---|
| **Decision** | Does the application handle SIGTERM? Is `terminationGracePeriodSeconds` tuned? |
| **Safe default** | Stop accepting new work on SIGTERM, drain in-flight requests, and set the grace period to cover p99 latency. Use `preStop` hooks for deregistration when needed. |
| **Full rationale** | [Graceful shutdown and rolling updates](/experts/rosa/best-practices-recommendations/#graceful-shutdown-and-rolling-updates) |

### 19. Resource requests, limits, and QoS

| | |
|---|---|
| **Decision** | Do all containers have CPU and memory requests and limits? |
| **Safe default** | Always set requests. Set memory limits. Be deliberate with CPU limits (they throttle via CFS). Use VPA in recommendation-only mode to right-size before committing. |
| **Don't** | Deploy without requests: the scheduler cannot place Pods fairly and the cluster autoscaler cannot react. |
| **Full rationale** | [Resource management and QoS](/experts/rosa/best-practices-recommendations/#resource-management-and-qos) |

### 20. Scheduling and spread

| | |
|---|---|
| **Decision** | Are replicas spread across nodes and AZs? |
| **Safe default** | Use `topologySpreadConstraints` for node and zone spread. Run 3+ replicas for tier-1 services. Pair with PDBs. |
| **Don't** | Run a single replica and call it "HA" because the cluster is multi-AZ. |
| **Full rationale** | [Scheduling spread, affinity, and noisy neighbors](/experts/rosa/best-practices-recommendations/#scheduling-spread-affinity-and-noisy-neighbors) |

### 21. Pod Disruption Budgets

| | |
|---|---|
| **Decision** | Does every stateful or tier-1 workload have a PDB? |
| **Safe default** | `maxUnavailable: 1` (or equivalent) so drains and upgrades can proceed. |
| **Don't** | Set `minAvailable` equal to your total replica count; that blocks all node drains and cluster upgrades. |
| **Full rationale** | [Pod Disruption Budgets (PDBs)](/experts/rosa/best-practices-recommendations/#pod-disruption-budgets-pdbs) |

### 22. Storage selection

| | |
|---|---|
| **Decision** | EBS (RWO), EFS (RWX), S3 (object), or ephemeral? |
| **Safe default** | EBS via CSI (gp3, tuned IOPS) for most RWO workloads. EFS only when true RWX is required. S3 for blobs, data lakes, and off-cluster backups. Avoid large `emptyDir` or `hostPath`. |
| **Don't** | Promise RWX on EBS-backed StorageClasses. Use `hostPath` in shared clusters without security review. |
| **Full rationale** | [Persistent storage, CSI, and data planes on AWS](/experts/rosa/best-practices-recommendations/#persistent-storage-csi-and-data-planes-on-aws) |

### 23. Backing services

| | |
|---|---|
| **Decision** | Managed AWS service (RDS, ElastiCache, DynamoDB) or in-cluster StatefulSet? |
| **Safe default** | Managed services for tier-1 data. In-cluster operators are valid for dev/test or when you fully own the support story. |
| **Don't** | Run a single-replica in-cluster database for production without documenting it as a deliberate SPOF. |
| **Full rationale** | [Managed backing services vs in-cluster state on AWS](/experts/rosa/best-practices-recommendations/#managed-backing-services-vs-in-cluster-state-on-aws) |

### 24. Application AWS access (IRSA)

| | |
|---|---|
| **Decision** | How do Pods authenticate to AWS APIs (S3, Secrets Manager, RDS, SQS)? |
| **Safe default** | IRSA: dedicated `ServiceAccount` per app, dedicated IAM role with least-privilege trust policy scoped to the cluster OIDC issuer and exact `sub` claim. |
| **Don't** | Embed `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in Secrets, ConfigMaps, or Deployment env vars. |
| **Full rationale** | [Application workloads: IRSA, STS, and AWS credentials](/experts/rosa/best-practices-recommendations/#application-workloads-irsa-sts-and-aws-credentials) |

### 25. Service accounts and RBAC

| | |
|---|---|
| **Decision** | Dedicated ServiceAccount per workload? Token automount disabled when not needed? |
| **Safe default** | One SA per app, `automountServiceAccountToken: false` for Pods that do not call the Kubernetes API. Minimal Role/ClusterRole bindings. |
| **Full rationale** | [Service accounts and RBAC for workloads](/experts/rosa/best-practices-recommendations/#service-accounts-and-rbac-for-workloads) |

### 26. Container image hygiene

| | |
|---|---|
| **Decision** | Images pinned by digest? Base image rebuild process? |
| **Safe default** | Pull by digest or one-to-one tagged builds. Rebuild on CVE fixes as part of normal change cadence. |
| **Don't** | Use unbounded `:latest` in production. |
| **Full rationale** | [Container images, digests, and CVE response](/experts/rosa/best-practices-recommendations/#container-images-digests-and-cve-response) |

### 27. Routes, TLS, and ingress

| | |
|---|---|
| **Decision** | TLS mode per Route (edge, passthrough, reencrypt)? Certificate source (cert-manager, ACM, manual)? |
| **Safe default** | TLS on every Route. cert-manager Operator for on-cluster certs with automated renewal. ACM for TLS terminated on ALB/CloudFront at the edge. External DNS Operator to sync Route hostnames to Route 53. |
| **Don't** | Expose Routes without TLS. Manually rotate wildcard certs pasted into Secrets. Hardcode IPs instead of FQDNs. |
| **Full rationale** | [OpenShift Routes, ingress policy, and OVN semantics on ROSA](/experts/rosa/best-practices-recommendations/#openshift-routes-ingress-policy-and-ovn-semantics-on-rosa) |

---

## Phase 4: Steady-state operations

### 28. Upgrade strategy

| | |
|---|---|
| **Decision** | How do you stage control plane and machine pool upgrades? |
| **Safe default** | Upgrade the hosted control plane first, then machine pools in sequence. Verify `ClusterOperator` health and Insights findings after each step. Use node surge so capacity is not reduced during upgrades. |
| **Full rationale** | [Decoupled upgrade strategy](/experts/rosa/best-practices-recommendations/#decoupled-upgrade-strategy), [API compatibility and upgrade readiness](/experts/rosa/best-practices-recommendations/#api-compatibility-and-upgrade-readiness) |

### 29. Autoscaling

| | |
|---|---|
| **Decision** | How do you scale nodes, replicas, and per-Pod resources? |
| **Safe default** | Cluster autoscaler for node capacity (at least one pool per AZ). HPA for replica scaling on CPU or custom metrics. VPA in recommendation-only mode to inform request/limit tuning. For predictable spikes, schedule capacity ahead of demand. |
| **Full rationale** | [Multi-Dimensional Autoscaling](/experts/rosa/best-practices-recommendations/#multi-dimensional-autoscaling) |

### 30. Cost optimization

| | |
|---|---|
| **Decision** | Savings Plans or Reserved Instances for steady pools? Consistent tagging for chargeback? |
| **Safe default** | Savings Plans for production workers. Tag VPC, LB, and machine pool resources with environment, cost center, and application keys. |
| **Full rationale** | [Financial engineering and cost optimization](/experts/rosa/best-practices-recommendations/#financial-engineering-and-cost-optimization), [Performance, FinOps tags, and predictable capacity](/experts/rosa/best-practices-recommendations/#performance-finops-tags-and-predictable-capacity) |

### 31. Disaster recovery and backup

| | |
|---|---|
| **Decision** | What is your RPO and RTO? HA scope (in-region) vs DR scope (cross-region)? |
| **Safe default** | Multi-AZ workers + spread Pods + multi-AZ managed data for in-region HA. Workload-scoped backup (RDS snapshots, EBS snapshots, Velero/OADP per namespace) rather than whole-cluster restore as the default story. Rehearse restores on a schedule. |
| **Don't** | Conflate multi-AZ HA with full regional DR. Promise "high availability" without multi-AZ data and enough spread replicas. |
| **Full rationale** | [Disaster Recovery and business continuity](/experts/rosa/best-practices-recommendations/#disaster-recovery-and-business-continuity) |

### 32. Multi-Region (if applicable)

| | |
|---|---|
| **Decision** | Hot/hot, hot/warm, or hot/cold posture? Data replication strategy? |
| **Safe default** | Hot/warm for most enterprise DR. Pair with Aurora Global, S3 CRR, Route 53 failover, and ECR cross-region replication. IaC and GitOps to rebuild the secondary cluster within RTO. |
| **Full rationale** | [Multi-Region and Global Connectivity](/experts/rosa/best-practices-recommendations/#multi-region-and-global-connectivity) |

### 33. Proactive health checks

| | |
|---|---|
| **Decision** | How do you catch drift before it becomes an incident? |
| **Safe default** | Insights Advisor for platform recommendations. Periodic cluster health scripts (operator status, unbounded Pods, privileged SCC, PDB violations). Compliance Operator scans. |
| **Full rationale** | [Proactive health monitoring with Insights Advisor](/experts/rosa/best-practices-recommendations/#proactive-health-monitoring-with-insights-advisor), [Health assessment framework and investigative scripting](/experts/rosa/best-practices-recommendations/#health-assessment-framework-and-investigative-scripting) |

### 34. Infrastructure as code

| | |
|---|---|
| **Decision** | How are VPCs, peering, and landing zones provisioned? |
| **Safe default** | Terraform, CloudFormation, or ROSA CLI + versioned manifests. Console steps are fine for illustration but should not be the only path to reproduce production. |
| **Full rationale** | [Operational excellence: IaC, observability, and residency](/experts/rosa/best-practices-recommendations/#operational-excellence-iac-observability-and-residency) |

---

## Quick-reference summary

Download the same rows as [best-practices-checklist-decisions.csv](/experts/rosa/best-practices-checklist-decisions.csv) (columns: `id`, `phase`, `decision_point`, `safe_default`).

| # | Decision point | Safe default |
|---|---|---|
| **Pre-provisioning** | | |
| [1](#1-cluster-model) | HCP or Classic? | HCP for new deployments |
| [2](#2-vpc-cidr-and-availability-zones) | AZs and CIDR ranges | 3 AZs; ROSA defaults; `/22`+ machine CIDR at scale |
| [3](#3-cluster-api-and-network-exposure) | Private or public API / ingress? | Private API + edge VPC for internet workloads |
| [4](#4-egress-model) | Egress model | Zero-egress or firewall/proxy via TGW |
| [5](#5-iam-sts-and-oidc) | STS roles, OIDC, IAM scoping | STS always; reusable OIDC; least-privilege roles |
| [6](#6-encryption-at-rest) | AWS-managed or CMK in KMS? | CMK for regulated / multi-tenant estates |
| [7](#7-instance-types-and-machine-pools) | EC2 families and pool layout | Current-gen GP; evaluate Graviton; multiple pools |
| [8](#8-aws-service-quotas) | Quotas reviewed and raised? | Review during architecture review, not cutover |
| **Day-1 configuration** | | |
| [9](#9-identity-provider-and-admin-access) | IdP, admin model, break-glass | External IdP + MFA; remove kubeadmin; vault for break-glass |
| [10](#10-security-baselines-scc-and-pod-security) | SCC baseline and enforcement | `restricted` for all; custom SCCs over `privileged` |
| [11](#11-project-templates-and-tenant-defaults) | Project template with defaults? | Auto-create quota + NetworkPolicy + LimitRange |
| [12](#12-network-isolation) | NetworkPolicy and EgressFirewall | Default-deny per namespace |
| [13](#13-observability-stack) | Monitoring, logging, metrics | User workload monitoring + log forwarding to CloudWatch/SIEM |
| [14](#14-gitops-and-cicd-operators) | GitOps / CI / CD operators | OpenShift GitOps + Pipelines or external CI |
| [15](#15-secret-management) | Secret delivery mechanism | ESO + Secrets Manager via IRSA |
| [16](#16-compliance-scanning) | Compliance profiles | Compliance Operator with regulatory profiles |
| **Workload onboarding** | | |
| [17](#17-health-probes) | Probe design per workload | Distinct liveness (`/livez`) and readiness (`/readyz`) |
| [18](#18-graceful-shutdown) | SIGTERM handling and grace period | Handle SIGTERM; tune `terminationGracePeriodSeconds` |
| [19](#19-resource-requests-limits-and-qos) | Requests, limits, QoS | Always set requests; VPA recommend-only to inform sizing |
| [20](#20-scheduling-and-spread) | Topology spread, replica count | `topologySpreadConstraints` + 3+ replicas for tier-1 |
| [21](#21-pod-disruption-budgets) | PDB policy | `maxUnavailable: 1` |
| [22](#22-storage-selection) | Storage tier per workload | EBS gp3 (RWO); EFS only for RWX; S3 for objects |
| [23](#23-backing-services) | Managed vs in-cluster state | Managed AWS services for tier-1 data |
| [24](#24-application-aws-access-irsa) | IRSA wiring per app | Dedicated SA + IAM role per app; no static keys |
| [25](#25-service-accounts-and-rbac) | SA and RBAC scoping | Dedicated SA; `automountServiceAccountToken: false` |
| [26](#26-container-image-hygiene) | Image pinning and rebuild | Pin by digest; rebuild on CVE |
| [27](#27-routes-tls-and-ingress) | TLS mode and cert source | TLS always; cert-manager + External DNS |
| **Steady-state operations** | | |
| [28](#28-upgrade-strategy) | Upgrade sequencing | Control plane first, then pools; verify ClusterOperators |
| [29](#29-autoscaling) | CA / HPA / VPA | CA per AZ + HPA + VPA recommend-only |
| [30](#30-cost-optimization) | Savings Plans, tagging | Savings Plans for production; consistent FinOps tags |
| [31](#31-disaster-recovery-and-backup) | RPO, RTO, backup scope | Workload-scoped backup; rehearse restores |
| [32](#32-multi-region-if-applicable) | Multi-Region posture | Hot/warm + Aurora Global / S3 CRR / Route 53 |
| [33](#33-proactive-health-checks) | Health check tooling | Insights + health scripts + Compliance Operator |
| [34](#34-infrastructure-as-code) | IaC tooling | Terraform / CloudFormation / ROSA CLI in Git |
