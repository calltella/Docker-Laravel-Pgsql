#!/bin/bash

# Laravelログをローテートするとユーザーがrootになるので対策
# 夜間に実行していたがパソコン電源断するとAplineが使用できなくなるので毎時実行に変更
# crontabの設定例
# 毎時実行する場合は以下のように設定
# 0 * * * * /home/ec2-user/Docker-Laravel-Pgsql/bat/local/laravel-log-chuser.sh >> /tmp/cron.log 2>&1
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