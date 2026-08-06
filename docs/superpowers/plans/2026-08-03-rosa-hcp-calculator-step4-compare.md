# Step 4 Platform Compare Implementation Plan

> **For agentic workers:** Implement from `docs/superpowers/specs/2026-08-03-rosa-hcp-calculator-step4-compare-design.md`.

**Goal:** Add Step 4 list-to-list compare (ROSA HCP vs self-managed OCP vs EKS Auto Mode).

**Tasks**
1. `platform-compare.mjs` + unit tests (pure cost model)
2. Wire Step 4 UI in `app.html`; persist OCP list price in draft-storage
3. Sync `static/` JS copies; run tests

**Done when:** Step 4 table renders from active Step 1 sizing, OCP list editable, tests pass.
