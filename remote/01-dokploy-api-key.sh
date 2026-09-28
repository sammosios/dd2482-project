#!/usr/bin/env bash
# Runs steps/01-dokploy-api-key.sh against the remote cluster (remote/hosts.env).
export CLUSTER_TARGET=remote
exec "$(dirname "${BASH_SOURCE[0]}")/../steps/01-dokploy-api-key.sh" "$@"
