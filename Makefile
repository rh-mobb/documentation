.PHONY: preview
preview:
	hugo server --minify --theme rhds -D

.PHONY: publish
publish:
	hugo --minify --theme rhds

.PHONY: preview.%
preview.%:
	gh repo set-default github.com/rh-mobb/documentation
	gh pr checkout $*
	hugo server --minify --theme rhds -D

.PHONY: devspaces
devspaces: 
	export HOST="$(shell jq -r '.CODESPACE_NAME' /workspaces/.codespaces/shared/environment-variables.json)"; \
	hugo server --minify --theme rhds -D  --baseURL "https://$$HOST-1313.app.github.dev/" --appendPort=false
