---
date: '2026-04-01'
title: ROSA Best Practices and Recommendations
tags: ["ROSA", "ROSA HCP", "ROSA Classic", "Best practices"]
authors:
  - Red Hat Cloud Experts
validated_version: "4.18"
---

## About this guide

**Purpose:** This guide collects architectural and operational recommendations for Red Hat OpenShift Service on AWS (ROSA), with emphasis on Hosted Control Planes (HCP) and how it compares to ROSA Classic. It spans networking, identity (STS, OIDC, IRSA), workload reliability, security and compliance, software supply chain, GitOps and CI/CD, scaling, cost, disaster recovery, and alignment with the AWS Well-Architected Framework. Citations point to product documentation; examples use `rosa`, `oc`, and `aws` where they help operators validate posture.

**Audience:** Platform engineers, SREs, cloud and OpenShift architects, and lead application teams designing or running ROSA estates. Core Kubernetes or OpenShift and AWS networking familiarity is assumed; specialized topics link to Red Hat and AWS docs rather than re-derive fundamentals.

The architectural evolution of managed Kubernetes on AWS has reached a significant milestone with the introduction of **Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Planes (HCP)**. ROSA HCP builds on the same fully managed ROSA [Classic] experience by decoupling the control plane from the data plane and hosting that control plane in a Red Hat-managed AWS account. That frees customer accounts to focus capacity on applications. [^1] The result is a smaller minimum footprint in your VPC, cluster creation on the order of ten minutes, and the same SRE-backed operations customers expect from ROSA. [^3] Many customers adopt or migrate to HCP when they want that leaner data-plane footprint and faster provisioning while staying on a single familiar platform. The body of this guide synthesizes Red Hat’s operational expertise with the AWS Well-Architected Framework for hosted control plane deployments.

Across a fleet of ROSA clusters, [Red Hat Advanced Cluster Management for Kubernetes (ACM)](https://www.redhat.com/en/technologies/management/advanced-cluster-management) extends these practices with hub-level governance, policy-driven configuration, application lifecycle management (including GitOps integration), and a single operational view of clusters and workloads, which suits teams that standardize ROSA HCP from a central platform org. [^71] [Red Hat Advanced Cluster Security for Kubernetes (ACS)](https://www.redhat.com/en/technologies/cloud-computing/openshift/advanced-cluster-security-kubernetes) adds deep image vulnerability scanning, deploy-time risk scoring, runtime threat detection, and OpenShift-native security policies that complement OpenShift’s built-in controls and ROSA’s managed boundary. [^70]

## Fundamental architecture and the paradigm shift

The core of the ROSA HCP value proposition lies in the separation of concerns. ROSA Classic runs a highly available control plane in your AWS account (typically seven or more EC2 instances for masters, workers, and infrastructure), so every layer stays visible in your cost and capacity reports while Red Hat SREs continue to operate the cluster end to end. [^1] ROSA with HCP moves that control plane into a Red Hat-managed service account, so your bill and VPC center on worker and application capacity; Red Hat SREs still own availability and performance of the control plane. [^1] Both models remove customer toil for etcd quorums and API server lifecycle; HCP adds a streamlined path for teams that want maximum focus on application delivery and the smallest data-plane footprint. [^6]

The connectivity between the worker nodes in the customer’s VPC and the control plane in the Red Hat-managed account is established through AWS PrivateLink. [^1] That keeps control-plane connectivity off the public internet while still supporting public API endpoints for developers where you enable them. Classic uses established in-VPC networking between your control plane and workers; HCP standardizes on PrivateLink for the hosted control plane path. That fits cleanly with AWS landing zones and private connectivity patterns. HCP also gives you independent upgrade lanes for the hosted control plane and each machine pool, so you can stage change with fine-grained control. [^3]

#### Detailed architectural comparison of ROSA models

| Architectural Feature | ROSA with HCP | ROSA Classic |
| :---- | :---- | :---- |
| Control Plane Location | Red Hat-owned AWS account | Customer-owned AWS account |
| Management Responsibility | Full Red Hat SRE management (control plane off-cluster) | Full Red Hat SRE management (control-plane EC2 in your account) |
| Communication Interface | AWS PrivateLink | Internal VPC networking |
| Minimum Node Requirement | 2 Worker nodes | 7-9 Nodes (3 Master, 3 Worker, 2-3 Infra) |
| Provisioning Velocity | ~10 minutes | ~40 minutes |
| Lifecycle Flexibility | Independent hosted control plane and machine pool upgrades | Coordinated cluster-wide upgrade cadence |
| EC2 in customer account | Workers and data-plane resources | Workers, Classic control plane, and infra nodes |

> *Source:* [^1]

ROSA with HCP extends the strong compliance story customers already trust on ROSA: programs such as HIPAA-eligible use on the service, FedRAMP High milestones for hosted control planes in AWS GovCloud, and FIPS-enabled clusters at install time are all part of how teams run regulated workloads on OpenShift on AWS. [^1] The full matrix of regions, offerings, and attestations evolves with the product. For the latest, see the authoritative [ROSA compliance and security documentation](https://docs.aws.amazon.com/rosa/latest/userguide/security.html). Organizations comparing Classic and HCP will find both supported under the same managed-service model; choose the architecture that matches your accounting, networking, and migration timeline. Published examples combining HCP with multi-year AWS commitments have cited on the order of ~37% infrastructure savings and ~68% savings versus on-demand in representative scenarios; treat those as signals to explore with your AWS account team. [^6]

## Strategic infrastructure and network design

A resilient ROSA HCP environment is built on a foundation of meticulously designed networking. ROSA HCP follows a Bring Your Own VPC (BYO-VPC) model: you prepare subnets and routing before cluster creation so the platform lands exactly where your security and landing-zone standards require. [^2] That upfront design is a strength: it lets you embed OpenShift in existing guardrails instead of adapting your enterprise network to a one-size-fits-all cluster network.

#### Cluster pod network (OVN-Kubernetes)

ROSA and current OpenShift Container Platform clusters use **OVN-Kubernetes** as the default cluster network (CNI). Pod overlay routing, NetworkPolicy, EgressFirewall, egress IP, and related dataplane features are implemented in OVN. The legacy OpenShift SDN plugin is not available on current releases. When you read older runbooks or community posts that assume OpenShift SDN, translate those patterns to OVN-Kubernetes behavior, limits, and troubleshooting instead. See [About the OVN-Kubernetes network plugin](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/ovn-kubernetes_network_plugin/about-ovn-kubernetes) in the OpenShift documentation. [^75]

#### VPC and CIDR architecture

The primary recommendation for VPC design is the implementation of a centralized landing zone architecture for business-critical applications. This approach uses a secured PrivateLink and Security Token Service (STS) enabled cluster where all ingress and egress traffic is routed through a managed firewall or proxy server. This design minimizes the attack surface and ensures that cluster traffic adheres to corporate security policies. For private API endpoints, VPC and CIDR alignment, and proxy options on ROSA, see [Infrastructure security in ROSA](https://docs.aws.amazon.com/rosa/latest/userguide/infrastructure-security.html) in the AWS documentation.

When calculating CIDR ranges for the Pod, Service, and Machine networks, architects must account for the maximum anticipated scale of the cluster. [^9] Early alignment with your network team pays dividends for routing simplicity and growth, especially if you keep Pod, Service, and Machine CIDRs unique across on-premises and cloud networks. Planning those ranges before install keeps connectivity straightforward through the life of the cluster.

| Network Requirement | Configuration Best Practice | Priority |
| :---- | :---- | :---- |
| Availability Zones | Minimum of 3 AZs for production environments | High |
| Subnet Segregation | Separate public and private subnets per AZ | High |
| Machine CIDR | Match the VPC CIDR (usually /16) | High |
| Service CIDR | Minimum /16 to support large-scale microservices | High |
| Pod CIDR | Sufficiently large to prevent IP exhaustion (e.g., /14) | High |
| DNS Settings | Set enableDnsHostnames and enableDnsSupport to true | High |

> *Source:* [^9]

Verification of the VPC configuration can be performed using the AWS CLI. To ensure that DNS attributes are correctly set, which is vital for Route 53 and PrivateLink interoperability, the following command should be executed:

```bash
aws ec2 describe-vpc-attribute --vpc-id <VPC_ID> --attribute enableDnsHostnames
```

#### Advanced DNS mechanics in HCP

DNS resolution in ROSA HCP aligns with patterns used by other AWS services such as Amazon RDS, giving operators a consistent, certificate-friendly DNS model across the AWS ecosystem. [^7] The same idea appears with internal Application Load Balancers and Network Load Balancers: the service DNS name is publicly resolvable, but it resolves to private IP addresses inside your VPC. ROSA HCP uses a Public Hosted Zone to handle certificate validation for API endpoints and application routes. While these records are public, they resolve exclusively to private IP addresses within the customer’s VPC. [^7] This ensures that even if a client on the public internet can resolve the DNS name, the traffic is blocked at the network layer because there is no internet-facing route to the private load balancer. [^7]

For private clusters, it is essential to configure DNS forwarders to resolve internal service URLs and ensure that the VPC can communicate with the AWS PrivateLink endpoints used for control plane management; see [Infrastructure security in ROSA](https://docs.aws.amazon.com/rosa/latest/userguide/infrastructure-security.html) in the AWS documentation. Hardcoding IP addresses is strongly discouraged; all application communication should utilize Fully Qualified Domain Names (FQDNs) to maintain portability and resilience during cluster maintenance. [^7]

#### Zero-Egress and Secure Egress architectures

Zero-egress-ready ROSA HCP gives you a strong foundation for compliance and supply-chain control: the install profile (for example `--properties zero_egress:true`) pairs the cluster with in-region Amazon ECR for Red Hat mirrored platform images, so trusted payload is close to your workloads on the AWS network. To realize a fully private posture, extend that foundation with your own egress controls (firewalls, egress gateways, or routing policies) so only the destinations you approve (ECR endpoints, PrivateLink, corporate proxies, and mirrored registries) are reachable. Without those network boundaries, the cluster retains the flexibility to use the public internet for OperatorHub, application dependencies, telemetry, and other features. That flexibility suits teams that want speed and breadth; add controls when policy requires lock-down.

Once egress is aligned with policy, you gain predictable pulls from ECR for mirrored platform content and a clear hook for golden-operator practices: cluster administrators curate Operator and catalog content via mirroring and restricted-network patterns in Red Hat documentation, so teams consume only approved artifacts. Layer image scanning and promotion policy on registries (see About this guide) so promoted workloads stay auditable. Optional capabilities that assume public endpoints (for example some telemetry or add-on flows) are tuned or supplemented in line with that architecture. Customers accept that adjustment as an explicit trade for stronger assurance. [^14]

Create a zero-egress-oriented cluster with the `--properties zero_egress:true` flag when using the ROSA CLI. [^14] Confirm the worker role can access in-region ECR, for example by attaching a read-only ECR policy when your design calls for it:

```bash
aws iam attach-role-policy --role-name ManagedOpenShift-HCP-ROSA-Worker-Role --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
```

Additionally, for load balancer integration in private subnets, subnets must be tagged correctly. Pre-flight checks should include verification of the following tag:

```bash
aws ec2 describe-tags --filters "Name=resource-id,Values=<subnet_id>" --query "Tags[?Key=='kubernetes.io/role/internal-elb']"
```

#### Private clusters, landing-zone ingress, and application DNS/TLS

Enterprise landing zones (hub-and-spoke setups with Transit Gateway, inspection or egress VPCs, and centrally governed DNS) share one goal with OpenShift on AWS: keep the workload data plane private and pass north-south traffic through known VPC paths, firewalls, proxies, and edge services, not ad hoc `0.0.0.0/0` on application subnets.

**Do:**

- Treat private ROSA API and bounded ingress exposure as the baseline for regulated and production internet-facing estates unless policy explicitly needs a public API surface.
- Align egress with NAT gateway, egress VPC, TGW, firewall, corporate proxy, or [zero-egress](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_clusters/rosa-hcp-egress-zero-install) installs as in Zero-Egress and Secure Egress architectures above.
- Front internet workloads with a dedicated edge or public VPC (peering or TGW) instead of opening worker subnets broadly.
- Use additional `IngressController` custom resources so platform listeners (private NLB) stay separate from selectively exposed application Routes.
- Document Internet → ALB → NLB → OpenShift Route (or equivalent) when AWS load balancers sit in front of the ingress operator Service.
- Prefer Amazon CloudFront and AWS WAF off-cluster for DDoS, geography, and L7 inspection.
- Make TLS ownership explicit when AWS terminates (ACM certificates on ALB) before traffic reaches Routes.
- Automate DNS and certificates with Route 53 patterns, cert-manager Operator, External DNS Operator, and/or ACM instead of manual records or pasted Secrets alone.

**Don’t:**

- Imply “we use a landing zone” without egress and ingress paths that match NetworkPolicy / `EgressFirewall` (see Network isolation later) and AWS routing reality.
- Burn worker CPU on full WAF inspection when a regional edge service is appropriate.
- Terminate TLS at ALB without validating SNI, Host, and backend protocol against OpenShift Route semantics.
- Hardcode IPs. Use FQDNs only (see Advanced DNS mechanics in HCP).

**Private API and listener posture:** Private ROSA clusters keep the Kubernetes and OpenShift API on private networking; application Routes still need a deliberate listener strategy (internal NLB for corporate access, public edge for customers) rather than a default public wildcard when your threat model calls for segmentation. Confirm visibility flags when auditing:

```bash
rosa describe cluster -c <cluster_name_or_id>
oc get ingresscontroller -n openshift-ingress-operator -o custom-columns=NAME:.metadata.name,DOMAIN:.status.domain,TYPE:.status.endpointPublishingStrategy.type
```

**Segmenting controllers:** Add `IngressController` instances (for example scoped `domain` and private `endpointPublishingStrategy`) so blast radius stays small. Use one controller for platform or CI routes, another for tenant apps, or regional variants as your DNS design requires. Product patterns live under [Configuring the Ingress Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/configuring-ingress-cluster-traffic) in the OpenShift documentation. [^83]

**Edge VPC and load balancers:** Common high-trust patterns place an internet-facing ALB or NLB in a peer or TGW-attached VPC, forward to an internal NLB or node ports that terminate at OpenShift ingress, and restrict security groups so only the edge tier is internet-reachable. Document that chain when you reference private clusters with public FQDNs so reviewers can see how DNS maps to listeners. Step-by-step patterns appear in this site’s [HCP private cluster + public NLB in edge VPC](/experts/rosa/hcp-private-nlb/) and [private ingress controller + public ALB + WAF considerations](/experts/rosa/private-ingress-controller-with-alb/) guides.

**Egress alignment:** `EgressFirewall`, NAT, TGW inspection, egress proxy, and zero-egress mirroring are complementary layers. Pick the combination your security team signs off on so workloads cannot bypass policy via mis-tagged subnets or overly permissive NAT routes. Network isolation with NetworkPolicies and Egress Firewalls (later in this guide) expands namespace-level controls.

**AWS WAF and CloudFront:** Attach AWS WAF to ALB, API Gateway, or CloudFront distributions that front OpenShift when you need managed rules, geo blocks, or bot controls. Prefer that edge over duplicating WAF logic inside every Pod. CloudFront patterns (with optional WAF) are illustrated in [CloudFront + WAF in front of the workload](/experts/rosa/waf/cloud-front/).

**TLS when ALB terminates with ACM:** AWS Certificate Manager (ACM) fits when TLS ends on ALB, NLB (with appropriate TLS listeners where used), or CloudFront, with managed renewal and IAM-scoped attachment to load balancers. When ALB terminates, the path to OpenShift may be plain HTTP or re-encrypted TLS; validate Host and SNI forwarding so Routes match virtual hosts. For `passthrough` Routes, expect client TLS end-to-end, so ALB TLS termination on that hop is usually wrong. `reencrypt` and `edge` Routes still matter when the ingress controller handles certificates closer to Pods. Contrast ACM with in-cluster automation below. [^82]

**DNS, wildcards, and FQDNs:** Route 53 public zones for API and apps often pair with private targets. Keep wildcard strategy (per-team subdomains vs shared SAN) consistent with certificate issuance and audit. Never embed load balancer IPs in docs or manifests; use FQDNs that track lifecycle (Advanced DNS mechanics in HCP).

**cert-manager Operator for Red Hat OpenShift:** Install via OperatorHub to issue and renew certificates from ACME (Let’s Encrypt), private CAs, or Vault or other issuer integrations using `Certificate` and `Issuer` CRs. That reduces manual Secret rotation and long-lived wildcard material checked into Git. See [cert-manager Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift) in the OpenShift documentation. [^84]

**External DNS Operator:** Sync Route and Service hostnames to Route 53 (and other providers) from cluster state so DNS stays aligned with GitOps. Avoid console-only A/ALIAS tweaks after each deploy. See External DNS under [Networking Operators](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking_operators/index) in the OpenShift documentation. [^85]

**ACM vs cert-manager (summary):** Use ACM certificates on AWS edge load balancers and CDN when that matches your termination point; use cert-manager (or manually managed Secrets with rotation discipline) when Routes or Ingress terminate on-cluster or you need Pod- or mesh-local PKI. Many estates combine both: ACM north-south and cert-manager for internal or mTLS tiers.

Quick checks for HostedZone awareness (replace the DNS name suffix):

```bash
aws route53 list-hosted-zones-by-name --dns-name apps.example.com --max-items 5
oc get certificates -A 2>/dev/null | head -20
```

(`oc get certificates` lists cert-manager `Certificate` custom resources when the operator is installed.)

## Identity and Access Management through STS and OIDC

The security model of ROSA HCP is fundamentally rooted in the AWS Security Token Service (STS). This mechanism provides a significant security advantage over static, long-term credentials by utilizing short-lived, dynamic tokens for all administrative and operational actions. [^16] In the HCP architecture, Red Hat SREs and internal cluster operators obtain credentials that expire in one hour or less, drastically reducing the risk of credential theft or leakage. [^16]

#### IAM Roles and the Principle of Least Privilege

ROSA HCP leverages two distinct sets of IAM roles: account-wide roles and operator-specific roles. [^16] Account-wide roles establish the foundational trust between the customer’s AWS account and Red Hat’s management tools, allowing Red Hat SREs to provide support and manage infrastructure. [^19] Operator-specific roles are more granular, assigned to specific pods within the cluster (for example the Ingress Controller or the EBS CSI driver) via OpenID Connect (OIDC). [^16] This follows the IAM Roles for Service Accounts (IRSA) pattern, ensuring that each cluster component has only the exact permissions required for its function.

| Role Type | Purpose | Critical Managed Policy |
| :---- | :---- | :---- |
| Installer Role | Used for initial provisioning and deletion | ROSAInstallerPolicy |
| Support Role | Allows Red Hat SRE to perform diagnostics | ROSASRESupportPolicy |
| Worker Role | Permissions for worker node lifecycle | ROSAWorkerInstancePolicy |
| Ingress Operator | Manages Load Balancers and Route 53 | ROSAIngressOperatorPolicy |
| Storage Operator | Manages EBS volume attachments | ROSAAmazonEBSCSIDriverOperatorPolicy |
| Control Plane Operator | Manages CP components in Red Hat account | ROSAControlPlaneOperatorPolicy |

> *Source:* [^16]

Administrators can verify the existence and configuration of these roles using the rosa CLI. A healthy cluster should return a list of roles associated with the specific OIDC provider:

```bash
rosa describe cluster -c <cluster_name>
```

#### OIDC Configuration and Identity Providers

Creating a reusable OIDC configuration is a recommended best practice for organizations managing multiple ROSA HCP clusters. This configuration establishes the identity-based trust relationship required for STS roles to function. [^19] During installation, the OIDC provider creation mode should be set to auto to ensure that the provider is correctly linked to the AWS account. [^20] For consistent IdP and RBAC across many clusters, use hub-level governance over imported clusters (see About this guide). [^71]

Post-installation, administrators must configure an external identity provider (IdP) for user authentication, as the default kubeadmin user is removed for security reasons. [^22] Supported providers include OpenID Connect (OIDC), LDAP, and GitHub. [^9] The integration of a centralized identity provider, such as Azure AD or Okta, is highly recommended to enforce Multi-Factor Authentication (MFA) and consistent RBAC policies across the enterprise. See [Configuring identity providers](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/authentication_and_authorization/configuring-identity-providers) in the OpenShift documentation.

When you need cluster-admin-style access outside that IdP flow (for example break-glass or temporary platform work), you can create a dedicated administrator user with the ROSA CLI using a strong secret generated and handled according to your organization’s policy (not a reused or predictable password). Some administrators keep such a user provisioned and store the credential in a managed vault (for example AWS Secrets Manager) with least-privilege IAM access, rotation, and auditing; others create an admin user only for a specific task and delete it when finished. **Follow your own security standards** for lifecycle, storage, and who may mint or use these credentials.

Creating or Deleting an ad-hoc Admin user:

```bash
rosa create admin -c <cluster_name> -p '<password>'
rosa delete admin -c <cluster_name>
```


Verification of the configured identity providers can be performed with the following command:

```bash
rosa list idps --cluster <cluster_name>
```

#### Application workloads: IRSA, STS, and AWS credentials

The IAM Roles and the Principle of Least Privilege subsection above describes account- and platform-operator roles. Application teams need the same STS-first discipline: workloads that call S3, DynamoDB, SQS, Secrets Manager, RDS (IAM DB auth), or other AWS APIs on ROSA should use IAM Roles for Service Accounts (IRSA). IRSA ties together a Kubernetes `ServiceAccount`, a projected service-account token, and an IAM role whose trust policy allows `sts:AssumeRoleWithWebIdentity` from your cluster OIDC issuer. Avoid long-lived IAM user access keys in Secrets or environment variables.

**Do:**

- Give each app (or integration) a dedicated `ServiceAccount` and a dedicated IAM role scoped with least privilege (specific actions and resource ARNs; for example `s3:GetObject` on one prefix, not `s3:*`).
- Tighten the role trust policy to the cluster OIDC URL and the exact `sub` claim (`system:serviceaccount:<namespace>:<name>`).
- Use `sts:AssumeRole` (short-lived) for cross-account or hub-and-spoke patterns with documented chaining.
- Run External Secrets Operator (ESO) controllers with IRSA so they read Secrets Manager without static keys.
- Prefer IAM DB authentication for RDS where it fits, in addition to network controls (security groups, PrivateLink).
- Log and audit AssumeRole paths like any other sensitive operation.

**Don’t:**

- Copy `<your-access-key-here>` into Deployment examples.
- Share one IAM user across many workloads.
- Use `system:serviceaccount:*` (or `StringLike` on `sub` that is too broad) in the trust policy.
- Stash database passwords in ConfigMaps when Secrets Manager plus ESO or IAM DB auth is available.
- Forget that RDS needs both reachability and auth. IAM tokens do not replace security groups or private DNS.

**Workload review:** Treat `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (or raw opaque keys clearly for AWS) in container env, Secret data, or ConfigMap payloads as a review finding unless you document a time-bound exception (legacy vendor, air-gap tooling, and similar). Prefer IRSA so pods receive short-lived session credentials that CloudTrail can tie back to the role and ServiceAccount. [^86]

**ServiceAccount and role wiring:** Annotate the `ServiceAccount` with the role ARN your platform pattern uses (on AWS ROSA this follows the EKS-compatible `eks.amazonaws.com/role-arn` convention referenced in AWS and ROSA guidance). Mount the projected token in the Pod (OpenShift injects the bounded-audience token volume when the annotation is present); ensure the application SDK picks up the web identity credential chain. [^86]

**Trust policy shape:** The OIDC provider ARN and `sub` must match this cluster and namespace tuple. Shared roles across unrelated namespaces usually mean `sub` was loosened too far. Prefer one role per ServiceAccount over one mega-role per cluster.

**RDS and IAM database authentication:** IAM DB auth issues database connection tokens tied to AWS identity. Wire that through IRSA-backed SDK usage and keep it separate from VPC routing, security groups, and TLS to the instance. Avoid publishing cleartext master passwords in sample YAML for production paths. [^87]

**Cross-account access:** Use `sts:AssumeRole` into a target-account role with another narrow policy. Never embed second-account keys on worker nodes shared by all Pods. Document chains (which role trusts which issuer or principal) so auditors can follow blast radius.

**External Secrets Operator:** The sync controller that reads Secrets Manager or Parameter Store should assume AWS credentials the same way applications do: use IRSA on the operator `ServiceAccount`, not keys in the operator namespace. Configuration, secrets, and external secret management (under Application reliability and workload resilience below) expands ESO patterns.

**Platform parity:** Ingress, CSI, and other Red Hat operators already use STS-style roles; first-party application content should not normalize weaker patterns in copy-paste samples.

**Operational habits:** Default to short-lived credentials, rotate what must stay static on a calendar, and record who can bind IAM to ServiceAccounts (often cluster RBAC on ServiceAccount annotation or namespace admin). Align with organizational IAM review and CloudTrail auditing expectations described in AWS ROSA security material. [^86]

Annotate trust and inventory without printing secrets:

```bash
rosa describe cluster -c <cluster_name_or_id> | grep -i -E 'OIDC|Operator roles'
oc get serviceaccount -n <namespace> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}{end}'
```

Describe one application ServiceAccount to verify projection and annotations:

```bash
oc describe serviceaccount <sa-name> -n <namespace>
```

## Application reliability and workload resilience

Application reliability in ROSA HCP is a [shared responsibility](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition#rosa-policy-responsibility-matrix). While the platform provides the necessary primitives for resilience, developers must architect their workloads to survive infrastructure failures and the automated maintenance cycles inherent in a managed service.

##### Health probes and the container lifecycle

The foundation of application reliability is the implementation of health check probes in every pod definition. [^27] These probes allow OpenShift, through the kubelet on each node, to make informed decisions about the state of a container.

1. **Liveness Probes:** These determine if a container is alive. If a liveness probe fails, OpenShift restarts the container, which is critical for recovering from application deadlocks or hangs. [^26]
2. **Readiness Probes:** These determine if a container is ready to serve traffic. A failing readiness probe removes the pod from the associated service's endpoints, preventing users from receiving "Service Unavailable" errors. [^27]
3. **Startup Probes:** These are designed for legacy or slow-starting applications. They delay liveness and readiness checks until the application has finished its initialization process, preventing premature restarts during the boot phase. [^26]

**Probe design:** Liveness and readiness should not blindly reuse the same HTTP endpoint or identical logic. Liveness should be narrow and exist only to detect deadlocks or hung processes worthy of a restart. Readiness should reflect whether the instance can serve traffic right now (dependencies up, migrations complete, warm caches). Using the same heavy check, or a readiness signal that fails under load, as liveness often causes restart loops during spikes. Prefer distinct paths (for example `/livez` vs `/readyz`) and stricter timeouts on liveness than readiness where appropriate.

| Probe Type | Recommended Test | Use Case |
| :---- | :---- | :---- |
| Liveness | HTTP GET (e.g., /healthz) | Detects process crashes or infinite loops |
| Readiness | HTTP GET (e.g., /readyz) | Ensures DB connections and cache are ready |
| Startup | Exec command (e.g., cat /tmp/ready) | For apps that take minutes to initialize |

> *Source:* [^27]

Verification of probe status for a running workload can be achieved by describing the pod and inspecting the Conditions and Events sections:

```bash
oc describe pod <pod_name> -n <namespace>
```

#### Graceful shutdown and rolling updates

**SIGTERM and drain time:** During node drains, rollouts, and scale-downs, the kubelet sends SIGTERM to each container and waits up to `terminationGracePeriodSeconds` before SIGKILL. Applications should stop accepting new work and drain in-flight requests (or jobs) within that window, then exit. Set `terminationGracePeriodSeconds` to fit your p99 latency and batch completion time, not only the default, so OpenShift does not truncate legitimate shutdown work during ROSA maintenance or your own deploys. See [Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination) in the Kubernetes documentation.

**preStop hooks:** When draining needs an explicit step before the main process sees SIGTERM (deregistering from a discovery backend, sleeping briefly to allow Route or endpoint propagation, or nudging a sidecar), configure a `lifecycle.preStop` hook. Pair hooks with an adequate `terminationGracePeriodSeconds` so the hook and application both have time to finish.

**Rolling update strategy:** For Deployments, `spec.strategy.rollingUpdate` should match your availability targets. `maxSurge` and `maxUnavailable` control how many extra or missing Pods are acceptable during a revision change; `minReadySeconds` keeps a new Pod ready for a soak interval before the controller counts it available and proceeds, which reduces flapping when readiness probes need a few seconds to stabilize. These settings interact with PodDisruptionBudgets (below): an overly aggressive `maxUnavailable` on the workload plus a tight PDB can stall node drains and cluster upgrades. See [Rolling updates](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#rolling-update-deployment) in the Kubernetes documentation.

**Readiness gates traffic:** Readiness probes remove the Pod from Service and OpenShift Route endpoints while they fail. Users should not hit instances that are mid-startup or unable to reach required backends. Align readiness with dependencies (databases, caches, feature flags) so rollouts shift traffic only when replicas can actually serve.

#### Configuration, secrets, and external secret management

**ConfigMaps vs Secrets:** use `ConfigMap` for non-sensitive configuration (feature flags, file templates, service URLs) and `Secret` for credentials, tokens, TLS private keys, and any data that would trigger a security incident if leaked. Kubernetes still base64-encodes Secret values at rest in etcd. That encoding is not application-level encryption, so treat the API and RBAC boundary as part of your threat model. See [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) and [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) in the Kubernetes documentation.

**Size and sprawl:** keep individual ConfigMaps and Secrets within documented size limits (very large objects stress the API and etcd and slow watches). Split bulky config across multiple objects, mount only what each Pod needs, or move large blobs to object storage (for example S3) with short-lived access via IRSA (see Application workloads: IRSA, STS, and AWS credentials under Identity and Access Management through STS and OIDC) instead of stuffing megabytes into a single Secret.

**Immutability:** where you promote manifests through GitOps or CI, mark `ConfigMap` / `Secret` resources `immutable: true` once a version is canonical so accidental in-place edits do not race with controllers; roll forward by creating a new object or revision rather than mutating production payloads silently.

**Rotation and lifecycle:** Production clusters should not rely on “we created a Secret once.” Prefer automated sync from AWS Secrets Manager or AWS Systems Manager Parameter Store (for SecureString and lower-sensitivity parameters), HashiCorp Vault, or another approved backend using the [External Secrets Operator for Red Hat OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/latest/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift) (install from OperatorHub on supported versions), community External Secrets where your support model allows, Secrets Store CSI with a provider, or Vault Agent-style injection, using whichever option your enterprise standardizes. Authenticate the sync path with IRSA and STS on ROSA (not long-lived IAM user keys on the operator). Prefer namespace-scoped store configuration and least-privilege IAM roles over one cluster-wide integration mapped to an overly broad secret path. Define refresh behavior: when the upstream secret rotates, whether workloads pick up values via reload or need a rollout, and document that operational choice. A hands-on pattern for Secrets Manager on ROSA HCP is in [Using AWS Secrets Manager with External Secrets Operator on ROSA HCP](/experts/rosa/eso/).

**Sealed Secrets and pipeline-only patterns:** Bitnami Sealed Secrets, SOPS, or CI-generated Secret manifests can be valid when you document who can seal, key rotation, and blast radius. They are weaker defaults than a central secret service for high-rotation credentials unless you explicitly accept that trade.

**Operational hygiene:** never log secret values, print them in startup banners, or commit cleartext credentials to Git; use `stringData` only in ephemeral apply pipelines, then rely on RBAC and audit for cluster-side reads.

#### Resource management and QoS

To prevent node overcommitment and Out-of-Memory (OOM) kills, it is mandatory to define resource requests and limits for every container. Resource requests are used by the scheduler to find a node with sufficient capacity, while resource limits cap the amount of CPU and memory a container can consume. [^32]

**Enforce discipline at the project boundary:** pair pod-level settings with `ResourceQuota` on each OpenShift project (namespace) so teams inherit hard budgets for CPU, memory, object counts, and storage. Add `LimitRange` in the same project to default or bound requests and limits for workloads that omit them. That keeps scheduling predictable and caps unexpected growth inside a shared cluster. [^32] For cluster-wide patterns across many projects, `ClusterResourceQuota` applies quotas by label selector (for example per team or cost center).

**Admission control beyond quotas:** many organizations add a validating admission layer so non-compliant Pods never reach the API. OPA Gatekeeper (policies expressed in Rego) is a common pattern to deny creation of workloads missing required `resources.requests` / `resources.limits`, or violating your CPU/memory ratio rules. That complements quotas with deterministic rejections at create time. Alternatives such as Kyverno or (on newer OpenShift releases) ValidatingAdmissionPolicy offer the same class of guardrail with different policy languages. Fleet-wide policy placement is covered with Resource quotas and Limit Ranges below.

**Sizing limits wisely:** CPU limits are enforced through the kernel scheduler (CFS quota); they quota CPU time over intervals, so aggressive limits can throttle latency-sensitive apps even when nodes have spare capacity. OpenShift applies these mechanics on workers the same way as upstream Kubernetes; read [Resource management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) for how requests and limits interact with the scheduler and the time-slicing behavior of CPU limits, then load-test before locking in production values. [^33]

**Rightsize with VPA in recommendation-only mode:** run the Vertical Pod Autoscaler with `updateMode: Off` so it recommends CPU and memory requests and limits from observed usage without mutating or restarting Pods. That makes it a practical way to tune values before you commit them in Git, LimitRanges, or quota-backed admission rules. Then promote changes deliberately after review and load validation. Automatic VPA modes are discussed under Multi-Dimensional Autoscaling.

A critical second-order insight is the role of memory requests in Java applications. Because the JVM does not always release memory back to the operating system immediately, scaling based on memory utilization (HPA) can be inefficient. Instead, CPU-based scaling is recommended for most JVM workloads. [^33]

Administrators should regularly audit their clusters for pods without defined limits using the following diagnostic command:

```bash
oc get pods -A -o json | jq '.items[] | select(any(.spec.containers[]?; (.resources.limits // null) == null)) | .metadata.name'
```

#### Persistent storage, CSI, and data planes on AWS

**StorageClass and performance:** every `PersistentVolumeClaim` should reference a `StorageClass` chosen for IOPS, throughput, and cost, not the cluster default without review. On ROSA, Amazon EBS-backed classes (provisioned through the cluster storage operator and AWS EBS CSI driver) are the usual block tier; gp3 lets you tune baseline IOPS and throughput independently of capacity, which matters for latency-sensitive databases and indexes. Align encrypted volumes with your KMS posture (see AWS best practices in your organizational standards). See [Dynamic provisioning](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/) and [Storage classes](https://kubernetes.io/docs/concepts/storage/storage-classes/) in the Kubernetes documentation, and [Understanding persistent storage](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/storage/understanding-persistent-storage) in the OpenShift documentation for how StorageClass, PV, and PVC interact.

**Volume expansion:** if data grows in place, confirm the StorageClass has `allowVolumeExpansion: true`, use a CSI driver that supports resize, and plan filesystem growth inside the guest (where required). Failing to design expansion forces offline migrations or risky attach/detach playbooks.

**Snapshots, backup, and RPO:** In-cluster PVCs are not a backup strategy by themselves. Design backup around workloads and application data: plan to restore a namespace, database, bucket prefix, or volume, not “the whole cluster” as the default story, so RPO, RTO, and runbooks match what teams actually rehearse. Use CSI volume snapshots (where enabled) for named PVCs, and Velero or OpenShift API for Data Protection (OADP) for scoped Kubernetes API object backup (namespaces, labels, schedules) and selected volumes when that fits your support model. Cluster-wide snapshots are a narrow platform pattern, not the typical application story; pair with application-consistent or logical backup when crash-only copies are not enough. Compare to Amazon RDS and Aurora automated backups and PITR when state lives off-cluster. State your RPO explicitly (for example “we snapshot nightly” versus “we replay the transaction log”).

**StatefulSets and headless Services:** ordered Pods with stable network identity use `StatefulSet` plus a `volumeClaimTemplate` so each replica gets its own PVC, and typically a `ClusterIP: None` (headless) Service so DNS resolves per-Pod records. Do not treat a Deployment with a shared RWX volume as a drop-in substitute unless your storage truly supports shared POSIX semantics.

**Access modes:** ReadWriteOnce (RWO) maps cleanly to EBS volumes attached to one node at a time, which suits most PostgreSQL- or MySQL-style data directories. ReadWriteMany (RWX) requires a file or object abstraction that supports multi-writer POSIX or NFS semantics (for example Amazon EFS or Amazon FSx file backends via their CSI drivers where ROSA and OpenShift support them). Do not promise RWX on an EBS-backed StorageClass. Validate supportability and performance for CSI add-ons on your exact cluster version.

**Right tool for the workload (CSI and beyond):**

* **Block / RWO (EBS via CSI):** default for Kubernetes-native state: most Deployments and StatefulSets that need a local filesystem. Prefer EBS over EFS when RWO isolation and cost predictability matter.
* **Shared file / RWX:** use when multiple Pods must mount the same POSIX directory concurrently (content farms, some ML feature stores, legacy apps); expect latency and ops tradeoffs versus block.
* **Object (S3):** web assets, data lakes, large immutable blobs, and cross-region patterns; use SDKs, batch COPY, or Mountpoint for Amazon S3-style patterns. Those are not a blind replacement for POSIX databases.
* **Ephemeral scratch:** `emptyDir` consumes node ephemeral or root disk and can hurt I/O fairness on shared workers; avoid large or high-throughput `emptyDir` or `hostPath` in production (`hostPath` also carries security risk). If scratch is unavoidable, set `sizeLimit`, keep lifetimes short, or use a small dedicated PVC tier.

**Operator path:** name the Red Hat and AWS operators you rely on, including AWS EBS CSI (often installed as Amazon EBS CSI Driver Operator on ROSA) plus any EFS or FSx CSI you add, so readers know what carries snapshot, resize, and support contracts. See the product [Storage](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/storage/index) guide for Red Hat OpenShift Service on AWS.

#### Managed backing services vs in-cluster state on AWS

**Principle:** ROSA excels at running applications. Durable, patched, multi-AZ data tiers often belong in AWS managed services so backup, failover, and capacity limits are enforced outside the cluster upgrade cycle. Running PostgreSQL, MySQL, Redis, or similar software in-cluster is valid for labs, edge cases, or Kubernetes-native operators you fully support, but production designs should compare that path to managed alternatives.

**Relational databases:** Amazon RDS and Aurora provide Multi-AZ deployments, read replicas, automated backups, and point-in-time recovery (PITR) with clear operational contracts. A StatefulSet plus PVC pattern couples database lifecycle to node drains, CSI snapshots, and cluster upgrades you schedule with OpenShift; it also concentrates single-writer risk if you run one replica without external replication. When you do keep a database on the cluster, document replication, backup, and who owns patching, and treat a single Pod and disk as a deliberate single point of failure (SPOF) unless you have another high-availability story.

**Caches and NoSQL:** Amazon ElastiCache (Redis- and Memcached-compatible engines), Amazon MemoryDB for Redis, and Amazon DynamoDB offload replication, shard limits, and (for on-demand modes) elastic throughput. In-cluster Redis or Valkey StatefulSets are common for dev/test or strict data-locality needs, but tier-1 clusters usually need multi-AZ caches and observable failover. Compare operational cost before standardizing on do-it-yourself operators.

**Multi-region and DR:** When the business needs geo redundancy or regional failover, pair data choices with networking (for example Aurora Global Database, RDS cross-region read replicas with promotion, DynamoDB global tables, S3 cross-region replication, and Route 53 routing policies). Single-region, single-AZ databases are a conscious RTO/RPO trade, not an implicit HA posture; align with Disaster Recovery and business continuity later in this guide.

**Serverless vs provisioned:** Aurora Serverless v2, DynamoDB on-demand, and similar models reduce capacity planning for spiky traffic but introduce scaling semantics, possible cold-start latency on some engines, and billing curves that differ from fixed instance fleets. Call those out when you recommend them so finance and SREs share expectations.

**SPOF audit:** One broker, one database instance, or one AZ for a tier-1 service should carry an explicit risk footnote: add replicas, failover, or move to a managed multi-AZ tier. This pairs with Pod disruption budgets, topology spread, and DR runbooks.

**Network placement:** Reach managed endpoints over private VPC routes (security groups, interface endpoints, transit gateway, or VPC peering), consistent with private cluster and landing zone patterns. Avoid publicly exposing database ports in secure baselines; if public surfaces exist, document the exception and compensating controls.

#### Pod Disruption Budgets (PDBs)

PDBs are the "stage managers" of an OpenShift cluster, ensuring that a minimum level of service availability is maintained during voluntary disruptions like cluster upgrades or node draining. A PDB specifies either the minimum number of pods that must remain available (minAvailable) or the maximum number that can be unavailable (maxUnavailable). [^35]

A significant operational risk occurs when a PDB is misconfigured. For example, if an application has only two replicas and a PDB with minAvailable: 2, the cluster will be unable to drain a node hosting one of those pods, effectively blocking the upgrade process. [^37] It is recommended to always leave room for at least one disruption by using maxUnavailable: 1 or by increasing the replica count before maintenance. [^37]

Verification of PDB status across all namespaces:

```bash
oc get pdb -A -o wide
```

#### Scheduling spread, affinity, and noisy neighbors

The default scheduler optimizes for fitting Pods onto nodes; without extra rules, several replicas of the same Deployment can land on one worker if requests fit. That is a single point of failure for the node and it concentrates shared host limits that OpenShift does not isolate per Pod.

**Noisy neighbors** on Linux mean more than CPU steal or memory pressure: every container on a node shares the same kernel connection tracking table (`nf_conntrack` / conntrack-max-style limits), process and file-descriptor budgets (`ulimit` and cgroup semantics where they apply), ephemeral port space for outbound connections, connection churn to the same backends, and ingress path load on the node’s networking stack. A highly connected API gateway, ingress controller, or service mesh sidecar tier amplifies that problem: all ingress throughput through a handful of Pods on one node can exhaust those tables or file handles long before CPU or memory quotas look saturated.

**Spread replicas across nodes (and zones):** use `podTopologySpreadConstraints` so the scheduler keeps skew low across `kubernetes.io/hostname` (nodes) and, for intra-region AZ resilience, across `topology.kubernetes.io/zone`. Prefer `DoNotSchedule` when missing capacity should surface as Pending (driving HPA or cluster autoscaler) rather than silently stacking gateways on one host. [^73]

```yaml
spec:
  template:
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: api-gateway
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: api-gateway
```

**Pod anti-affinity** is the classic alternative: `requiredDuringSchedulingIgnoredDuringExecution` with a `podAffinityTerm` that matches your app’s labels and `topologyKey: kubernetes.io/hostname` forbids two gateway Pods on the same node. Use it when you need hard exclusion; combine with enough replicas and nodes or scheduling stays impossible. `podAffinity` (co-location) suits sidecars or cache locality; use it sparingly so you do not undo spread goals.

**Node selectors vs node affinity:** `nodeSelector` is a simple map of required node labels (`matchLabels` only). `nodeAffinity` adds soft preferences (`preferredDuringSchedulingIgnoredDuringExecution`) and `In` / `NotIn` expressions that fit GPU, ARM (Graviton), dedicated machine pools, or topology hints. Affinity rules interact with taints and tolerations on ROSA machine pools; align pool labels and taints with what your templates require.

**Operational checklist:** run at least three gateway replicas in production where you require AZ and node spread; pair spread rules with PDBs so drains remain feasible; load-test with realistic concurrent connections and validate node-level metrics (not only Pod CPU); and document when teams must not pin gateways with `nodeSelector` to a single pool. See [Assigning Pods to Nodes](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/) and [Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) in the upstream Kubernetes documentation; scheduling semantics are the same in OpenShift. For scheduling, affinity, and placement in the OpenShift documentation, see [Working with pods](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/working-with-pods). [^72] [^73] [^74]

#### Batch workloads: Jobs and CronJobs

**Do:** set `activeDeadlineSeconds` on Jobs that must not run indefinitely; use a sensible `backoffLimit` and idempotent batch logic when Kubernetes retries failed Pods; configure `concurrencyPolicy` and `startingDeadlineSeconds` on CronJobs to match how missed or overlapping runs should behave; declare CPU and memory requests and limits on batch Pods (same QoS discipline as long-running workloads).

**Don’t:** rely on the default “run until success” behaviour without a wall-clock cap when stuck work would leave Pods and nodes tied up; allow unbounded CronJob overlap when pile-ups would corrupt data or overload dependencies; schedule CPU- or memory-heavy batch without requests, which lets the scheduler pack batch next to tier-1 services and starve them at busy times.

**Jobs: deadlines and retries:** `spec.activeDeadlineSeconds` terminates the whole Job once elapsed time exceeds the budget. Use it for ETL, migrations, or CI steps that should fail fast instead of blocking capacity. `spec.backoffLimit` bounds how many times failed Pods are recreated before the Job is marked failed; pair a low limit with logs and alerts so teams notice poison messages or downstream outages. Any work that Kubernetes may retry must be safe to repeat (idempotent writes, transactional boundaries, or explicit dedupe keys). If not, `backoffLimit: 0` and fix-forward may be safer than silent double application. See [Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/) in the Kubernetes documentation. [^77]

**CronJobs: overlap and missed schedules:** `spec.concurrencyPolicy` chooses whether a new run may start while the previous one is still Active (`Allow`), whether the new run is skipped (`Forbid`), or whether the previous instance is replaced (`Replace`). Pick deliberately when mutual exclusion or throughput matters. `startingDeadlineSeconds` caps how late a missed invocation may still start; without it, a long control-plane or scheduler blip can produce sudden bursts of catch-up runs. See [CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) in the Kubernetes documentation. [^78]

**Resources:** set `requests` and `limits` on Job template containers so batch participates in the same scheduling and fairness model as the rest of the cluster (see Resource management and QoS above). For tenant isolation, combine with `ResourceQuota` so CronJob-heavy namespaces cannot exhaust the project slice.

List **CronJobs** and recent **Jobs**; inspect deadlines, backoff, and CronJob timing fields:

```bash
oc get cronjobs -A -o wide
oc get jobs -A --sort-by=.metadata.creationTimestamp | tail -20
```

Inspect one object’s guardrails (replace namespace and name):

```bash
oc get cronjob -n <namespace> <cronjob-name> -o jsonpath='{.spec.concurrencyPolicy}{"\n"}{.spec.startingDeadlineSeconds}{"\n"}'
oc get job -n <namespace> <job-name> -o jsonpath='{.spec.activeDeadlineSeconds}{"\n"}{.spec.backoffLimit}{"\n"}'
```

#### Services, Routes, resilience, and service mesh

**Do:** pick `Service` types and `sessionAffinity` deliberately; implement timeouts, retries, and circuit breaking in application code, at the ingress or API gateway tier, or via a service mesh when you need cross-cutting L7 policy; ensure OpenShift Routes (or Ingress) only target backends that are ready; evaluate OpenShift Service Mesh (Istio-based) when east-west mTLS or uniform resilience across many services is a platform requirement.

**Don’t:** turn on `ClientIP` session affinity “just in case,” since it can pin traffic and impede even load balancing; assume NetworkPolicy or edge TLS alone delivers mutual service-to-service identity and encryption; stack retry logic in both the mesh and every library without checking for amplified load (retry storms); treat ambient or sidecarless mesh modes as drop-in compatible with every workload until you validate against your OpenShift release notes.

**Kubernetes `Service`:** `ClusterIP` is the usual east-west surface inside the cluster; `LoadBalancer` on ROSA/OpenShift provisions a cloud load balancer when you need a stable VIP outside NodePort patterns. Justify that choice against cost and ingress architecture. `sessionAffinity: ClientIP` keeps a client on the same Pod; use it only when the application truly requires sticky sessions and you accept hot spots and failover behavior. Prefer stateless designs or server-side sessions so affinity stays off at scale. See [Service](https://kubernetes.io/docs/concepts/services-networking/service/) in the Kubernetes documentation. [^79]

**Timeouts, retries, and circuit breaking:** OpenShift Routes and Kubernetes Service objects deliver connectivity, but they do not replace application deadlines, retry budgets, or outlier ejection. Implement resilience in HTTP/gRPC clients where you own the code; terminate TLS at the edge (Route edge, reencrypt, or passthrough) and use ALB, NLB, or API gateway features where north–south rate limits and timeouts belong to the platform edge. When many internal services need the same policies, a mesh can centralize retries and circuit breaking. Coordinate with app defaults so you do not double-retry on transient errors.

**Routes and readiness:** Readiness probes remove not-ready Pods from Endpoints (and EndpointSlices); the router and Service load balancing should not send traffic to backends that fail readiness. After deploys, confirm subsets show only ready addresses:

```bash
oc get route -n <namespace> <route-name> -o jsonpath='{.spec.to.name}{" (service)\n"}{.spec.tls.termination}{" (TLS termination)\n"}'
oc get endpoints -n <namespace> <service-name> -o wide
```

Cross-check Service affinity and port mappings:

```bash
oc get svc -n <namespace> <service-name> -o yaml | grep -E 'sessionAffinity:|type:'
```

**Service mesh (optional platform layer):** OpenShift Service Mesh (upstream Istio patterns) addresses east-west mTLS, fine-grained authorization, telemetry, and data-plane resilience (retries, timeouts, outlier detection) where copy-pasting libraries into dozens of repos is operationally worse than a shared mesh. Mesh is not mandatory for every cluster. NetworkPolicy, edge TLS, and good client behavior remain valid baseline choices.

**Sidecar vs ambient / sidecarless:** Classic mesh injects sidecar proxies; ambient or other sidecar-reduced modes move L4 or parts of L7 to node or waypoint-style components to cut per-Pod CPU and memory and speed lifecycle events. The tradeoffs include upgrade coupling, feature parity, and compatibility with Jobs, cron floods, or low-latency paths. Follow current OpenShift Service Mesh documentation for the mode names and support matrix on your version.

**Double retries and blast radius:** if both Envoy (mesh) and application code retry `5xx`, latency and downstream pressure can multiply. Set global defaults in one layer or explicitly partition responsibility (mesh: transport; app: business rules). Mesh adoption implies trust roots, namespace (or multi-cluster) scope, CA rotation runbooks, and exceptions for workloads that cannot use injection or waypoints.

See [About OpenShift Service Mesh](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/service_mesh/about-ossm) in the OpenShift documentation for architecture and release-specific capabilities. [^81] Route TLS termination (edge, passthrough, reencrypt) and backend configuration are covered under [Configuring Routes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/configuring-routes). [^80]

Check whether mesh operands are present (empty output means no mesh in that API group on this cluster):

```bash
oc api-resources --api-group=maistra.io -o name 2>/dev/null
oc get pods -A -l app.kubernetes.io/name=istio 2>/dev/null | head -5
```

## Operational excellence and lifecycle management

Operational excellence in ROSA HCP is achieved through automation, proactive monitoring, and a disciplined approach to cluster maintenance. The HCP model's separate lifecycle for the control plane and worker nodes allows for more surgical maintenance windows and reduced risk during updates.

#### Decoupled upgrade strategy

In ROSA HCP, upgrades are not holistic cluster events. Administrators have the flexibility to upgrade the hosted control plane first, followed by the individual machine pools. [^1] This is particularly advantageous for large-scale environments where different application teams may have different maintenance windows. A multi-cluster hub can add fleet visibility and staged rollouts on top of ROSA’s native upgrade APIs (see About this guide). [^71]

Red Hat utilizes a "Node Surge" strategy during machine pool upgrades. A new node is provisioned in excess of the replica count (maxSurge) before an old node is drained and replaced. [^8] This ensures that the application's capacity is not compromised during the upgrade process, provided that PDBs and node surge settings are correctly configured. [^8]

| Upgrade Action | Command | Verification |
| :---- | :---- | :---- |
| List Available Versions | `rosa list upgrade -c <cluster_id>` | Review "Notes" for recommendations |
| Upgrade Control Plane | `rosa upgrade cluster -c <cluster_id> --version <version>` | `rosa describe cluster -c <cluster_id>` |
| List Machine Pools | `rosa list machinepools -c <cluster_id>` | Check current version per pool |
| Upgrade Machine Pool | `rosa upgrade machinepool -c <cluster_id> <name>` | `oc get nodes` |

> *Source:* [^2]

#### API compatibility and upgrade readiness

OpenShift and Kubernetes remove beta and GA APIs across minor releases. Manifests that still declare deprecated `apiVersion` pairs block clean upgrades or surprise GitOps controllers mid-window when admission starts rejecting apply traffic.

**Do:** Author YAML with `apiVersion` and `kind` documented for your target cluster minor (for example `apps/v1` Deployment, `route.openshift.io/v1` Route, `project.openshift.io/v1` ProjectRequest templates, not `extensions/v1beta1`-era holdovers); run `oc explain` or `oc api-resources` when unsure which group or version is current; add CI or policy linters that fail pull requests on known removals. Community tools such as [Pluto](https://github.com/FairwindsOps/pluto) or [kubent](https://github.com/doitintl/kube-no-trouble) scan Helm charts and flat manifests for deprecated APIs before you upgrade control planes or machine pools. Pair them with [Insights Advisor](https://www.redhat.com/en/blog/insights-advisor-openshift-how-react-advisor-recommendations) and release notes for your ROSA layer so fleet and application repositories ship the same truth.

**Don’t:** Copy five-year-old blog snippets into production `kustomize` bases without a version gate; rely only on manual `oc apply` the night before change freeze to discover removed CRDs.

Sample inventory of API groups available to your user (trim output as needed):

```bash
oc api-resources -o wide | head -40
oc explain deployment --api-version=apps/v1 | head -20
```

See the [Kubernetes Deprecated API Migration Guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/) for cross-version removal timelines tied to Kubernetes minors underlying your OpenShift version. [^95]

#### Cluster API hygiene for automation

Controllers, operators, Terraform providers, custom scripts, and CI jobs all talk to the same cluster API server quota and rate limits. Bursts of LIST or WATCH without backoff or shared informers amplify 429 Too Many Requests and transient 5xx responses, which increases etcd load and slows everyone else’s `oc` sessions.

**Do:** Implement exponential backoff with jitter on 429, 500–504, and timeouts; reuse official client libraries (client-go, controller-runtime) that honor `Retry-After` and built-in rate limiters instead of tight `while` loops; batch reads where possible and scope RBAC so automation does not require cluster-wide LIST when a namespaced watch suffices.

**Garbage collection and ownership:** Understand `metadata.ownerReferences` on objects your controllers create. When the parent is deleted, the API server may cascade-delete dependents unless policies or `blockOwnerDeletion` say otherwise. Design parent/child graphs deliberately so a namespace teardown or upper custom resource removal does not orphan secrets you thought were independent, or delete shared ConfigMaps still referenced by live Pods. See [Garbage collection](https://kubernetes.io/docs/concepts/architecture/garbage-collection/) in the Kubernetes documentation. [^96]

Inspect owner links on a resource (replace kind, name, namespace):

```bash
oc get secret -n <namespace> <name> -o jsonpath='{.metadata.ownerReferences}' | jq .
```

#### Proactive health monitoring with Insights Advisor

The Insights Operator is a core component of the OpenShift platform that provides continuous assessment of cluster health against Red Hat’s database of recommendations and best practices. It reports configuration drifts, security vulnerabilities, and performance bottlenecks to the Red Hat Hybrid Cloud Console. [^40]

The Insights Advisor categorizes issues into four areas: Service Availability, Performance, Fault Tolerance, and Security. [^40] Each recommendation includes a detailed resolution guide tailored to the specific cluster. Administrators should treat Insights findings as high-priority tasks and integrate them into their regular operational reviews. Pair Insights with workload- and image-centric scanning from the Red Hat security portfolio where you need supply-chain and runtime depth (see About this guide). [^70]

To verify that the Insights Operator is functioning and to inspect the data being reported:

```bash
oc get pods -n openshift-insights
oc get configmap insights-config -n openshift-insights -o yaml
```

#### Centralized logging and metrics federation

While platform monitoring is managed by Red Hat SREs, consumers are responsible for monitoring their own application workloads. Enable [user workload monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/configuring-user-workload-monitoring) so teams can deploy custom Prometheus rules and Grafana dashboards in application namespaces.

For long-term persistence and audit compliance, federate metrics to an external system such as [Amazon Managed Service for Prometheus](https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-Amazon-Managed-Service-for-Prometheus.html) or an S3-backed destination where that fits your retention model. For logs from workloads and cluster infrastructure in your AWS account, use [Cluster Logging](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/logging/about-logging) (and related forwarders) so application, infrastructure, and audit streams can land in sinks such as Loki, CloudWatch Logs, or a SIEM. That preserves evidence for forensics after a cluster is decommissioned or replaced.

**Hosted control plane logs (ROSA HCP):** ROSA with Hosted Control Planes adds a managed control plane log forwarder that runs separately from your worker nodes, so forwarding control plane telemetry does not compete with application CPU or memory. You can deliver those logs to Amazon CloudWatch Logs or to an Amazon S3 bucket in your account (or configure both), using a small YAML file referenced from the ROSA CLI. Product guidance: prefer CloudWatch when you need live search, alarms, and operational triage (for example CloudWatch Logs Insights); prefer S3 when you prioritize durable object storage, long retention, or downstream analytics and partition-based scans. Forwarding and storage add AWS service charges; align log groups, retention, and lifecycle rules with FinOps and security stakeholders.


**Configuring control plane log forwarding:**

```bash
rosa create log-forwarder -c <cluster> --log-fwd-config=<file>.yaml
```

See [Forwarding control plane logs](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/security_and_compliance/rosa-forwarding-control-plane-logs) in the Red Hat OpenShift Service on AWS documentation for IAM policy samples, YAML schemas, and troubleshooting. [^102]

#### Application observability: logs, metrics, traces, and SLOs

Tier-1 services on ROSA should emit signals operators can aggregate, alert on, and retain, whether logs land in Loki, Amazon CloudWatch, or a SIEM downstream of [Cluster Logging](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/logging/about-logging).

Red Hat publishes optional operators that go beyond default platform monitoring and user workload monitoring. The [Cluster Observability Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cluster_observability_operator/index) helps you install and run a customer-managed observability stack (for example Prometheus, Alertmanager, and related monitoring UI or correlation tooling) when teams need a dedicated, customizable plane. The [Network Observability Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/network_observability/) focuses on cluster networking: eBPF-based collectors, the cluster `FlowCollector` API, flow visualization, and optional export to stores such as Loki for search and retention. Treat both as add-ons: check OperatorHub channels, sizing and node overhead (especially for network flow collection), and support statements for your ROSA / OpenShift version before you bake them into a reference design. [^103] [^104]

**Structured logs:** Prefer JSON or stable `key=value` formats (avoid prose-only printf strings that break field extraction in Loki, Elasticsearch, or CloudWatch Logs Insights). Annotate containers with consistent `app`, `version`, and instance labels via OpenShift metadata where your pipeline expects them.

**RED / USE metrics for HTTP and gRPC:** Standardize rate, errors, and duration (RED) for request-driven services, and utilization, saturation, and errors (USE) for dependencies such as CPU, connection pools, and queues where SLOs matter. [User workload monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/index) (enable monitoring for user-defined projects per the Monitoring guide) exposes application Prometheus scrapes and `PrometheusRule` alerts alongside platform monitoring. Turn it on when teams own SLO burn-rate alerts. [^91]

**Distributed traces:** Wire OpenTelemetry (or your mesh trace exporter) client libraries so latency spread across Routes, services, and managed backends is visible in Jaeger, Tempo, CloudWatch Service Lens, or enterprise APM. That visibility matters when p99 regressions cannot be blamed on a single Pod CPU graph.

**SLOs and error budgets:** For customer-facing tiers, define objectives (for example 99.9% availability, p95 latency under 250 ms) and error-budget policy. Tie alert routing and freeze windows to budget burn so on-call responds to user-impacting risk, not every noisy counter.

Quick ServiceMonitor inventory (user workload monitoring scrapes these when enabled for user projects):

```bash
oc get servicemonitor -A 2>/dev/null | head -20
```

## Security hardening and automated compliance

The multi-layered security approach of ROSA HCP combines OpenShift-native controls with AWS-specific infrastructure protections. Achieving a "Zero Trust" posture requires the enforcement of restricted policies at both the network and workload levels. When you operate many clusters, centralized workload security and hub-level governance extend that model with consistent sensors, policies, and visibility (see About this guide). [^71] [^70]

#### Security Context Constraints (SCC) and Pod Security

OpenShift’s SCCs are more restrictive and granular than standard Kubernetes Pod Security Policies (PSPs). It is a critical recommendation to stick to the restricted SCC whenever possible. This policy prevents pods from running as the root user, using host network interfaces, or mounting sensitive host paths, which are common vectors for container breakout attacks. [^45]

For applications that require additional capabilities (e.g., certain storage drivers or network tools), a custom SCC should be created rather than granting the privileged SCC, which provides absolute control over the host node. [^22]

Verification of the SCCs applied to running pods:

```bash
oc get pods -A -o json | jq '.items[] | {name:.metadata.name, scc:.metadata.annotations["openshift.io/scc"]}'
```

#### Pod security context baselines (complements SCC)

SCC admission decides which security profiles a Pod may use; `securityContext` on the Pod and containers should still encode team intent so manifests are portable, reviewable, and aligned with `restricted-v2` (or your approved custom SCC) without relying on implicit defaults.

**Do:** Set `allowPrivilegeEscalation: false` when compatible so setuid binaries cannot gain more privileges than the container user; prefer `readOnlyRootFilesystem: true` and mount `emptyDir` or `tmpfs` only where the app must write; drop all capabilities then add the minimum set (`CAP_NET_BIND_SERVICE`, `CAP_SYS_TIME`, and similar) instead of running `CAP_SYS_ADMIN`-heavy images; set `seccompProfile.type: RuntimeDefault` (or `Restricted` where policy and SCC allow) instead of `Unconfined` unless documented; run `runAsNonRoot: true` with an explicit `runAsUser` / `runAsGroup` or `fsGroup` that matches your image contract and restricted SCC expectations. See [Managing security context constraints](https://docs.okd.io/latest/authentication/managing-security-context-constraints.html) (same SCC mechanics as OpenShift) and [Configure a security context for a Pod or container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/) in the Kubernetes documentation. [^88] [^89]

**Don’t:** Omit `securityContext` blocks and assume SCC will “fix it”; use `privileged: true` or `CAP_SYS_ADMIN` without a ticket-level exception; expand `readOnlyRootFilesystem: false` without listing which paths need write access.

Inspect effective fields on a running Pod (replace namespace and pod-name):

```bash
oc get pod -n <namespace> <pod-name> -o jsonpath='{range .spec.containers[*]}{.name}{": allowPrivilegeEscalation="}{.securityContext.allowPrivilegeEscalation}{", readOnlyRootFS="}{.securityContext.readOnlyRootFilesystem}{"\n"}{end}'
```

#### Service accounts and RBAC for workloads

**Do:** Create a dedicated `ServiceAccount` per application or integration (avoid `default` for production Deployments); set `automountServiceAccountToken: false` on Pods that do not call the Kubernetes API (fewer tokens on disk reduces lateral movement if a container is compromised); grant Roles or ClusterRoles with RoleBinding / ClusterRoleBinding using minimal verbs and resources (get/list/watch on specific APIs, not wildcard `*` unless the controller pattern requires it and policy reviews it); pair with IRSA (Application workloads: IRSA, STS, and AWS credentials) for AWS APIs instead of reusing the same ServiceAccount token for both Kubernetes and cloud.

**Don’t:** Bind `cluster-admin` (or `edit` on cluster-scoped objects) to namespace service accounts to get unblocked; leave `automountServiceAccountToken` default true on stateless HTTP services that never need `oc`-style access.

Inventory bindings and non-default ServiceAccounts:

```bash
oc get rolebindings -n <namespace>
oc get pods -n <namespace> -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName,AUTOMOUNT:.spec.automountServiceAccountToken --no-headers
```

See [Using RBAC and defining authorization](https://docs.okd.io/latest/authentication/using-rbac.html) (aligned with OpenShift RBAC). [^90]

#### Network isolation with NetworkPolicies and Egress Firewalls

By default, OpenShift allows all pod-to-pod communication within the cluster until you define policies. With **OVN-Kubernetes**, NetworkPolicy objects are enforced in the OVN dataplane (see Cluster pod network (OVN-Kubernetes)). Use NetworkPolicy resources for namespace-scoped micro-segmentation (restricting traffic by labels, namespaces, and CIDR blocks) as described in the Network security guide. [^48] Where your cluster version supports them, AdminNetworkPolicy objects add an optional cluster-wide rule layer on top of namespace-scoped NetworkPolicies. [^76]

For controlling traffic leaving the cluster, EgressFirewall (OpenShift’s `EgressFirewall` resource; historically referred to as egress network policy in some docs) allows or denies traffic to specific external domains or IP ranges. [^49] This is particularly useful for preventing data exfiltration or ensuring that internal applications only communicate with approved external APIs. Validate egress with flow logs, SIEM correlation, or workload-aware observability so policy and reality stay aligned, especially when several teams share a cluster.

| Policy Objective | Resource Type | Implementation |
| :---- | :---- | :---- |
| Isolate Namespace | NetworkPolicy | Deny all ingress/egress by default |
| Allow Ingress Controller | NetworkPolicy | Permit traffic from the Ingress namespace |
| Block External Access | EgressFirewall | Deny traffic to unknown CIDRs |
| Allow Specific API | EgressFirewall | Permit traffic to a target FQDN |

> *Source:* [^48], [^49]

#### The OpenShift Compliance Operator

Maintaining compliance in a dynamic cloud environment requires automated auditing. The Compliance Operator allows administrators to describe the required compliance state (e.g., CIS Benchmarks, PCI-DSS, or FedRAMP) and provides remediation strategies for any detected gaps. [^51]

The operator uses OpenSCAP to scan both the OpenShift API resources visible in your cluster context and the underlying nodes. [^47] For ROSA HCP, administrators must ensure that the operator is configured to run on worker nodes, as the hosted control plane components are handled by Red Hat's own compliance processes. [^53] Propagate scan configuration fleet-wide from your governance hub and pair operator results with workload security reporting when auditors need both views (see About this guide). [^71] [^70]

To check the results of a compliance scan and identify failing controls:

```bash
oc get compliancecheckresults -n openshift-compliance | grep FAIL
```

## Software supply chain and secure development

Modern ROSA estates treat what runs in cluster as the output of a pipeline: known images, attested artifacts, and policy that survives promotion from development to production. Pair OpenShift-native and AWS registry practices with Red Hat tooling when your organization buys SBOM-driven governance or Sigstore-class signing; use [Insights](https://www.redhat.com/en/blog/insights-advisor-openshift-how-react-advisor-recommendations) for platform drift and the security portfolio described in About this guide for CVE and runtime depth.

**Do:** Reference container images by immutable digest (`sha256:…`) or pinned tags with a rebuild discipline; track base image and runtime updates and redeploy on vendor CVE fixes; adopt [Red Hat Trusted Profile Analyzer](https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/) when SBOMs, VEX, and component policy anchor release gates; adopt [Red Hat Trusted Artifact Signer](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/) when signatures must prove integrity at registry, pipeline, or admission; adopt [Red Hat Advanced Developer Suite](https://developers.redhat.com/products/advanced-developer-suite) when golden paths and developer portals should connect those controls end to end via [Red Hat Developer Hub](https://developers.redhat.com/products/developer-hub/overview).

**Don’t:** Rely on unbounded `:latest` in production without digest capture in Git or CI metadata; assume registry scanning alone satisfies regulated attestation without SBOM inventory or signature verification where policy requires it; present TPA, artifact signing, and internal developer portals as unrelated products when the suite story fits the reader.

#### Container images, digests, and CVE response

**Immutable references:** Production workloads should pull images by digest or tags that map one-to-one to a build record (CI run ID, Git commit, SBOM id), not a floating `latest` that changes underneath running Pods on the next reschedule. Pin base images in Dockerfiles or Build tasks the same way. See [Container images](https://kubernetes.io/docs/concepts/containers/images/) in the Kubernetes documentation. [^92]

**Patch velocity:** Policy scanners (ACS, Compliance Operator, Insights) complement but do not replace a process to rebuild and roll forward when maintainers publish fixes for your base layers. Tie image promotion to change windows and PDBs so security updates ship as often as feature releases, not only after incidents.

Sample image strings on live workloads (replace namespace):

```bash
oc get pods -n <namespace> -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

#### Red Hat Trusted Profile Analyzer and Trusted Artifact Signer

**Trusted Profile Analyzer** focuses on SBOM ingestion and analysis (CycloneDX, SPDX, VEX-style context where you use it) and policy over what components appear in deliverables before and after they reach ROSA. It sits left of runtime: pair it with ACS so build-time attestation and deploy-time or runtime enforcement share a consistent story. Product detail: [Red Hat Trusted Profile Analyzer](https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/) documentation. [^93]

**Trusted Artifact Signer** delivers enterprise Sigstore- and cosign-style signing and verification for OCI images and other artifacts, OIDC-integrated identity for signers, and patterns that support SLSA-oriented pipelines. Wire verification into OpenShift Pipelines (Tekton), external CI (GitHub Actions, GitLab), registries (Quay, ECR), or admission policy so only signed or allowed images enter namespaces. Product detail: [Red Hat Trusted Artifact Signer](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/) documentation. [^94]

#### Red Hat Advanced Developer Suite (golden path to production)

[Red Hat Advanced Developer Suite](https://developers.redhat.com/products/advanced-developer-suite) bundles developer experience and supply chain security so teams do not stitch ad hoc portals, scanners, and signers alone. [Red Hat Developer Hub](https://developers.redhat.com/products/developer-hub/overview) is a supported, Backstage-based internal developer portal that hosts software templates, documentation, and plugins that encode golden paths onto OpenShift (with integrations to OpenShift GitOps, OpenShift Pipelines, Dev Spaces, and the wider portfolio). Trusted Profile Analyzer and Trusted Artifact Signer complete the arc from scaffold → build → attest → sign → deploy. Align platform enablement content with that narrative when you describe secure SDLC on ROSA, not three isolated SKUs.

## CI/CD and GitOps (platform-native)

Production ROSA estates benefit when deploy and build patterns match supported OpenShift operators: OpenShift GitOps (Argo CD) for declarative desired state, and OpenShift Pipelines (Tekton) or external CI for build, test, and promote. BuildConfig, ImageStream, and S2I stay valid, especially in brownfield, but they should not be documented as the only “OpenShift way” without a path toward Git-backed deploys and registry-native promotion.

**Do:** Keep cluster and application intent in versioned Git (or an auditable equivalent) reconciled by GitOps; use Tekton when on-cluster CI fits tenancy and support; document GitHub Actions, GitLab CI, or CodePipeline building to Amazon ECR or Quay and updating manifests for GitOps; pin promoted images by digest where policy requires (Software supply chain and secure development); pick one system of record for live config and make drift visible; inject pipeline secrets via Vault, Secrets Manager plus External Secrets Operator, CSI, or IRSA, not cleartext PipelineRun parameters.

**Don’t:** Rely on unattended `oc apply` from laptops as the primary day-two loop; normalize long-lived cloud or registry keys in Tekton parameters or Git; leave Jenkins-on-cluster or snowflake shell deploys without a migration or deprecation plan.

#### GitOps for desired state

[OpenShift GitOps](https://docs.openshift.com/gitops/latest/about/understanding-openshift-gitops.html) delivers a supported Argo CD experience in which Application, ApplicationSet, and progressive-delivery hooks (where you enable them) reconcile Helm, Kustomize, or plain manifests into the cluster with sync status, history, and rollback. Pair GitOps workflows with External DNS and cert-manager (see Private clusters, landing-zone ingress, and application DNS/TLS) so Routes and certificates track declared intent. At fleet scale, place GitOps subscriptions from your hub so application placement stays consistent (see About this guide). [^100]

#### Pipelines and external CI

Use [OpenShift Pipelines](https://docs.openshift.com/pipelines/latest/about/understanding-openshift-pipelines.html) when builds should run inside OpenShift namespaces under native RBAC and audit. External CI is equally appropriate: run tests, build OCI images, push to ECR (or Quay), then open commits or merge requests that bump image digests or Kustomize overlays for GitOps to reconcile. Whichever path you choose, document runner placement, network egress to registries and Git, and secret handling (Secrets in pipelines below). [^101]

#### From BuildConfig / S2I toward modern CI/CD

Where BuildConfig, ImageStream, and S2I remain, build out a modernization lane: Tekton Tasks (Dockerfile, buildpack, or wrapped S2I), digest-pinned promotion, admission or signing hooks from Software supply chain and secure development, and GitOps-owned deploys. That gives brownfield teams a sequenced move off integrated-only defaults without pretending everything must jump in one weekend.

#### Legacy Jenkins, scripts, and dual-run

Jenkins on cluster, VM agents, and ad hoc scripts are common technical debt, so treat them explicitly. Prefer a dual-run window (legacy builds or deploys alongside Tekton or GitOps), clear ownership of which system applies production manifests, and dated milestones to retire the legacy path. GitOps-first deploy plus central or external CI for artifacts usually shrinks blast radius compared with shared SSH and kubectl runbooks.

#### Source of truth and drift

If GitOps shares the cluster with imperative automation or console edits, state which source wins, how break-glass `oc` patches return to Git (or get reverted), and how operators expose OutOfSync or Degraded Applications. Enable prune and RBAC so drift is actionable, not invisible.

#### Secrets in pipelines

Integrate Tekton with Vault, AWS Secrets Manager (commonly via External Secrets Operator; see Configuration, secrets, and external secret management), CSI secret stores, or short-lived OIDC and STS where steps call AWS APIs. Do not bake long-lived keys into PipelineRun parameters, ConfigMaps, or Git; use the same bar as for workload Secrets elsewhere in this guide.

Check GitOps and Pipelines operators, Argo CD Applications, and recent PipelineRun activity (names vary with versions):

```bash
oc get subscription -n openshift-operators -o custom-columns=NAME:.metadata.name,PKG:.spec.name,CHANNEL:.spec.channel --no-headers | grep -iE 'gitops|pipelines|openshift-gitops|openshift-pipelines' || true
oc get applications.argoproj.io -A 2>/dev/null | head -20
oc get pipelinerun -A --no-headers 2>/dev/null | head -20
```

## Performance efficiency and dynamic scaling

Optimizing performance in a ROSA HCP cluster involves a data-driven approach to resource allocation and the intelligent use of AWS instance types.

#### Multi-Dimensional Autoscaling

Think of your ROSA worker nodes as loading bays in a warehouse, Pods as crews working a shift, and CPU and memory requests as how much space and tooling each crew reserves on the floor. Three different autoscalers solve three different problems. Stack them and you get elasticity at the node, replica, and per-Pod resource layers.

| Layer | “Workers” idea | What it scales | Primary benefit |
| :---- | :---- | :---- | :---- |
| **Cluster Autoscaler** | Open more bays when there is no dock space left | Worker nodes (machine pools) | Capacity for new Pods when the cluster is out of schedulable room |
| **Horizontal Pod Autoscaler (HPA)** | Send more crews to the same job when the queue grows | Pod replicas | Throughput and latency under load without changing each Pod’s size |
| **Vertical Pod Autoscaler (VPA)** | Right-size each crew’s toolkit | CPU/memory requests and limits per Pod | Efficiency and stable scheduling signals for the other two |

**Cluster Autoscaler (nodes):** When Pods stay Pending because no node has enough free requests, the cluster autoscaler grows the machine pool (adds EC2 workers) up to its maximum. That is how you scale the foundation, not the application logic directly. On ROSA HCP, each machine pool maps to a single Availability Zone, so run at least one autoscaled pool per AZ you want to grow in, and size min and max replicas so you always meet platform minimums (for example system workloads) while leaving headroom for bursts. [^55]

**HPA (replicas):** HPA adds or removes identical Pods based on CPU, memory, or custom metrics. It answers “how many copies of this service?”, not “how big should each copy be?”. It works best when requests and limits are already sensible (often informed by VPA recommendations); otherwise the scheduler may place too many small Pods on a node or trigger scaling off noisy metrics.

**VPA (per-Pod resources):** VPA adjusts how much CPU and memory each Pod asks for and may cap. Recommendation-only mode (`updateMode: Off`) is usually the safest production default: you get continuous suggestions to rightsize requests and limits without VPA evicting running Pods. Promote values through GitOps or change control, then use Recreate or Auto only if the workload tolerates eviction. See [Using the Vertical Pod Autoscaler Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/working-with-pods#nodes-pods-vpa) in the OpenShift documentation.

**How to stack them for a flexible cluster**

1. **Establish baselines:** use VPA Off (or disciplined load tests) so requests and limits match real behavior; that stabilizes scheduling and HPA signals.
2. **Scale out the app:** use HPA on production tiers so replica count tracks demand.
3. **Grow the fleet:** rely on cluster autoscaler when pending Pods prove you need more nodes, not just more replicas on full nodes.
4. **Protect rollouts:** keep PodDisruptionBudgets and sensible maxSurge on machine pools so scaling and upgrades do not starve the app.

Together, VPA keeps each crew efficient, HPA balances how many crews you run, and the cluster autoscaler adds bays when the warehouse is full.

**Spare capacity and “burst-friendly” scheduling:** Pod priority and preemption in OpenShift let you run lower-priority work (batch jobs, analytics, CI, or deliberate buffer Deployments) that consume node capacity in steady state. When a higher-priority burst workload needs those requests, the scheduler can preempt lower-priority Pods if policies and quotas allow, freeing room quickly without waiting for a new node. Define `PriorityClass` objects, assign them in Pod templates, and test preemption paths so business-critical tiers are always higher priority than fill-in work. See [Pod priority and preemption](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/working-with-pods#nodes-pods-priority) in the OpenShift documentation.

For policy-based rebalancing (for example evicting Pods to improve spread or honor node utilization targets), many teams add the Kube Descheduler Operator, which runs Descheduler profiles you enable on the cluster. That operator is complementary to priority/preemption, not a replacement for HPA or the cluster autoscaler. See [Evicting pods using the descheduler](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/controlling-pod-placement-onto-nodes-scheduling#descheduler) in the OpenShift documentation.

#### Instance Type Optimization and Graviton

A significant cost and performance opportunity in ROSA HCP is the support for ARM-based AWS Graviton instances (e.g., m6g series). These instances often provide a better price-performance ratio than traditional x86 instances for containerized workloads. [^6] When creating new machine pools, organizations should evaluate if their application code is cross-platform and can take advantage of Graviton’s efficiency. [^6]

Verification of the instance types currently in use in the cluster:

```bash
oc get nodes -o custom-columns=NAME:.metadata.name,INSTANCE-TYPE:.metadata.labels."node.kubernetes.io/instance-type"
```

## Financial engineering and cost optimization

ROSA HCP provides several mechanisms to reduce the Total Cost of Ownership (TCO) of an OpenShift environment. Moving to HCP focuses your AWS spend on worker and application capacity because control-plane EC2 leaves your account bill; published examples cite on the order of ~37% infrastructure savings in customer-ready scenarios, which is a useful starting point for a conversation with your AWS team. [^6]

#### Reserved Instances and Savings Plans (ROSA HCP)

For ROSA with HCP, worker nodes in your AWS account remain eligible for Reserved Instances and Savings Plans, a powerful way to lock in favorable rates for steady production pools. Combined with HCP’s leaner footprint, materials have cited ~68% savings versus on-demand in representative deployments; your mix of instance families, coverage, and ROSA subscription will determine your outcome. [^6] HCP worker pools use On-Demand or Savings Plan–backed capacity, a pattern that matches predictable production SLAs. Spot remains a ROSA Classic option for bursty pools (see below).

#### Spot Instances and bursty workers (ROSA Classic)

ROSA Classic supports Spot Instances in dedicated machine pools so you can optimize price for fault-tolerant or batch-style work (for example CI bursters or elastic analytics). Configure Spot pools and maximum Spot price (or equivalent) through the console, OCM API, or CLI for your cluster version. [^6] Details and eligibility live in [AWS ROSA documentation](https://docs.aws.amazon.com/rosa/latest/userguide/rosa-deployment-options.html); HCP delivers value through committed and On-Demand worker economics instead.

#### Resource Quotas and Limit Ranges

Project-scoped quotas are the primary lever for fair sharing on multi-tenant ROSA clusters: each OpenShift project gets its own `ResourceQuota` so aggregate CPU, memory, storage, and API object usage stay inside the slice you allocate to that team. `LimitRange` objects in the same project backstop individual Pods with defaults, minima, and maxima so workloads remain schedulable and bounded. [^32] `ClusterResourceQuota` extends that idea across multiple projects when you need a single budget for a business unit or service line.

Pair ResourceQuota, LimitRange, ClusterResourceQuota, and related OpenShift objects with policy-as-code admission (for example Gatekeeper and Rego) if you require every workload to declare requests/limits. Quotas alone cap totals but do not always stop a lone Pod with missing resources from being created. [ACM governance policies](https://www.redhat.com/en/technologies/management/advanced-cluster-management) offer a fleet-scale way to require those same declarations and to reconcile quota- and LimitRange-related templates across many ROSA clusters from the hub. [^71] For how limits can shape or throttle application performance over time, see the upstream guide [Resource management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/). [^33] OpenShift-specific quota and LimitRange guidance is in the product docs under scalability and performance (for example [Using quotas and limit ranges](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/scalability_and_performance/compute-resource-quotas)). [^59]

| Cost Control Object | Scope | Best Practice |
| :---- | :---- | :---- |
| ResourceQuota | Namespace / project | Team or app budgets (CPU, memory, objects, storage) |
| LimitRange | Namespace / project | Defaults and min/max per Pod or container |
| ClusterResourceQuota | Multi-project | One budget spanning labeled projects (team or LOB) |

> *Source:* [^32]

Verification of active quotas in a namespace:

```bash
oc get resourcequotas -n <namespace>
```

## AWS Well-Architected lens for ROSA

ROSA clusters sit on your VPC, IAM, KMS, load balancers, and data plane services. Design choices there should follow the [AWS Well-Architected Framework](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html) (security, reliability, performance, cost, and operational excellence pillars) together with [ROSA documentation on AWS](https://docs.aws.amazon.com/rosa/latest/userguide/welcome.html). This section names the customer–AWS–Red Hat boundary and fills gaps that are easy to miss when the narrative stays inside Kubernetes objects alone.

**Do:** align IAM, encryption, network allow-lists, quotas, tagging, and IaC with the same rigor as workload manifests; cross-reference **Identity and Access Management through STS and OIDC**, **Private clusters, landing-zone ingress, and application DNS/TLS**, **Financial engineering and cost optimization**, and **Disaster Recovery and business continuity** when a topic spans layers.

**Don’t:** treat “inside the VPC” as automatic confidentiality for regulated tiers; size machine pools and budget Savings Plans without checking **Service Quotas** and **ROSA** limits for your **region**; leave production landing zones to **clickops-only** runbooks with no versioned **Terraform** / **CloudFormation** / **ROSA CLI** source of truth.

#### Security, identity, and encryption on AWS

**Shared responsibility:** For who patches, who secures the control plane, and what you own in the data plane, use the [shared responsibility model for ROSA on AWS](https://docs.aws.amazon.com/rosa/latest/userguide/rosa-responsibilities.html) and the Red Hat [policies and service definition](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition#rosa-policy-responsibility-matrix) so runbooks and compliance packets use the same vocabulary. [^97] [^98]

**IAM:** Prefer IAM roles and short-lived STS credentials over long-lived IAM users and static access keys. Align automation (pipeline roles, Terraform / CloudFormation principals, organization SCPs) with least privilege; use permission boundaries where your cloud center of excellence requires them. Application workloads that call AWS APIs should follow IRSA (see **Identity and Access Management through STS and OIDC**), not `AWS_SECRET_ACCESS_KEY` in Deployment env vars for production patterns.

**Network:** Treat security groups (and NACLs where you use them) as minimal allow-lists. `0.0.0.0/0` ingress to the API, SSH, or management ports needs an explicit pairing with private cluster, edge VPC, WAF, or break-glass policy, not a silent default (see **Private clusters, landing-zone ingress, and application DNS/TLS**).

**Encryption and keys:** Enable encryption at rest for EBS, S3, RDS / Aurora, Secrets Manager, and logs where your controls require it. Regulated and multi-tenant estates often standardize customer managed keys (CMKs) in AWS KMS (BYOK) instead of AWS-owned keys only. Document key ARN or alias, key policies, IAM usage, and separate CMKs for primary data, backups, and audit or long-term retention when blast-radius separation matters. For client-side encryption or KMS grants from Pods, scope IAM via IRSA; plan key rotation (where AWS supports it for your key type) and multi-Region keys when DR spans Regions (see **Disaster Recovery and business continuity**).

**Data in transit:** Use TLS across trust boundaries (ALB/NLB, PrivateLink, VPN/Transit Gateway paths). Do not imply that “inside the VPC” alone satisfies regulated confidentiality without an org policy statement.

**Secrets at the AWS layer:** Prefer Secrets Manager or Systems Manager Parameter Store (SecureString) integrated with External Secrets Operator (see **Configuration, secrets, and external secret management**) over secrets baked into user data, world-readable S3 objects, or long-lived keys embedded in Lambda configuration.

#### Reliability scope, quotas, and backups

**HA and DR:** Multi-AZ workers, spread Pods, and managed data tiers (RDS Multi-AZ, Aurora, replicated caches) carry the reliability story, not Kubernetes objects alone. Keep in-region HA distinct from cross-Region DR; bias toward workload-scoped backup and restore (**Backup, restore, and recovery testing**).

**Quotas and limits:** Large designs hit AWS service quotas (for example VPC, Elastic IP, ELB rules) and ROSA-specific limits documented for your version. Review defaults and request quota increases during architecture review, not the day before cutover.

```bash
aws service-quotas list-aws-default-service-quotas --service-code ec2 --region "${AWS_REGION:-us-east-1}" --no-cli-pager --output table | head -40
```

Consult the Service Quotas console and [ROSA service documentation](https://docs.aws.amazon.com/rosa/latest/userguide/welcome.html) for cluster and account boundaries that apply to your region and offering.

#### Performance, FinOps tags, and predictable capacity

**Instance and storage:** Prefer current ROSA-supported instance families and GP3 (tunable IOPS/throughput) where it beats legacy defaults on cost and latency. Evaluate Graviton machine pools when images are multi-arch or ARM-ready (see **Instance Type Optimization and Graviton**).

**Cost allocation:** Apply a consistent tagging standard to VPC-attached resources, load balancers, and machine pool workers (environment, cost center, application, `map-migrated` or internal chargeback keys) so FinOps can attribute ROSA spend to teams, especially when IaC creates peer VPCs or shared networking.

**Commitments:** Savings Plans and Reserved Instances for steady worker pools belong in the same conversation as production SLAs (see **Reserved Instances and Savings Plans**).

**Predictable spikes:** When HPA and cluster autoscaler reaction time is too slow for known windows (evening traffic, batch cron floods), plan ahead: raise machine pool min/max replicas or scheduled capacity before the window, and pair with GitOps or CronJob-driven bumps to Deployment `minReplicas` so Pods do not sit Pending at minute zero, then scale down after the event to control cost.

#### Operational excellence: IaC, observability, and residency

**Infrastructure as code:** Prefer Terraform, CloudFormation, ROSA CLI plus versioned manifests, or equivalent IaC for landing zones, VPC layouts, and peer networking over clickops-only production paths. Console steps are fine illustrations when labeled as such.

**AWS-side observability:** Complement Cluster Logging and User Workload Monitoring with CloudWatch metrics, logs, and alarms on load balancers, NAT gateways, and account-level signals, or forward to your SIEM where SecOps expects a single pane.

**Region and data residency:** State primary Region, where RDS, S3, and KMS keys live, and data residency requirements explicitly for regulated or latency-sensitive workloads so architectural diagrams and legal posture stay aligned.

## Disaster Recovery and business continuity

**Vocabulary:** High availability (HA) here means surviving failures inside a deployment scope, typically within one AWS Region (for example loss of an Availability Zone), not automatically surviving a full regional outage. Disaster recovery (DR) means recovering from a wider blast radius: a failed deployment, data corruption, regional impairment, ransomware, or other events you express with RPO and RTO.

**Cluster platform HA vs. workload HA:** A **multi-AZ** ROSA cluster means the **platform** is built for availability across zones: Red Hat runs the hosted **control plane** for HA, and you place **worker** machine pools across multiple AZs so the cluster retains schedulable capacity when a zone degrades. That is **cluster-level** resilience (managed service plus AWS networking and compute layout), not automatic **application-level** resilience. **You** are responsible for using **OpenShift** workload APIs and patterns (multiple replicas, PodDisruptionBudgets, topology spread constraints, readiness and liveness probes, Routes/Services, rolling updates aligned with maintenance) and **AWS** data and edge primitives (Multi-AZ or replicated RDS/Aurora and caches, load balancers, health checks, backups, replication) so **each workload and data tier** you care about can ride out the same events the cluster survives. Saying “our cluster is multi-AZ” states **infrastructure** posture; saying “our service is HA in-region” requires that **workload** and **data** story too. Saying “we can fail away from `us-east-1`” is a **DR** commitment. Be explicit for compliance or executive readers. Promising “high availability” for a production tier should tie together multi-AZ workers, replicated or Multi-AZ data, and enough spread replicas; if a leg is missing, narrow the claim (dev/test, tier-2, or explicit risk acceptance).

ROSA HCP succeeds when teams design for those targets early. The platform supplies resilient building blocks across AWS regions, networking, and OpenShift, and documented RPO and RTO turn that into runbooks you can rehearse.

#### High availability within a Region

**Multi-AZ compute:** Production clusters should run workers across multiple Availability Zones. On ROSA HCP, each machine pool is tied to one AZ, so mirror the autoscaler guidance elsewhere and maintain at least one pool per AZ that matters for your SLOs, scaling min and max together so one zone’s loss does not remove all worker capacity. That layout makes **cluster capacity** resilient; you still **must** combine it with Pod scheduling and application design: topology spread constraints (and affinity or anti-affinity where they add value) so replicas do not concentrate in a single AZ, and enough replicas and PDBs that a zone loss does not take the service below your minimum availability target.

**Data-plane HA:** A Deployment with two Pods does not by itself make the database or cache highly available. For tier-1 services, document how persistent data is protected: RDS Multi-AZ, Aurora replication, ElastiCache replication groups, DynamoDB global or Multi-AZ patterns, or a supported operator design, not only “Kubernetes runs it.”

**Control plane:** On ROSA, Red Hat operates the hosted control plane’s HA; customer runbooks should emphasize workers, Routes and Ingress, application dependencies, and backing services. Avoid wording that suggests customers scale or fail over the control plane the way they do machine pools.

**Application layer:** Service HA needs enough replicas and disruption budgets that still let drains complete. Production tiers commonly run two or more replicas and often three when you need spread across failure domains and headroom under PodDisruptionBudgets. Multi-AZ nodes plus one application replica remain a single point of failure at the workload layer. Align PDBs, replica counts, and load balancers with the same story (see Pod Disruption Budgets and Services, Routes, resilience, and service mesh earlier in this guide).

#### Backup, restore, and recovery testing

Backups only reduce risk when restore paths are proven. Bias toward workload-scoped recovery: restore an application, tenant namespace, managed database, or object prefix, not “rebuild or restore this entire cluster” as the default mental model. Whole-cluster or fleet-wide backup patterns belong where policy or RTO truly requires them, with documented blast radius; most tier-1 stories pair GitOps or IaC for control plane intent with data-plane backup of what actually holds state. Combine AWS-native snapshots and replication with cluster-aware tooling where it fits your RPO and RTO:

* **Relational data:** Amazon RDS and Aurora automated backups, manual snapshots, and point-in-time recovery (PITR) where enabled. Validate restore time and failover behavior per engine (application-level recovery of the database, not only “the cluster came back”).
* **Block storage:** Amazon EBS snapshots for specific volumes behind CSI-backed PVCs tied to known workloads; understand crash-consistent versus application-consistent recovery and whether you need quiesce hooks or filesystem tools.
* **Object storage:** Amazon S3 versioning, replication, and lifecycle rules for artifacts and Velero targets (when used).
* **Kubernetes resources:** When Velero with the OpenShift API for Data Protection (OADP) matches your support model, prefer namespace-, label-, or schedule-scoped backup of API objects (and persistent data when configured) so you can replay a service cutover; cluster-wide scopes are an explicit platform choice, not the default stand-in for application DR.
* **Consistency:** Prefer application-integrated backup patterns (hooks, logical exports, or managed service features) when crash-only snapshots are insufficient.
* **Process:** Schedule tabletop and technical restore exercises at workload granularity (for example a DR drill restores the payments namespace and its RDS clone, not only `kubectl get nodes`); RTO and RPO are claims on paper until a timed restore passes.

#### Multi-Region and Global Connectivity

Regional DR typically pairs two or more Regions (for example `us-east-1` and `us-west-2`) with routing, data replication, and runbooks for promotion or cutover:

* **Hot/Hot:** Active workloads in both regions with global load balancing (for example Route 53 latency or weighted routing). Lowest RTO, highest cost.
* **Hot/Warm:** Primary region live; secondary hosts a smaller cluster and dependencies ready to scale or promote.
* **Hot/Cold:** Primary live; secondary relies on infrastructure-as-code and GitOps (for example Terraform, Argo CD) to rebuild clusters and replay manifests within your RTO.

Pair compute posture with data: Aurora Global Database, RDS cross-region read replicas (with promotion runbooks), DynamoDB global tables, S3 cross-region replication (CRR), and Route 53 health checks and routing policies should appear in the same architecture narrative, not only a second cluster with no shared recovery story.

For network paths between regions, use inter-Region VPC peering, Transit Gateway peering attachments, or other validated designs for throughput and routing. Replicate container images with Amazon ECR cross-region replication (and keep manifest and OLM sources consistent with that posture). When ROSA spans multiple regions or accounts, keep inventory, placement, and failover drills visible through your fleet tooling (see About this guide). [^71]

#### Stateful Application Considerations

Stateful applications remain a high-value focus: [managed relational tiers on AWS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_HighAvailability.html) such as RDS or Aurora (often with global or cross-region options) simplify failover and align with AWS resilience patterns. Where data must stay on cluster storage, storage operators, replication, and workload-scoped Velero or OADP (with tested namespace- or PVC-level restores) must close the RPO/RTO gap explicitly, without treating whole-cluster restore as the only articulated path. [^63]

## OpenShift platform alignment on ROSA

OpenShift objects such as `Route`, `Project`, `EgressFirewall`, SCC bindings, and OperatorHub subscriptions need to match **OVN-Kubernetes** semantics, your DNS and TLS posture, and what ROSA customers can actually change, not legacy OpenShift SDN lore or generic Kubernetes tutorials alone.

**Do:** State Route TLS modes explicitly (edge, passthrough, reencrypt) and who holds certificates; keep Pod Security admission and `securityContext` aligned with real SCC outcomes; scope admin tasks with [dedicated-admin](https://docs.aws.amazon.com/rosa/latest/userguide/using-dedicated-admins.html) patterns; validate ClusterOperators after upgrades; turn on user-defined monitoring when teams own `PrometheusRule` alerts; pin Operator channels and InstallPlan approval; use project templates so new Projects inherit quotas and network baselines.

**Don’t:** Treat `cluster-admin` as routine day-two access without policy; leave kubeadmin active after IdP cutover; document node SSH or MachineConfig edits as if customers own the hosted control plane on ROSA HCP; embed long-lived pull or cloud credentials in BuildConfig specs.

#### Networking: OVN, Routes, and policy

Assume **OVN-Kubernetes** for pod networking (see Cluster pod network (OVN-Kubernetes)). Author NetworkPolicy, EgressFirewall, and AdminNetworkPolicy (when available) against OVN behavior in your OpenShift minor. Cross-check product docs rather than assuming upstream-only NetworkPolicy examples apply verbatim.

For Routes (and Ingress where you use it), document TLS end-to-end: edge terminates at the router, passthrough keeps client TLS to the Pod (pair with IngressController and load-balancer designs that do not break that chain), and reencrypt terminates at the router then re-establishes TLS to backends. Record certificate sources and CA trust for each hop; align hostnames and wildcards with private or public ingress (see Private clusters, landing-zone ingress, and application DNS/TLS and [Configuring Routes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/configuring-routes)). [^80]

#### Projects, quotas, and project request templates

Treat each Project as a tenancy slice: RBAC, ResourceQuota, LimitRange, default NetworkPolicy, and SCC posture should be intentional, not ad hoc after self-service Project creation. For fleets, configure a project request template (or supported equivalent) so every new Project is born with baseline ResourceQuota, LimitRange, starter NetworkPolicy (for example default-deny with narrow egress), optional EgressFirewall, and RoleBinding patterns rather than hoping teams remember manual steps. See [Configuring project creation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/applications/projects/configuring-project-creation) in the OpenShift documentation and validate the exact menu path for your ROSA or OpenShift version. [^99]

#### SCC, Pod Security, AWS access, and secrets

Keep ServiceAccount-to-SCC mapping intentional: prefer `restricted` or an approved custom SCC; `privileged` should be rare and documented. Namespace Pod Security labels (or synonyms on your version) should match what SCC actually admits. Avoid “restricted YAML, privileged at runtime” drift. Application AWS access stays IRSA-first (Application workloads: IRSA, STS, and AWS credentials); sensitive material belongs in Secrets Manager or Vault via External Secrets Operator for production baselines, not only raw Secret YAML in Git (Configuration, secrets, and external secret management).

#### Administration, identity, and break-glass

Use [dedicated-admin](https://docs.aws.amazon.com/rosa/latest/userguide/using-dedicated-admins.html)-style privileges for supported customer administration; reserve `cluster-admin`-class grants for exceptions your security and subscription policies approve. Remove kubeadmin once external IdP and RBAC are validated (OIDC Configuration and Identity Providers), and write down break-glass steps (who can restore access, how tickets are opened).

#### ClusterOperators, monitoring, logging, and OperatorHub

Treat ClusterOperator health as part of upgrade and steady-state review. Resolve Degraded operators before declaring maintenance complete; use Insights alongside `oc get clusteroperators`.

```bash
oc get clusteroperators
```

When teams own application SLO burn-rate alerts, enable monitoring for user-defined projects and User Workload Monitoring and keep its ownership distinct from platform monitoring SREs run (Operational excellence and Monitoring product docs). [^91]

If narratives cover audit or SOC reviews, align Cluster Logging forwarders, Loki (or external sinks), and retention with policy (same section as centralized logging above).

For OperatorHub workloads, set Subscription `installPlanApproval` (Automatic versus Manual), pin channel and startingCSV discipline per your change model, and document catalog sources, including disconnected or mirror registries when egress policy requires them (Zero-Egress and Secure Egress architectures).

```bash
oc get subscription -A
oc get installplan -A | head -30
```

#### Integrated builds (BuildConfig, ImageStream)

Where BuildConfig, ImageStream, or S2I remain in play, protect pull secrets and Git or registry credentials: scope secrets to the namespace, rotate them, and avoid stuffing cluster-wide kubeconfigs or static cloud keys into build Source blocks.

#### Day-2 tooling and support bundles

Prefer `oc` and `rosa` flows that match supported ROSA operations. Do not document SSH to nodes or MachineConfig surgery as customer-operable levers on HCP when those planes are SRE-owned. For Red Hat support, collect `oc adm must-gather` (and Insights where applicable) and attach outputs per your support playbook (Health assessment framework).

## Health assessment framework and investigative scripting

Many teams codify health checks with the OpenShift and ROSA CLIs. A modular script can run proactive checks that reflect the best practices in this document.

#### Logic for a Cluster Health Script

The script should be structured into four main diagnostic categories: Platform Health, Resource Efficiency, Security Posture, and Lifecycle Readiness.

##### 1. Platform Health Diagnostics

* **Operator Status:** Verify all Cluster Operators are Available and not Degraded.

  ```bash
  oc get co -o json | jq -r '.items[] | select(any(.status.conditions[]?; .type=="Degraded" and .status=="True")) | .metadata.name'
  ```

* **Node Readiness:** Ensure all worker nodes are in the Ready state and have no disk pressure or memory pressure taints.

  ```bash
  oc get nodes --no-headers | awk '$2 != "Ready" {print $1, $2}'
  ```

##### 2. Resource Efficiency Diagnostics

* **Unbounded Pods:** Identify any workloads missing resource limits.

  ```bash
  oc get pods -A -o json | jq '.items[] | select(any(.spec.containers[]?; (.resources.limits // null) == null)) | .metadata.name'
  ```

* **Unused Persistent Volumes:** List PVs that are Available but not Bound.

  ```bash
  oc get pv | grep "Available"
  ```

##### 3. Security Posture Diagnostics

* **Privileged SCC Usage:** List any pods running with the privileged SCC.

  ```bash
  oc get pods -A -o json | jq '.items[] | select(.metadata.annotations["openshift.io/scc"] == "privileged") | .metadata.name'
  ```

* **Namespace Isolation:** Report on namespaces that are missing a NetworkPolicy.

  ```bash
  for ns in $(oc get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    if [ "$(oc get networkpolicy -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; then
      echo "Warning: No NetworkPolicy in namespace/$ns"
    fi
  done
  ```

##### 4. Lifecycle Readiness Diagnostics

* **PDB Violations:** Find Pod Disruption Budgets that are currently allowing zero disruptions, as these will block upgrades.

  ```bash
  oc get pdb -A -o json | jq -r '.items[] | select(.status.disruptionsAllowed == 0) | "\(.metadata.namespace) \(.metadata.name)"'
  ```

* **Upgrade Availability:** Check for recommended control plane and machine pool updates.

  ```bash
  rosa list upgrade -c <cluster_id>
  ```

#### Bonus ecosystem tools for health analysis

Beyond custom scripting, several open-source and native tools are designed for deep cluster auditing:

* **[Red Hat Advanced Cluster Security for Kubernetes (ACS)](https://www.redhat.com/en/technologies/cloud-computing/openshift/advanced-cluster-security-kubernetes):** Full-stack workload security (image scanning, risk-ranked CVEs, policy, runtime detection); complements ROSA’s managed platform when you centralize security operations (see About this guide). [^70]

* **Popeye:** A cluster linter commonly used with **OpenShift** that scans live clusters and reports potential issues with resources and configurations. [^64] It provides a standardized "scoring" system to evaluate the health of core OpenShift resources like BuildConfigs, ImageStreams, and Routes. [^65]
* **Kubescape:** An end-to-end security platform that scans clusters against hardening guidelines from the NSA, CISA, and MITRE ATT&CK. [^66] It is particularly effective for identifying insecure capabilities and service account token exposure. [^66]
* **must-gather:** The supported OpenShift utility for bundling diagnostics from your cluster context. [^67] On ROSA HCP, it surfaces rich detail for workers, namespaces, operators, and node and network data in your account (the layers where applications live), while Red Hat SREs hold the dedicated tooling for the hosted control plane itself. [^68]
* **Must-Gather Analyzer:** A specialized skill that parses the complex directory structures produced by must-gather to provide readable summaries of failing pods and degraded operators. [^69]

## Nuanced conclusions and expert recommendations

ROSA HCP is a major step forward in managed OpenShift on AWS: faster time-to-cluster, a data-plane-centric footprint, and independent upgrade lanes that let platform teams move at the speed of the business. ROSA Classic customers get the same SRE partnership and add a clear migration path when they are ready for that next wave of efficiency, all without leaving the ROSA product family.

Lean on STS-first identity, GitOps for golden configuration, and Insights Advisor for continuous improvement so your data plane and applications inherit the same rigor Red Hat brings to the control plane.

At fleet scale, add [ACM](https://www.redhat.com/en/technologies/management/advanced-cluster-management) for governance, application and GitOps placement, and multi-cluster visibility, and [ACS](https://www.redhat.com/en/technologies/cloud-computing/openshift/advanced-cluster-security-kubernetes) for image assurance and runtime security. Together they turn ROSA best practices into repeatable, measurable outcomes across every cluster you import.

Layer autoscaled machine pools (nodes), Horizontal Pod Autoscaler (replicas), Vertical Pod Autoscaler (commonly recommendation-only for safer rightsizing), optional low-priority buffer workloads where preemption matches your burst SLOs, and Compliance Operator workflows to keep capacity right-sized and audit-ready. Teams that operate ROSA HCP this way routinely report higher developer satisfaction alongside enterprise-grade reliability on AWS.

For regulated environments, zero-egress–oriented installs, regional ECR, your egress guardrails, and mirrored Operators combine into a strong assurance stack: maximum control over software supply chain and network boundaries when your policies call for it, while standard deployments keep full internet flexibility for velocity. These practices help platform teams deliver OpenShift experiences that engage developers and satisfy demanding enterprise standards.

[^1]: ROSA architecture - Red Hat OpenShift Service on AWS, accessed April 1, 2026, [https://docs.aws.amazon.com/rosa/latest/userguide/rosa-architecture-models.html](https://docs.aws.amazon.com/rosa/latest/userguide/rosa-architecture-models.html)
[^2]: Hosted Control Planes - Red Hat OpenShift Service on AWS, accessed April 1, 2026, [https://www.rosaworkshop.io/rosa/18-deploy\_hcp/](https://www.rosaworkshop.io/rosa/18-deploy_hcp/)
[^3]: Chapter 2\. Learn more about ROSA with HCP | About | Red Hat OpenShift Service on AWS, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red\_hat\_openshift\_service\_on\_aws/4/html/about/about-hcp](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/about/about-hcp)
[^6]: Maximizing the Value of Red Hat OpenShift on AWS - Amazon.com, accessed April 1, 2026, [https://aws.amazon.com/blogs/ibm-redhat/maximizing-the-value-of-red-hat-openshift-on-aws/](https://aws.amazon.com/blogs/ibm-redhat/maximizing-the-value-of-red-hat-openshift-on-aws/)
[^7]: DNS resolution: ROSA with Hosted Control Plane (HCP) compared to ROSA classic, accessed April 1, 2026, [https://access.redhat.com/articles/7109571](https://access.redhat.com/articles/7109571)
[^8]: Chapter 1\. Upgrading Red Hat OpenShift Service on AWS clusters, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red\_hat\_openshift\_service\_on\_aws/4/html/upgrading/rosa-hcp-upgrading](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/upgrading/rosa-hcp-upgrading)
[^9]: Create a ROSA with HCP cluster using the ROSA CLI - Red Hat OpenShift Service on AWS, accessed April 1, 2026, [https://docs.aws.amazon.com/rosa/latest/userguide/getting-started-hcp.html](https://docs.aws.amazon.com/rosa/latest/userguide/getting-started-hcp.html)
[^14]: Chapter 7\. Creating Red Hat OpenShift Service on AWS clusters ..., accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red\_hat\_openshift\_service\_on\_aws/4/html/install\_clusters/rosa-hcp-egress-zero-install](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_clusters/rosa-hcp-egress-zero-install)
[^16]: Chapter 3\. AWS STS and ROSA with HCP explained | Introduction to ..., accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red\_hat\_openshift\_service\_on\_aws/4/html/introduction\_to\_rosa/cloud-experts-rosa-hcp-sts-explained](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/cloud-experts-rosa-hcp-sts-explained)
[^19]: ROSA HCP Quickstart | Red Hat Cloud Experts Documentation, accessed April 1, 2026, [/experts/rosa/rosa-quickstart/](/experts/rosa/rosa-quickstart/)
[^20]: Chapter 4\. OpenID Connect Overview | Introduction to ROSA | Red Hat OpenShift Service on AWS classic architecture, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red\_hat\_openshift\_service\_on\_aws\_classic\_architecture/4/html/introduction\_to\_rosa/rosa-oidc-overview](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws_classic_architecture/4/html/introduction_to_rosa/rosa-oidc-overview)
[^22]: Using RBAC to define and apply permissions | Authentication and authorization | OKD 4.18, accessed April 1, 2026, [https://search.help.openshift.com/cache/?docId=3cdbc49e36de42aaa983344c05aca64d&hq=routes](https://search.help.openshift.com/cache/?docId=3cdbc49e36de42aaa983344c05aca64d&hq=routes)
[^26]: 6 Types of Kubernetes Health Checks & Using Them in Your Cluster - Codefresh, accessed April 1, 2026, [https://codefresh.io/learn/kubernetes-management/6-types-of-kubernetes-health-checks-and-using-them-in-your-cluster/](https://codefresh.io/learn/kubernetes-management/6-types-of-kubernetes-health-checks-and-using-them-in-your-cluster/)
[^27]: Chapter 12\. Monitoring application health by using health checks | Building applications | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift\_container\_platform/4.18/html/building\_applications/application-health](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/building_applications/application-health)
[^32]: OpenShift- limit/Quota/LimitRange | by Khemnath chauhan - Medium, accessed April 1, 2026, [https://be-reliable-engineer.medium.com/openshift-quota-limitrange-6247ea1451bb](https://be-reliable-engineer.medium.com/openshift-quota-limitrange-6247ea1451bb)
[^33]: Resource Management for Pods and Containers - Kubernetes, accessed April 1, 2026, [https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
[^35]: Pod Disruption Budgets: Pitfalls, Evictions & Kubernetes Upgrades - Chkk, accessed April 1, 2026, [https://www.chkk.io/blog/pod-disruption-budgets](https://www.chkk.io/blog/pod-disruption-budgets)
[^37]: How to Handle Kubernetes Pod Disruption Budgets - OneUptime, accessed April 1, 2026, [https://oneuptime.com/blog/post/2026-02-02-kubernetes-pod-disruption-budgets/view](https://oneuptime.com/blog/post/2026-02-02-kubernetes-pod-disruption-budgets/view)
[^40]: Insights Advisor for OpenShift - How to react to Advisor recommendations - Red Hat, accessed April 1, 2026, [https://www.redhat.com/en/blog/insights-advisor-openshift-how-react-advisor-recommendations](https://www.redhat.com/en/blog/insights-advisor-openshift-how-react-advisor-recommendations)
[^45]: OpenShift Security: Challenges and 5 Critical Best Practices - Tigera.io, accessed April 1, 2026, [https://www.tigera.io/learn/guides/kubernetes-security/openshift-security/](https://www.tigera.io/learn/guides/kubernetes-security/openshift-security/)
[^47]: Red Hat OpenShift Compliance Operator – Compliance Scans | techbeatly, accessed April 1, 2026, [https://techbeatly.com/red-hat-openshift-compliance-operator-compliance-scans/](https://techbeatly.com/red-hat-openshift-compliance-operator-compliance-scans/)
[^48]: Chapter 3\. Network policy | Network security | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift\_container\_platform/4.18/html/network_security/network-policy](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/network_security/network-policy)
[^49]: Chapter 5\. Egress Firewall | Network security | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift\_container\_platform/4.18/html/network_security/egress-firewall](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/network_security/egress-firewall)
[^51]: A Guide to OpenShift Compliance Operator Best Practices - Red Hat, accessed April 1, 2026, [https://www.redhat.com/en/blog/a-guide-to-openshift-compliance-operator-best-practices](https://www.redhat.com/en/blog/a-guide-to-openshift-compliance-operator-best-practices)
[^53]: Installing the Compliance Operator - OKD Documentation, accessed April 1, 2026, [https://docs.okd.io/latest/security/compliance\_operator/co-management/compliance-operator-installation.html](https://docs.okd.io/latest/security/compliance_operator/co-management/compliance-operator-installation.html)
[^55]: CSA-RH/rosa-hcp-fast-deploy: The idea behind this shell script was to automatically create ... - GitHub, accessed April 1, 2026, [https://github.com/CSA-RH/rosa-hcp-fast-deploy](https://github.com/CSA-RH/rosa-hcp-fast-deploy)
[^59]: Chapter 5\. Using quotas and limit ranges | Scalability and performance | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift\_container\_platform/4.18/html/scalability\_and\_performance/compute-resource-quotas](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/scalability_and_performance/compute-resource-quotas)
[^63]: Best practices for high availability with OpenShift | Compute Engine | Google Cloud Documentation, accessed April 1, 2026, [https://docs.cloud.google.com/compute/docs/containers/openshift-ha](https://docs.cloud.google.com/compute/docs/containers/openshift-ha)
[^64]: popeye | A Kubernetes cluster resource sanitizer, accessed April 1, 2026, [https://popeyecli.io/](https://popeyecli.io/)
[^65]: OpenShift Popeye Analysis | Claude Code Skill - MCP Market, accessed April 1, 2026, [https://mcpmarket.com/tools/skills/openshift-popeye-health-analysis](https://mcpmarket.com/tools/skills/openshift-popeye-health-analysis)
[^66]: How to Audit Kubernetes Cluster Security Posture with Kubescape Frameworks, accessed April 1, 2026, [https://oneuptime.com/blog/post/2026-02-09-audit-security-posture-kubescape/view](https://oneuptime.com/blog/post/2026-02-09-audit-security-posture-kubescape/view)
[^67]: GitHub - openshift/must-gather: A client tool for gathering information about an operator managed component., accessed April 1, 2026, [https://github.com/openshift/must-gather](https://github.com/openshift/must-gather)
[^68]: Gathering data about your cluster | Support - OKD Documentation, accessed April 1, 2026, [https://docs.okd.io/latest/support/gathering-cluster-data.html](https://docs.okd.io/latest/support/gathering-cluster-data.html)
[^69]: Must-Gather Analyzer | OpenShift Claude Code Skill - MCP Market, accessed April 1, 2026, [https://mcpmarket.com/tools/skills/must-gather-analyzer-for-openshift](https://mcpmarket.com/tools/skills/must-gather-analyzer-for-openshift)
[^70]: Red Hat Advanced Cluster Security for Kubernetes | Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/)
[^71]: Red Hat Advanced Cluster Management for Kubernetes | Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/)
[^72]: Assigning Pods to Nodes | Kubernetes Documentation, accessed April 1, 2026, [https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
[^73]: Pod Topology Spread Constraints | Kubernetes Documentation, accessed April 1, 2026, [https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
[^74]: Chapter 2\. Working with pods | Nodes | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift\_container\_platform/4.18/html/nodes/working-with-pods](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/working-with-pods)
[^75]: Chapter 1\. About the OVN-Kubernetes network plugin | OVN-Kubernetes network plugin | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift\_container\_platform/4.18/html/ovn-kubernetes\_network\_plugin/about-ovn-kubernetes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/ovn-kubernetes_network_plugin/about-ovn-kubernetes)
[^76]: Chapter 2\. Admin network policy | Network security | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift\_container\_platform/4.18/html/network_security/admin-network-policy](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/network_security/admin-network-policy)
[^77]: Jobs | Kubernetes Documentation, accessed April 1, 2026, [https://kubernetes.io/docs/concepts/workloads/controllers/job/](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
[^78]: CronJob | Kubernetes Documentation, accessed April 1, 2026, [https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
[^79]: Service | Kubernetes Documentation, accessed April 1, 2026, [https://kubernetes.io/docs/concepts/services-networking/service/](https://kubernetes.io/docs/concepts/services-networking/service/)
[^80]: Configuring Routes | Networking | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/configuring-routes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/configuring-routes)
[^81]: About OpenShift Service Mesh | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/service_mesh/about-ossm](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/service_mesh/about-ossm)
[^82]: What is AWS Certificate Manager? | AWS Documentation, accessed April 1, 2026, [https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html](https://docs.aws.amazon.com/acm/latest/userguide/acm-overview.html)
[^83]: Configuring ingress cluster traffic | Networking | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/configuring-ingress-cluster-traffic](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking/configuring-ingress-cluster-traffic)
[^84]: cert-manager Operator for Red Hat OpenShift | Security and compliance | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift)
[^85]: Networking Operators | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking_operators/index](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/networking_operators/index) (includes **External DNS Operator**)
[^86]: Security in IAM for ROSA | Red Hat OpenShift Service on AWS | AWS Documentation, accessed April 1, 2026, [https://docs.aws.amazon.com/rosa/latest/userguide/security-iam.html](https://docs.aws.amazon.com/rosa/latest/userguide/security-iam.html)
[^87]: IAM database authentication for Amazon RDS | AWS Documentation, accessed April 1, 2026, [https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html)
[^88]: Managing security context constraints | Authentication and authorization | OKD Documentation, accessed April 1, 2026, [https://docs.okd.io/latest/authentication/managing-security-context-constraints.html](https://docs.okd.io/latest/authentication/managing-security-context-constraints.html)
[^89]: Configure a security context for a Pod or container | Kubernetes Documentation, accessed April 1, 2026, [https://kubernetes.io/docs/tasks/configure-pod-container/security-context/](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
[^90]: Using RBAC and defining authorization | Authentication and authorization | OKD Documentation, accessed April 1, 2026, [https://docs.okd.io/latest/authentication/using-rbac.html](https://docs.okd.io/latest/authentication/using-rbac.html)
[^91]: Monitoring | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/index](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/monitoring/index)
[^92]: Container images | Kubernetes Documentation, accessed April 1, 2026, [https://kubernetes.io/docs/concepts/containers/images/](https://kubernetes.io/docs/concepts/containers/images/)
[^93]: Red Hat Trusted Profile Analyzer | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/](https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/)
[^94]: Red Hat Trusted Artifact Signer | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/)
[^95]: Deprecated API Migration Guide | Kubernetes Documentation, accessed April 1, 2026, [https://kubernetes.io/docs/reference/using-api/deprecation-guide/](https://kubernetes.io/docs/reference/using-api/deprecation-guide/)
[^96]: Garbage Collection | Kubernetes Documentation, accessed April 1, 2026, [https://kubernetes.io/docs/concepts/architecture/garbage-collection/](https://kubernetes.io/docs/concepts/architecture/garbage-collection/)
[^97]: Shared responsibility for ROSA | Amazon Web Services Documentation, accessed April 1, 2026, [https://docs.aws.amazon.com/rosa/latest/userguide/rosa-responsibilities.html](https://docs.aws.amazon.com/rosa/latest/userguide/rosa-responsibilities.html)
[^98]: Policies and service definition – responsibility matrix | Red Hat OpenShift Service on AWS Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition#rosa-policy-responsibility-matrix](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition#rosa-policy-responsibility-matrix)
[^99]: Configuring project creation | OpenShift Container Platform | 4.18 | Red Hat Documentation, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/applications/projects/configuring-project-creation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/applications/projects/configuring-project-creation)
[^100]: Understanding OpenShift GitOps | Red Hat OpenShift GitOps | Red Hat Documentation, accessed April 1, 2026, [https://docs.openshift.com/gitops/latest/about/understanding-openshift-gitops.html](https://docs.openshift.com/gitops/latest/about/understanding-openshift-gitops.html)
[^101]: Understanding OpenShift Pipelines | OpenShift Pipelines | Red Hat Documentation, accessed April 1, 2026, [https://docs.openshift.com/pipelines/latest/about/understanding-openshift-pipelines.html](https://docs.openshift.com/pipelines/latest/about/understanding-openshift-pipelines.html)
[^102]: Chapter 2. Forwarding control plane logs | Security and compliance | Red Hat OpenShift Service on AWS, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/security_and_compliance/rosa-forwarding-control-plane-logs](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/security_and_compliance/rosa-forwarding-control-plane-logs)
[^103]: Red Hat OpenShift Cluster Observability Operator | OpenShift Container Platform | 4.18, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cluster_observability_operator/index](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cluster_observability_operator/index)
[^104]: Network Observability | OpenShift Container Platform | 4.18, accessed April 1, 2026, [https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/network_observability/index](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/network_observability/index)
