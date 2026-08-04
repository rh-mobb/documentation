# ROSA HCP Calculator: Step 4 ROSA vs EKS + capabilities

Date: 2026-08-03  
Status: Implemented (capabilities narrative-only; no Argo CD $ modeling)  
Related: `2026-08-03-rosa-hcp-calculator-step4-compare-design.md` (supersedes self-managed column)

## Decision

Revise **Step 4 - Platform Comparison and TCO** to:

1. Compare **ROSA HCP** vs **EKS Auto Mode** only (remove self-managed OpenShift)
2. Keep a list-to-list **cost** table
3. Add a **capabilities** matrix (GitOps, Observability, Service Mesh): narrative inclusion/support only (no Capability dollar lines)
4. Keep the **lifecycle** table (ROSA vs EKS only)

## Cost table (two columns, locked to 1-year)

Columns: **Cost component | ROSA HCP (1-year) | EKS Auto Mode (1-year)**

Rows:

1. Worker EC2 (shared OD list; Step 2 EC2 discount ignored)
2. Platform control-plane fee (`$0.25/hr` HCP list vs `$0.10/hr` EKS standard only; no published standard % off HCP cluster fee)
3. Worker Node Fee (ROSA standard **1-year Private Offer 33% off** PAYGO; EKS `-`)
4. EKS Auto Mode management fee (`~12%` of worker OD EC2; ROSA `-`)
5. Production support (ROSA Included Premium; EKS AWS Business 10%)
6. **1-year total**
7. **vs ROSA**

Callout after the table: 1-year base understates EKS; hidden/deferred costs (including platform ops labor, extended support) appear in 3-year TCO. EKS extended Kubernetes support (`$0.60/hr`) is a potential additional cost (lifecycle + TCO), not a base-table toggle. Platform ops labor is **TCO-only**.

Remove: price-unit selector on Step 4, EKS extended-support checkbox, OCP list price control, self-managed column.

## Capabilities matrix

Compact table (keep width tight): **Capability | ROSA | EKS | Difference**

Status marks: **✓** included/supported · **✗** not included · **?** partial, add-on, or BYO.

| Capability | ROSA | EKS | Difference (short) |
|------------|------|-----|--------------------|
| **GitOps** | ✓ | ? | OpenShift GitOps vs EKS Argo CD Capability or self-managed Argo/Flux |
| **Observability** | ✓ | ✗ | ROSA includes Prometheus + Observe; EKS uses CloudWatch/AMP/AMG or BYO |
| **Service Mesh** | ✓ | ✗ | OpenShift Service Mesh vs no managed Istio twin on EKS (BYO/other) |
| **Dev Spaces** | ✓ | ✗ | OpenShift Dev Spaces vs no EKS twin (Codespaces/CodeCatalyst/BYO) |
| **Image builds** | ✓ | ✗ | OpenShift Builds/Pipelines + ImageStreams vs external CI→ECR or BYO Tekton |
| **Production support** | ✓ | ? | ROSA includes Red Hat Premium; EKS needs AWS Business Support (~10% of AWS spend) |
| **Hardened base images** | ✓ | ✗ | Red Hat UBI / Hardened Images with OpenShift vs Chainguard or DIY on EKS |
| **Developer console** | ✓ | ✗ | OpenShift web console vs kubectl/AWS console or DIY developer portal on EKS |
| **Cluster IdP / SSO** | ✓ | ? | ROSA cluster OAuth + in-product IdPs; EKS IAM Access Entries + bolted-on Cognito/Identity Center/Dex/Okta |

Wash items (ingress, managed worker OS) stay out.

### Support dollars (cost table)

- Always on for EKS: **AWS Business Support at 10%** of modeled EKS AWS spend (worker EC2 + control-plane fee + Auto Mode fee). List-price proxy; no discount modeling.
- ROSA cell: **Included (Premium)** with **$0** added (Premium is bundled; AWS Support on ROSA for pure infra is not modeled).

### 3-year TCO

36-month list-price total at end of Step 4:

- **ROSA:** Worker Node Fee at standard **3-year Private Offer 55% off** PAYGO; HCP cluster fee + EC2 at list × 36 (Premium / EUS Term 1 included; Term 2/3 not modeled)
- **EKS control plane:** 14 months × `$0.10/hr` + 12 months × `$0.60/hr` extended + 10 months × `$0.10/hr` after upgrade (matches longer ROSA stay within the horizon)
- **EKS other:** worker EC2 + Auto Mode (~12%) + AWS Business 10% across all 36 months
- **Platform components (not editable, TCO-only):** conservative EKS proxy for **common** monitoring + logging + GitOps/CI (**$3,600**/yr base + **$600**/yr per extra cluster, **cap $10,800**/yr). ROSA **Included**. Excludes mesh, hardened images, runtimes, registry (wash). Footnote clarifies heavier enterprise add-ons would raise EKS further.
- **Platform ops labor (not editable, TCO-only):** stepped by Step 1 **cluster count** at **$225,000**/FTE/year fully loaded (ROSA / EKS): 1 → 1/2; 2–5 → 1.5/3; 6–15 → 2.5/5; 16–40 → 4/8; 41+ → 5/10. ROSA mid/high tiers anchored to field examples (~4 FTEs for 30+ HCP); EKS ≈2×.

## Lifecycle

Two columns only. Note EKS extended support as a **potential additional cost** (no checkbox).

## Persistence (local draft)

- Remove `ocpListUsdPerCorePairYear` from new saves (ignore if present in old drafts)
- `eksExtendedSupport` ignored if present in old drafts (no UI toggle)

## Non-goals

- Modeling CloudWatch/AMP/AMG dollars
- Modeling EKS Argo CD Capability base/Application fees in the cost table
- ACK/KRO Capability rows
- AWS Support plan %
- Share-URL encoding of Step 4 fields (draft is enough)

## Approval record

- Scope A (GitOps + Observability + Service Mesh): approved
- Dual-table layout: approved
- Drop self-managed: approved
- GitOps/Observability/Service Mesh all narrative-only (no Capability $): approved
