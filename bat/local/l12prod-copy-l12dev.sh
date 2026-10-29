#!/bin/bash

# 開発環境へのデータベースコピー
# テスト本番環境で「production-db-copy」バッチを起動して（production ➡ Laravel12 コピー）
# 日時スケジュール及びバックアップコマンドでCloudflareR2へバックアップ
# 開発環境で「cloudflareR2-production-restore」を実行（Laravel12 Productionに展開）
# 開発環境で「l12prod-copy-l12dev」を実行して （Laravel12 Production ➡ Laravel12 コピー）

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

# ProductionのテーブルAからLaravel12のテーブルへコピーする
# カラム構成が同じであることが前提
# Laravel12側のテーブルをTRUNCATEしてからINSERTする
sync_different_table_to_development() {
    SOURCE_TABLE="$1"
    DESTINATION_TABLE="$2"

    echo "Syncing Production table "$SOURCE_TABLE" -> Laravel12 table "$DESTINATION_TABLE""

    # Laravel12側のテーブルが存在するか確認
    TABLE_EXISTS=$(docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -tAc "SELECT 1 FROM pg_class WHERE relname='$DESTINATION_TABLE' AND relkind='r';" | sed 's/ //g')
    if [ "$TABLE_EXISTS" != "1" ]; then
    echo "Warning: Table "$DESTINATION_TABLE" does not exist in Laravel12 database."
    echo "Skipping."
    return
    fi

    # laravel12_production 側テーブルをCSVとして一時ファイルに出力
    echo "Exporting Production table "$SOURCE_TABLE"..."
    docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12_production -c "\COPY "$SOURCE_TABLE" TO '/tmp/pgsql/${SOURCE_TABLE}.csv' CSV HEADER"

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

# 開発側で新設したテーブルを本番環境にコピーする
dump_table() {
    local table_name="$1"

    echo "Exporting ${table_name}..."

    docker exec "$DATABASE_CONTAINER_ID" sh -c "pg_dump -U postgres -d laravel12 --table=${table_name} --inserts > /tmp/pgsql/${table_name}.sql"

    echo "Done: /tmp/pgsql/${table_name}.sql"
}


sync_different_table_to_development "l12_apline_base_model"             "l12_apline_base_model"
sync_different_table_to_development "l12_apline_configuration"          "l12_apline_configuration"
sync_different_table_to_development "l12_pos_helpdesk_daily_reports"    "l12_pos_helpdesk_daily_reports"
sync_different_table_to_development "l12_scrape_cvcf_status"            "l12_scrape_cvcf_status"
sync_different_table_to_development "l12_store_search_settings"         "l12_store_search_settings"

# テーブル名変更： l12_device_masters から l12_store_network_device_masters / 正規化
sync_different_table_to_development "l12_store_network_device_masters"  "l12_store_network_device_masters"

sync_different_table_to_development "l12_store_network_hosts"           "l12_store_network_hosts"
sync_different_table_to_development "l12_store_network_scan_state"      "l12_store_network_scan_state"
sync_different_table_to_development "l12_store_network_ping_logs"       "l12_store_network_ping_logs"

# テーブル名変更： l12_store_device_batch_configs から l12_store_network_device_batch_configs / 正規化
sync_different_table_to_development "l12_store_network_device_batch_configs"    "l12_store_network_device_batch_configs"

sync_different_table_to_development "l12_legacy_user_id_map"            "l12_legacy_user_id_map"
sync_different_table_to_development "l12_failure_component_options"     "l12_failure_component_options"
sync_different_table_to_development "l12_request_type_options"          "l12_request_type_options"
sync_different_table_to_development "l12_status_options"                "l12_status_options"
sync_different_table_to_development "l12_subsystem_options"             "l12_subsystem_options"
sync_different_table_to_development "l12_business_system_options"       "l12_business_system_options"
sync_different_table_to_development "l12_severity_options"              "l12_severity_options"
sync_different_table_to_development "l12_emergency_options"             "l12_emergency_options"
sync_different_table_to_development "l12_impact_options"                "l12_impact_options"
sync_different_table_to_development "l12_priority_options"              "l12_priority_options"
sync_different_table_to_development "l12_cause_options"                 "l12_cause_options"
sync_different_table_to_development "l12_resolution_type_options"       "l12_resolution_type_options"


# CloudflareD1からエクスポートされたSQLを実行（apline_file_store）※ Postgres用にCreate分の書換必要
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS apline_file_store;"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -f "/tmp/pgsql/apline_file_store_backup.sql"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "TRUNCATE TABLE l12_apline_file_store;"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "INSERT INTO l12_apline_file_store (id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type)
SELECT id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type FROM apline_file_store";
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "SELECT setval(pg_get_serial_sequence('l12_apline_file_store', 'id'), COALESCE((SELECT MAX(id) FROM l12_apline_file_store), 1), true);"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS apline_file_store;"

# インデックスの再作成
echo "Recreating index on l12_apline_base_model..."
docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d laravel12 -c \"
DROP INDEX IF EXISTS pgroonga_nfkc100_unify_kana_index;
CREATE INDEX pgroonga_nfkc100_unify_kana_index
    ON l12_apline_base_model
    USING pgroonga (ticket_number, title, reception_content, customer_organization, 
    investigation_result, resolution_content, customer_impact, 
    remediation_note pgroonga_varchar_full_text_search_ops_v2);
\""

# MaxApidを更新（開発用ＤＢ）
docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d laravel12 -c \"
UPDATE l12_apline_configuration
SET max_apid_check = sub.max_numeric_part
FROM (
    SELECT MAX(CAST(split_part(regexp_replace(ticket_number, '^[^0-9]+', ''), '-', 1) AS INTEGER)) AS max_numeric_part
    FROM public.l12_apline_base_model
    WHERE ticket_number LIKE 'FSAS%'
) AS sub
WHERE env = 'develop';
\""

# sort_orderを振り直す
docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d laravel12 -c \"
WITH renumbered AS (
    SELECT id, store_type * 1000 + (ROW_NUMBER() OVER (PARTITION BY store_type ORDER BY sort_order, id)) * 10 AS new_sort_order
    FROM public.l12_store_search_settings )
UPDATE public.l12_store_search_settings AS t SET sort_order = r.new_sort_order
FROM renumbered AS r WHERE t.id = r.id;
\""

echo "Index recreated successfully."