FROM tangramor/nginx-php8-fpm
# https://github.com/tangramor/nginx-php8-fpm
ENV TZ Asia/Tokyo

ENV WEBROOT /var/www/html/public

RUN apk add --no-cache --virtual .build-deps gcc g++ libc-dev make \
    && apk del .build-deps

COPY ./infra/nginx/*.conf /etc/nginx/conf.d/

COPY ./infra/php/php.ini /usr/local/etc/php/php.ini
