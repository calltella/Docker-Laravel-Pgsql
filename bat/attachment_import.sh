#!/bin/sh

# 添付ファイルの最新化

set -e

sudo chown ec2-user -R ~/Docker-Laravel-Pgsql

# 本番環境の添付ファイル群を取得
ssh sailpreserver20 ~/Docker-Laravel-Script/production_attachment_import.sh # 本番環境の添付ファイルをZIP圧縮

# 本番環境からファイルをコピー
scp sailpreserver20:/home/ec2-user/Docker-Laravel-Pgsql/export/archive2023.zip /home/ec2-user/Docker-Laravel-Pgsql/export/

# フォルダ移動
cd ~/Docker-Laravel-Pgsql/export

# 解凍したフォルダが存在してなければ解凍してファイルを移動
if [ ! -d "2023/" ]; then
    unzip archive2023.zip > /dev/null
    echo "exec unzip"
    docker exec docker_php_1 bash -c "rm -rf /var/www/html/storage/app/apline/2023"
    docker exec docker_php_1 bash -c "mv /tmp/2023 /var/www/html/storage/app/apline/"
    echo "attachfile moved"
fi

# 権限の変更
docker exec docker_php_1 bash -c "chown -R nginx:nginx /var/www/html/storage/app/apline/2023"
docker exec docker_php_1 bash -c "find /var/www/html/storage/app/apline -type d -print | xargs chmod 751"
docker exec docker_php_1 bash -c "find /var/www/html/storage/app/apline -type f -print | xargs chmod 644"



