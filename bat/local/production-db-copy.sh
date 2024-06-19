#!/bin/bash

# Dockerが起動している事が前提
# 毎日１２時に起動
# FJ001からバックアップファイルをコピーしてきて
# 開発環境のproductionデータベースにインポート
# 特定のテーブルのみdevelopmentデータベースにコピー

# 添付ファイルの最新化

set -e

# コマンドライン引数の取得
arg1=$1

# 引数がなかった場合は今年をセット
if [ -z "$arg1" ]; then
  BACKUP_DATE=$(date -d 'yesterday' '+%Y%m%d')
else
  BACKUP_DATE=$arg1
fi

# ユーザーディレクトリを取得
USER_DIRECTORY=~

# envファイルから環境変数を読込
source "${USER_DIRECTORY}/Docker-Laravel-Pgsql/.env"

# コンテナのIDを取得
CONTAINER_ID=$(docker ps -q --filter name=$DATABASE_CONTAINER_NAME)

# コンテナが起動しているか確認
if [ -z "$CONTAINER_ID" ]; then
  echo "Container $DATABASE_CONTAINER_NAME is not running."
  exit 1  # 終了コード 1 でスクリプトを終了
else
  echo "Container $DATABASE_CONTAINER_NAME is running with ID: $CONTAINER_ID"
fi

# バックアップファイルを配置するディレクトリ
BACKUP_DIRECTORY="${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/pgsql"

# ディレクトリが存在しない場合は作成
if [ ! -d "$BACKUP_DIRECTORY" ]; then
    mkdir -p "$BACKUP_DIRECTORY"
    echo "Directory created: $BACKUP_DIRECTORY"
fi

# 不要なファイルを削除
find "${BACKUP_DIRECTORY}" -name "production-dbdump-*.sql" -type f -exec rm -f {} \;

# 本番環境からファイルをコピー
scp "preserver30:${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/DailyBackup/production-dbdump-*.sql" "${BACKUP_DIRECTORY}"

# 昨日日付のファイルを選択
BACKUP_FILE=$(find "${BACKUP_DIRECTORY}" -type f -name "*${BACKUP_DATE}*" -exec basename {} \;)

# バックアップファイルをレストア
docker exec $CONTAINER_ID bash -c "psql -U postgres -d production -f /tmp/pgsql/${BACKUP_FILE}"

# table development database copy
copy_table_to_development() {
    TABLE=$1
    docker exec $CONTAINER_ID bash -c "pg_dump -c --if-exists -U postgres -t $TABLE production > /tmp/pgsql/production_$TABLE.dump"
    docker exec $CONTAINER_ID bash -c "psql -U postgres -d development < /tmp/pgsql/production_$TABLE.dump"
}

copy_table_to_development "poshelp_desk"
copy_table_to_development "apline_base_model"
copy_table_to_development "apline_file_store"

# phpipamテーブルコピー
copy_table_to_development "phpipam_subnet_table"
copy_table_to_development "phpipam_display_information"

# 不要なファイルを削除
docker exec $CONTAINER_ID bash -c "rm -f /tmp/pgsql/*.dump"

# migrateデータベーステスト（2024/06/18から）
docker exec $CONTAINER_ID bash -c "psql -U postgres -d development -f /tmp/pgsql/migrate-table-copy.sql"

