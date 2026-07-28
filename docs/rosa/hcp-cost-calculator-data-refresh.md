# ROSA HCP calculator data refresh workflow

## Purpose

The ROSA HCP calculator reads committed snapshot JSON files at runtime from:

- `static/rosa/hcp-cost-calculator/data/regions.json`
- `static/rosa/hcp-cost-calculator/data/instance-catalog.json`
- `static/rosa/hcp-cost-calculator/data/pricing/<region>.json`
- `static/rosa/hcp-cost-calculator/data/snapshot-manifest.json`

Use this workflow to validate and refresh those files in a deterministic, local repo process before opening a PR.

## Command

From repository root:

```bash
make refresh-hcp-pricing
```

This target runs:

```bash
node scripts/refresh-hcp-calculator-data.mjs
```

## What the refresh script validates

The script fetches source data and fails fast when integrity checks fail.

Sources used by refresh:

- ROSA CLI:
  - `rosa list regions -o json` (supported regions)
  - `rosa list instance-types -o json` (supported instance types, architecture, vCPU, memory)
- Red Hat ROSA service definition page (canonical reference link captured in metadata):
  - https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition
- `rosa.wigarcia.com` region metadata and EC2 pricing snapshots (for AZ lists and region pricing files)

Integrity checks:

- Pricing records reference an instance type that is missing from `instance-catalog.json`
- Pricing payloads are missing required tier fields:
  - `onDemandMonthly`
  - `oneYearMonthly`
  - `threeYearMonthly`
- Region pricing JSON is missing or has invalid region/schema shape

If validation succeeds, the script updates `generated_at` timestamps and rewrites `snapshot-manifest.json` with an updated generated timestamp and region file mapping.

The generated dataset also records source URLs in:

- `snapshot-manifest.json` (`sources`)
- `regions.json` (`source`)
- `instance-catalog.json` (`source`)

### Region coverage behavior

- The refresh attempts all enabled HCP-supported regions returned by ROSA CLI.
- Runtime snapshots include regions where pricing feeds are available.
- If a supported region is missing pricing feed data, refresh reports that region as skipped.

## Common validation failures

- **Unknown instance in pricing**
  - Meaning: `pricing/<region>.json` contains a `byInstanceType` key that does not exist in `instance-catalog.json`.
  - Fix: add the instance to catalog or remove/rename the pricing record key.

- **Missing required tier field**
  - Meaning: one of `onDemandMonthly`, `oneYearMonthly`, or `threeYearMonthly` is absent for a priced instance.
  - Fix: add all required tier values for every priced instance.

- **Invalid numeric tier value**
  - Meaning: a required tier field exists but is not a finite number.
  - Fix: provide numeric monthly values for each required tier field.

- **Region/schema mismatch**
  - Meaning: a pricing file has a `region` value that does not match its filename, or expected top-level objects are missing.
  - Fix: correct the `region` field and ensure `byInstanceType` is a valid object.
