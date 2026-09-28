#!/usr/bin/env bash
# Runs steps/07-deploy-web-app.sh against the local multipass cluster.
export CLUSTER_TARGET=local
exec "$(dirname "${BASH_SOURCE[0]}")/../steps/07-deploy-web-app.sh" "$@"
