#!/usr/bin/env bash
# Checks that the tool versions in the image match manifest.json. With a tag, also checks that the tag, manifest.json
# and run.sh have the same version. If a rebuild brings a new tool version, update manifest.json: a patch version if
# the numbers do not change, a major version of the test if they do.
#   ci/check-versions.sh <image> [vX.Y.Z]
set -euo pipefail
cd "$(dirname "$0")/.."

found=$(docker run --rm --entrypoint /opt/bench/versions.sh "$1")
expected=$(jq '[.tests[].tools] | add' manifest.json)
diff=$(jq -rn --argjson found "$found" --argjson expected "$expected" \
    '$expected | to_entries[] | select($found[.key] != .value) | "\(.key): manifest \(.value), image \($found[.key] // "missing")"')
if [[ -n $diff ]]; then
    echo "tool versions differ from manifest.json:" >&2
    echo "$diff" >&2
    exit 1
fi
echo "tools match manifest.json"

if [[ -n ${2:-} ]]; then
    runner=$(jq -r .runner manifest.json)
    script=$(sed -n 's/^VERSION=//p' run.sh)
    [[ $2 == "v$runner" && $script == "$runner" ]] || { echo "tag $2, manifest.json $runner, run.sh $script" >&2; exit 1; }
    echo "release $2 matches manifest.json and run.sh"
fi
