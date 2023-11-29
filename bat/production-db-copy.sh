#!/bin/sh

# Dockerが起動している事が前提
# 毎日１２時に起動
# FJ001からバックアップファイルをコピーしてきて
# 開発環境のproductionデータベースにインポート
# 特定のテーブルのみdevelopmentデータベースにコピー

# 添付ファイルの最新化

set -e

cd /home/ec2-user/Docker-Laravel-Pgsql/export/psql

# 不要なファイルを削除
cd ~/Docker-Laravel-Pgsql/export/psql && find ~/Docker-Laravel-Pgsql/export/psql -name "production*" -type f -exec rm -f {} \;

# 本番環境からファイルをコピー
scp sailpreserver20:/home/ec2-user/apline-laravel/storage/app/backup/production-dbdump-*.zip /home/ec2-user/Docker-Laravel-Pgsql/export/psql

ZIP_FILE=$(find . -type f -name *`date +%Y%m%d --date '1 day ago'`*zip)
echo $ZIP_FILE
unzip -P 9G7V94%n $ZIP_FILE
rm $ZIP_FILE

ARCHIVE=$(find . -type f -name *`date +%Y%m%d --date '1 day ago'`*)
echo $ARCHIVE


#docker exec docker_php_1 bash -c "chown -R nginx:nginx /var/www/html/storage/app/apline/2023"
docker exec postgres bash -c "cd /tmp/psql && psql -U postgres -f $ARCHIVE -d production"

TABLE=poshelp_desk
docker exec postgres bash -c "cd /tmp && pg_dump -c --if-exists -U postgres -t $TABLE production > production_$TABLE.dump"
docker exec postgres bash -c "cd /tmp && psql -U postgres -d development < production_$TABLE.dump"

TABLE=apline_base_model
docker exec postgres bash -c "cd /tmp && pg_dump -c --if-exists -U postgres -t $TABLE production > production_$TABLE.dump"
docker exec postgres bash -c "cd /tmp && psql -U postgres -d development < production_$TABLE.dump"

TABLE=apline_file_store
docker exec postgres bash -c "cd /tmp && pg_dump -c --if-exists -U postgres -t $TABLE production > production_$TABLE.dump"
docker exec postgres bash -c "cd /tmp && psql -U postgres -d development < production_$TABLE.dump"
