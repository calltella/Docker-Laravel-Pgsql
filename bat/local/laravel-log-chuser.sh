#!/bin/bash

# Laravelログをローテートするとユーザーがrootになるので対策
#

set -e

# ユーザーディレクトリを取得
USER_DIRECTORY=~

# envファイルから環境変数を読込
source "${USER_DIRECTORY}/Docker-Laravel-Pgsql/.env"

LARAVEL_CONTAINER_ID=$(docker ps -q --filter name=$LARAVEL_CONTAINER_NAME)
echo "Container $LARAVEL_CONTAINER_NAME is running with ID: $LARAVEL_CONTAINER_ID"

# Laravelログの所有者を変更
docker exec $LARAVEL_CONTAINER_ID chown -R nginx:nginx /var/www/html/storage/logs/
echo "Laravel logs ownership changed to nginx:nginx"

# Nginxログの所有者を変更
docker exec $LARAVEL_CONTAINER_ID chown -R nginx:nginx /var/log
echo "Nginx logs ownership changed to nginx:nginx"