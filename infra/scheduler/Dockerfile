FROM php:8.4-cli-bookworm
# Laravel（php-fpm）と Scheduler（CLI）は分けるべき
# Laravel 公式ドキュメントも scheduler 分離を推奨

RUN apt-get update && \
    apt-get install -y \
        libpq-dev \
        unzip \
        zip \
        libzip-dev \
        libc-client-dev \
        libkrb5-dev \
        postgresql-client && \
    docker-php-ext-install zip pdo pdo_pgsql && \
    pecl install imap && \
    docker-php-ext-enable imap

# Composer インストール
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html/laravel

CMD ["sh", "-c", "exec php artisan schedule:work"]