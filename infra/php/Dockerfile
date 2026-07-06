FROM php:8.4-fpm-alpine

RUN apk add --no-cache \
    git curl zip unzip \
    libpng-dev \
    libzip-dev \
    postgresql-dev \
    icu-dev \
    openssl-dev \
    imap-dev \
    krb5-dev \
    oniguruma-dev \
    autoconf \
    g++ \
    make \
    sudo \
    nodejs npm

# PHP拡張インストール（imap以外）
RUN docker-php-ext-install -j$(nproc) \
        pdo_pgsql \
        pdo_mysql \
        mbstring \
        exif \
        pcntl \
        bcmath \
        gd \
        zip \
        intl

# imap は PHP 8.4 で PECL に移行
RUN pecl install imap \
 && docker-php-ext-enable imap

# redis
RUN pecl install redis \
    && docker-php-ext-enable redis

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

COPY ./infra/php/php.ini /usr/local/etc/php/php.ini

WORKDIR /var/www/html/laravel

RUN addgroup -g 1000 www && \
    adduser -u 1000 -D -G www www && \
    chown -R www:www /var/www/html/laravel

RUN echo "www ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/www \
    && chmod 0440 /etc/sudoers.d/www

USER www