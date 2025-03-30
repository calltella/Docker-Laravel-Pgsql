#!/bin/bash

# 本番環境のデータベースを開発環境にコピーする
# Cronで app:restore-database-command を実行することで
# Dropboxからファイルをダウンロードしproductionデータベースにインポート
# 特定のテーブルのみdevelopmentデータベースにコピー
#

# 添付ファイルの最新化

set -e

# コマンドライン引数の取得
#arg1=$1

# 引数がなかった場合は今年をセット
#if [ -z "$arg1" ]; then
#  BACKUP_DATE=$(date -d 'yesterday' '+%Y%m%d')
#else
#  BACKUP_DATE=$arg1
#fi

# ユーザーディレクトリを取得
USER_DIRECTORY=~

# envファイルから環境変数を読込
source "${USER_DIRECTORY}/Docker-Laravel-Pgsql/.env"

# コンテナのIDを取得
DATABASE_CONTAINER_ID=$(docker ps -q --filter name=$DATABASE_CONTAINER_NAME)
#LARAVEL_CONTAINER_ID=$(docker ps -q --filter name=$LARAVEL_CONTAINER_NAME)


# コンテナが起動しているか確認
if [ -z "$DATABASE_CONTAINER_ID" ]; then
  echo "Container $DATABASE_CONTAINER_NAME is not running."
  exit 1  # 終了コード 1 でスクリプトを終了
else
  echo "Container $DATABASE_CONTAINER_NAME is running with ID: $DATABASE_CONTAINER_ID"
fi

# バックアップファイルを配置するディレクトリ
#BACKUP_DIRECTORY="${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/pgsql"

# ディレクトリが存在しない場合は作成
#if [ ! -d "$BACKUP_DIRECTORY" ]; then
#    mkdir -p "$BACKUP_DIRECTORY"
#    echo "Directory created: $BACKUP_DIRECTORY"
#fi

# 不要なファイルを削除
#find "${BACKUP_DIRECTORY}" -name "production-dbdump-*.sql" -type f -exec rm -f {} \; -o -name "production-dbdump-*.zip" -type f -exec rm -f {} \;

# 本番環境からファイルをコピー
#scp "preserver30:${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/DailyBackup/production-dbdump-*.sql" "${BACKUP_DIRECTORY}"

# 昨日日付のファイルを選択
#BACKUP_FILE=$(find "${BACKUP_DIRECTORY}" -type f -name "*${BACKUP_DATE}*" -exec basename {} \;)

# バックアップファイルをレストア
#docker exec $DATABASE_CONTAINER_ID bash -c "psql -U postgres -d production -f /tmp/pgsql/${BACKUP_FILE}"

# table development database copy
copy_table_to_development() {
  TABLE="$1"
  docker exec "$DATABASE_CONTAINER_ID" bash -c "pg_dump -c -U postgres -t \"$TABLE\" production > /tmp/pgsql/production_\"$TABLE\".dump"
  docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d development -c 'TRUNCATE TABLE \"$TABLE\" CASCADE;' && psql -U postgres -d development < /tmp/pgsql/production_\"$TABLE\".dump"
}

copy_table_to_development "migrate_pos_helpdesk_daily_reports"
copy_table_to_development "migrate_apline_base_model"
copy_table_to_development "migrate_apline_file_store"
copy_table_to_development "migrate_fresta_ping_exec_values"
copy_table_to_development "migrate_phpipam_device_parameters"
copy_table_to_development "migrate_apline_users_list"
copy_table_to_development "migrate_fresta_ipadress_thirdoctet"
copy_table_to_development "migrate_local_file_storage_store"
copy_table_to_development "migrate_local_file_storage_file_history"
copy_table_to_development "migrate_fresta_ping_exec_values"
copy_table_to_development "migrate_store_information"
copy_table_to_development "migrate_store_device_fp1_setup_info"


# 不要なファイルを削除
#docker exec $DATABASE_CONTAINER_ID bash -c "rm -f /tmp/pgsql/*.dump"

# dropbox用バックアップファイルコピー
#BACKUP_FILE_NAME="${BACKUP_FILE%.*}"
#HOST_PATH="/home/ec2-user/Docker-Laravel-Pgsql/export/pgsql/${BACKUP_FILE_NAME}.sql"
#TARGET_PATH="/home/ec2-user/apline_laravel10/storage/app/backup"
#cp $HOST_PATH "${TARGET_PATH}/${BACKUP_FILE_NAME}.sql"

# バックアップファイルの圧縮
#zip "${TARGET_PATH}/${BACKUP_FILE_NAME}.zip" "${TARGET_PATH}/${BACKUP_FILE_NAME}.sql"



