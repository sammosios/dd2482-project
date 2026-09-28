#!/usr/bin/env bash
# Turns `go test -json` output into Markdown for the run's summary page: a
# headline with the counts, one row per top-level test (subtests folded into
# their parent), why skipped tests skipped, and the output of every failure,
# including a package that didn't build.
# Usage: test-summary.sh <go-test.json> >>"$GITHUB_STEP_SUMMARY"
set -euo pipefail

json="${1:?usage: test-summary.sh <go-test.json>}"
if [[ ! -s "$json" ]]; then
  printf '### Go tests: did not run\n\nAn earlier step failed, see the job log.\n'
  exit 0
fi

jq -rs '
  . as $ev
  # Every test and subtest that finished, in the order they finished.
  | [$ev[] | select(.Test and (.Action == "pass" or .Action == "fail" or .Action == "skip"))] as $done
  | [$done[] | select(.Test | contains("/") | not)] as $top
  # Packages that failed without a failing test: they did not build.
  | [$ev[] | select(.Test == null and .Action == "fail") | .Package] as $failed_pkgs
  | [$failed_pkgs[] | . as $p | select([$done[] | select(.Action == "fail" and .Package == $p)] | length == 0)] as $broken

  | def output($t): [$ev[] | select(.Action == "output" and .Test == $t) | .Output] | join("");
    # What t.Skip or t.Error said, without the "file_test.go:12: " prefix.
    def message($t): [$ev[] | select(.Action == "output" and .Test == $t) | .Output
                      | select(test("^\\s+\\S+\\.go:[0-9]+: "))
                      | sub("^\\s+\\S+\\.go:[0-9]+: "; "") | rtrimstr("\n")] | last // "";
    def cell: gsub("\\|"; "\\|");
    def secs: "\((. // 0) * 100 | round / 100)s";
    def icon: {"pass": "✅", "fail": "❌", "skip": "⏭️"}[.];
    def count($a): [$top[] | select(.Action == $a)] | length;
    def tail($n): split("\n") | .[-$n:] | join("\n");

    "### Go tests: "
    + ([ (if ($broken | length) == 1 then "1 package did not build"
          elif ($broken | length) > 1 then "\($broken | length) packages did not build" else empty end),
         (if count("fail") > 0 then "\(count("fail")) failed" else empty end),
         (if ($top | length) > 0 then "\(count("pass")) passed" else empty end),
         (if count("skip") > 0 then "\(count("skip")) skipped" else empty end)
       ] | join(", "))
    + "\n\n"

    # Failed tests first, then the rest in the order they ran.
    + (if ($top | length) > 0 then
        "| | Test | Time |\n|:-:|---|--:|\n"
        + ([ ([$top[] | select(.Action == "fail")] + [$top[] | select(.Action != "fail")])[] | .Test as $t
             | [$done[] | select(.Test | startswith($t + "/"))] as $subs
             | "| \(.Action | icon) | `\($t)`"
               + (if ($subs | length) == 0 then ""
                  elif ([$subs[] | select(.Action == "fail")] | length) > 0
                  then " · \([$subs[] | select(.Action == "fail")] | length) of \($subs | length) subtests failed"
                  else " · \($subs | length) subtests" end)
               + (if .Action == "skip" and message($t) != "" then " — \(message($t) | cell)" else "" end)
               + " | \(.Elapsed | secs) |"
           ] | join("\n"))
        + "\n"
      else "" end)

    # The output of every failed test that has no failed subtests of its own.
    + ([ $done[] | select(.Action == "fail") | .Test as $t
         | select([$done[] | select(.Action == "fail" and (.Test | startswith($t + "/")))] | length == 0)
         | "\n#### ❌ `\($t)`\n\n````\n\(output($t) | rtrimstr("\n") | tail(60))\n````\n"
       ] | join(""))

    + ([ $broken[] | . as $p
         | "\n#### ❌ `\($p)` did not build\n\n````\n"
           + ([$ev[] | select((.Action == "build-output") or (.Action == "output" and .Test == null and .Package == $p)) | .Output]
              | join("") | rtrimstr("\n") | tail(60))
           + "\n````\n"
       ] | join(""))
' "$json"
