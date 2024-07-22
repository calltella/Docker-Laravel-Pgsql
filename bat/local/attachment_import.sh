#!/bin/sh
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

# 本番環境の添付ファイル群を取得
ssh preserver30 "${USER_DIRECTORY}/Docker-Laravel-Pgsql/bat/production/production_attachment_import.sh ${CURRENT_YEAR}"

# 本番環境からファイルをコピー
scp "preserver30:${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/archive${CURRENT_YEAR}.zip" "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export"
scp "preserver30:${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/filestore.zip" "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export"

# 解凍したフォルダが存在してなければ解凍してファイルを移動
if [ ! -d "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/${CURRENT_YEAR}" ]; then
    unzip -d "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export" "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/archive${CURRENT_YEAR}.zip" > /dev/null
    echo "exec unzip"
    docker exec $CONTAINER_ID bash -c "rm -rf /var/www/html/storage/app/apline/${CURRENT_YEAR}"
    docker exec $CONTAINER_ID bash -c "rm -f /home/export/archive${CURRENT_YEAR}.zip"
    docker exec $CONTAINER_ID bash -c "mv /home/export/home/ec2-user/apline_laravel10/storage/app/apline/${CURRENT_YEAR} /var/www/html/storage/app/apline/${CURRENT_YEAR}"
    docker exec $CONTAINER_ID bash -c "rm -rf /home/export/home"
    echo "attachfile moved"
fi

# 権限の変更
docker exec $CONTAINER_ID bash -c "chown -R docker:docker /var/www/html/storage/app/apline/${CURRENT_YEAR}"
docker exec $CONTAINER_ID bash -c "find /var/www/html/storage/app/apline -type d -print | xargs chmod 751"
docker exec $CONTAINER_ID bash -c "find /var/www/html/storage/app/apline -type f -print | xargs chmod 644"

# 解凍したフォルダが存在してなければ解凍してファイルを移動
if [ ! -d "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/filestore" ]; then
    unzip -d "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export" "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/filestore.zip" > /dev/null
    echo "exec unzip filestore.zip"
    docker exec $CONTAINER_ID bash -c "rm -rf /var/www/html/storage/app/filestore"
    docker exec $CONTAINER_ID bash -c "rm -f /home/export/filestore.zip"
    docker exec $CONTAINER_ID bash -c "mv /home/export/home/ec2-user/apline_laravel10/storage/app/filestore /var/www/html/storage/app/filestore"
    docker exec $CONTAINER_ID bash -c "rm -rf /home/export/home"
    echo "attachfile moved"
fi

# 権限の変更
docker exec $CONTAINER_ID bash -c "chown -R docker:docker /var/www/html/storage/app/filestore"
docker exec $CONTAINER_ID bash -c "find /var/www/html/storage/app/filestore -type d -print | xargs chmod 751"
docker exec $CONTAINER_ID bash -c "find /var/www/html/storage/app/filestore -type f -print | xargs chmod 644"

exit 0

