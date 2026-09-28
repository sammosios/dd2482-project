#!/usr/bin/env bash
# Runs steps/04-setup-ci-runner.sh against the remote cluster (remote/hosts.env).
export CLUSTER_TARGET=remote
exec "$(dirname "${BASH_SOURCE[0]}")/../steps/04-setup-ci-runner.sh" "$@"
