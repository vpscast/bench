# Image built by the build test. Typical steps of a Laravel project's Dockerfile, without network access.
ARG BASE
FROM ${BASE}
RUN docker-php-ext-install -j"$(nproc)" bcmath pcntl pdo_mysql sockets exif
COPY composer /usr/local/bin/composer
COPY app /app
WORKDIR /app
RUN composer dump-autoload --optimize --no-dev --no-interaction \
    && php artisan optimize \
    && php artisan view:cache
