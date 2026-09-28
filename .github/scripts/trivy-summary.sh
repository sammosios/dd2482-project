#!/usr/bin/env bash
# Turns a Trivy JSON report of every finding (all severities, fixed or not)
# into Markdown for the run's summary page: whether the gate passes, counts
# per target and severity, the findings that block (HIGH or CRITICAL with a
# fix, the gate step's own rule) and every finding in a collapsed table.
# Usage: trivy-summary.sh <trivy.json> >>"$GITHUB_STEP_SUMMARY"
set -euo pipefail

json="${1:?usage: trivy-summary.sh <trivy.json>}"
if [[ ! -s "$json" ]]; then
  printf '### Trivy: no report\n\nThe scan failed before writing one, see the job log.\n'
  exit 0
fi

jq -r '
  def severities: ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"];
  def rank: . as $s | severities | index($s) // 5;
  # What the gate step fails on: --severity HIGH,CRITICAL --ignore-unfixed.
  def blocking: (.Severity == "CRITICAL" or .Severity == "HIGH") and .Status == "fixed";
  def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";
  def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
  def os: (.Target | capture("\\((?<os>[^)]+)\\)$").os) // .Target;
  def target: if .Class == "os-pkgs" then "\(os) packages" else "`\(.Target)` (\(.Type))" end;
  # The same, short enough to repeat on every row of the findings tables.
  def short: if .Class == "os-pkgs" then os else "`\(.Target | split("/") | last)`" end;
  def link: if .PrimaryURL then "[\(.VulnerabilityID)](\(.PrimaryURL))"
            elif (.VulnerabilityID | startswith("GO-")) then "[\(.VulnerabilityID)](https://pkg.go.dev/vuln/\(.VulnerabilityID))"
            else .VulnerabilityID end;
  def fix: if .Status == "fixed" then .FixedVersion
           else "no fix (\(.Status // "unknown" | gsub("_"; " ")))" end;
  def title: (.Title // "") | if length > 80 then .[0:79] + "…" else . end;
  def table($max):
    "| Severity | Vulnerability | Target | Package | Installed | Fixed in | Title |\n"
    + "|---|---|---|---|---|---|---|\n"
    + (.[0:$max] | map("| \(.Severity) | \(link) | \(.Where) | \(.PkgName | cell) "
                       + "| \(.InstalledVersion | cell) | \(fix | cell) | \(title | cell) |") | join("\n"))
    + "\n"
    + (if length > $max then "\n…and \(length - $max) more.\n" else "" end);

  . as $report
  | ($report.Results // []) as $results
  | ([$results[] | short as $w | (.Vulnerabilities // [])[] | . + {Where: $w}]
     | sort_by((.Severity | rank), .PkgName, .VulnerabilityID)) as $all
  | [$all[] | select(blocking)] as $blocking

  | "### Trivy: "
    + (if ($blocking | length) > 0
       then "❌ fails the gate · \($blocking | length) of \(plural($all | length; "finding")) block"
       elif ($all | length) > 0
       then "✅ passes the gate · \(plural($all | length; "finding")), none blocking"
       else "✅ passes the gate · no known vulnerabilities" end)
    + "\n\nScanned `\($report.ArtifactName)`. The gate fails the run on HIGH or CRITICAL findings that have a fix.\n\n"

    + "| Target | Critical | High | Medium | Low | Unknown |\n|---|--:|--:|--:|--:|--:|\n"
    + ([$results[] | target as $w | (.Vulnerabilities // []) as $v
        | "| \($w) | " + ([severities[] as $s | [$v[] | select(.Severity == $s)] | length | tostring] | join(" | ")) + " |"
       ] | join("\n"))
    + "\n"

    + (if ($blocking | length) > 0 then "\n#### Blocking\n\n" + ($blocking | table(100)) else "" end)
    + (if ($all | length) > 0
       then "\n<details><summary>\(if ($all | length) == 1 then "1 finding" else "All \($all | length) findings" end)</summary>\n\n"
            + ($all | table(300)) + "\n</details>\n"
       else "" end)
' "$json"
