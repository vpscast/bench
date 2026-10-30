# Network tests: download and upload to the nearest Cloudflare node, download from the nearest point in another
# network, downloads from fixed points on each continent, and latency to the targets in targets.txt.

CF=https://speed.cloudflare.com
UA="vpscast-bench/$BENCH_VERSION (+https://github.com/vpscast/bench)"

# Runs parallel streams of 25 MB requests for up to $2 seconds, at most 250 MB per stream. Cloudflare limits the
# traffic per IP, so the total is capped at 1 GB. Prints Mbit/s, or an error if Cloudflare refused a request.
cf_streams() { # down|up seconds streams
    local dir=$1 t=$2 n=$3 start deadline i
    start=$(now)
    deadline=$(awk -v s="$start" -v t="$t" 'BEGIN{printf "%.3f", s + t}')
    for ((i = 1; i <= n; i++)); do
        (
            moved=0
            while ((moved < 250000000)) && left=$(awk -v d="$deadline" -v n="$(now)" 'BEGIN{l = d - n; if (l > 0.2) printf "%.2f", l; else exit 1}'); do
                if [[ $dir == down ]]; then
                    read -r code bytes after < <(curl -s -o /dev/null -A "$UA" --max-time "$left" -w '%{http_code} %{size_download} %header{retry-after}\n' "$CF/__down?bytes=25000000")
                else
                    read -r code bytes after < <(curl -s -o /dev/null -A "$UA" --max-time "$left" -H 'Expect:' -w '%{http_code} %{size_upload} %header{retry-after}\n' --data-binary @"$WORK/up.bin" "$CF/__up")
                fi
                # Status 000 means the request was cut at the deadline (100 during an upload). Its bytes still count.
                [[ $code == 200 || $code == 000 || $code == 100 ]] || { echo "refused $code $after"; break; }
                echo "$bytes"
                moved=$((moved + bytes))
            done
        ) >"$WORK/stream.$i" &
    done
    wait
    if grep -qh refused "$WORK"/stream.*; then
        grep -h refused "$WORK"/stream.* | head -1
    else
        cat "$WORK"/stream.* | awk -v s="$start" -v e="$(now)" '{b+=$1} END{printf "%.1f", b*8/(e-s)/1000000}'
    fi
    rm -f "$WORK"/stream.*
}

# cf_streams, once more after a 429: some IPs get one on the first request. It waits as long as Retry-After asks,
# 10 s if it does not say, at most 30 s.
cf_speed() { # down|up seconds streams
    local out status code after
    out=$(cf_streams "$@")
    read -r status code after <<<"$out"
    if [[ $status == refused && $code == 429 ]]; then
        [[ $after =~ ^[0-9]+$ ]] || after=10
        ((after > 30)) && after=30
        log "  Cloudflare answered 429, trying again in $after s"
        sleep "$after"
        out=$(cf_streams "$@")
        read -r status code after <<<"$out"
    fi
    if [[ $status == refused ]]; then echo "refused $code"; else echo "$out"; fi
}

# The AS number of an IP, from RIPEstat. Prints nothing if the lookup fails.
asn() { # ip
    curl -s -A "$UA" --max-time 10 "https://stat.ripe.net/data/network-info/data.json?resource=$1" | jq -r '.data.asns[0] // empty' 2>/dev/null || true
}

# Median TCP connect time in ms over 3 samples, or nothing if the host does not answer.
connect_ms() { # ip
    local i a b
    for ((i = 0; i < 3; i++)); do
        a=$(now)
        timeout 3 bash -c "exec 3<>/dev/tcp/$1/443" 2>/dev/null || continue
        b=$(now)
        awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f\n", (b-a)*1000}'
    done | sort -n | awk '{v[NR]=$1} END{if (NR) print v[int((NR+1)/2)]}'
}

# Picks the point of downloads.txt with the lowest connect time, skipping points in the server's own network (same
# AS), which would show the provider's internal speed. Prints "<slug> <url> <ms>", or "refused <reason>".
near_point() {
    local own slug url host ip as ms best='' best_ms=''
    own=$(curl -s -A "$UA" --max-time 10 https://stat.ripe.net/data/whats-my-ip/data.json | jq -r '.data.ip // empty' 2>/dev/null) || true
    [[ -n $own ]] && own=$(asn "$own")
    [[ -n $own ]] || { echo "refused no-asn"; return; }
    while read -r slug url _; do
        host=${url#https://}
        host=${host%%/*}
        ip=$(getent ahostsv4 "$host" | awk 'NR==1{print $1}') || continue
        [[ -n $ip ]] || continue
        as=$(asn "$ip")
        [[ -n $as && $as != "$own" ]] || continue
        ms=$(connect_ms "$ip")
        [[ -n $ms ]] || continue
        if [[ -z $best_ms ]] || awk -v a="$ms" -v b="$best_ms" 'BEGIN{exit !(a < b)}'; then
            best="$slug $url" best_ms=$ms
        fi
    done < <(grep -v '^\s*\(#\|$\)' "$BENCH_DIR/downloads.txt")
    if [[ -n $best ]]; then echo "$best $best_ms"; else echo "refused no-point"; fi
}

# Parallel streams of one file for up to $2 seconds, 500 MB per stream at most (a byte range), so 1 GB in total.
# Two streams: some points (Hetzner) refuse a third connection from one IP.
# Prints Mbit/s, or "refused <code>" if the host refused a request.
streams_down() { # url seconds streams
    local url=$1 t=$2 n=$3 start i code
    start=$(now)
    for ((i = 1; i <= n; i++)); do
        curl -s -o /dev/null -A "$UA" -r 0-499999999 --max-time "$t" -w '%{http_code} %{size_download}\n' "$url" >"$WORK/stream.$i" &
    done
    wait
    code=$(awk '$1 != 200 && $1 != 206 && $1 != "000" {print $1; exit}' "$WORK"/stream.*)
    if [[ -n $code ]]; then
        echo "refused $code"
    else
        cat "$WORK"/stream.* | awk -v s="$start" -v e="$(now)" '{b+=$2} END{printf "%.1f", b*8/(e-s)/1000000}'
    fi
    rm -f "$WORK"/stream.*
}

download() { # url
    curl -s -o /dev/null -A "$UA" --max-time 6 -w '%{speed_download}' "$1" | awk '{printf "%.1f", $1*8/1000000}' || true
}

test_network() {
    local t slug url
    t=$(secs 8 4)
    head -c 25000000 /dev/urandom >"$WORK/up.bin"

    # Run once, to stay within Cloudflare's per-IP limit.
    TARGET=cloudflare REPEATS=1 measure network net_down "{\"streams\":4,\"time\":$t,\"max_bytes\":1000000000}" cf_speed down "$t" 4
    TARGET=cloudflare REPEATS=1 measure network net_up "{\"streams\":4,\"time\":$t,\"max_bytes\":1000000000}" cf_speed up "$t" 4
    rm -f "$WORK/up.bin"

    # The same download from the nearest point outside the server's own network: a speed figure that does not depend
    # on Cloudflare letting the IP in.
    local near
    read -r slug url near < <(near_point)
    if [[ $slug == refused ]]; then
        log "  No download point for net_down_near: $url"
        TARGET='' REPEATS=1 measure network net_down_near "{\"streams\":2,\"time\":$t,\"max_bytes\":1000000000}" echo "refused $url"
    else
        log "  Nearest download point in another network: $slug, $near ms"
        TARGET=$slug REPEATS=1 measure network net_down_near "{\"streams\":2,\"time\":$t,\"max_bytes\":1000000000,\"url\":\"$url\",\"connect_ms\":$near}" streams_down "$url" "$t" 2
    fi

    [[ $QUICK == 1 ]] && return
    while read -r slug url _; do
        TARGET=$slug REPEATS=1 measure network net_down_point '{"streams":1,"max_time":6}' download "$url"
    done < <(grep -v '^\s*\(#\|$\)' "$BENCH_DIR/downloads.txt")
}

# TCP connect time in ms, 10 samples. DNS is resolved first and not timed.
tcp_rtt() { # host port
    local ip i a b
    ip=$(getent ahostsv4 "$1" | awk 'NR==1{print $1}') || return
    for ((i = 0; i < 10; i++)); do
        a=$(now)
        timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$2" 2>/dev/null || continue
        b=$(now)
        awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f\n", (b-a)*1000}'
        sleep 0.2
    done
}

# Request time in ms on one keep-alive connection, 10 samples. The first request opens the connection and is
# not counted.
api_rtt() { # url
    local args=() i
    for ((i = 0; i < 11; i++)); do args+=(-o /dev/null "$1"); done
    curl -s -A "$UA" --max-time 20 -w '%{time_pretransfer} %{time_starttransfer} %{http_code}\n' "${args[@]}" |
        awk 'NR>1 && $3>0 && $3<500 {printf "%.2f\n", ($2-$1)*1000}'
}

test_latency() {
    local slug kind address samples
    mkdir -p "$WORK/latency"
    # Up to 8 targets in parallel. The connections are small and do not affect each other.
    while read -r slug kind address _; do
        while (($(jobs -rp | wc -l) >= 8)); do wait -n; done
        if [[ $kind == tcp ]]; then
            tcp_rtt "${address%:*}" "${address##*:}" >"$WORK/latency/$slug" &
        else
            api_rtt "$address" >"$WORK/latency/$slug" &
        fi
    done < <(grep -v '^\s*\(#\|$\)' "$BENCH_DIR/targets.txt")
    wait

    while read -r slug kind address _; do
        mapfile -t samples <"$WORK/latency/$slug"
        if [[ $kind == tcp ]]; then
            TARGET=$slug record latency latency_tcp "{\"address\":\"$address\",\"count\":10}" 0 "${samples[@]}"
        else
            TARGET=$slug record latency latency_api "{\"url\":\"$address\",\"count\":10}" 0 "${samples[@]}"
        fi
    done < <(grep -v '^\s*\(#\|$\)' "$BENCH_DIR/targets.txt")
    rm -rf "$WORK/latency"

    # Save the route to two public resolvers next to the results.
    for address in 1.1.1.1 8.8.8.8; do
        mtr --report --report-wide --report-cycles 10 --no-dns "$address" >"$OUT/mtr-$address.txt" 2>&1 || true
    done
}
