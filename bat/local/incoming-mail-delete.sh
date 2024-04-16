#!/bin/sh

# 添付ファイルの最新化
set -e

# コマンドライン引数の取得
arg1=$1

# 引数がなかった場合は今年をセット
if [ -z "$arg1" ]; then
  CURRENT_YEAR=$(date +'%Y')
else
  CURRENT_YEAR=$arg1
fi

# ユーザーディレクトリを取得
USER_DIRECTORY=~

# envファイルから環境変数を読込
source "${USER_DIRECTORY}/Docker-Laravel-Pgsql/.env"

# コンテナIDを取得
CONTAINER_ID=$(docker ps -q --filter name=$LARAVEL_CONTAINER_NAME)

# コンテナが起動しているか確認
if [ -z "$CONTAINER_ID" ]; then
  echo "Container $LARAVEL_CONTAINER_NAME is not running."
  exit 1  # 終了コード 1 でスクリプトを終了
else
  echo "Container $LARAVEL_CONTAINER_NAME is running with ID: $CONTAINER_ID"
fi

# フォルダ移動
MAILPATH=${USER_DIRECTORY}/apline_laravel10/storage/app/mailrcv

# ファイル一覧を取得してループ処理
for file in $MAILPATH/*; do
    # ファイルを削除
    rm -f "$file"
done

exit 0
