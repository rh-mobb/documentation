## Structure Overview

The docs in this repo follow the structure of `/content/docs/[Section]/[Topic]/index.md`.

For example `/content/docs/aro/add-infra-nodes/index.md`.

This becomes the URL of your page, so keep the Section and Topic descriptive but short.

Docs that follow this structure will be automatically added to the content menu (left side of the rendered website) based on their title (set in front matter).

### Front Matter

* Date - The examples of the date object show were generated via script so going forward follow the YYYY-MM-DD format
* Title - This will be displayed page title
* Tags - The tags associated with your page, they will display alphabetically atop of the page regardless of the order definied in the front amtter

![Front Matter Example](./contrib_files/Screen%20Shot%202023-01-09%20at%206.25.37%20PM.png)

## Adding New Docs

### New Document in an existing section

1. Create a new feature branch in your forked copy of the repository.

1. Create your dir structure (`/content/docs/[Section]/[Topic]/index.md`)

1. Write your Doc with the proper front matter (Title, Date, Tags)

   ```
   ---
   date: "2023-01-01"
   title: "Creating s3 buckets in ROSA using ACK"
   tags: ["rosa","s3", "ack"]
   ---
   ```

1. Update `/content/docs/_index.md` to include your new document.

1. Update `/content/docs/[Section]/_index.md` to include your new document.

1. Submit PR


### New Document and New Section

> Note: Most documents will fit inside an existing Section, if you feel like you need to create a new one, speak to your team leads first.

In order to create a landing page for your new section you will need to create a `/docs/[Section]/_index.md` which is a chapter page in our useage. This page will create the section in the drop down menu as well as display as a landing page for the new section. The front matter for the chapter pages should follow the format below

```
---
date: "2023-01-01"
title: "DevSecFinOps"
tags: ["devops", "finops", "devsecops"]
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

The strategy here is to keep our taxonomy simple and helpful for traversing the site and finding docs relevant to a product or topic. Feel free as we expand our docs to create new tags by simply adding them to the front matter of your page. However please keep in mind simplicity.

### Current Tags
* ACM
* ACS
* ARO
* AWS
* Azure
* Cost
* GCP
* GitOps
* GPU
* Observability
* OCP
* OSD
* Private Link
* Quickstarts
* ROSA
* STS
