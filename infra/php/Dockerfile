FROM tangramor/nginx-php8-fpm:php8.2.12_node21.1.0

ENV USER_NAME=docker
ENV USER_ID=1000
ENV GROUP_ID=1000

# https://github.com/tangramor/nginx-php8-fpm
ENV TZ Asia/Tokyo

ENV WEBROOT /var/www/html/public

RUN apk add --no-cache --virtual .build-deps gcc g++ libc-dev make \
    && apk del .build-deps

COPY ./infra/nginx/*.conf /etc/nginx/conf.d/

COPY ./infra/php/php.ini /usr/local/etc/php/php.ini

# artisan コマンド使うときやcomposerやnpmつかう時に一般ユーザーないと困るので作成
# コンテナ自体を一般ユーザーで稼働させるのは可能ではあるがイメージを1からつくらないといけないので面倒
RUN addgroup -S -g "${GROUP_ID}" "${USER_NAME}" && \
    adduser -u "${USER_ID}" -G "${USER_NAME}" -D "${USER_NAME}"
