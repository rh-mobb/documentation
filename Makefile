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

spellcheck:
  # https://github.com/nektos/act/releases/tag/v0.2.24
	act -j spellcheck

lint:
  # https://github.com/nektos/act/releases/tag/v0.2.24
	act -j lint

test: lint spellcheck