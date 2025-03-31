#!/bin/bash

# Laravelログをローテートするとユーザーがrootになるので対策
#

set -e

# ユーザーディレクトリを取得
USER_DIRECTORY=~

# envファイルから環境変数を読込
source "${USER_DIRECTORY}/Docker-Laravel-Pgsql/.env"

LARAVEL_CONTAINER_ID=$(docker ps -q --filter name=$LARAVEL_CONTAINER_NAME)

# Laravelログの所有者を変更
docker exec -it $LARAVEL_CONTAINER_ID chown -R nginx:nginx /var/www/html/storage/logs/

# ngixnログの所有者を変更
docker exec -it $LARAVEL_CONTAINER_ID chown -R nginx:nginx /var/log



