#!/bin/bash

# Dockerが起動している事が前提
# 毎日１２時に起動
# FJ001からバックアップファイルをコピーしてきて
# 開発環境のproductionデータベースにインポート
# 特定のテーブルのみdevelopmentデータベースにコピー

# 添付ファイルの最新化

set -e

# envファイルから環境変数を読込
source ../../.env

# コンテナのIDを取得
CONTAINER_ID=$(docker ps -q --filter name=$DATABASE_CONTAINER_NAME)

# コンテナが起動しているか確認
if [ -z "$CONTAINER_ID" ]; then
  echo "Container $DATABASE_CONTAINER_NAME is not running."
  exit 1  # 終了コード 1 でスクリプトを終了
else
  echo "Container $DATABASE_CONTAINER_NAME is running with ID: $CONTAINER_ID"
fi

# カレントディレクトリを変更
cd /home/ec2-user/Docker-Laravel-Pgsql/export/pgsql

# 不要なファイルを削除
find /home/ec2-user/Docker-Laravel-Pgsql/export/pgsql -name "production-dbdump-*.zip" -type f -exec rm -f {} \;

# 本番環境からファイルをコピー
scp sailpreserver20:/home/ec2-user/Docker-Laravel-Pgsql/export/DailyBackup/production-dbdump-*.zip /home/ec2-user/Docker-Laravel-Pgsql/export/pgsql


ZIP_FILE=$(find . -type f -name "*$(date +%Y%m%d --date '1 day ago')*zip")
echo $ZIP_FILE
unzip -P $PRODUCTION_ZIPFILE_PASSWORD $ZIP_FILE
rm $ZIP_FILE

ARCHIVE=$(find . -type f -name *`date +%Y%m%d --date '1 day ago'`*)
echo $ARCHIVE

# バックアップを開発環境のPostgreSQLにリストア
docker exec postgres bash -c "psql -U postgres -f /tmp/pgsql/$ARCHIVE -d production"

# table development database copy
copy_table_to_development() {
    TABLE=$1
    docker exec postgres bash -c "pg_dump -c --if-exists -U postgres -t $TABLE production > /tmp/pgsql/production_$TABLE.dump"
    docker exec postgres bash -c "psql -U postgres -d development < /tmp/pgsql/production_$TABLE.dump"
}

copy_table_to_development "poshelp_desk"
copy_table_to_development "apline_base_model"
copy_table_to_development "apline_file_store"

# phpipamテーブルコピー
copy_table_to_development "phpipam_subnet_table"

docker exec postgres bash -c "rm -f /tmp/pgsql/*.dump"
docker exec postgres bash -c "rm -f /tmp/pgsql/*.zip"
docker exec postgres bash -c "rm -f /tmp/pgsql/$ARCHIVE"
