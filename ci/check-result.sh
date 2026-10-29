#!/usr/bin/env bash
# Checks a result.json from a CI run: no test skipped, and every metric of the tests that ran has a value.
#   ci/check-result.sh <result.json>
set -euo pipefail
cd "$(dirname "$0")/.."

jq -e --slurpfile manifest manifest.json '
    ($manifest[0].tests) as $tests
    | (.skipped | map("skipped: \(.test), \(.skipped)")) as $skipped
    | ([.tests | keys[] as $t | $tests[$t].metrics | keys[]] - [.results[] | select(.median != null) | .metric]
        | map("no value: \(.)")) as $missing
    | ($skipped + $missing) as $errors
    | if $errors == [] then true else ($errors | join("\n") | halt_error(1)) end' "$1" >/dev/null
echo "$1: every metric has a value"
