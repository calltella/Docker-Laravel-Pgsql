FROM php:8.3-cli
# Laravel（php-fpm）と Scheduler（CLI）は分けるべき
# Laravel 公式ドキュメントも scheduler 分離を推奨

RUN apt-get update && \
    apt-get install -y \
        libpq-dev \
        unzip \
        zip \
        libzip-dev \
        postgresql-client && \
    docker-php-ext-install zip pdo pdo_pgsql

# Composer インストール
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html/laravel

CMD ["sh", "-c", "while true; do php artisan schedule:run; sleep 60; done"]
