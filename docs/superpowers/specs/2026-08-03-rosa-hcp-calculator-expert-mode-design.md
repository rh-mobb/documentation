# ROSA HCP Calculator: Expert mode (separate state)

Date: 2026-08-03  
Status: Approved for implementation  
Related: `2026-07-27-rosa-hcp-calculator-design.md`, PR #970

## Decision

Basic and Expert modes keep **independent state**. No conversion or sync between modes.

| Mode | Step 1 model | Cluster fee |
|------|----------------|-------------|
| Basic | Flat instance rows + scalar cluster count | `$0.25/hr × cluster count` |
| Expert | Named clusters, each with machine pools | `$0.25/hr × number of clusters` |

Step 2 discounts (EC2 Savings Plan %, Private Offer) are **shared**.

## Expert domain model

```text
expertState
  clusters[]
    id
    name
    region
    filters   // draft picker: architecture, category, family, instanceType, threeAz
    pools[]
      id
      name
      instanceType
      az
      count    // v1: single count (steady / exact)
```

Defaults:

- One cluster (`Cluster 1`)
- Region `us-east-1`
- Multi-AZ starter pools: one pool per AZ (`workers-a/b/c`, `m7i.xlarge`, count `3` each)
- Additional clusters start with **no** machine pools
- Per-cluster Create uses the card’s instance-type filters; optional **3-AZ pool** checkbox creates three pools (same type, one AZ each)

## UX

- Step 1 mode toggle: Basic | Expert
- Switching modes does not copy or wipe the other mode’s state
- Expert Step 1: each cluster card has name + region, then per-cluster filters + Create, then pool rows; remove cluster is an × on the card
- Step 3 prices the **active** mode only (same summary + Private Offer comparison)

## Persistence

- Share payload and CSV include `mode: "basic" | "expert"`
- Missing mode defaults to `basic` (backward compatible)
- Import/share loads into that mode’s bag and activates that mode
- Browser `localStorage` remembers last mode, Basic bag, Expert clusters (including draft filters), and Step 2 discounts
- Share URL hash wins over local draft on page load; successful loads are written back to local draft
- **Reset saved data** clears local draft and restores sizing/discount defaults, but keeps the current Basic/Expert mode (results-disclaimer cookie stays)

## Out of scope (this pass)

- min / steady / max per pool
- Rightsizing recommendations
- Cross-mode conversion
- Inventory / VMware import ([#974](https://github.com/rh-mobb/documentation/issues/974))
