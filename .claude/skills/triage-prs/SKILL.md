---
name: triage-prs
description: Use when the user asks to triage, review, list, or prioritize open pull requests for the rh-mobb/documentation repo. Also use when reviewing a specific PR for quality, code impressions, preview feedback, or suggesting/posting fixes.
---

# PR Triage — rh-mobb/documentation

## Overview

Lists open PRs sorted oldest-first (most waiting = highest priority). For specific PR review: check out the PR locally, run the local preview server, assess quality against standards, make approved fixes, then restore the original branch.

## GitHub API rule — always use a JSON file for POST requests

**Never use `--field` or inline body strings with `gh api --method POST`.** Shell interpolation breaks on multi-line strings containing backticks, colons, pipes, or quotes. This applies to every POST: reviews, comments, replies — everything.

Always write the payload with the Write tool first, then pass it via `--input`:

```bash
# Write tool → ./tmp/pr{NNN}-payload.json
gh api repos/rh-mobb/documentation/<endpoint> --method POST --input ./tmp/pr{NNN}-payload.json
```

Use `./tmp/` (project-local, in `.gitignore`) — not `/tmp/`. Delete payload files after each API call:

```bash
rm ./tmp/pr{NNN}-payload.json
```

---

## Local Preview URL

```
http://localhost:1313/experts/
```

AWS Amplify fallback (only if local preview is not possible):
```
https://pr-{PR_NUMBER}.dqokbbp7eqr35.amplifyapp.com/experts/
```

---

## Triage List (default behavior)

```bash
gh pr list --repo rh-mobb/documentation --state open \
  --json number,title,body,createdAt,author,url \
  --limit 50
```

Sort by `createdAt` ascending (oldest = top priority). Output per PR:

```
### PR #NNN — Title
- **Author:** @username
- **Age:** X days (opened YYYY-MM-DD)
- **PR:** https://github.com/rh-mobb/documentation/pull/NNN
- **Preview:** https://pr-NNN.dqokbbp7eqr35.amplifyapp.com/experts/
- **Description:** <first 2 sentences of body, or title if empty>
```

---

## Specific PR Review

Do ALL steps below in order.

### Step 0 — Pre-flight check

Before touching anything, verify the working tree is clean and record the current branch so you can restore it at the end:

```bash
# Confirm clean working tree — abort if there are uncommitted changes
git status --short

# Record current branch for cleanup at the end
ORIGINAL_BRANCH=$(git branch --show-current)
echo "Will return to: $ORIGINAL_BRANCH"
```

If `git status --short` produces any output, **stop and tell the user** they have uncommitted changes that need to be stashed or committed before proceeding. Do not continue until the working tree is clean.

### Step 1 — Fetch metadata and check out the PR locally

Fetch PR metadata, prior reviews, and inline comments in parallel — then check out the branch.

```bash
# Metadata
gh pr view NNN --repo rh-mobb/documentation \
  --json number,title,body,createdAt,author,url,headRefOid,additions,deletions,changedFiles

# Full diff
gh pr diff NNN --repo rh-mobb/documentation

# Prior reviews (who reviewed, what state, what they said)
gh api repos/rh-mobb/documentation/pulls/NNN/reviews \
  | jq '.[] | {user: .user.login, state, body: .body[:300]}'

# Prior inline comments (line-level suggestions and notes)
gh api repos/rh-mobb/documentation/pulls/NNN/comments \
  | jq '.[] | {user: .user.login, path, line, body: .body[:300]}'

# Check out the branch locally
gh pr checkout NNN --repo rh-mobb/documentation
```

Read the changed files directly with the Read tool — no blob SHA gymnastics needed.

If prior reviews or inline comments exist, note them — they drive the re-review checklist in Step 3.

### Step 2 — Run the local preview server

Start Hugo and navigate the browser to the changed article path. Derive the article URL from the changed file path (e.g. `content/aro/trident/index.md` → `http://localhost:1313/experts/aro/trident/`).

First, verify the local Hugo version matches (or exceeds) the version pinned in `amplify.yml`:

```bash
REQUIRED=$(grep HUGO_VERSION amplify.yml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
INSTALLED=$(hugo version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "Required: $REQUIRED  Installed: $INSTALLED"
```

If the installed version is older than required, warn the user to upgrade Hugo to at least the version in `amplify.yml` before proceeding. If the version is sufficient, run:

```bash
make preview
```

If `make preview` fails, troubleshoot in this order:
1. **Port conflict** — port 1313 may be in use: `hugo server --theme rhds --port 1314`
2. **Theme missing** — run `git submodule update --init` then retry `make preview`
3. **Build error** — run `hugo --theme rhds` (no server) to see the full error output; if the error looks version-related, tell the user to install the exact Hugo version specified in `amplify.yml`

Hugo serves at `http://localhost:1313/experts/` (or alternate port). If the browser MCP tool is available:

```
mcp__chrome-devtools__navigate_page  url=http://localhost:1313/experts/<article-path>/
mcp__chrome-devtools__take_screenshot
mcp__chrome-devtools__take_snapshot
```

Look for: rendering errors, code block display, shortcode output (alerts, notices, tabs), navigation integrity, layout issues.

If local preview is not possible at all, fall back to the AWS Amplify preview URL.

### Step 3 — Code quality assessment

**If prior reviews or inline comments exist**, go through each one and verify whether it was addressed in the current file. For each prior comment:
- ✅ Addressed — note what changed
- ❌ Not addressed — carry it forward as an active issue
- ⚠️ Partially addressed — describe what's still missing

Include a prior-comments summary table in the Step 5 report.

**Evaluate the diff (and local files) against AGENTS.md standards:**

- Front matter: `date`, `title`, `tags`, `authors` all present and correct
- `validated_version` used when appropriate; no redundant version alert callouts
- No em dashes in Markdown prose or headings (em dashes inside Mermaid diagram labels are acceptable)
- Internal links use `/experts/...` root-relative paths (not hardcoded hostnames or Amplify URLs)
- Shortcodes used correctly (`{{< alert >}}`, `{{< notice >}}`, `{{< tabs >}}`, etc.) — prefer shortcodes over raw blockquotes/HTML for callouts
- No changes to `themes/rhds` in a content-only PR
- Tag taxonomy follows CONTRIBUTING.md (no invented tags without coordination)
- `kubectl` → `oc` for OpenShift content
- No EOL or deprecated container images (e.g. `centos:latest`)
- `grep -E` instead of `egrep` (`egrep` is deprecated and removed on some systems)

**If the PR touches `content/examples/`**, additionally check:
- `draft: true` is present in the front matter of every page added or modified — this is required so examples are never published
- No `tags` in the front matter — example pages are not indexed for user discovery
- File path follows `content/examples/<topic>/index.md` convention
- Em dashes are acceptable inside Mermaid diagram source labels but not in Markdown headings or prose

### Step 4 — Find exact line numbers for suggestions

Since the PR is checked out locally, just read the file and grep:

```bash
grep -n "pattern to find" content/path/to/index.md
```

Or use the Read tool and note line numbers directly from the output.

### Step 5 — Present findings and ask how to proceed

Present the full review report to the user using the output format below, then **stop and ask** which approach they want for addressing the issues. Do not post comments or edit files until the user has confirmed — unless they already specified upfront (e.g., "review and fix" or "review and post suggestions").

```
## PR #NNN — Title

**Author:** @username | **Age:** X days | **+ADD / -DEL lines**
**PR:** <link> | **Preview:** <local or Amplify link used>

### Description
<PR body summary>

### Prior Review Status
<table of prior comments and whether each was addressed — omit section if no prior reviews>

### Code Review
<diff observations — quality, correctness, standards adherence>

**Issues found:** <numbered list, or "None">

### Preview Impressions
<what the browser showed — rendering, layout, content quality>

### Verdict
**Quality:** <Good / Acceptable / Needs Work / Poor>
**Confidence this is a good change:** XX%
<1-2 sentence rationale>
```

Then ask:

> How would you like to handle this?
> 1. **Post as GitHub suggestion blocks** — inline suggestions the author can apply with one click
> 2. **Fix locally and push** — apply edits, commit, and push to the PR branch
> 3. **Approve on GitHub** — post an APPROVE review (use when all issues are resolved)
> 4. **Approve and merge (squash)** — approve then immediately squash-merge
> 5. **Just the report** — no action

Use `AskUserQuestion` with the relevant options. Omit options 3/4 if there are unresolved issues; omit 1/2 if the PR is clean with nothing to fix.

To squash-merge after approving (option 4):

```bash
gh pr merge {NNN} --repo rh-mobb/documentation --squash
```

### Step 6 — Post review comments to GitHub (if user chose option 1)

Use `gh api --input` with a JSON file written by the Write tool. **Do not use the GitHub MCP review tools** — they require credentials that are typically absent and will return 401.

**Important:** Use `"event": "REQUEST_CHANGES"` when issues need fixing, `"event": "APPROVE"` when the PR is clean. If the API returns 422 (you are the PR author), retry with `"event": "COMMENT"`.

**Do not use `gh api --field` for review bodies** — shell interpolation breaks on multi-line strings containing special characters (pipes, colons, quotes). Always write the payload to a file with the Write tool first:

```
Write tool → ./tmp/pr{NNN}-review.json
{
  "commit_id": "<head SHA from step 1>",
  "body": "<overall review summary>",
  "event": "REQUEST_CHANGES",
  "comments": [
    {
      "path": "content/path/to/index.md",
      "line": 36,
      "side": "RIGHT",
      "body": "Issue description.\n\n```suggestion\nreplacement line here\n```"
    }
  ]
}
```

Then post it:

```bash
gh api repos/rh-mobb/documentation/pulls/{NNN}/reviews \
  --method POST \
  --input ./tmp/pr{NNN}-review.json && rm ./tmp/pr{NNN}-review.json
```

GitHub renders ` ```suggestion ``` ` blocks as one-click apply buttons on the PR — use them for all line-level fixes.

### Step 7 — Commit and push local fixes

After applying approved edits:

```bash
# Get user identity for co-author line
GIT_NAME=$(git config user.name)
GIT_EMAIL=$(git config user.email)

git add <changed files>
git commit -m "$(cat <<'EOF'
fix: <short description of fixes>

<bullet list of what was fixed>

Co-Authored-By: $GIT_NAME <$GIT_EMAIL>
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
git push
```

Use the actual expanded values of `$GIT_NAME` and `$GIT_EMAIL` in the commit message — do not pass the shell variables literally.

**Always confirm with the user before committing or pushing.**

### Step 8 — Cleanup

After the review is complete (whether or not any fixes were pushed), stop the preview server and restore the original branch:

```bash
pkill hugo
git checkout $ORIGINAL_BRANCH
```

Confirm the branch has been restored before reporting the review as done.

---

## Confidence Score Guidelines

| Score | Meaning |
|-------|---------|
| 90–100% | Clean diff, preview renders perfectly, follows all conventions |
| 70–89% | Minor fixable issues; solid overall |
| 50–69% | Notable problems; needs revision |
| <50% | Significant issues — wrong approach, broken preview, or policy violations |

---

## Common Issues to Flag

- Hardcoded Amplify/hostname URLs in content (must be root-relative `/experts/...`)
- Em dashes in guide text
- Missing or incorrect front matter fields
- Invented tags not in established taxonomy
- Raw `> blockquote` callouts that should use `{{< alert >}}`
- Theme edits in a content PR
- `kubectl` used instead of `oc`
- Stale/EOL container images
- Typos or stray characters in YAML/code examples (these break copy-paste)
- Example page in `content/examples/` missing `draft: true` (page would be published without it)
- Example page in `content/examples/` with `tags` set (tags pollute the taxonomy and are not useful for internal reference pages)
