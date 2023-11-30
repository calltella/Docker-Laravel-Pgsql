FROM tangramor/nginx-php8-fpm:php8.2.12_node21.1.0

ARG USER=docker

RUN apk --no-cache add \
    make        \
    gcc         \
    g++         \
    musl-dev    \
    binutils    \
    autoconf    \
    automake    \
    libtool     \
    pkgconfig   \
    check-dev   \
    file        \
    patch       \
    sudo

# nginx.conf コピー
COPY ./infra/nginx/*.conf /etc/nginx/conf.d/

# php.ini コピー
COPY ./infra/php/php.ini /usr/local/etc/php/php.ini

# 一般ユーザー追加
# php artisan でファイル作成時にrootで作成されるので
# ログイン後に’su docker’で利用
RUN adduser -D $USER \
        && echo "$USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER \
        && chmod 0440 /etc/sudoers.d/$USER

# 起動ユーザーを一般ユーザーにするとnginx起動しなくなる
