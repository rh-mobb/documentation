# Documentation from the MOBB/MOST team

## Welcome to the MOBB Ninja Documentation repo!

This repository holds all of the MOBB Team's guides, documents and quickstarts for the Managed Openshift suite of products and their integrations.

If this is your first interaction with Red Hat's Managed Openshift service offerings and would like to find out more, please reach out to the Red Hat team using the [Contact Us](https://www.redhat.com/en/contact) link provided on the sidebar menu.

### Working from GitHub Code Spaces

You should be able to review PRs, preview branches, and even write new posts directly in code spaces.

1. In github look for the green **<> Code** button, choose that, click code spaces and the **+** button.

    This will bring up the code spaces interface.

1. In the **TERMINAL** run `make devspaces` which will create a preview hugo site for your branch

1. Click **Ports** and click the **Open in browser** icon.

You should now have a github space ready for writing content or reviewing PRs.


### Reviewing PRs with Claude Code

If you have [Claude Code](https://claude.ai/code) installed, you can review pull requests directly from the terminal:

```
> review PR 123
```

Claude will check out the branch, spin up the local preview server, assess the diff against site standards, and post inline suggestions or comments to the PR. You can then follow up with:

- `"approve and merge it"` — approve and squash merge once satisfied
- `"go ahead and make the suggestion"` — apply a fix locally and push it to the branch
- `"just comment on the PR"` — post feedback without touching the code

If the PR is yours and you want to address reviewer comments, phrase it accordingly:

```
> PR 123 is mine, I want to address any comments/concerns
```

Claude will fetch the prior review comments, check what's been addressed and what hasn't, assess the diff, apply fixes locally, and push them back to your branch.

### Example pages

The [`content/examples/`](./content/examples/) directory holds shortcode demos, diagram templates, and other formatting reference pages for content authors. These pages render in local preview (`make preview`) but are never published to the live site. See [CONTRIBUTING.md](./CONTRIBUTING.md#example-pages) for how to add one.

### Contributing

For contributing to this repository, please follow the guidelines specified in the [contributing.md](./CONTRIBUTING.md)
