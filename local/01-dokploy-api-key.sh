#!/usr/bin/env bash
# Runs steps/01-dokploy-api-key.sh against the local multipass cluster.
export CLUSTER_TARGET=local
exec "$(dirname "${BASH_SOURCE[0]}")/../steps/01-dokploy-api-key.sh" "$@"
