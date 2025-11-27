#!/bin/bash

docker run \
	--cap-add=NET_ADMIN \
	-v ~/.aws:/root/.aws \
	-v ~/.config/gcloud:/root/.config/gcloud/ \
	-v "${HOME}"/.gnupg:/root/.gnupg \
	-v ~/workspace:/root/workspace \
	-v /var/run/docker.sock:/var/run/docker.sock \
	-p $1:$1 \
	--mount source=local-dev-go-pkg-path,target=/opt/go/pkg \
	--rm -it local-docker:latest
