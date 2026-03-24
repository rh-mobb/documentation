## GitHub Flow

It is expected that you will use the [GitHub flow](https://docs.github.com/en/get-started/quickstart/github-flow) for contributing to this repository.

1. [Fork the repository](https://docs.github.com/en/get-started/quickstart/fork-a-repo) into your own GitHub account.

1. Clone the `rh-mobb/documentation` repo locally and configure it to push to your fork, but pull from the upstream repo.

   ```bash
   git clone https://github.com/rh-mobb/documentation.git mobb-docs
   cd mobb-docs
   git remote set-url --push origin git@github.com:<username>/documentation.git
   ```

1. Create a feature branch

   ```bash
   git checkout -b my-feature-branch
   ```

1. Work on the Code

1. Commit and push

   ```bash
   git add .
   git commit -sm 'fix typo in /index.md'
   git push origin my-feature-branch
   ```

1. Create a Pull request at https://github.com/rh-mobb/documentation



## Structure Overview

The docs in this repo follow the structure of `/content/docs/[Section]/[Topic]/index.md`.

For example `/content/docs/aro/add-infra-nodes/index.md`.

This becomes the URL of your page, so keep the Section and Topic descriptive but short.

Docs that follow this structure will be automatically added to the content menu (left side of the rendered website) based on their title (set in front matter).

### Front Matter

These fields are recommended and are used to auto-generate portions of the content body.  They belong at the
top of each article that you publish.

* Date - The original date of content creation, in YYYY-MM-DD format
* Title - This will be displayed page title
* Tags - The tags associated with your page; they display alphabetically atop the page regardless of the order defined in the front matter
* Authors - Anyone who has edited this page

Example:

```yaml
---
date: '2022-08-17'
title: Adding infrastructure nodes to an ARO cluster
tags: ["ARO"]
authors:
  - Paul Czarkowski
---
```

## Adding New Docs

### New Document in an existing section

1. Create a new feature branch in your forked copy of the repository.

1. Create your dir structure (`/content/docs/[Section]/[Topic]/index.md`)

1. Write your Doc with the proper front matter (Title, Date, Tags)

```yaml
---
date: "2023-01-01"
title: "Creating s3 buckets in ROSA using ACK"
tags: ["ROSA", "Terraform"]
authors:
   - My Name
---
```

1. Update `/content/docs/_index.md` to include your new document.

1. Update `/content/docs/[Section]/_index.md` to include your new document.

1. To verify your changes you can run `make preview` to preview the site locally at [http://localhost:1313/experts/](http://localhost:1313/experts/)

1. Submit PR

## Site search (local development)

The black header bar includes [Pagefind](https://pagefind.app/) client-side search. Netlify runs `npm ci`, builds the site with Hugo, then runs `npx pagefind --site public/experts` so the index is published under `/experts/pagefind/` (see [`netlify.toml`](netlify.toml)).

For a local build where search works end-to-end, run `npm install` once, then `make preview-search`. That runs Hugo, indexes the output, and starts `hugo server` with `--renderToDisk` so the Pagefind assets are served. Using `make preview` alone does not create an index, so the search field appears but queries will not return results until you run `make search-index` (or the full `preview-search` flow).

### New Document and New Section

> Note: Most documents will fit inside an existing Section, if you feel like you need to create a new one, speak to your team leads first.

In order to create a landing page for your new section you will need to create a `/docs/[Section]/_index.md` which is a chapter page in our useage. This page will create the section in the drop down menu as well as display as a landing page for the new section. The front matter for the chapter pages should follow the format below

```yaml
---
date: "2023-01-01"
title: "DevSecFinOps"
tags: ["GitOps", "ROSA"]
authors:
   - My Name
---
```

Note: you can add a `weight` field to override the default alphabetical sorting for menu items on the site's navigation pane.

* Create the Directory structure (`/content/docs/<highlevel_topic>/_index.md`
                                                                <subject_dir>/index.md)
* Create your chapter page (_index.md)
* Create your doc page (index.md)
* Add your doc to the home page (/content/docs/_index.md) creating a new section on the page for your new topic
* submit PR

## Taxonomy

The strategy here is to keep our taxonomy simple and helpful for traversing the site and finding docs relevant to a product or topic. **Use tags from the list below** so pages appear on the right tag hubs and stay consistent. If you need a new tag, discuss with a maintainer before attempting to add it to a PR.

Tag values are **case-sensitive** and must match exactly (including spaces in multi-word tags such as `ROSA HCP`).

### Current tags

These are the tag strings currently in use:

* AAP
* ACM
* ACS
* ARO
* DevSpaces
* GitOps
* GovCloud
* IDP
* Keycloak
* Lightspeed
* Maximo
* OADP
* Observability
* OCM
* ODF
* OSD
* Quickstarts
* RHOAI
* ROSA
* ROSA Classic
* ROSA HCP
* Service Interconnect
* Terraform
* Virtualization
