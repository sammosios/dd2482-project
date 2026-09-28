#!/usr/bin/env bash
# Runs steps/04-setup-ci-runner.sh against the local multipass cluster.
export CLUSTER_TARGET=local
exec "$(dirname "${BASH_SOURCE[0]}")/../steps/04-setup-ci-runner.sh" "$@"
