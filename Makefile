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
