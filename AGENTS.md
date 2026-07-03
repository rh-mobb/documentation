# Agent guide — MOBB / Red Hat Cloud Experts documentation

This repository is a **[Hugo](https://gohugo.io/)** static site using the **`rhds`** theme, deployed on **AWS Amplify** with **Pagefind** for client-side search. Agents should treat **[`CONTRIBUTING.md`](./CONTRIBUTING.md)** as the human-facing contribution contract; this file adds automation-oriented defaults and repo-specific gotchas.

## Quick facts

| Item | Value |
|------|--------|
| Hugo config | [`config.toml`](./config.toml) |
| Theme | `themes/rhds` (set in config and Make targets) |
| Published subtree | `public/experts` (`publishDir` in `config.toml`; site `baseURL` ends with `/experts/`) |
| Amplify build spec | [`amplify.yml`](./amplify.yml) (Hugo `0.157.0`, Node 24, Pagefind). **`main`** uses `PRODUCTION_BASEURL` (`https://cloud.redhat.com/experts/`); previews/branches use `*.amplifyapp.com`. |
| Amplify redirects | [`customRules.json`](./customRules.json) + Hugo [`_redirects`](./themes/rhds/layouts/_default/index.redir) aliases; merged and synced via [`.github/workflows/sync-amplify-redirects.yml`](./.github/workflows/sync-amplify-redirects.yml). IaC: [`rh-mobb/documentation-infra`](https://github.com/rh-mobb/documentation-infra). |
| Node.js | 24 (see [`.nvmrc`](./.nvmrc); used for Pagefind via `npm ci` / `npx pagefind`) |
| Local preview | `make preview` — see [`Makefile`](./Makefile) |
| Preview + working search | `make preview-search` (builds + Pagefind index; do not use `hugo server -M` / `--renderToMemory` if search must work) |

## Content layout

- **Top-level sections** live under [`content/`](./content/) as directories (for example `rosa/`, `aro/`, `osd/`, `misc/`, `idp/`, `redhat/`, `tags/`).
- **Chapter / section landing pages** use **`_index.md`** (often `archetype: chapter` and `weight` for menu order).
- **Individual guides** use **`index.md`** inside a topic directory (for example `content/rosa/some-topic/index.md`).
- **[`CONTRIBUTING.md`](./CONTRIBUTING.md)** still mentions historical **`/content/docs/...`** paths; prefer the **current** `content/<section>/...` layout unless you are following an explicit maintainer instruction to use `docs/`.
- **[`content/examples/`](./content/examples/)** is a special section whose `_index.md` cascades `draft: true` to all pages within it. Drafts are rendered by `make preview` (which passes `-D`) but excluded from production builds (`hugo --gc --minify`), so example pages are browsable locally but never published. Use this directory for shortcode demos, diagram templates, or formatting examples. Add new pages as `content/examples/<topic>/index.md`; no extra front matter is needed.

### Front matter (guides)

Use YAML front matter at the top of each article. Recommended fields (see CONTRIBUTING for detail):

- `date` — `YYYY-MM-DD`
- `title` — page title
- `tags` — list of strings; **case- and spacing-sensitive**; use established tags from CONTRIBUTING’s taxonomy; coordinate **before** inventing new tags
- `authors` — list of contributors
- `validated_version` (optional) — OpenShift version string when the guide was validated (e.g. `"4.20"`). **Do not** duplicate that disclaimer with a separate `alert` shortcode in the body when this field is set.

Draft content: `draft: true` in front matter; local preview uses `-D` in the Makefile so drafts are visible.

## Markdown and Hugo behavior

- **Goldmark** is configured with `unsafe = true` in [`config.toml`](./config.toml), so raw HTML in Markdown is allowed; still prefer semantic Markdown unless the layout or design system requires HTML/web components.
- **Code fences** are enabled; highlight style and options are under `[markup.highlight]`.
- **Minify**: `disableJS` and `disableJSON` are `true` so builds do not choke on code blocks labeled `json` or `js`. Keep those labels accurate.
- **Shortcodes** ship with the theme under `themes/rhds/layouts/shortcodes/` (for example `alert`, `notice`, `expand`, `tabs` / `tab`, `mermaid`, `include`, `attachments`, `button`, `children`, `swagger`, `math`, `siteparam`). Prefer existing shortcodes over ad-hoc HTML when they fit.
- **`expand` shortcode:** Do **not** rely on it for collapsible sections in this repo. The theme partial uses **jQuery** in its `onclick` handler, but RHDS layouts never load jQuery, so content stays hidden and **clicking the label does not expand**. Fixing that would require a theme change (out of scope for content-only work).
- **Collapsible sections (recommended):** Use native **`<details>`** and **`<summary>`** in content. Browsers handle open/close with no JavaScript. With Goldmark `unsafe = true`, put a **blank line after `</summary>`** so Markdown inside (paragraphs, lists, **tables**) still renders. Example:

  ```html
  <details open>
  <summary>Section title</summary>

  | Column A | Column B |
  |----------|----------|
  | …        | …        |

  </details>
  ```

  Omit the `open` attribute on `<details>` if the block should **start collapsed** instead.

- **`{{< alert >}}`**: supports RHDS-aligned `state` values (see [`themes/rhds/layouts/shortcodes/alert.html`](./themes/rhds/layouts/shortcodes/alert.html)); avoid redundant version-validation callouts when `validated_version` is set.
- **Em dash (`—`)**: Do not use em dashes in site content (guides, chapter pages, etc.). Prefer commas, parentheses, colons, or split into two sentences.

## `static/`, assets, and `baseURL`

Static files are served from [`static/`](./static/). The site is published under the **`/experts/`** path prefix on every environment.

- **Internal cross-links** (to other guides or chapter pages on this site): use **root-relative** paths starting with **`/experts/`** (for example `/experts/rosa/some-topic/`). Do not use fully qualified `https://...` URLs for same-site navigation; those pin a hostname, go stale across domains, and are harder to maintain.
- **Amplify production** (`main`) uses `PRODUCTION_BASEURL` in [`amplify.yml`](./amplify.yml). Do not put Amplify preview hostnames in content. Treat those URLs as infrastructure for testing only; root-relative `/experts/...` links work locally, on Amplify, and on any future host.
- **Assets** under [`static/`](./static/): same idea; prefer `/experts/...` (or Hugo helpers that resolve under `baseURL`) so paths stay portable.

When inline Markdown or shortcodes support it, Hugo `ref` / `relref` (or other theme-safe link helpers) are fine as long as the resolved URL stays under `/experts/` and does not hardcode a host.

## Theme and layouts

- **Do not** change `themes/rhds` for content-only tasks.
- Layout or theme edits affect every page; keep them minimal, reversible, and consistent with RHDS patterns (`rh-alert`, etc.).

## Standalone app pages (`assets/` + custom layout)

Use this pattern for **full-page interactive tools** (Vue apps, calculators, dashboards) that need complete control over HTML, CSS, and JS while still sharing site header, nav, footer, cookie consent, and Pagefind search with the rest of the docs.

**Reference implementation:** [ROSA Fleet Optimizer](content/rosa/cost-explorer/index.md)

| Piece | Path | Role |
|-------|------|------|
| Hugo content stub | `content/<section>/<name>/index.md` | Front matter only; sets `layout:` and metadata (`title`, `tags`, `authors`, etc.). Body is empty or omitted. |
| App source (HTML) | `assets/<section>/<name>/app.html` | Full `<!DOCTYPE html>` document: page markup, inline styles, and scripts. Uses **placeholders** where Hugo injects shared chrome at build time. |
| Layout | `layouts/_default/<layout-name>.html` | Loads the asset via `resources.Get`, replaces placeholders, outputs with `safeHTML` (bypasses `baseof`). |
| Shared partials | `layouts/partials/rhds/` | Header, nav, footer, Pagefind init (do **not** copy these into `app.html`). |

### Why `assets/` and not `content/` or `static/`?

- **`content/`** is for Markdown guides processed by Goldmark. Large Vue/HTML apps do not belong in the body.
- **`static/`** copies files verbatim with no Hugo templating; you cannot inject partials or fingerprint CSS.
- **`assets/`** files are available to layouts via `resources.Get` and can be transformed (string replace, pipe to other resources) at build time.

### Placeholders (contract between `app.html` and layout)

The app HTML must include these literal tokens; the layout replaces them before publish:

| Token | Injected by layout | Purpose |
|-------|-------------------|---------|
| `__TRACKING_HEAD__` | `partial "head/tracking.html"` | TrustArc / analytics scripts (cookie consent bootstrap). |
| `__MAIN_CSS__` | Fingerprinted `resources.Get "css/main.css"` href | Site-wide RHDS styles (header search, nav, typography tokens). |
| `__HEADER__` | `partial "rhds/header.html"` | Logo + Pagefind search mount (`#site-search`). |
| `__NAV__` | `partial "rhds/nav.html"` | Sticky `rh-navigation-secondary` nav. |
| `__FOOTER__` | `partial "rhds/footer.html"` | RHDS footer, `#teconsent`, and `#consent_blackbar`. |
| `__PAGEFIND_INIT__` | `partial "rhds/pagefind-init.html"` | Pagefind UI init + header search drawer behavior. |

Put `__TRACKING_HEAD__` in `<head>`. Put `__HEADER__` and `__NAV__` immediately after `<body>`. Put `__FOOTER__` and `__PAGEFIND_INIT__` after your app’s closing `</main>` (or equivalent), before app-specific scripts if those scripts must run after DOM chrome exists.

**Do not** duplicate header, nav, footer, consent markup, or Pagefind init JS in `app.html`. When site chrome is fixed in partials, all standalone apps pick up the change on the next build.

### Layout template (minimal pattern)

Copy [`layouts/_default/cost-explorer-app.html`](./layouts/_default/cost-explorer-app.html) and adjust the asset path and error message:

```go-html-template
{{- $css := resources.Get "css/main.css" -}}
{{- $cssHref := "/experts/css/main.css" -}}
{{- if hugo.IsProduction -}}
  {{- with $css | minify | fingerprint -}}
    {{- $cssHref = .RelPermalink -}}
  {{- end -}}
{{- else -}}
  {{- with $css -}}
    {{- $cssHref = .RelPermalink -}}
  {{- end -}}
{{- end -}}
{{- $tracking := partial "head/tracking.html" . -}}
{{- $app := resources.Get "section/name/app.html" -}}
{{- if not $app -}}
  {{- errorf "My App: assets/section/name/app.html not found" -}}
{{- end -}}
{{- $html := replace $app.Content "__MAIN_CSS__" $cssHref -}}
{{- $html = replace $html "__TRACKING_HEAD__" $tracking -}}
{{- $html = replace $html "__HEADER__" (partial "rhds/header.html" .) -}}
{{- $html = replace $html "__NAV__" (partial "rhds/nav.html" .) -}}
{{- $html = replace $html "__FOOTER__" (partial "rhds/footer.html" .) -}}
{{- $html = replace $html "__PAGEFIND_INIT__" (partial "rhds/pagefind-init.html" .) -}}
{{ $html | safeHTML }}
```

Front matter in `content/.../index.md`:

```yaml
---
title: "My Tool"
description: "Short summary for listings and SEO."
date: 2026-06-25
tags: ["ROSA"]
authors:
  - Name
layout: my-app   # matches layouts/_default/my-app.html
---
```

Layout file name must match the `layout` front-matter value (`my-app` → `my-app.html`).

### `app.html` checklist

- Full HTML document with RHDS import map and module imports for web components you use (`rh-navigation-secondary`, `rh-footer`, etc.). See the Fleet Optimizer head for a working set.
- Link `__MAIN_CSS__`, `/experts/pagefind/pagefind-ui.css`, and RHDS element lightdom CSS URLs for nav/footer.
- Wrap tool UI in `<main class="…">` (class name is app-specific).
- Same-site links and static assets use **`/experts/...`** root-relative paths.
- Modals, popovers, and overlays: **`teleport` to `body`** (if using Vue) and use **`z-index` ≥ 1000** so they sit above the site header (`z-index: 200`) and cookie consent bar.
- Prefer **native `<details>` / `<summary>`** over the theme `expand` shortcode (jQuery not loaded on these pages).
- No em dashes in user-facing copy inside the app.

### Pagefind and search indexing

The injected header expects `#site-search`. Include `pagefind-ui.css` in `<head>` and `__PAGEFIND_INIT__` before your app scripts.

Standalone app pages use a **custom layout**, not `baseof`, so they do **not** get `data-pagefind-body` on `<main>` unless you add it yourself. Most tools should stay **out of the search index**; do not add `data-pagefind-body` unless the page should appear in site search.

### Verification

After adding or changing a standalone app:

```bash
hugo --gc --minify --theme rhds
```

Confirm in `public/experts/<section>/<name>/index.html`:

- No unreplaced `__HEADER__`-style tokens remain.
- `#consent_blackbar`, `#teconsent`, and `site-header__search` are present.
- Header search opens and respects viewport height (Pagefind drawer).

Smoke-check in the browser: header, nav, footer, cookie consent, modals, and app functionality.

## Verification / testing (before claiming a change works)

Run these from the repository root after substantive edits:

1. **Production-like build** (matches deploy stress: GC + minify):

   ```bash
   hugo --gc --minify --theme rhds
   ```

2. **Optional**: if search or Pagefind bundling matters for the change:

   ```bash
   make preview-search
   ```

   or `make search-index` after a normal build (see Makefile).

3. **Smoke-check** the browser for the specific pages touched (headers, TOC, shortcodes, code blocks).

If CI or Amplify reports failures, compare local **Hugo version** to [`amplify.yml`](./amplify.yml) and align before debugging.

There is **no** project test runner in `package.json` beyond **Pagefind** as a dev dependency; `hugo` exit code and manual checks are the default quality gate unless maintainers add CI scripts later.

## Amplify redirect sync

Amplify does **not** read `customRules.json` or Hugo `_redirects` from the build artifact. When `customRules.json`, content **`aliases:`**, or the sync scripts change on **`main`**, [`.github/workflows/sync-amplify-redirects.yml`](./.github/workflows/sync-amplify-redirects.yml) runs Hugo (with `disableAliases = true`), merges static rules from [`customRules.json`](./customRules.json) with alias rules from `public/experts/_redirects`, then assumes an IAM role via GitHub OIDC and runs [`scripts/sync-amplify-redirects.sh`](./scripts/sync-amplify-redirects.sh) (`aws amplify update-app`). Use **Actions → Sync Amplify redirects → Run workflow** for a one-off sync.

**Infrastructure:** Amplify app, GitHub OIDC role, and `mobb.ninja` redirect stack are provisioned by Terraform in [`rh-mobb/documentation-infra`](https://github.com/rh-mobb/documentation-infra). Terraform bootstraps Amplify with a minimal `/` → `/experts/` rule and ignores `custom_rule` drift so this workflow owns the full rule set from [`customRules.json`](./customRules.json).

### GitHub repository variables

Set under **Settings → Secrets and variables → Actions → Variables**:

| Variable | Example | Purpose |
|----------|---------|---------|
| `AMPLIFY_APP_ID` | `d1234abcd` | Amplify app ID |
| `AWS_REGION` | `us-east-1` | Region where the app lives |
| `AWS_AMPLIFY_REDIRECTS_ROLE_ARN` | `arn:aws:iam::123456789012:role/github-amplify-redirects` | OIDC role for the workflow |

### One-time AWS IAM setup

Provisioned by [`rh-mobb/documentation-infra`](https://github.com/rh-mobb/documentation-infra) (`terraform apply`). After apply, set the GitHub repository variables below from Terraform outputs. Manual IAM JSON (if not using Terraform):

1. **OIDC identity provider** (if not already present): `token.actions.githubusercontent.com` → `https://token.actions.githubusercontent.com`.

2. **IAM role** trusted by GitHub (adjust account, org, and repo):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:rh-mobb/documentation:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

3. **Inline policy** on that role (single app only):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "amplify:UpdateApp",
      "Resource": "arn:aws:amplify:REGION:ACCOUNT_ID:apps/APP_ID"
    }
  ]
}
```

The Amplify **build service role** does not need `amplify:UpdateApp`.

### What updates automatically

| Redirect source | On push to `main` |
|-----------------|-------------------|
| [`customRules.json`](./customRules.json) | Yes, merged in sync workflow |
| Hugo content `aliases:` (`disableAliases = true` → `public/experts/_redirects`) | Yes, merged in sync workflow after `hugo` build |
| `mobb.ninja` | No; managed outside Amplify (Route 53 + CloudFront) |

**Manual sync** (local):

```bash
hugo --gc --minify --theme rhds
AWS_APP_ID=your-app-id AWS_REGION=us-east-1 ./scripts/sync-amplify-redirects.sh
```

Requires AWS credentials with `amplify:UpdateApp` on the app ARN.

## Git and pull-request hygiene

Follow **[GitHub Flow](https://docs.github.com/en/get-started/using-github/github-flow)** as in CONTRIBUTING:

- Branch from default branch; one focused topic per branch.
- **`git commit -s`** (sign-off): CONTRIBUTING examples use **`-sm`** on commit; use the same for DCO/sign-off unless maintainers say otherwise.
- Push to your fork and open a PR against **`rh-mobb/documentation`** if that is the upstream (see README/CONTRIBUTING remote examples).
- PR description should state **what** changed and **why**, link related issues, and call out **content moves** or **redirect** needs (static redirects live in [`customRules.json`](./customRules.json) for Amplify).
- Avoid committing **build output** (`public/`), caches, or editor noise; rely on `.gitignore` and inspect `git status` before commit.

## Cross-repo references

- **Edit on GitHub** links use `params.editURL` in `config.toml` (points at `main` content paths). Keep file paths consistent so the edit link resolves.

## ROSA best practices triple (keep in sync)

Three related artifacts work as one editorial unit:

| Role | Path |
|------|------|
| **Authoritative** | [`content/rosa/best-practices-recommendations/index.md`](./content/rosa/best-practices-recommendations/index.md) |
| **Derivative checklist** | [`content/rosa/best-practices-checklist/index.md`](./content/rosa/best-practices-checklist/index.md) (numbered sections, per-item tables, **Quick-reference summary** at the end) |
| **Table export (CSV)** | [`static/rosa/best-practices-checklist-decisions.csv`](./static/rosa/best-practices-checklist-decisions.csv) (`publishDir` is `public/experts`, so this is served at `/experts/rosa/best-practices-checklist-decisions.csv`) |
| **Category tags (visual)** | [`layouts/shortcodes/rh-category.html`](./layouts/shortcodes/rh-category.html) is the **source of truth** for label names, emoji, and `rh-tag` colours. In the recommendations and checklist intros, list the five ROSA BP categories **explicitly** in the shortcode (do not use `legend`), so the page does not pick up extra tags if `legend` changes. In the recommendations guide, `{{< rh-category >}}` rows sit under **`####` subsection** headings (not under `##`). CSV `category` column stays plain text; keep wording aligned with that shortcode. |

**Source of truth:** The recommendations guide owns scope, rationale, and alignment with product docs. The checklist distills that into decision items and links back into the guide. The CSV mirrors the **Quick-reference summary** table (same rows, order, text, and **category** labels).

**When editing any one of these files:** Do **not** silently update the other files in the same turn. **Propose a short plan** that names which sibling file(s) need updates and why (for example: safe default changed, new or renumbered item, heading slug / anchor change, new summary row). **Ask the user for explicit permission** before applying cross-file edits.

**Direction of updates:**

- **Recommendations changed:** Update the affected checklist section(s), the **Quick-reference summary** rows for those ids, and the CSV.
- **Checklist body or summary table changed:** Confirm the recommendations doc still supports the wording; update the CSV to match the summary table.
- **CSV changed:** Treat it as an export of the summary table; reconcile the checklist table first, then recommendations if semantics shifted.

**If the checklist or CSV is edited in isolation:** Flag when the recommendations doc does not yet reflect the same guidance; recommend aligning recommendations first or call out the contradiction for the user.

**Agent guardrail:** If a change touches any path matching `best-practices-recommendations`, `best-practices-checklist`, or `best-practices-checklist-decisions.csv`, follow the plan-and-permission workflow above before updating sibling artifacts.

## When unsure

- Prefer matching **existing guides** in the same section for tone, front matter, and heading style.
- Ask a maintainer before **taxonomy**, **Amplify redirect**, or **large structural** changes.
