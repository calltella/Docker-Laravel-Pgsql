#!/bin/bash

# 本番環境のデータベースを開発環境にコピーする
# scheduler の app:restore-database-command を実行することで
# CloudflareR2 からファイルをダウンロードしproductionデータベースにインポート
# 特定のテーブルのみLaravel12 データベースにコピー
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

# Production側テーブルをCSVとして一時ファイルに出力
echo "Exporting Production table "$SOURCE_TABLE"..."
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d production -c "\COPY "$SOURCE_TABLE" TO '/tmp/pgsql/${SOURCE_TABLE}.csv' CSV HEADER"

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

# カラム構成が違うので個別に処理 (migrate_apline_base_model)
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS migrate_apline_base_model;"
docker exec "$DATABASE_CONTAINER_ID" sh -c "pg_dump -U postgres -d production --table=migrate_apline_base_model | psql -U postgres -d laravel12"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "TRUNCATE TABLE l12_apline_base_model CASCADE;"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "INSERT INTO l12_apline_base_model (id, ticket_number, title, status_id, customer_organization, customer_contact_name, reception_content, investigation_result, resolution_content, received_at, started_at, resolved_at, occurred_at, customer_impact, remediation_note, created_at, updated_at, is_received_by_email, accepted_by_user_id, created_by_user_id, updated_by_user_id, request_type_id, failure_component_id, severity_id, business_system_id, emergency_id, impact_id, priority_id, cause_id, resolution_type_id, subsystem_id)
SELECT id, apid, title, status_id, organization, responsible, work_content, surveyresults, dealanswer, reception, work_start_time, work_end_time, occurrencedate, customerimpact, correspondingnote, created_at, updated_at, mailflag, acceptance_id, slipissuance_id, itemupdater_id, request_category_id, classification_id, severity_id, business_id, emergency_id, impact_id, priority_id, cause_id, deal_id, subsystem_id
FROM migrate_apline_base_model";
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "SELECT setval(pg_get_serial_sequence('l12_apline_base_model', 'id'), COALESCE((SELECT MAX(id) FROM l12_apline_base_model), 1), true);"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS migrate_apline_base_model;"

# カラム構成が違うので個別に処理 (migrate_apline_configuration)
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS migrate_apline_configuration;"
docker exec "$DATABASE_CONTAINER_ID" sh -c "pg_dump -U postgres -d production --table=migrate_apline_configuration | psql -U postgres -d laravel12"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "TRUNCATE TABLE l12_apline_configuration;"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "INSERT INTO l12_apline_configuration (env,perpage,header_only_size,main_title,dev_bgcolor,max_apid_check,request_ip,status_color,base_url,slack_post,fileupload_max,phpipam_tengroup,apline_export_id,file_store_export_id)
SELECT env,perpage,header_only_size,main_title,dev_bgcolor,max_apid_check,request_ip,status_color,base_url,slack_post,fileupload_max,phpipam_tengroup,apline_export_id,file_store_export_id
FROM migrate_apline_configuration";
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS migrate_apline_configuration;"

# CloudflareD1からエクスポートされたSQLを実行（apline_file_store）※ Postgres用にCreate分の書換必要
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS apline_file_store;"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -f "/tmp/pgsql/apline_file_store_backup.sql"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "TRUNCATE TABLE l12_apline_file_store;"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "INSERT INTO l12_apline_file_store (id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type)
SELECT id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type FROM apline_file_store";
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "SELECT setval(pg_get_serial_sequence('l12_apline_file_store', 'id'), COALESCE((SELECT MAX(id) FROM l12_apline_file_store), 1), true);"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS apline_file_store;"

# データベースをエクスポート用にバックアップ（ついでにインポートテスト）
docker exec "$DATABASE_CONTAINER_ID" pg_dump -U postgres -d laravel12 --schema-only -f /tmp/pgsql/l12_backup_db_schema_only.sql
docker exec "$DATABASE_CONTAINER_ID" pg_dump -U postgres -d laravel12 --data-only -f /tmp/pgsql/l12_backup_db_data_only.sql
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'laravel12_BK' AND pid <> pg_backend_pid();"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -c "DROP DATABASE IF EXISTS \"laravel12_BK\";"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -c "CREATE DATABASE \"laravel12_BK\";"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12_BK -f /tmp/pgsql/l12_backup_db_schema_only.sql
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12_BK -f /tmp/pgsql/l12_backup_db_data_only.sql

# 随時更新されるデータだけ本番環境からコピー
sync_different_table_to_development "migrate_fresta_ping_exec_values" "l12_fresta_ping_exec_values"
sync_different_table_to_development "migrate_fresta_ipadress_thirdoctet" "l12_fresta_ipadress_thirdoctet"
sync_different_table_to_development "migrate_phpipam_device_parameters" "l12_phpipam_device_parameters"
sync_different_table_to_development "migrate_phpipam_function_ipaddresses_table" "l12_phpipam_function_ipaddresses_table"

sync_different_table_to_development "migrate_fresta_ping_exec_values" "l12_fresta_ping_exec_values"
sync_different_table_to_development "migrate_store_device_fp1_setup_info" "l12_store_device_fp1_setup_info"
sync_different_table_to_development "migrate_store_device_fp1_ping_log" "l12_store_device_fp1_ping_log"
sync_different_table_to_development "migrate_pos_helpdesk_daily_reports" "l12_pos_helpdesk_daily_reports"

sync_different_table_to_development "migrate_scrape_cvcf_status" "l12_scrape_cvcf_status"
sync_different_table_to_development "migrate_scrape_cvcf_settings" "l12_scrape_cvcf_settings"

# productionにテーブルがないので作成
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