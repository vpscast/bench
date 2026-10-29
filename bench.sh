#!/usr/bin/env bash
# Runs the tests inside the runner image. Started by run.sh, writes $OUT/result.json.
set -uo pipefail

BENCH_DIR=$(cd "$(dirname "$0")" && pwd)
# Runner and test versions from the manifest, tool versions from the image.
MANIFEST=$(jq -c . "$BENCH_DIR/manifest.json")
TOOLS=$("$BENCH_DIR/versions.sh" | jq -c .)
BENCH_VERSION=$(jq -r .runner <<<"$MANIFEST")
ALL=(cpu disk web db build network latency)

QUICK=0 REPEATS=3 ONLY=()
while (($#)); do
    case $1 in
        --quick) QUICK=1 REPEATS=1 ;;
        --repeats) REPEATS=$2; shift ;;
        --only) IFS=, read -ra ONLY <<<"$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
((${#ONLY[@]})) || ONLY=("${ALL[@]}")
for test in "${ONLY[@]}"; do
    [[ " ${ALL[*]} " == *" $test "* ]] || { echo "no such test: $test (tests: ${ALL[*]})" >&2; exit 2; }
done

OUT=${OUT:-/out}
WORK=${WORK:-/work}
NPROC=$(nproc)
RESULTS=$OUT/results.jsonl
export BENCH_DIR BENCH_VERSION MANIFEST TOOLS OUT WORK NPROC RESULTS QUICK REPEATS
mkdir -p "$OUT" "$WORK"
: >"$RESULTS"
# Files are created as root inside the container. Clean the work directory and give the results to the caller.
finish() { rm -rf "${WORK:?}"/*; [[ -n ${OWNER:-} ]] && chown -R "$OWNER" "$OUT"; }
trap finish EXIT

# shellcheck source=lib.sh
source "$BENCH_DIR/lib.sh"
for f in "$BENCH_DIR"/tests/*.sh; do
    # shellcheck disable=SC1090
    source "$f"
done

started=$(date -u +%FT%TZ)
log "vpscast-bench $BENCH_VERSION: $NPROC vCPU, $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo) MB RAM, tests: ${ONLY[*]}"
env_json=$(collect_env)
log "CPU: $(jq -r .cpu.model <<<"$env_json"), hypervisor: $(jq -r '.virtualization.hypervisor // "none"' <<<"$env_json")"

for test in "${ONLY[@]}"; do
    log "$test"
    t0=$(date +%s)
    "test_$test"
    jq -cn --arg test "$test" --argjson s "$(($(date +%s) - t0))" '{test: $test, seconds: $s}' >>"$RESULTS"
done

# VPScast accepts a result only if runner.digest belongs to a published release.
jq -n --arg version "$BENCH_VERSION" --arg git_sha "${RUNNER_GIT_SHA:-dev}" \
    --arg image "${RUNNER_IMAGE:-}" --arg digest "${RUNNER_DIGEST:-}" \
    --argjson manifest "$MANIFEST" --argjson tools "$TOOLS" --arg only "${ONLY[*]}" \
    --arg started "$started" --arg finished "$(date -u +%FT%TZ)" \
    --argjson quick "$QUICK" --argjson repeats "$REPEATS" --argjson env "$env_json" \
    --slurpfile results "$RESULTS" \
    '{schema: 1, runner: {version: $version, git_sha: $git_sha, image: $image, digest: $digest},
      tests: ($only | split(" ") | map({(.): $manifest.tests[.].version}) | add), tools: $tools,
      quick: ($quick == 1), repeats: $repeats, started_at: $started, finished_at: $finished, environment: $env,
      results: [$results[] | select(has("metric"))], skipped: [$results[] | select(has("skipped"))],
      durations: ([$results[] | select(has("seconds")) | {(.test): .seconds}] | add)}' \
    >"$OUT/result.json"
rm -f "$RESULTS"

echo
jq -r '.results[] | [.metric + (if .target then " " + .target else "" end), (.median // "-" | tostring) + " " + .unit,
    if .steal_pct > 1 then "steal \(.steal_pct)%" else "" end] | @tsv' "$OUT/result.json" | column -t -s $'\t'
jq -r '.skipped[] | "skipped: \(.test), \(.skipped)"' "$OUT/result.json"
jq -r '"time, s: " + (.durations | to_entries | map("\(.key) \(.value)") | join(", "))' "$OUT/result.json"
