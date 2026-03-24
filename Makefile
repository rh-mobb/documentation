.PHONY: preview
preview:
	hugo server --minify --theme rhds -D -b http://localhost:1313/experts

# Build static HTML and generate the Pagefind index under public/experts/pagefind/
.PHONY: search-index
search-index:
	hugo --gc --minify --theme rhds && npx pagefind --site public/experts

# Local preview with working header search (requires disk output for /pagefind/ assets)
.PHONY: preview-search
preview-search: search-index
	hugo server --minify --theme rhds -D -b http://localhost:1313/experts --renderToDisk

.PHONY: publish
publish:
	hugo --minify --theme rhds

.PHONY: preview.%
preview.%:

	gh repo set-default github.com/rh-mobb/documentation
	gh pr checkout $*
	hugo server --minify --theme rhds -D --baseURL http://localhost:1313/experts

.PHONY: devspaces
devspaces:
	export HOST="$(shell jq -r '.CODESPACE_NAME' /workspaces/.codespaces/shared/environment-variables.json)"; \
	hugo server --minify --theme rhds -D  --baseURL "https://$$HOST-1313.app.github.dev/" --appendPort=false
