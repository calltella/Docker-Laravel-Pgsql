FROM tangramor/nginx-php8-fpm

RUN apk --no-cache add make gcc g++ musl-dev binutils autoconf automake libtool pkgconfig check-dev file patch

COPY ./infra/nginx/*.conf /etc/nginx/conf.d/
