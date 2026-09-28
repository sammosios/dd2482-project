#!/usr/bin/env bash
# Deploys the core service set onto the cluster via Dokploy.
#
# Deliberately a stub: which services and how (Dokploy "Application" vs.
# "Compose" resources, image sources, etc.) hasn't been decided yet - see
# "Core services" checklist in PLAN.md. Fill in one dokploy_api / `dokploy`
# CLI call per service below as those decisions are made.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source lib/common.sh

require curl jq
target_require
load_cp
require_dokploy_api

echo "== core service deployment not yet implemented, see PLAN.md 'Core services'"
echo "   (docker registry: see 03-setup-registry.sh)"
echo "   (CI runners: see 04-setup-ci-runner.sh)"
echo "   (example web app, its database and Redis: see 07-deploy-web-app.sh)"
echo "   TODO: Trivy scanning"
echo "   (secrets vault: see 05-setup-openbao.sh, APP-PROJECT-SETUP.md)"
echo "== other services tbi:"
echo "   TODO: s3 compatible storage"
echo "   TODO: observability pipeline"
