build:
	docker run --rm \
	  --name=jekyll-build \
		--volume="$(PWD):/srv/jekyll" \
		-it jekyll/jekyll:3.8 \
		jekyll build

preview:
	docker run --rm -ti \
		--name=jekyll-preview \
		--volume="$(PWD):/srv/jekyll" \
		--publish 4000:4000 \
		jekyll/jekyll \
		jekyll serve