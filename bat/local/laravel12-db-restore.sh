#!/bin/bash

# 開発環境を再構築する為の必要なデータをバックアップから戻す
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

# ファイル出力先をクリア
docker exec "$DATABASE_CONTAINER_ID" sh -c 'rm -f /tmp/pgsql/l12_*.sql'

# laravel12_BKのテーブルAからLaravel12のテーブルへコピーする
# カラム構成が同じであることが前提
# Laravel12側のテーブルをTRUNCATEしてからINSERTする
sync_different_table_to_development() {
SOURCE_TABLE="$1"
DESTINATION_TABLE="$2"

echo "Syncing laravel12_BK table "$SOURCE_TABLE" -> Laravel12 table "$DESTINATION_TABLE""

# Laravel12側のテーブルが存在するか確認
TABLE_EXISTS=$(docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -tAc "SELECT 1 FROM pg_class WHERE relname='$DESTINATION_TABLE' AND relkind='r';" | sed 's/ //g')
if [ "$TABLE_EXISTS" != "1" ]; then
echo "Warning: Table "$DESTINATION_TABLE" does not exist in Laravel12 database."
echo "Skipping."
return
fi

# laravel12_BK側テーブルをCSVとして一時ファイルに出力
echo "Exporting laravel12_BK table "$SOURCE_TABLE"..."
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12_BK -c "\COPY "$SOURCE_TABLE" TO '/tmp/pgsql/${SOURCE_TABLE}.csv' CSV HEADER"

# Laravel12側テーブルをTRUNCATE
echo "Truncating Laravel12 table "$DESTINATION_TABLE"..."
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "TRUNCATE TABLE "$DESTINATION_TABLE" CASCADE;"

# CSVをLaravel12側テーブルへINSERT
echo "Importing data into Laravel12 table "$DESTINATION_TABLE"..."
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "\COPY "$DESTINATION_TABLE" FROM '/tmp/pgsql/${SOURCE_TABLE}.csv' CSV HEADER"

# idシーケンスを最大値に合わせる
echo "Updating sequence for $DESTINATION_TABLE..."
docker exec "$DATABASE_CONTAINER_ID" \
    psql -U postgres -d laravel12 -c "SELECT setval(pg_get_serial_sequence('$DESTINATION_TABLE', 'id'),
            COALESCE((SELECT MAX(id) FROM $DESTINATION_TABLE), 1), true);"

# 一時ファイル削除
docker exec "$DATABASE_CONTAINER_ID" rm -f "/tmp/pgsql/${SOURCE_TABLE}.csv"
echo "Successfully synced "$SOURCE_TABLE" -> "$DESTINATION_TABLE""
}

sync_different_table_to_development "l12_legacy_user_id_map"        "l12_legacy_user_id_map"
sync_different_table_to_development "l12_failure_component_options" "l12_failure_component_options"
sync_different_table_to_development "l12_request_type_options"      "l12_request_type_options"
sync_different_table_to_development "l12_status_options"            "l12_status_options"
sync_different_table_to_development "l12_subsystem_options"         "l12_subsystem_options"
sync_different_table_to_development "l12_business_system_options"   "l12_business_system_options"
sync_different_table_to_development "l12_severity_options"          "l12_severity_options"
sync_different_table_to_development "l12_emergency_options"         "l12_emergency_options"
sync_different_table_to_development "l12_impact_options"            "l12_impact_options"
sync_different_table_to_development "l12_priority_options"          "l12_priority_options"
sync_different_table_to_development "l12_cause_options"             "l12_cause_options"
sync_different_table_to_development "l12_resolution_type_options"   "l12_resolution_type_options"
sync_different_table_to_development "l12_store_search_settings"     "l12_store_search_settings"
sync_different_table_to_development "l12_store_information"         "l12_store_information"



