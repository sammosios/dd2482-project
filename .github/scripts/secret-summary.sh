#!/usr/bin/env bash
# Turns a Trivy secret scan's JSON report into Markdown for the run's summary
# page: whether the scan passes, and one row per secret found with where it
# is. Trivy masks the secret itself in the matched line.
# Usage: secret-summary.sh <trivy.json> >>"$GITHUB_STEP_SUMMARY"
set -euo pipefail

json="${1:?usage: secret-summary.sh <trivy.json>}"
if [[ ! -s "$json" ]]; then
  printf '### Secret scan: no report\n\nThe scan failed before writing one, see the job log.\n'
  exit 0
fi

jq -r '
  def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
  def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

  [(.Results // [])[] | .Target as $t | (.Secrets // [])[] | . + {Target: $t}] as $all
  | "### Secret scan: "
    + (if ($all | length) > 0
       then "❌ \(plural($all | length; "secret")) found"
       else "✅ no secrets found" end)
    + "\n\nTrivy scanned every tracked file of this commit. Any secret it finds fails the run.\n"
    + (if ($all | length) > 0
       then "\n| Severity | Rule | File | Line | Match |\n|---|---|---|--:|---|\n"
            + ($all | map("| \(.Severity) | \(.Title | cell) | `\(.Target)` | \(.StartLine) | `\(.Match | cell)` |") | join("\n"))
            + "\n\nRemoving it in a new commit is not enough: it stays in the history. Revoke it first.\n"
       else "" end)
' "$json"
