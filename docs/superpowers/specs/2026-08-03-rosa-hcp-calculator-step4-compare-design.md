# ROSA HCP Calculator: Step 4 platform compare

Date: 2026-08-03  
Status: Superseded for self-managed column by `2026-08-03-rosa-hcp-calculator-step4-capabilities-design.md` (ROSA vs EKS + capabilities)  
Related: `2026-07-27-rosa-hcp-calculator-design.md`, `2026-08-03-rosa-hcp-calculator-expert-mode-design.md`, PR #970

## Decision

Add **Step 4 - Compare platforms**: a list-to-list comparison of the active Step 1 scenario against:

1. **ROSA HCP** (baseline)
2. **Self-managed OpenShift** (editable yearly core-pair list price)
3. **Amazon EKS Auto Mode** (published control-plane rate + approximate Auto Mode management fee)

Step 2 discounts (EC2 Savings Plan %, Private Offer) are **not** applied in Step 4 so all three columns stay list-to-list.

## Goals

- Give sales/partners a clear “same workers, different platform tax” view
- Keep assumptions explicit and editable where list price is not public (OCP)
- Reuse Step 1 sizing; do not invent alternate worker mixes in v1

## Non-goals (v1)

- Regional EKS Auto Mode rate tables or AWS Price List API pulls
- EKS extended support (`$0.60/hr`), Provisioned Control Plane, Hybrid Nodes, Capabilities
- Editable self-managed control/infra counts or instance types
- Applying Step 2 discounts inside Step 4
- Share-code encoding of OCP list price (local draft persistence is enough)
- Modeling EBS, LBs, data transfer, NAT, or other non-worker AWS costs (same exclusions as Step 3)

## Cost model

Inputs come from the **active** calculator mode (Basic or Expert). Summary price unit matches Step 3 (`hourly` / `monthly` / `yearly`).

### Shared worker EC2

- Same instance types, counts, and regions as Step 1
- Priced at snapshot **On-Demand** only (ignore EC2 Savings Plan %)
- Worker vCPU for subscriptions/fees: sum of catalog vCPUs × node counts for worker pools only
- Core-pairs: `ceil(totalWorkerVcpu / 4)` (same 4-vCPU block size as ROSA Worker Node Fee)

### ROSA HCP column

| Component | Formula |
|-----------|---------|
| Worker EC2 | OD snapshot × worker nodes |
| Control / infra EC2 | none (`-`) |
| Platform control-plane fee | `$0.25/hr × clusterCount` (HCP cluster fee) |
| OpenShift / node software | PAYGO Worker Node Fee: `$1,500/year` per 4 vCPU (`ceil(vCPU/4)` blocks) |
| EKS Auto Mode fee | none (`-`) |

### Self-managed OpenShift column

| Component | Formula |
|-----------|---------|
| Worker EC2 | Same OD worker EC2 as ROSA |
| Control / infra EC2 | Per cluster: **3 control + 3 infra** nodes, type **`m7i.xlarge`**, priced OD in that cluster’s region |
| Platform control-plane fee | none (`-`); control plane is customer EC2 above |
| OpenShift / node software | `corePairs × ocpListUsdPerCorePairYear` (editable; default **`15000`**) |
| EKS Auto Mode fee | none (`-`) |

Region for control/infra EC2:

- **Expert:** each cluster’s own `region`
- **Basic:** scenario region (region select / primary basic region) for every cluster in `clusterCount`

If `m7i.xlarge` pricing is missing for a region, show `N/A` for that control/infra line and block a numeric total for self-managed (same pattern as missing worker pricing in Step 3).

### EKS Auto Mode column

| Component | Formula |
|-----------|---------|
| Worker EC2 | Same OD worker EC2 as ROSA |
| Control / infra EC2 | none (`-`); EKS control plane is managed |
| Platform control-plane fee | `$0.10/hr × clusterCount` (standard Kubernetes version support) |
| OpenShift / node software | none (`-`) |
| EKS Auto Mode fee | **12% of worker OD EC2** (approximation of public AWS examples where Auto Mode ≈ 12% of listed OD instance rate; document clearly) |

v1 does **not** add Auto Mode fee on self-managed control/infra nodes (those nodes are not part of the EKS column).

## UI

New collapsed `<details>` after Step 3:

**Step 4 - Compare platforms**

### Controls

- Number input: **OCP list price (USD / core-pair / year)**, default `15000`, min `0`
- Short muted assumptions copy covering:
  - List-to-list (Step 2 discounts ignored)
  - Self-managed adds 3 control + 3 infra `m7i.xlarge` per cluster
  - Auto Mode fee modeled as ~12% of worker OD EC2
  - Estimate-only / not a quote

### Table

Columns: **Cost component | ROSA HCP | Self-managed OpenShift | EKS Auto Mode**

Rows:

1. Worker EC2
2. Control / infra EC2
3. Platform control-plane fee
4. OpenShift subscription / Worker Node Fee
5. EKS Auto Mode management fee
6. **Total**
7. **vs ROSA** (absolute delta + percent; ROSA cell = `Baseline`)

Empty or hard-validation-failed Step 1: show the same class of blocked/empty message as Step 3 (no fabricated compare totals).

Help modal: add a short Step 4 subsection.

## Persistence

- Store `ocpListUsdPerCorePairYear` in the existing localStorage draft payload (`draft-storage.mjs`)
- Reset saved data restores the `15000` default but keeps current Basic/Expert mode
- Share URL v1: no new fields required

## Implementation sketch

- New pure module: `assets/rosa/hcp-cost-calculator/js/platform-compare.mjs` (+ tests)
  - Input: active estimate/worker rows, cluster count, per-cluster regions, pricing/catalog snapshots, OCP list rate, unit
  - Output: row model with monthly values + formatted unit conversion helpers reused from app patterns
- Wire Step 4 DOM in `app.html`; recompute when Step 1/unit/OCP list price changes
- Mirror module under `static/rosa/hcp-cost-calculator/js/` if that tree remains the static copy convention

## CSV (optional follow-up)

Nice-to-have: append a `SECTION,Platform compare` block on export. Not required to ship Step 4 UI.

## Version support lifecycle (non-cost table)

Always show a second table under the cost compare:

| Topic | ROSA HCP | Self-managed | EKS Auto Mode |
|-------|----------|--------------|---------------|
| Included version window | ~24 months on even OpenShift minors (Full + Maintenance + **EUS Term 1 / Long-Life Additional Term 1**, included with Premium-class ROSA) | ~18 months + EUS Term 1 with Premium OCP | **14 months** standard at `$0.10/hr` |
| Stay longer | Optional EUS Term 2 / Term 3 | Optional EUS Term 2 / Term 3 | +12 months extended at **`$0.60/hr`** |

Optional checkbox: **EKS on extended Kubernetes support ($0.60/hr)** switches the EKS platform control-plane fee in the cost table and updates lifecycle copy. Persisted in local draft.

## Open assumptions (documented in UI)

- OCP default `$15,000` / core-pair / year is a planning placeholder; users must edit to match their list/quote
- EKS Auto Mode 12% is an approximation of published examples, not a contractual rate card
- Self-managed control+infra sizing is a fixed planning assumption, not a sizing recommendation
- Comparisons exclude the same non-worker AWS costs already excluded in Step 3
- AWS Support plans (Business/Enterprise) are still not modeled as a dollar line item

## Approval record

- Editable OCP list default $15k: approved
- EKS like-for-like workers + CP + ~12% Auto Mode: approved
- Self-managed 3 control + 3 infra `m7i.xlarge` per cluster: approved
- List-to-list (ignore Step 2): approved
- Comparison table UI (approach B): approved
- Scope / persistence / out of scope: approved
