# Network tests, over IPv4: download and upload to the nearest Cloudflare node, download from the nearest neutral
# point outside the server's network (near.txt), downloads from fixed points on each continent (downloads.txt), and
# latency to the targets in targets.txt.

CF=https://speed.cloudflare.com
UA="vpscast-bench/$BENCH_VERSION (+https://github.com/vpscast/bench)"

# Runs parallel streams of 25 MB requests for up to $2 seconds, at most 250 MB per stream. Uploads are read from the
# file as they go (-T), not loaded into memory, so four streams fit a 512 MB server. Cloudflare limits the
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
                    read -r code bytes after < <(curl -4 -s -o /dev/null -A "$UA" --max-time "$left" -w '%{http_code} %{size_download} %header{retry-after}\n' "$CF/__down?bytes=25000000")
                else
                    read -r code bytes after < <(curl -4 -s -o /dev/null -A "$UA" --max-time "$left" -H 'Expect:' -w '%{http_code} %{size_upload} %header{retry-after}\n' -X POST -T "$WORK/up.bin" "$CF/__up")
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

# A RIPEstat answer field, asked twice before giving up. Empty if both fail.
ripestat() { # path jq-filter
    local out i
    for i in 1 2; do
        out=$(curl -4 -s -A "$UA" --max-time 10 "https://stat.ripe.net/data/$1" | jq -r "$2 // empty" 2>/dev/null) || true
        [[ -n $out ]] && { echo "$out"; return; }
        sleep 2
    done
}

# The network the server is in, as RIPEstat names the holder of its AS ("HETZNER-AS Hetzner Online GmbH"). The public
# IPv4 address is read from the route when the server has it on an interface, as cloud servers usually do. Empty if
# the lookup fails.
own_network() {
    local ip as
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
    if [[ -z $ip || $ip =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; then
        ip=$(ripestat whats-my-ip/data.json .data.ip)
    fi
    [[ -n $ip ]] || return 0
    as=$(ripestat "network-info/data.json?resource=$ip" '.data.asns[0]')
    [[ -n $as ]] || return 0
    ripestat "as-overview/data.json?resource=AS$as" .data.holder
}

# One TCP connect time in ms, nothing if the host does not answer in 3 s. The clock is read in the child shell right
# around the connect, so starting the processes is not counted: timed from outside, that added 4 to 7 ms on a fast
# desktop and more on a slow vCPU (latency 2.x).
tcp_connect() { # ip port
    # shellcheck disable=SC2016
    timeout 3 bash -c 'a=$EPOCHREALTIME; exec 3<>"/dev/tcp/$1/$2" && echo "$a $EPOCHREALTIME"' _ "$1" "$2" 2>/dev/null |
        awk '{printf "%.2f\n", ($2 - $1) * 1000}'
}

# Median TCP connect time in ms over 3 samples, or nothing if the host does not answer.
connect_ms() { # ip port
    local i
    for ((i = 0; i < 3; i++)); do tcp_connect "$1" "$2"; done | sort -n | awk '{v[NR]=$1} END{if (NR) print v[int((NR+1)/2)]}'
}

# Picks the point of near.txt with the lowest connect time, skipping points whose owner runs the server's network
# (that would be the provider's internal speed). Prints "<slug> <url> <ms>", or "refused no-point".
near_point() { # own network
    local network=${1,,} slug owner url host port ip ms best='' best_ms=''
    while read -r slug owner url _; do
        [[ -n $network && $network == *"$owner"* ]] && continue
        host=${url#*://}
        host=${host%%/*}
        port=80
        [[ $url == https://* ]] && port=443
        ip=$(getent ahostsv4 "$host" | awk 'NR==1{print $1}') || continue
        [[ -n $ip ]] || continue
        ms=$(connect_ms "$ip" "$port")
        [[ -n $ms ]] || continue
        if [[ -z $best_ms ]] || awk -v a="$ms" -v b="$best_ms" 'BEGIN{exit !(a < b)}'; then
            best="$slug $url" best_ms=$ms
        fi
    done < <(grep -v '^\s*\(#\|$\)' "$BENCH_DIR/near.txt")
    if [[ -n $best ]]; then echo "$best $best_ms"; else echo "refused no-point"; fi
}

# Parallel streams of one file for up to $2 seconds, 500 MB per stream at most (a byte range), so 1 GB in total.
# Two streams: some points (Hetzner) refuse a third connection from one IP.
# Prints Mbit/s, or "refused <code>" if the host refused a request.
streams_down() { # url seconds streams
    local url=$1 t=$2 n=$3 start i code
    start=$(now)
    for ((i = 1; i <= n; i++)); do
        curl -4 -s -o /dev/null -A "$UA" -r 0-499999999 --max-time "$t" -w '%{http_code} %{size_download}\n' "$url" >"$WORK/stream.$i" &
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
    curl -4 -s -o /dev/null -A "$UA" --max-time 6 -w '%{speed_download}' "$1" | awk '{printf "%.1f", $1*8/1000000}' || true
}

test_network() {
    local t slug url
    t=$(secs 8 4)
    head -c 25000000 /dev/urandom >"$WORK/up.bin"

    # Run once, to stay within Cloudflare's per-IP limit.
    TARGET=cloudflare REPEATS=1 measure network net_down "{\"streams\":4,\"time\":$t,\"max_bytes\":1000000000,\"ip\":4}" cf_speed down "$t" 4
    TARGET=cloudflare REPEATS=1 measure network net_up "{\"streams\":4,\"time\":$t,\"max_bytes\":1000000000,\"ip\":4}" cf_speed up "$t" 4
    rm -f "$WORK/up.bin"

    # The same download from the nearest neutral point outside the server's network: a speed figure that does not
    # depend on Cloudflare letting the IP in. How far the point is goes into params; what counts as near is the
    # reader's call.
    local network near params
    network=$(own_network)
    read -r slug url near < <(near_point "$network")
    params=$(jq -cn --argjson t "$t" --arg network "$network" '{streams: 2, time: $t, max_bytes: 1000000000, ip: 4, network: ($network | if . == "" then null else . end)}')
    if [[ $slug == refused ]]; then
        log "  No download point for net_down_near: $url"
        TARGET='' REPEATS=1 measure network net_down_near "$params" echo "refused $url"
    else
        log "  Nearest neutral download point: $slug, $near ms"
        params=$(jq -c --arg url "$url" --argjson ms "$near" '. + {url: $url, connect_ms: $ms}' <<<"$params")
        # Repeated like the other tests: one download of 1 GB lasts under a second on a fast link and varies a lot.
        TARGET=$slug measure network net_down_near "$params" streams_down "$url" "$t" 2
    fi

    [[ $QUICK == 1 ]] && return
    while read -r slug url _; do
        TARGET=$slug REPEATS=1 measure network net_down_point '{"streams":1,"max_time":6,"ip":4}' download "$url"
    done < <(grep -v '^\s*\(#\|$\)' "$BENCH_DIR/downloads.txt")
}

# TCP connect time in ms, 10 samples. DNS is resolved first and not timed.
tcp_rtt() { # host port
    local ip i
    ip=$(getent ahostsv4 "$1" | awk 'NR==1{print $1}') || return
    for ((i = 0; i < 10; i++)); do
        tcp_connect "$ip" "$2"
        sleep 0.2
    done
}

# Request time in ms on one keep-alive connection over IPv4, 10 samples. The first request opens the connection and is
# not counted. Only 2xx answers count: a 403, 429 or 451 comes from the CDN in front of the API (Binance answers 451 to
# US addresses at the edge) and says nothing about the way to the exchange. With a body the requests are POSTs: the CDN
# in front of some APIs answers a GET from its cache, but never a POST.
api_rtt() { # url [json body]
    local args=() i
    for ((i = 0; i < 11; i++)); do args+=(-o /dev/null "$1"); done
    [[ -n ${2:-} ]] && args+=(-X POST -H 'Content-Type: application/json' -d "$2")
    curl -4 -s -A "$UA" --max-time 20 -w '%{time_pretransfer} %{time_starttransfer} %{http_code}\n' "${args[@]}" |
        awk 'NR>1 && $3>=200 && $3<300 {printf "%.2f\n", ($2-$1)*1000}'
}

test_latency() {
    local slug kind address samples
    mkdir -p "$WORK/latency"
    # Up to 8 targets in parallel. The connections are small and do not affect each other.
    while read -r slug kind address body _; do
        while (($(jobs -rp | wc -l) >= 8)); do wait -n; done
        if [[ $kind == tcp ]]; then
            tcp_rtt "${address%:*}" "${address##*:}" >"$WORK/latency/$slug" &
        elif [[ $kind == post ]]; then
            api_rtt "$address" "$body" >"$WORK/latency/$slug" &
        else
            api_rtt "$address" >"$WORK/latency/$slug" &
        fi
    done < <(grep -v '^\s*\(#\|$\)' "$BENCH_DIR/targets.txt")
    wait

    while read -r slug kind address _; do
        mapfile -t samples <"$WORK/latency/$slug"
        if [[ $kind == tcp ]]; then
            TARGET=$slug record latency latency_tcp "{\"address\":\"$address\",\"count\":10,\"ip\":4}" 0 "${samples[@]}"
        else
            TARGET=$slug record latency latency_api "$(jq -cn --arg url "$address" --arg method "$([[ $kind == post ]] && echo POST || echo GET)" '{url: $url, method: $method, count: 10, ip: 4}')" 0 "${samples[@]}"
        fi
    done < <(grep -v '^\s*\(#\|$\)' "$BENCH_DIR/targets.txt")
    rm -rf "$WORK/latency"

    # Save the route to two public resolvers next to the results.
    for address in 1.1.1.1 8.8.8.8; do
        mtr --report --report-wide --report-cycles 10 --no-dns "$address" >"$OUT/mtr-$address.txt" 2>&1 || true
    done
}
