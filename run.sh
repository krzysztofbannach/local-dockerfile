#!/bin/bash

# params
USE_HOST_NETWORK=""
CUSTOM_PORT=""

# options
HOST_NETWORK="--network=host"
NET_ADMIN_CAPABILITY="--cap-add=NET_ADMIN"
AWS_VOLUME="-v $HOME/.aws:/root/.aws"
GCLOUD_VOLUME="-v $HOME/.config/gcloud:/root/.config/gcloud/"
WORKSPACE_VOLUME="-v $HOME/workspace:/root/workspace"
DOCKER_SOCK_VOLUME="-v /var/run/docker.sock:/var/run/docker.sock"
ALIASES_VOLUME="-v ./misc/aliases.sh:/etc/profile.d/personal_aliases.sh:ro"
GO_LIB_VOLUME="--mount source=local-dev-go-pkg-path,target=/opt/go/pkg"

function load_params() {
  while [[ "$#" -gt 0 ]]; do
      case $1 in
          --use-host-network)
              USE_HOST_NETWORK="$HOST_NETWORK"
              ;;
          -p|--expose-port)
              CUSTOM_PORT="-p $2:$2"
              shift
              ;;
          -h|--help)
              echo "Usage: $0 [--use-host-network] [-p|--expose-port <port>]"
              exit 0
              ;;
          *)
              echo "Unknown parameter passed: $1"
              exit 1
              ;;
      esac
      shift
  done
}

function run() {
  docker run \
    $NET_ADMIN_CAPABILITY \
    $AWS_VOLUME \
    $GCLOUD_VOLUME \
    $WORKSPACE_VOLUME \
    $DOCKER_SOCK_VOLUME \
    $ALIASES_VOLUME \
    $GO_LIB_VOLUME \
    $USE_HOST_NETWORK \
    $CUSTOM_PORT \
    --rm -it local-docker:latest
}

function main() {
    load_params "$@"
    run
}

main "$@"
