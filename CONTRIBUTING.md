

## Structure Overview

The docs follow this org structure:

* /content > docs > *High Level Topic* (eg. ARO, ROSA, etc.) > *Subject Matter*(eg. aro/add-infra-nodes/) > index.md *this is the former 'README.md'*
  * the index files allow for the side bar menu to generate a topic heading which mirrors the *Front Matter* of the page that you create

![Front Matter Example](./contrib_files/Screen%20Shot%202023-01-09%20at%206.25.37%20PM.png)

### Front Matter

* Date - The examples of the date object show were generated via script so going forward follow the YYYY-MM-DD format
* Title - This will be displayed page title
* Tags - The tags associated with your page, they will display alphabetically atop of the page regardless of the order definied in the front amtter


## Adding New Docs

### New Document and New High level section
  
In order to create a landing page for your new section you will need to create a "_index.md" which is a chapter page in our useage. This page will create the section in the drop down menu as well as display as a landing page for the new section. The front matter for the chapter pages should follow the format below

![Chapter Page Front Matter](contrib_files/Screen%20Shot%202023-01-10%20at%209.12.02%20AM.png)

Note: weight overrides the default alphabetical sorting for menu items on the site's navigation pane.

* Create the Directory structure (/content/docs/<highlevel_topic>/_index.md 
                                                                <subject_dir>/index.md)
* Create your chapter page (_index.md)
* Create your doc page (index.md)
* Add your doc to the home page (/content/docs/_index.md) creating a new section on the page for your new topic
* submit PR

### New Document in an existing section
* Create your dir structure (.../<subject_dir>/index.md)
* Write your Doc with the proper front matter (Title, Date, Tags)
* Add your new doc to the home page under the correct high level section
* submit PR

## Taxonomy


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