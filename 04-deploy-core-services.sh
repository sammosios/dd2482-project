#!/usr/bin/env bash
# Deploys the core service set onto the cluster via Dokploy.
#
# Deliberately a stub: which services and how (Dokploy "Application" vs.
# "Compose" resources, image sources, etc.) hasn't been decided yet - see
# "Core services" checklist in PLAN.md. Fill in one dokploy_api / `dokploy`
# CLI call per service below as those decisions are made.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

require curl jq

vm_exists "$CP_NAME" || { echo "control plane VM not found — run 00-launch-cp-vm.sh first" >&2; exit 1; }
CP_IP="$(vm_ip "$CP_NAME")"

dokploy_api "$CP_IP" "cluster.getNodes" >/dev/null \
  || { echo "cannot reach Dokploy API on $CP_IP — run 01-dokploy-api-key.sh first" >&2; exit 1; }

echo "== core service deployment not yet implemented, see PLAN.md 'Core services'"
echo "   (docker registry: see 03-setup-registry.sh; example web app + database: see 05-deploy-web-app.sh)"
echo "   TODO: s3 compatible storage"
echo "   TODO: CI runner(s)"
echo "   TODO: secrets vault"
echo "== other services tbi:"
echo "   TODO: observability pipeline"
echo "   TODO: Trivy scanning"
