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

# 一時ファイル削除
docker exec "$DATABASE_CONTAINER_ID" rm -f "/tmp/pgsql/${SOURCE_TABLE}.csv"
echo "Successfully synced "$SOURCE_TABLE" -> "$DESTINATION_TABLE""
}

# カラム構成が違うので個別に処理 (migrate_apline_base_model)
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS migrate_apline_base_model;"
docker exec "$DATABASE_CONTAINER_ID" sh -c "pg_dump -U postgres -d production --table=migrate_apline_base_model | psql -U postgres -d laravel12"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "TRUNCATE TABLE l12_apline_base_model;"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "INSERT INTO l12_apline_base_model (id, ticket_number, title, status_id, customer_organization, customer_contact_name, reception_content, investigation_result, resolution_content, received_at, started_at, resolved_at, occurred_at, customer_impact, remediation_note, created_at, updated_at, is_received_by_email, accepted_by_user_id, created_by_user_id, updated_by_user_id, request_type_id, failure_component_id, severity_id, business_system_id, emergency_id, impact_id, priority_id, cause_id, resolution_type_id, subsystem_id)
SELECT id, apid, title, status_id, organization, responsible, work_content, surveyresults, dealanswer, reception, work_start_time, work_end_time, occurrencedate, customerimpact, correspondingnote, created_at, updated_at, mailflag, acceptance_id, slipissuance_id, itemupdater_id, request_category_id, classification_id, severity_id, business_id, emergency_id, impact_id, priority_id, cause_id, deal_id, subsystem_id
FROM migrate_apline_base_model";
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS migrate_apline_base_model;"

# CloudflareD1からエクスポートされたSQLを実行（apline_file_store）※ Postgres用にCreate分の書換必要
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS apline_file_store;"
docker compose exec postgres psql -U postgres -d laravel12 -f /tmp/pgsql/apline_file_store_backup.sql
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "TRUNCATE TABLE l12_apline_file_store;"
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "INSERT INTO l12_apline_file_store (id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type)
SELECT id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type FROM apline_file_store";
docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d laravel12 -c "DROP TABLE IF EXISTS apline_file_store;"

# sync_table_to_development "migrate_user_article_reads"

# 本番環境にはないので本番からレストア（修正がある場合は本番を修正）
sync_different_table_to_development "l12_legacy_user_id_map" "l12_legacy_user_id_map"

sync_different_table_to_development "migrate_apline_pulldown_list" "l12_apline_pulldown_list"
sync_different_table_to_development "migrate_apline_subsystem_lists" "l12_apline_subsystem_lists"
sync_different_table_to_development "migrate_apline_classification_lists" "l12_apline_classification_lists"
sync_different_table_to_development "migrate_apline_classification_lists" "l12_apline_classification_lists"
sync_different_table_to_development "migrate_apline_business_lists" "l12_apline_business_lists"
sync_different_table_to_development "migrate_apline_severity_lists" "l12_apline_severity_lists"
sync_different_table_to_development "migrate_apline_emergency_lists" "l12_apline_emergency_lists"
sync_different_table_to_development "migrate_apline_impact_lists" "l12_apline_impact_lists"
sync_different_table_to_development "migrate_apline_priority_lists" "l12_apline_priority_lists"
sync_different_table_to_development "migrate_apline_cause_lists" "l12_apline_cause_lists"
sync_different_table_to_development "migrate_apline_deal_lists" "l12_apline_deal_lists"
sync_different_table_to_development "migrate_apline_status_list" "l12_apline_status_list"

sync_different_table_to_development "migrate_fresta_ping_exec_values" "l12_fresta_ping_exec_values"
sync_different_table_to_development "migrate_fresta_ipadress_thirdoctet" "l12_fresta_ipadress_thirdoctet"
sync_different_table_to_development "migrate_phpipam_device_parameters" "l12_phpipam_device_parameters"
sync_different_table_to_development "migrate_phpipam_function_ipaddresses_table" "l12_phpipam_function_ipaddresses_table"

sync_different_table_to_development "migrate_fresta_ping_exec_values" "l12_fresta_ping_exec_values"
sync_different_table_to_development "migrate_store_information" "l12_store_information"
sync_different_table_to_development "migrate_store_device_fp1_setup_info" "l12_store_device_fp1_setup_info"
sync_different_table_to_development "migrate_store_device_fp1_ping_log" "l12_store_device_fp1_ping_log"
sync_different_table_to_development "migrate_pos_helpdesk_daily_reports" "l12_pos_helpdesk_daily_reports"

sync_different_table_to_development "migrate_scrape_cvcf_status" "l12_scrape_cvcf_status"
sync_different_table_to_development "migrate_scrape_cvcf_settings" "l12_scrape_cvcf_settings"

# sync_table_to_development "migrate_local_file_storage_store"
# sync_table_to_development "migrate_local_file_storage_file_history"

# インデックスの再作成
echo "Recreating index on l12_apline_base_model..."
docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d laravel12 -c \"
DROP INDEX IF EXISTS pgroonga_nfkc100_unify_kana_index;
CREATE INDEX pgroonga_nfkc100_unify_kana_index
    ON l12_apline_base_model
    USING pgroonga (apid, title, work_content, organization, surveyresults, dealanswer, customerimpact, correspondingnote pgroonga_varchar_full_text_search_ops_v2);
\""

# MaxApidを更新（開発用ＤＢ）
docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d laravel12 -c \"
UPDATE l12_apline_configuration
SET max_apid_check = sub.max_numeric_part
FROM (
    SELECT MAX(CAST(split_part(regexp_replace(apid, '^[^0-9]+', ''), '-', 1) AS INTEGER)) AS max_numeric_part
    FROM public.l12_apline_base_model
    WHERE apid LIKE 'FSAS%'
) AS sub
WHERE env = 'develop';
\""

echo "Index recreated successfully."
