# Agent guide — MOBB / Red Hat Cloud Experts documentation

This repository is a **[Hugo](https://gohugo.io/)** static site using the **`rhds`** theme, deployed on **Netlify** with **Pagefind** for client-side search. Agents should treat **[`CONTRIBUTING.md`](./CONTRIBUTING.md)** as the human-facing contribution contract; this file adds automation-oriented defaults and repo-specific gotchas.

## Quick facts

| Item | Value |
|------|--------|
| Hugo config | [`config.toml`](./config.toml) |
| Theme | `themes/rhds` (set in config and Make targets) |
| Published subtree | `public/experts` (`publishDir` in `config.toml`; site `baseURL` ends with `/experts/`) |
| Netlify Hugo version | See [`netlify.toml`](./netlify.toml) `HUGO_VERSION` (pin local Hugo to the same minor series when diagnosing CI-only failures) |
| Local preview | `make preview` — see [`Makefile`](./Makefile) |
| Preview + working search | `make preview-search` (builds + Pagefind index; do not use `hugo server -M` / `--renderToMemory` if search must work) |

## Content layout

- **Top-level sections** live under [`content/`](./content/) as directories (for example `rosa/`, `aro/`, `osd/`, `misc/`, `idp/`, `redhat/`, `tags/`).
- **Chapter / section landing pages** use **`_index.md`** (often `archetype: chapter` and `weight` for menu order).
- **Individual guides** use **`index.md`** inside a topic directory (for example `content/rosa/some-topic/index.md`).
- **[`CONTRIBUTING.md`](./CONTRIBUTING.md)** still mentions historical **`/content/docs/...`** paths; prefer the **current** `content/<section>/...` layout unless you are following an explicit maintainer instruction to use `docs/`.

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
- **`{{< alert >}}`**: supports RHDS-aligned `state` values (see [`themes/rhds/layouts/shortcodes/alert.html`](./themes/rhds/layouts/shortcodes/alert.html)); avoid redundant version-validation callouts when `validated_version` is set.
- **Em dash (`—`)**: Do not use em dashes in site content (guides, chapter pages, etc.). Prefer commas, parentheses, colons, or split into two sentences.

## `static/`, assets, and `baseURL`

Static files are served from [`static/`](./static/). The site is published under the **`/experts/`** path prefix on every environment.

- **Internal cross-links** (to other guides or chapter pages on this site): use **root-relative** paths starting with **`/experts/`** (for example `/experts/rosa/some-topic/`). Do not use fully qualified `https://...` URLs for same-site navigation; those pin a hostname, go stale across domains, and are harder to maintain.
- **Netlify hosts**: `baseURL` in [`config.toml`](./config.toml) may point at a Netlify deploy URL for builds, but **do not** put Netlify preview or deploy hostnames in content. Treat those URLs as infrastructure for testing only; root-relative `/experts/...` links work locally, on Netlify, and on any future host.
- **Assets** under [`static/`](./static/): same idea; prefer `/experts/...` (or Hugo helpers that resolve under `baseURL`) so paths stay portable.

When inline Markdown or shortcodes support it, Hugo `ref` / `relref` (or other theme-safe link helpers) are fine as long as the resolved URL stays under `/experts/` and does not hardcode a host.

## Theme and layouts

- **Do not** change `themes/rhds` for content-only tasks.
- Layout or theme edits affect every page; keep them minimal, reversible, and consistent with RHDS patterns (`rh-alert`, etc.).

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

If CI or Netlify reports failures, compare local **Hugo version** to [`netlify.toml`](./netlify.toml) and align before debugging.

There is **no** project test runner in `package.json` beyond **Pagefind** as a dev dependency; `hugo` exit code and manual checks are the default quality gate unless maintainers add CI scripts later.

## Git and pull-request hygiene

Follow **[GitHub Flow](https://docs.github.com/en/get-started/using-github/github-flow)** as in CONTRIBUTING:

- Branch from default branch; one focused topic per branch.
- **`git commit -s`** (sign-off): CONTRIBUTING examples use **`-sm`** on commit; use the same for DCO/sign-off unless maintainers say otherwise.
- Push to your fork and open a PR against **`rh-mobb/documentation`** if that is the upstream (see README/CONTRIBUTING remote examples).
- PR description should state **what** changed and **why**, link related issues, and call out **content moves** or **redirect** needs (many redirects live in [`netlify.toml`](./netlify.toml)).
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

**Source of truth:** The recommendations guide owns scope, rationale, and alignment with product docs. The checklist distills that into decision items and links back into the guide. The CSV mirrors the **Quick-reference summary** table (same rows, order, and text).

**When editing any one of these files:** Do **not** silently update the other files in the same turn. **Propose a short plan** that names which sibling file(s) need updates and why (for example: safe default changed, new or renumbered item, heading slug / anchor change, new summary row). **Ask the user for explicit permission** before applying cross-file edits.

**Direction of updates:**

- **Recommendations changed:** Update the affected checklist section(s), the **Quick-reference summary** rows for those ids, and the CSV.
- **Checklist body or summary table changed:** Confirm the recommendations doc still supports the wording; update the CSV to match the summary table.
- **CSV changed:** Treat it as an export of the summary table; reconcile the checklist table first, then recommendations if semantics shifted.

**If the checklist or CSV is edited in isolation:** Flag when the recommendations doc does not yet reflect the same guidance; recommend aligning recommendations first or call out the contradiction for the user.

**Agent guardrail:** If a change touches any path matching `best-practices-recommendations`, `best-practices-checklist`, or `best-practices-checklist-decisions.csv`, follow the plan-and-permission workflow above before updating sibling artifacts.

## When unsure

- Prefer matching **existing guides** in the same section for tone, front matter, and heading style.
- Ask a maintainer before **taxonomy**, **netlify redirect**, or **large structural** changes.
