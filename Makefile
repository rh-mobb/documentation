# build:
# 	docker run --rm \
# 	  --name=jekyll-build \
# 		--volume="$(PWD):/srv/jekyll" \
# 		-it jekyll/jekyll:3.8.6 \
# 		jekyll build

preview:
	hugo server --minify --theme relearn -D

publish:
	hugo --minify --theme relearn
