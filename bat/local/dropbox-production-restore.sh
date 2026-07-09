#!/bin/bash

# 本番環境のデータベースを開発環境にコピーする
# Cronで app:restore-database-command を実行することで
# Dropboxからファイルをダウンロードしproductionデータベースにインポート
# 特定のテーブルのみdevelopmentデータベースにコピー
#

# 添付ファイルの最新化

set -e

# ユーザーディレクトリを取得
USER_DIRECTORY=~

# envファイルから環境変数を読込
source "${USER_DIRECTORY}/Docker-Laravel-Pgsql/.env"

# コンテナのIDを取得
LARAVEL_CONTAINER_ID=$(docker ps -q --filter name=$LARAVEL_CONTAINER_NAME)

# コンテナが起動しているか確認
if [ -z "$LARAVEL_CONTAINER_ID" ]; then
  echo "Container $LARAVEL_CONTAINER_ID is not running."
  exit 1  # 終了コード 1 でスクリプトを終了
else
  echo "Container $LARAVEL_CONTAINER_ID is running with ID: $LARAVEL_CONTAINER_ID"
fi

# dropboxからデータベースをレストア
docker exec $LARAVEL_CONTAINER_ID bash -c "php artisan app:restore-database-command"

