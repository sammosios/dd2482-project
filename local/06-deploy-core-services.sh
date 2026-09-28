#!/usr/bin/env bash
# Runs steps/06-deploy-core-services.sh against the local multipass cluster.
export CLUSTER_TARGET=local
exec "$(dirname "${BASH_SOURCE[0]}")/../steps/06-deploy-core-services.sh" "$@"
