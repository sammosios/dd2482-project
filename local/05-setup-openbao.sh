#!/usr/bin/env bash
# Runs steps/05-setup-openbao.sh against the local multipass cluster.
export CLUSTER_TARGET=local
exec "$(dirname "${BASH_SOURCE[0]}")/../steps/05-setup-openbao.sh" "$@"
