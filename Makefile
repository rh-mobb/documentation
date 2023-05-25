.PHONY: preview
preview:
	hugo server --minify --theme relearn -D

.PHONY: publish
publish:
	hugo --minify --theme relearn

.PHONY: review.%
review.?:
	gh pr checkout $*
	hugo server --minify --theme relearn -D
