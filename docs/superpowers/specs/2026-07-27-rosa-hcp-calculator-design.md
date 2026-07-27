# ROSA HCP Calculator Design

Date: 2026-07-27  
Status: Draft for review  
Scope: V1 design only

## 1. Problem and goal

We need a ROSA calculator that matches current platform direction and avoids deprecated cluster models.

Goals for v1:

- HCP only
- MachinePools only
- Cost estimation with min, steady-state, and max scenarios
- Right-sizing recommendations
- Guardrails for invalid and risky inputs
- Manual snapshot-based pricing and catalog refresh

Out of scope for v1:

- ROSA Classic modeling
- Karpenter modeling
- Live pricing fetch at runtime
- Fleet aggregation logic (phase 2)

## 2. Product principles

- Keep the first experience short: users can produce a result within a minute.
- Model HCP as it is operated: single-AZ pools, with multi-AZ represented by multiple pools.
- Use deterministic snapshot data in the app.
- Separate hard validation from advisory warnings.
- Keep recommendation logic transparent and reproducible.
- Present legal/financial disclaimers clearly: this tool provides estimates only and is not a quote.

## 3. V1 domain model

### 3.1 Estimate

- region
- pricing snapshot metadata
- instance catalog snapshot metadata
- list of MachinePool Sets

### 3.2 MachinePool Set

A set is the right-sizing and operational unit.

- set_name
- instance_type (single type for the set)
- architecture (derived from instance type)
- three AZ pools (A/B/C) created by helper action
- per-AZ counts:
  - min_nodes
  - steady_nodes
  - max_nodes

### 3.3 AZ Pool

- az (required, valid in selected region)
- min_nodes
- steady_nodes
- max_nodes

### 3.4 Defaults

On new estimate, auto-create one default 3-AZ set:

- AZ A, AZ B, AZ C
- min/steady/max = 1/1/1 per AZ pool

## 4. UX and workflow

## 4.1 Top controls

- Region selector
- New estimate / reset action
- Snapshot freshness metadata
- Persistent estimation disclaimer link/button opening full disclaimer text

## 4.2 Input panel

- List of MachinePool Sets
- Set card fields:
  - set name
  - instance type selector
  - architecture badge
  - AZ rows with min/steady/max fields
- Actions:
  - Create 3-AZ set
  - Duplicate set
  - Remove set (except required default set if lock is enabled)

## 4.3 Results panel

- Summary cards:
  - Min monthly
  - Steady-state monthly
  - Max monthly
- Tier comparison:
  - On-Demand
  - 1-year
  - 3-year
- Detailed table by set and scenario
- Recommendation panel:
  - generated per set
  - one-click apply to swap instance type for the entire set
- Inline estimate disclaimer near totals and export/share actions

## 4.4 Validation UX

- Inline hard errors block calculation
- Warning panel does not block calculation

## 5. Calculation semantics

For each MachinePool Set and scenario S in {min, steady, max}:

1. `nodes_S = sum(AZ pool nodes for scenario S)`
2. `set_cost_S_tier = nodes_S * per_node_price(instance_type, region, tier)`
3. `total_cost_S_tier = sum(set_cost_S_tier across all sets)`

Displayed tiers:

- On-Demand
- 1-year
- 3-year

Displayed scenarios:

- Min
- Steady-state
- Max

## 6. Right-sizing behavior

Recommendations are computed per MachinePool Set.

Candidate requirements:

- Must be in ROSA HCP supported instance catalog snapshot
- Must have pricing for selected region
- Must satisfy capacity-fit thresholds (vCPU/memory fit policy)

Ranking:

1. Lower steady-state cost
2. Lower max scenario cost impact
3. Preference policy for architecture (including Graviton options)

Applied recommendation updates only the set's instance type and recalculates all scenarios.

## 7. Guardrail policy

## 7.1 Hard blocks

- Missing or invalid region
- Missing instance type
- Instance type unsupported for HCP
- AZ not valid for selected region
- Invalid count ordering:
  - min > steady
  - steady > max
- Negative or non-integer counts
- No machine pool sets present

## 7.2 Soft warnings

- Strong AZ imbalance within a set
- Large burst spread: max - steady
- Significant savings alternative available
- Graviton alternative with better price-performance
- Snapshot age beyond warning threshold

## 8. Data pipeline and refresh

The app reads only committed snapshots.

No live API calls in v1.

### 8.0 Source vs runtime locations

Users are not expected to read JSON directly, but the browser app must fetch JSON at runtime.

Therefore, runtime JSON must be published at web-loadable URLs under `static/`.

Path split:

- Canonical/generated snapshot source (maintainer-facing): `assets/rosa/<new-calculator>/data/`
- Runtime published JSON (app-facing): `static/rosa/<new-calculator>/data/`
- App fetch URLs: `/experts/rosa/<new-calculator>/data/...`

### 8.1 Snapshot artifacts

- `regions.json`
- `instance-catalog.json`
- `pricing/<region>.json`
- `snapshot-manifest.json`

Runtime location examples:

- `static/rosa/<new-calculator>/data/regions.json`
- `static/rosa/<new-calculator>/data/instance-catalog.json`
- `static/rosa/<new-calculator>/data/pricing/us-east-1.json`
- `static/rosa/<new-calculator>/data/snapshot-manifest.json`

### 8.2 Manual refresh workflow

One maintainer command refreshes:

- Supported instance catalog (ROSA/OCM source)
- Pricing payloads for selected common regions
- Snapshot manifest timestamps and metadata
- Runtime JSON publish step from canonical source to `static/rosa/<new-calculator>/data/`

### 8.3 Refresh integrity checks

Hard fail refresh if:

- Priced instance missing in catalog
- Region missing required payloads
- Tier fields incomplete for required output
- Unknown schema drift detected

## 9. Implementation architecture (repo-aligned)

Follow the existing standalone app pattern used by the current cost explorer:

- Content stub:
  - `content/rosa/<new-calculator>/index.md`
- Standalone app source:
  - `assets/rosa/<new-calculator>/app.html`
- Layout injector:
  - `layouts/_default/<new-layout>.html`
- Shared chrome injection tokens:
  - `__TRACKING_HEAD__`
  - `__MAIN_CSS__`
  - `__HEADER__`
  - `__NAV__`
  - `__FOOTER__`
  - `__PAGEFIND_INIT__`

Recommended internal code organization in `app.html`:

- Data access module (snapshot loading + normalization)
- Validation module (hard/soft rule engine)
- Cost engine module (scenario and tier math)
- Recommendation module (candidate generation and ranking)
- UI state/store module
- View components (set cards, result cards, table, warnings)

## 10. Verification plan

For implementation validation:

1. Build:
   - `hugo --gc --minify --theme rhds`
2. Smoke checks in browser:
   - New estimate defaults create one 3-AZ set with 1/1/1
   - Region changes update AZ availability and pricing source
   - Hard errors block calculation
   - Warnings display while calculation still renders
   - Recommendations apply per set correctly
   - Estimation disclaimer is visible in header/control area and near results
   - Disclaimer language clearly states: estimate only, not a quote, no commercial offer
3. Snapshot integrity checks:
   - refresh command fails on mismatched catalog/pricing
4. Optional search check:
   - `make preview-search`

## 11. Phase plan

### V1

- HCP + MachinePools + snapshots + min/steady/max + right-sizing + guardrails

### V2

- Karpenter model support
- Fleet aggregation
- Advanced burst utilization percent over month

## 12. Open questions

- Should default set be removable after creating additional sets?
- What exact capacity-fit thresholds define recommendation eligibility?
- Should architecture preference default to neutral, amd64, or allow bias toward arm64 savings?

## 13. Required disclaimer language

The UI must include a clearly visible disclaimer (not hidden behind only a tooltip) that communicates:

- This calculator is for estimation purposes only.
- Results are not a quote, offer, or contractual commitment.
- Actual charges may vary based on provider pricing changes, account configuration, discounts, taxes, region/AZ specifics, and runtime usage patterns.
- Users must validate final pricing through official commercial channels before procurement or budgeting decisions.

Baseline copy source:

- Reuse and adapt the existing disclaimer pattern from `assets/rosa/cost-explorer/app.html`:
  - short inline estimate note (for example, "Planning estimates in USD only. Not a formal quote or billing guarantee.")
  - full legal disclaimer block near footer/results/export context
- Keep legal intent equivalent to the current ROSA optimizer wording, and tighten only for HCP-specific scope.

Recommended placement:

- Short version: always visible near header or top controls.
- Full version: visible near result totals and in export/share context.
