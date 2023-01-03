ifeq (, $(shell which podman))
    DOCKER = docker
else
    DOCKER = podman
endif

build:
	$(DOCKER) run --rm \
	  --name=jekyll-build \
		--volume="$(PWD):/srv/jekyll" \
		-it docker.io/jekyll/jekyll:3.8.6 \
		jekyll build

preview:
	$(DOCKER) run --rm -ti \
		--name=jekyll-preview \
		--volume="$(PWD):/srv/jekyll" \
		--publish 4000:4000 \
		docker.io/jekyll/jekyll:3.8.6 \
		jekyll serve
