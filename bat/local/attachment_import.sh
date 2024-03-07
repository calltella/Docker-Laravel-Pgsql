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

# 今年を採取


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

# 本番環境の添付ファイル群を取得
ssh sailpreserver20 "${USER_DIRECTORY}/Docker-Laravel-Pgsql/bat/production/production_attachment_import.sh ${CURRENT_YEAR}" # 本番環境の添付ファイルをZIP圧縮

# 本番環境からファイルをコピー
scp "sailpreserver20:${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/archive${CURRENT_YEAR}.zip" "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export"




# フォルダ移動
cd "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export"




# 解凍したフォルダが存在してなければ解凍してファイルを移動
if [ ! -d "${CURRENT_YEAR}/" ]; then
    unzip "archive${CURRENT_YEAR}.zip" > /dev/null
    echo "exec unzip"
    docker exec $CONTAINER_ID bash -c "rm -rf /var/www/html/storage/app/apline/${CURRENT_YEAR}"
    docker exec $CONTAINER_ID bash -c "rm -f /home/export/archive${CURRENT_YEAR}.zip"
    docker exec $CONTAINER_ID bash -c "mv /home/export/${CURRENT_YEAR} /var/www/html/storage/app/apline/${CURRENT_YEAR}"
    echo "attachfile moved"
fi

# 権限の変更
docker exec $CONTAINER_ID bash -c "chown -R docker:docker /var/www/html/storage/app/apline/${CURRENT_YEAR}"
docker exec $CONTAINER_ID bash -c "find /var/www/html/storage/app/apline -type d -print | xargs chmod 751"
docker exec $CONTAINER_ID bash -c "find /var/www/html/storage/app/apline -type f -print | xargs chmod 644"

exit 0

