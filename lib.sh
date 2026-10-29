# Helpers for the tests, sourced by bench.sh. Each metric is appended to $RESULTS as one JSON line.

log() { printf '\033[2m%s\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Total and steal CPU ticks. Steal is time the hypervisor gave to other guests.
cpu_ticks() { awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $9}' /proc/stat; }

steal_pct() { # before after
    awk -v a="$1" -v b="$2" 'BEGIN{split(a,x," "); split(b,y," "); d=y[1]-x[1]; printf "%.2f", (d > 0 ? 100 * (y[2] - x[2]) / d : 0)}'
}

# measure <test> <metric> <params json> <command...>
# Runs the command $REPEATS times. The command prints one number. Records the samples and the steal time.
measure() {
    local test=$1 metric=$2 params=$3
    shift 3
    local samples=() value before after i
    before=$(cpu_ticks)
    for ((i = 1; i <= REPEATS; i++)); do
        if ! value=$("$@") || [[ ! $value =~ ^[0-9.]+$ ]]; then
            log "  $metric: run $i failed${value:+ ($value)}"
            continue
        fi
        samples+=("$value")
        log "  $metric #$i: $value"
    done
    after=$(cpu_ticks)
    record "$test" "$metric" "$params" "$(steal_pct "$before" "$after")" "${samples[@]}"
}

# record <test> <metric> <params json> <steal %> <samples...>
# Test version, unit, direction and tool are read from manifest.json. The tool version comes from versions.sh,
# or from $TOOL_VERSION for tools outside the image (the host's Docker). $TARGET is set for latency targets.
record() {
    local test=$1 metric=$2 params=$3 steal=$4
    shift 4
    jq -cn --argjson manifest "$MANIFEST" --argjson tools "$TOOLS" --arg test "$test" --arg metric "$metric" \
        --arg target "${TARGET:-}" --arg tool_version "${TOOL_VERSION:-}" --argjson params "$params" --argjson steal "$steal" \
        --args 'def r2: if . == null then . else . * 100 | round / 100 end;
            def q($p): if length == 0 then null else .[(length - 1) * $p | round] end;
            ($ARGS.positional | map(tonumber)) as $s | ($s | sort) as $o
            | ($manifest.tests[$test].metrics[$metric] // error("\($metric) is not in manifest.json")) as $m
            | {test: $test, test_version: $manifest.tests[$test].version, metric: $metric}
            + (if $target == "" then {} else {target: $target} end)
            + {unit: $m.unit, better: $m.better, tool: $m.tool,
                tool_version: (if $tool_version != "" then $tool_version else $tools[$m.tool] end),
                params: $params, samples: $s,
                median: (if ($o | length) % 2 == 1 or ($o | length) == 0 then $o | q(0.5)
                    else ($o[($o | length) / 2 - 1] + $o[($o | length) / 2]) / 2 end | r2),
                p10: ($o | q(0.1)), p90: ($o | q(0.9)), steal_pct: $steal}' "$@" >>"$RESULTS"
}

# Test duration in seconds: full, or shorter with --quick.
secs() { if [[ $QUICK == 1 ]]; then echo "$2"; else echo "$1"; fi; }

skipped() { # test reason
    jq -cn --arg test "$1" --arg reason "$2" '{test: $test, skipped: $reason}' >>"$RESULTS"
    log "$1: skipped, $2"
}

now() { date +%s.%N; }
