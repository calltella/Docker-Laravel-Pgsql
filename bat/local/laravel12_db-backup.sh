#!/bin/bash

# 開発環境データベースをファイルにダンプ
# 本番環境にファイルを移動してレストア
# 
# 
#

set -e

# ユーザーディレクトリを取得
USER_DIRECTORY=~

# envファイルから環境変数を読込
source "${USER_DIRECTORY}/Docker-Laravel-Pgsql/.env"

# コンテナのIDを取得
DATABASE_CONTAINER_ID=$(docker ps -q --filter name=$DATABASE_CONTAINER_NAME)

# コンテナが起動しているか確認
if [ -z "$DATABASE_CONTAINER_ID" ]; then
  echo "Container $DATABASE_CONTAINER_NAME is not running."
  exit 1  # 終了コード 1 でスクリプトを終了
else
  echo "Container $DATABASE_CONTAINER_NAME is running with ID: $DATABASE_CONTAINER_ID"
fi

docker exec "$DATABASE_CONTAINER_ID" pg_dump -U postgres -d laravel12 -Fc -f /tmp/pgsql/laravel12.dump

