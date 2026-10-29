FROM php:8.4-cli-alpine

# 同期ジョブの実行用。ビルドツールは同じレイヤー内で削除する。
RUN apk add --no-cache libpq oniguruma libzip \
    && apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS postgresql-dev oniguruma-dev libzip-dev \
    && docker-php-ext-install -j$(nproc) pdo_pgsql mbstring pcntl zip \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps \
    && rm -rf /tmp/pear

COPY ./infra/php/php.ini /usr/local/etc/php/php.ini

WORKDIR /var/www/html/laravel

RUN addgroup -g 1000 www \
    && adduser -u 1000 -D -G www www \
    && chown www:www /var/www/html/laravel

USER www
