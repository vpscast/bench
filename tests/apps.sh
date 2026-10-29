# Application tests: nginx with a static page and a Laravel page (PHP-FPM, OPcache) under wrk, PostgreSQL with
# pgbench, and a Docker build of a Laravel app.

wrk_rps() { # path seconds
    wrk -t2 -c64 -d"$2"s "http://127.0.0.1:8088$1" | awk '/^Requests\/sec/{printf "%.0f", $2}'
}

test_web() {
    local t
    t=$(secs 10 5)
    sed "s/__CHILDREN__/$((NPROC * 2))/" "$BENCH_DIR/fixtures/web/php-fpm.conf" >/run/php-bench.conf
    if ! php-fpm8.5 -y /run/php-bench.conf || ! nginx -c "$BENCH_DIR/fixtures/web/nginx.conf"; then
        skipped web "nginx or php-fpm did not start"
        return
    fi
    sleep 1
    if [[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8088/) != 200 ]]; then
        skipped web "the Laravel page does not answer 200"
    else
        wrk -t2 -c64 -d2s http://127.0.0.1:8088/ >/dev/null # warms OPcache
        measure web web_static "{\"client\":\"wrk\",\"threads\":2,\"connections\":64,\"time\":$t}" wrk_rps /static.html "$t"
        measure web web_php "{\"client\":\"wrk\",\"threads\":2,\"connections\":64,\"time\":$t,\"fpm_children\":$((NPROC * 2)),\"app\":\"laravel welcome\"}" wrk_rps / "$t"
    fi
    nginx -c "$BENCH_DIR/fixtures/web/nginx.conf" -s stop
    kill "$(cat /run/php-bench.pid)"
}

PG=/usr/lib/postgresql/18/bin
pg() { runuser -u postgres -- "$@"; }

pgbench_tps() { # seconds [-S]
    pg pgbench -h "$WORK/pgsock" -c "$((NPROC * 2))" -j "$NPROC" -T "$1" "${@:2}" bench | awk '/^tps/{printf "%.0f", $3}'
}

test_db() {
    local t scale mem shared
    t=$(secs 20 5)
    scale=$([[ $QUICK == 1 ]] && echo 10 || echo 50)
    mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    shared=$((mem / 4 > 4096 ? 4096 : mem / 4))
    mkdir -p "$WORK/pg" "$WORK/pgsock" && chown postgres "$WORK/pg" "$WORK/pgsock"
    pg $PG/initdb -D "$WORK/pg" -A trust -U postgres >/dev/null || { skipped db "initdb failed"; return; }
    pg $PG/pg_ctl -D "$WORK/pg" -l "$WORK/pgsock/log" -w start \
        -o "-k $WORK/pgsock -c listen_addresses='' -c shared_buffers=${shared}MB -c max_connections=200" >/dev/null ||
        { skipped db "postgres did not start"; return; }
    pg createdb -h "$WORK/pgsock" bench
    log "db: pgbench -i -s $scale (shared_buffers ${shared}MB)"
    pg pgbench -h "$WORK/pgsock" -i -q -s "$scale" bench >/dev/null 2>&1

    local params="{\"scale\":$scale,\"clients\":$((NPROC * 2)),\"threads\":$NPROC,\"time\":$t,\"shared_buffers_mb\":$shared}"
    measure db db_pgbench_rw "$params" pgbench_tps "$t"
    measure db db_pgbench_ro "$params" pgbench_tps "$t" -S
    pg $PG/pg_ctl -D "$WORK/pg" -m fast stop >/dev/null
    rm -rf "$WORK/pg" "$WORK/pgsock"
}

# Builds a Laravel app image: compiles PHP extensions, copies the app, builds its caches. The base image is pulled
# before timing starts and vendor/ is included, so the build does not use the network.
BUILD_BASE=php:8.5-cli-trixie@sha256:acaa95199b53a1d7c346dddc7bcfc367ef3bd21ab832bd178eac7f043ed5396c
BUILD_TAG=vpscast-bench-build:tmp

docker_build_secs() {
    local a b
    a=$(now)
    DOCKER_BUILDKIT=1 docker build -q --no-cache --pull=false --build-arg BASE="$BUILD_BASE" -t "$BUILD_TAG" "$WORK/build" >/dev/null || return 1
    b=$(now)
    docker image rm -f "$BUILD_TAG" >/dev/null
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%.1f", b-a}'
}

test_build() {
    if ! docker version >/dev/null 2>&1; then
        skipped build "no Docker socket (run.sh mounts it)"
        return
    fi
    local had_base=1
    docker image inspect "$BUILD_BASE" >/dev/null 2>&1 || had_base=0
    log "build: pulling $BUILD_BASE (not timed)"
    docker pull -q "$BUILD_BASE" >/dev/null || { skipped build "cannot pull the base image"; return; }
    mkdir -p "$WORK/build"
    cp "$BENCH_DIR/fixtures/build/Dockerfile" "$WORK/build/"
    cp -a /opt/app "$WORK/build/app"
    cp /usr/local/bin/composer "$WORK/build/"

    TOOL_VERSION=$(docker version --format '{{.Server.Version}}') measure build docker_build_laravel "{\"base\":\"$BUILD_BASE\",\"no_cache\":true}" docker_build_secs
    rm -rf "$WORK/build"
    [[ $had_base == 0 ]] && docker image rm "$BUILD_BASE" >/dev/null 2>&1
    true
}
