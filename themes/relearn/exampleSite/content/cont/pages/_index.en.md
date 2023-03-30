+++
title = "Pages organization"
weight = 1
+++

In **Hugo**, pages are the core of your site. Once it is configured, pages are definitely the added value to your documentation site.

## Folders

Organize your site like [any other Hugo project](https://gohugo.io/content/organization/). Typically, you will have a *content* folder with all your pages.

````plaintext
content
├── level-one
│   ├── level-two
│   │   ├── level-three
│   │   │   ├── level-four
│   │   │   │   ├── _index.md       <-- /level-one/level-two/level-three/level-four
│   │   │   │   ├── page-4-a.md     <-- /level-one/level-two/level-three/level-four/page-4-a
│   │   │   │   ├── page-4-b.md     <-- /level-one/level-two/level-three/level-four/page-4-b
│   │   │   │   └── page-4-c.md     <-- /level-one/level-two/level-three/level-four/page-4-c
│   │   │   ├── _index.md           <-- /level-one/level-two/level-three
│   │   │   ├── page-3-a.md         <-- /level-one/level-two/level-three/page-3-a
│   │   │   ├── page-3-b.md         <-- /level-one/level-two/level-three/page-3-b
│   │   │   └── page-3-c.md         <-- /level-one/level-two/level-three/page-3-c
│   │   ├── _index.md               <-- /level-one/level-two
│   │   ├── page-2-a.md             <-- /level-one/level-two/page-2-a
│   │   ├── page-2-b.md             <-- /level-one/level-two/page-2-b
│   │   └── page-2-c.md             <-- /level-one/level-two/page-2-c
│   ├── _index.md                   <-- /level-one
│   ├── page-1-a.md                 <-- /level-one/page-1-a
│   ├── page-1-b.md                 <-- /level-one/page-1-b
│   └── page-1-c.md                 <-- /level-one/page-1-c
├── _index.md                       <-- /
└── page-top.md                     <-- /page-top
````

{{% notice note %}}
`_index.md` is required in each folder, it’s your “folder home page”
{{% /notice %}}

## Create your project

The following steps are here to help you initialize your new website. If you don't know Hugo at all, we strongly suggest you to train by following [great documentation for beginners](https://gohugo.io/overview/quickstart/).

Hugo provides a `new` command to create a new website.

```shell
hugo new site <new_project>
```

The Relearn theme provides [archetypes]({{%relref "cont/archetypes" %}}) to help you create this kind of pages.

## Frontmatter Configuration

Each Hugo page has to define a [frontmatter](https://gohugo.io/content/front-matter/) in *toml*, *yaml* or *json*. This site will use *toml* in all cases.

The Relearn theme uses the following parameters on top of Hugo ones:

```toml
+++
# Table of contents (toc) is enabled by default. Set this parameter to true to disable it.
# Note: Toc is always disabled for chapter pages
disableToc = false
# If set, this will be used for the page's menu entry (instead of the `title` attribute)
menuTitle = ""
# If set, this will explicitly override common rules for the expand state of a page's menu entry
alwaysopen = true
# If set, this will explicitly override common rules for the sorting order of a page's submenu entries
ordersectionsby = "title"
# The title of the page heading will be prefixed by this HTML content
headingPre = ""
# The title of the page heading will be postfixed by this HTML content
headingPost = ""
# The title of the page in menu will be prefixed by this HTML content
menuPre = ""
# The title of the page in menu will be postfixed by this HTML content
menuPost = ""
# Hide a menu entry by setting this to true
hidden = false
# Display name of this page modifier. If set, it will be displayed in the footer.
LastModifierDisplayName = ""
# Email of this page modifier. If set with LastModifierDisplayName, it will be displayed in the footer
LastModifierEmail = ""
+++
```

### Add icon to a menu entry

In the page frontmatter, add a `menuPre` param to insert any HTML code before the menu label. The example below uses the GitHub icon.

```toml
+++
title = "GitHub repo"
menuPre = "<i class='fab fa-github'></i> "
+++
```

![Title with icon](frontmatter-icon.png?classes=shadow&width=300px)

### Ordering sibling menu/page entries

Hugo provides a [flexible way](https://gohugo.io/content/ordering/) to handle order for your pages.

The simplest way is to set `weight` parameter to a number.

```toml
+++
title = "My page"
weight = 5
+++
```

### Using a custom title for menu entries

By default, the Relearn theme will use a page's `title` attribute for the menu item (or `linkTitle` if defined).

But a page's title has to be descriptive on its own while the menu is a hierarchy.
We've added the `menuTitle` parameter for that purpose:

For example (for a page named `content/install/linux.md`):

```toml
+++
title = "Install on Linux"
menuTitle = "Linux"
+++
```

### Override expand state rules for menu entries

You can change how the theme expands menu entries on the side of the content with the `alwaysopen` setting on a per page basis. If `alwaysopen=false` for any given entry, its children will not be shown in the menu as long as it is not necessary for the sake of navigation.

The theme generates the menu based on the following rules:

- all parent entries of the active page including their siblings are shown regardless of any settings
- immediate children entries of the active page are shown regardless of any settings
- if not overridden, all other first level entries behave like they would have been given `alwaysopen=false`
- if not overridden, all other entries of levels besides the first behave like they would have been given `alwaysopen=true`
- all visible entries show their immediate children entries if `alwaysopen=true`; this proceeds recursivley
- all remaining entries are not shown

You can see this feature in action on the example page for [children shortcode]({{< relref "shortcodes/children" >}}) and its children pages.
