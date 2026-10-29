# Runner image. All tools are installed here at fixed versions, so results depend on the server only.
# Published as ghcr.io/vpscast/bench, and run.sh pins it by digest. Ubuntu 26.04 LTS has recent tool versions
# and gets security updates until 2031.
FROM ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl jq bc util-linux bsdextrautils iproute2 iputils-ping mtr-tiny \
        sysbench 7zip fio wrk \
        nginx php8.5-fpm php8.5-cli php8.5-mbstring php8.5-xml php8.5-curl php8.5-zip unzip \
        postgresql-18 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=docker:29.9-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:29.9-cli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
COPY --from=composer:2.10 /usr/bin/composer /usr/local/bin/composer

# Laravel starter app for the web and build tests. Production settings, no sessions or cache stored between requests.
RUN composer create-project --no-dev --no-interaction --prefer-dist laravel/laravel:13.* /opt/app \
    && cd /opt/app \
    && sed -i -e 's/^APP_ENV=.*/APP_ENV=production/' -e 's/^APP_DEBUG=.*/APP_DEBUG=false/' \
        -e 's/^SESSION_DRIVER=.*/SESSION_DRIVER=array/' -e 's/^CACHE_STORE=.*/CACHE_STORE=array/' \
        -e 's/^LOG_CHANNEL=.*/LOG_CHANNEL=null/' .env \
    && { echo '<!doctype html><title>static</title><pre>'; yes 'VPScast static test page, 10 KB.' | head -c 10000; } >public/static.html \
    && php artisan optimize && php artisan view:cache \
    && chown -R www-data:www-data storage bootstrap/cache

COPY . /opt/bench
# Git commit of the build, passed by CI. Local builds report "dev".
ARG GIT_SHA=dev
ENV RUNNER_GIT_SHA=$GIT_SHA
ENTRYPOINT ["/opt/bench/bench.sh"]
