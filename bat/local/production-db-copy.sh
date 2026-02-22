#!/bin/bash

# 本番環境のデータベースを開発環境にコピーする
# Cronで app:restore-database-command を実行することで
# Dropboxからファイルをダウンロードしproductionデータベースにインポート
# 特定のテーブルのみdevelopmentデータベースにコピー
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


sync_table_to_development() {
  TABLE="$1"

  # production データベースからテーブルをダンプ
  docker exec "$DATABASE_CONTAINER_ID" bash -c "pg_dump -c -U postgres -t \"$TABLE\" production > /tmp/pgsql/production_\"$TABLE\".dump"

  # development データベースでテーブルが存在するか確認
  TABLE_EXISTS=$(docker exec "$DATABASE_CONTAINER_ID" psql -U postgres -d development -tAc "SELECT 1 FROM pg_class WHERE relname='$TABLE' AND relkind='r';" | sed 's/ //g')

  # テーブルが存在する場合のみ TRUNCATE とリストアを実行
  if [ "$TABLE_EXISTS" -eq 1 ]; then
    docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d development -c 'TRUNCATE TABLE \"$TABLE\" CASCADE;'"
    docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d development < /tmp/pgsql/production_\"$TABLE\".dump"
  else
    echo "Warning: Table \"$TABLE\" does not exist in the development database. Skipping TRUNCATE and restore."
  fi
}
sync_table_to_development "migrate_apline_users_list"
sync_table_to_development "migrate_user_article_reads"

sync_table_to_development "migrate_apline_base_model"
sync_table_to_development "migrate_apline_file_store"
sync_table_to_development "migrate_apline_pulldown_list"
sync_table_to_development "migrate_apline_users_list"

sync_table_to_development "migrate_apline_subsystem_lists"
sync_table_to_development "migrate_apline_classification_lists"
sync_table_to_development "migrate_apline_business_lists"
sync_table_to_development "migrate_apline_severity_lists"
sync_table_to_development "migrate_apline_emergency_lists"
sync_table_to_development "migrate_apline_impact_lists"
sync_table_to_development "migrate_apline_priority_lists"
sync_table_to_development "migrate_apline_cause_lists"
sync_table_to_development "migrate_apline_deal_lists"

sync_table_to_development "migrate_fresta_ping_exec_values"
sync_table_to_development "migrate_fresta_ipadress_thirdoctet"
sync_table_to_development "migrate_phpipam_device_parameters"
sync_table_to_development "migrate_phpipam_function_ipaddresses_table"

sync_table_to_development "migrate_local_file_storage_store"
sync_table_to_development "migrate_local_file_storage_file_history"
sync_table_to_development "migrate_fresta_ping_exec_values"

sync_table_to_development "migrate_store_information"
sync_table_to_development "migrate_store_device_fp1_setup_info"
sync_table_to_development "migrate_store_device_fp1_ping_log"

sync_table_to_development "migrate_pos_helpdesk_daily_reports"

sync_table_to_development "migrate_scrape_cvcf_status"
sync_table_to_development "migrate_scrape_cvcf_settings"

# インデックスの再作成
echo "Recreating index on migrate_apline_base_model..."
docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d development -c \"
DROP INDEX IF EXISTS pgroonga_nfkc100_unify_kana_index;
CREATE INDEX pgroonga_nfkc100_unify_kana_index
    ON migrate_apline_base_model
    USING pgroonga (apid, title, work_content, organization, surveyresults, dealanswer, customerimpact, correspondingnote pgroonga_varchar_full_text_search_ops_v2);
\""

# MaxApidを更新（開発用ＤＢ）
docker exec "$DATABASE_CONTAINER_ID" bash -c "psql -U postgres -d development -c \"
UPDATE migrate_apline_configuration
SET max_apid_check = sub.max_numeric_part
FROM (
    SELECT MAX(CAST(split_part(regexp_replace(apid, '^[^0-9]+', ''), '-', 1) AS INTEGER)) AS max_numeric_part
    FROM public.migrate_apline_base_model
    WHERE apid LIKE 'FSAS%'
) AS sub
WHERE env = 'develop';
\""

echo "Index recreated successfully."
