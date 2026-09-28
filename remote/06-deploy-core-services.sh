#!/usr/bin/env bash
# Runs steps/06-deploy-core-services.sh against the remote cluster (remote/hosts.env).
export CLUSTER_TARGET=remote
exec "$(dirname "${BASH_SOURCE[0]}")/../steps/06-deploy-core-services.sh" "$@"
