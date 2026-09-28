#!/usr/bin/env bash
# Runs steps/03-setup-registry.sh against the local multipass cluster.
export CLUSTER_TARGET=local
exec "$(dirname "${BASH_SOURCE[0]}")/../steps/03-setup-registry.sh" "$@"
