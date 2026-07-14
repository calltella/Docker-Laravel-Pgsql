FROM php:8.4-cli-bookworm
# Laravel（php-fpm）と Scheduler（CLI）は分けるべき
# Laravel 公式ドキュメントも scheduler 分離を推奨

RUN apt-get update && \
    apt-get install -y \
        libpq-dev \
        iputils-ping \
        unzip \
        zip \
        libzip-dev \
        libc-client-dev \
        libkrb5-dev \
        wget \
        gnupg \
        lsb-release && \
    # PostgreSQL公式リポジトリを追加
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
        gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg && \
    apt-get update && \
    apt-get install -y postgresql-client-16 && \
    docker-php-ext-install zip pdo pdo_pgsql && \
    pecl install imap && \
    docker-php-ext-enable imap

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html/laravel

CMD ["sh", "-c", "exec php artisan schedule:work"]