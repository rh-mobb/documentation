.PHONY: preview
preview:
	hugo server --minify --theme relearn -D

.PHONY: publish
publish:
	hugo --minify --theme relearn

.PHONY: preview.%
preview.%:
	gh repo set-default github.com/rh-mobb/documentation
	gh pr checkout $*
	hugo server --minify --theme relearn -D

.PHONY: devspaces
devspaces: 
	export HOST="$(shell jq -r '.CODESPACE_NAME' /workspaces/.codespaces/shared/environment-variables.json)"; \
	hugo server --minify --theme relearn -D  --baseURL "https://$$HOST-1313.app.github.dev/" --appendPort=false