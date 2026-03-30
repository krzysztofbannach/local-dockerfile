#!/bin/bash

export DOK_3RD_PARTY_IMAGE=dok-3rd-party:0.0.20-20260219-113948
docker pull 256120352618.dkr.ecr.us-east-1.amazonaws.com/dok-cicd-registry/$DOK_3RD_PARTY_IMAGE

DOCKER_BUILDKIT=1 docker build -t local-docker:latest -f Dockerfile --build-arg BUILDKIT_INLINE_CACHE=1 --build-arg OPERATORS_DOK_3RD_PARTY_IMAGE=$DOK_3RD_PARTY_IMAGE .
