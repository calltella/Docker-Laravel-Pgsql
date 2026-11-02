#!/bin/bash

# ローカルの本番相当DBから、選択した同名テーブルを開発DB laravel12 へコピーする。
# Docker用.envの APP_ENV=local / DATABASE_CONTAINER_NAME / LOCAL_COPY_SOURCE_DATABASE が必須。
# コピー元は明示指定（例: production）。R2復元先DB名と一致させること。
# 添付情報は従来どおり export/pgsql/apline_file_store_backup.sql を使用する。
# このSQLはPostgreSQL用に変換済みの、信頼できるファイルに限る（postgres権限で実行）。
# コピー元にないテーブルは対象外とし、コピー先の既存データを保持する。
# コピー元にあるテーブルは全列がコピー先に同じ型で存在することを検証。列順の違いは許可する。
# コピー先だけの追加列は既存値を維持し、新規行ではデフォルト値を使用する。
# コピー元のCSVは全対象テーブルを一つの読み取りスナップショットで取得する。
# 関連サービス停止後、開発DB全体を before.dump へ退避してから更新する。
# 同じIDは更新、新規IDは追加。コピー元にないIDは削除（既存の外部キー定義に従う）。
# TRUNCATE CASCADEは使わず、外部キー等で拒否された場合は全更新をロールバックする。
# 全テーブルと設定・索引・シーケンスの更新は単一トランザクション。
# 非遅延外部キーで新規親子の挿入順序が合わない場合も中止し、制約は無効化しない。
# 成功時のみ今回停止したサービスを再開。失敗時は停止を維持する。
# 作業/退避先: export/pgsql/local-db-copy.XXXXXXXX（自動削除しない）。
# before.dump が更新前DB。未完成ファイルには .partial を付ける。
# 同ユーザーの同時実行をflockで防止。外部クライアントも事前に停止すること。

set -euo pipefail
umask 077

USER_DIRECTORY=~
PROJECT_DIRECTORY="${USER_DIRECTORY}/Docker-Laravel-Pgsql"
ENV_FILE="${PROJECT_DIRECTORY}/.env"
if [ ! -r "$ENV_FILE" ]; then
  echo "設定ファイルを読み込めません: $ENV_FILE" >&2
  exit 1
fi
source "$ENV_FILE"
: "${APP_ENV:?APP_ENV を .env に設定してください}"
: "${DATABASE_CONTAINER_NAME:?DATABASE_CONTAINER_NAME を .env に設定してください}"
if [[ ! "$DATABASE_CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
  echo "DATABASE_CONTAINER_NAME が不正です。" >&2
  exit 1
fi
if [ "$APP_ENV" != local ]; then
  echo "APP_ENV=local の場合のみ実行できます。" >&2
  exit 1
fi
: "${LOCAL_COPY_SOURCE_DATABASE:?LOCAL_COPY_SOURCE_DATABASE にコピー元DBを指定してください}"
if [[ ! "$LOCAL_COPY_SOURCE_DATABASE" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || \
  [[ "$LOCAL_COPY_SOURCE_DATABASE" = laravel12 || "$LOCAL_COPY_SOURCE_DATABASE" = postgres || "$LOCAL_COPY_SOURCE_DATABASE" = template* ]]; then
  echo "コピー元DB名が不正、またはコピー先と同じです。" >&2
  exit 1
fi
CONTAINER_NAME_PATTERN=${DATABASE_CONTAINER_NAME//./\\.}
DATABASE_CONTAINER_ID=$(docker ps --no-trunc -q --filter "name=^/${CONTAINER_NAME_PATTERN}$")
if [ -z "$DATABASE_CONTAINER_ID" ] || [[ "$DATABASE_CONTAINER_ID" == *$'\n'* ]]; then
  echo "起動中の対象コンテナを一意に特定できません: $DATABASE_CONTAINER_NAME" >&2
  exit 1
fi

DOCKER_EXEC_OPTIONS=()
if [ -n "${PGDUMP_PASSWORD:-}" ]; then
  export PGPASSWORD="$PGDUMP_PASSWORD"
  DOCKER_EXEC_OPTIONS=(-e PGPASSWORD)
fi
container_exec() {
  docker exec "${DOCKER_EXEC_OPTIONS[@]}" "$DATABASE_CONTAINER_ID" "$@"
}
psql_admin() {
  container_exec psql -X -w -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}
COMPOSE=(docker compose --project-directory "$PROJECT_DIRECTORY" --env-file "$ENV_FILE" -f "${PROJECT_DIRECTORY}/compose.yaml")
COMPOSE_DB_ID=$("${COMPOSE[@]}" ps -q postgres)
if [ -z "$COMPOSE_DB_ID" ]; then
  echo "Compose の postgres サービスが起動していません。" >&2
  exit 1
fi
COMPOSE_DB_ID=$(docker inspect --format '{{.Id}}' "$COMPOSE_DB_ID")
if [ "$COMPOSE_DB_ID" != "$DATABASE_CONTAINER_ID" ]; then
  echo "指定コンテナとComposeのpostgresが一致しません。" >&2
  exit 1
fi


exec 9>"${PROJECT_DIRECTORY}/.local-db-copy.lock"
if ! flock -n 9; then
  echo "別の開発DBコピーが実行中です。" >&2
  exit 1
fi
SOURCE_DATABASE=$LOCAL_COPY_SOURCE_DATABASE
TARGET_DATABASE=laravel12
INPUT_SQL=/tmp/pgsql/apline_file_store_backup.sql
container_exec test -r "$INPUT_SQL"
container_exec test -s "$INPUT_SQL"
TABLES=(
  l12_apline_base_model
  l12_apline_configuration
  l12_pos_helpdesk_daily_reports
  l12_scrape_cvcf_status
  l12_store_search_settings
  l12_store_network_device_masters
  l12_store_network_hosts
  l12_store_network_scan_state
  l12_store_network_ping_logs
  l12_store_network_device_batch_configs
  l12_legacy_user_id_map
  l12_failure_component_options
  l12_request_type_options
  l12_status_options
  l12_subsystem_options
  l12_business_system_options
  l12_severity_options
  l12_emergency_options
  l12_impact_options
  l12_priority_options
  l12_cause_options
  l12_resolution_type_options
)
query() {
  local database=$1
  shift
  container_exec psql -X -w -qAt -U postgres -d "$database" -v ON_ERROR_STOP=1 "$@"
}
# 生成列はこのコピー方式の対象外。違いを隠さず事前に拒否する。
declare -A COPY_COLUMNS COPY_NAMES
metadata() {
  local filter=${3:-true}
  query "$1" -c "SELECT string_agg(quote_ident(attname) || ':' || format_type(atttypid, atttypmod) || ':' || attgenerated::text, ',' ORDER BY attname) FROM pg_attribute WHERE attrelid=to_regclass('public.$2') AND attnum>0 AND NOT attisdropped AND ($filter);"
}
column_list() {
  query "$1" -c "SELECT string_agg(quote_ident(attname), ',' ORDER BY attnum) FROM pg_attribute WHERE attrelid='public.$2'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='';"
}
validate_table() {
  local source_db=$1 source_table=$2 target_table=$3 source_meta target_meta
  source_meta=$(metadata "$source_db" "$source_table")
  local names
  names=$(query "$source_db" -c "SELECT string_agg(quote_literal(attname), ',' ORDER BY attnum) FROM pg_attribute WHERE attrelid=to_regclass('public.$source_table') AND attnum>0 AND NOT attisdropped;")
  if [ -z "$names" ]; then echo "コピー元テーブルがありません: $source_table" >&2; exit 1; fi
  target_meta=$(metadata "$TARGET_DATABASE" "$target_table" "attname IN ($names)")
  if [ -z "$source_meta" ] || [ "$source_meta" != "$target_meta" ]; then
    echo "テーブル欠落または列構成不一致: $source_table -> $target_table" >&2
    exit 1
  fi
  COPY_COLUMNS[$target_table]=$(column_list "$source_db" "$source_table")
  COPY_NAMES[$target_table]=$names
  query "$TARGET_DATABASE" -c "SELECT id FROM public.$target_table LIMIT 0;" > /dev/null
  if [ "$(query "$TARGET_DATABASE" -c "SELECT count(*) FROM pg_attribute WHERE attrelid='public.$target_table'::regclass AND attgenerated<>'' AND NOT attisdropped;")" != 0 ]; then
    echo "生成列のあるテーブルには対応していません: $target_table" >&2
    exit 1
  fi
}
COPY_TABLES=()
for table in "${TABLES[@]}"; do
  source_exists=$(query "$SOURCE_DATABASE" -c "SELECT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='$table' AND c.relkind IN ('r','p'));")
  if [ "$source_exists" = f ]; then
    echo "コピー元にないためスキップ（コピー先は保持）: $table"
    continue
  fi
  if [ "$source_exists" != t ]; then
    echo "コピー元テーブルの存在を確認できません: $table" >&2
    exit 1
  fi
  validate_table "$SOURCE_DATABASE" "$table" "$table"
  COPY_TABLES+=("$table")
done
TABLES=("${COPY_TABLES[@]}")

RUNNING_SERVICES=$("${COMPOSE[@]}" ps --services --status running)
RESTART_SERVICES=()
while IFS= read -r service; do
  case "$service" in
    nginx|php|legacy|scheduler|apline-sync-worker|pgadmin4) RESTART_SERVICES+=("$service") ;;
  esac
done <<< "$RUNNING_SERVICES"
printf '環境: %s\nコンテナ: %s\nコピー元: %s\n更新先: %s\n添付SQL: %s\n停止対象: %s\n' \
  "$APP_ENV" "$DATABASE_CONTAINER_NAME" "$SOURCE_DATABASE" "$TARGET_DATABASE" "$INPUT_SQL" "${RESTART_SERVICES[*]:-なし}"
if ! read -r -p '開発DBを退避後に更新します。続行する場合は copy laravel12 と入力してください: ' CONFIRM || [ "$CONFIRM" != 'copy laravel12' ]; then
  echo "処理を中止しました。" >&2
  exit 1
fi
WORK_DIRECTORY=$(container_exec mktemp -d /tmp/pgsql/local-db-copy.XXXXXXXX)
VALIDATION_DB="localcopy_$(date +%Y%m%d%H%M%S)_$$"
VALIDATION_CREATED=false
MAINTENANCE_STARTED=false
COMMITTED=false
LOCAL_WORK=$(mktemp -d)
on_exit() {
  local status=$?
  trap - EXIT
  if [ "$VALIDATION_CREATED" = true ]; then
    psql_admin -c "DROP DATABASE IF EXISTS \"$VALIDATION_DB\" WITH (FORCE);" || echo "検証用DBを手動削除してください: $VALIDATION_DB" >&2
  fi
  rm -rf -- "$LOCAL_WORK"
  if [ "$status" -ne 0 ]; then
    echo "失敗。作業/退避先: $WORK_DIRECTORY / コミット済み: $COMMITTED" >&2
    if [ "$MAINTENANCE_STARTED" = true ]; then
      echo "サービスは自動再開していません: ${RESTART_SERVICES[*]:-なし}" >&2
    fi
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 入力SQLは独立した検証用DBへ読み込み、更新先に直接実行しない。
container_exec cp -- "$INPUT_SQL" "$WORK_DIRECTORY/input.sql"
psql_admin -c "CREATE DATABASE \"$VALIDATION_DB\" TEMPLATE template0;"
VALIDATION_CREATED=true
query "$VALIDATION_DB" -f "$WORK_DIRECTORY/input.sql"
validate_table "$VALIDATION_DB" apline_file_store l12_apline_file_store

# スナップショット内で全テーブルをCSV化。明示的な列リストで並びを固定する。
SOURCE_SQL="$LOCAL_WORK/source.sql"
printf 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n' > "$SOURCE_SQL"
for table in "${TABLES[@]}"; do
  columns=$(column_list "$SOURCE_DATABASE" "$table")
  printf "\\copy (SELECT %s FROM public.%s) TO '%s/%s.csv' WITH (FORMAT csv, HEADER true)\n" \
    "$columns" "$table" "$WORK_DIRECTORY" "$table" >> "$SOURCE_SQL"
done
printf 'COMMIT;\n' >> "$SOURCE_SQL"
docker exec -i "${DOCKER_EXEC_OPTIONS[@]}" "$DATABASE_CONTAINER_ID" \
  psql -X -w -U postgres -d "$SOURCE_DATABASE" -v ON_ERROR_STOP=1 -f - < "$SOURCE_SQL"
columns=${COPY_COLUMNS[l12_apline_file_store]}
query "$VALIDATION_DB" -c "\copy (SELECT $columns FROM public.apline_file_store) TO '$WORK_DIRECTORY/l12_apline_file_store.csv' WITH (FORMAT csv, HEADER true)"
TABLES+=(l12_apline_file_store)

# 事前に更新SQL全体を生成。SQLには資格情報や行データを埋め込まない。
UPDATE_SQL="$LOCAL_WORK/update.sql"
printf 'SET LOCAL search_path=public;\nSET CONSTRAINTS ALL DEFERRED;\n' > "$UPDATE_SQL"
for table in "${TABLES[@]}"; do
  columns=${COPY_COLUMNS[$table]}
  assignments=$(query "$TARGET_DATABASE" -c "SELECT string_agg(format('%I = EXCLUDED.%I', attname, attname), ',' ORDER BY attnum) FROM pg_attribute WHERE attrelid='public.$table'::regclass AND attnum>0 AND NOT attisdropped AND attname<>'id' AND attgenerated='' AND attname IN (${COPY_NAMES[$table]});")
  if [ -z "$assignments" ]; then echo "更新可能な列がありません: $table" >&2; exit 1; fi
  printf 'CREATE TEMP TABLE stage_%s ON COMMIT DROP AS SELECT %s FROM public.%s WITH NO DATA;\n' "$table" "$columns" "$table" >> "$UPDATE_SQL"
  printf "\\copy stage_%s (%s) FROM '%s/%s.csv' WITH (FORMAT csv, HEADER true)\n" "$table" "$columns" "$WORK_DIRECTORY" "$table" >> "$UPDATE_SQL"
  printf 'LOCK TABLE public.%s IN EXCLUSIVE MODE;\n' "$table" >> "$UPDATE_SQL"
  printf 'INSERT INTO public.%s (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM stage_%s WHERE true ON CONFLICT (id) DO UPDATE SET %s;\n' "$table" "$columns" "$columns" "$table" "$assignments" >> "$UPDATE_SQL"
done
# 子を先に削除。非遅延制約で順序が合わなければ、安全に全体を中止する。
for ((i=${#TABLES[@]}-1; i>=0; i--)); do
  table=${TABLES[$i]}
  printf 'DELETE FROM public.%s AS t WHERE NOT EXISTS (SELECT 1 FROM stage_%s AS s WHERE s.id=t.id);\n' "$table" "$table" >> "$UPDATE_SQL"
done
# PGroonga経由の計数差を避け、全行走査でステージング件数と比較する。
cat >> "$UPDATE_SQL" <<'SQL'
SET LOCAL enable_indexscan=off;
SET LOCAL enable_indexonlyscan=off;
SET LOCAL enable_bitmapscan=off;
SQL
for table in "${TABLES[@]}"; do
  cat >> "$UPDATE_SQL" <<SQL
DO \$\$
DECLARE seq_name text; next_id bigint;
BEGIN
  IF (SELECT count(*) FROM public.$table) <> (SELECT count(*) FROM stage_$table) THEN
    RAISE EXCEPTION '件数不一致: $table';
  END IF;
  seq_name := pg_get_serial_sequence('public.$table', 'id');
  IF seq_name IS NOT NULL THEN
    SELECT COALESCE(MAX(id)+1,1) INTO next_id FROM public.$table;
    EXECUTE format('ALTER SEQUENCE %s RESTART WITH %s',seq_name,next_id);
  END IF;
END \$\$;
SQL
done
cat >> "$UPDATE_SQL" <<'SQL'
DROP INDEX IF EXISTS pgroonga_nfkc100_unify_kana_index;
CREATE INDEX pgroonga_nfkc100_unify_kana_index
    ON l12_apline_base_model
    USING pgroonga (ticket_number, title, reception_content, customer_organization, 
    investigation_result, resolution_content, customer_impact, 
    remediation_note pgroonga_varchar_full_text_search_ops_v2);
UPDATE l12_apline_configuration
SET max_apid_check = sub.max_numeric_part
FROM (
    SELECT MAX(CAST(split_part(regexp_replace(ticket_number, '^[^0-9]+', ''), '-', 1) AS INTEGER)) AS max_numeric_part
    FROM public.l12_apline_base_model
    WHERE ticket_number LIKE 'FSAS%'
) AS sub
WHERE env = 'develop';
WITH renumbered AS (
    SELECT id, store_type * 1000 + (ROW_NUMBER() OVER (PARTITION BY store_type ORDER BY sort_order, id)) * 10 AS new_sort_order
    FROM public.l12_store_search_settings )
UPDATE public.l12_store_search_settings AS t SET sort_order = r.new_sort_order
FROM renumbered AS r WHERE t.id = r.id;
SQL

# SQL生成完了後にサービスを止め、更新前DBを確実に退避する。
MAINTENANCE_STARTED=true
if [ "${#RESTART_SERVICES[@]}" -gt 0 ]; then
  "${COMPOSE[@]}" stop "${RESTART_SERVICES[@]}"
fi
container_exec pg_dump -w -U postgres -d "$TARGET_DATABASE" -Fc -f "$WORK_DIRECTORY/before.partial"
container_exec test -s "$WORK_DIRECTORY/before.partial"
container_exec pg_restore --list "$WORK_DIRECTORY/before.partial" > /dev/null
container_exec mv -- "$WORK_DIRECTORY/before.partial" "$WORK_DIRECTORY/before.dump"
docker exec -i "$DATABASE_CONTAINER_ID" tee "$WORK_DIRECTORY/update.sql" < "$UPDATE_SQL" > /dev/null
docker exec -i "${DOCKER_EXEC_OPTIONS[@]}" "$DATABASE_CONTAINER_ID" \
  psql -X -w -U postgres -d "$TARGET_DATABASE" -v ON_ERROR_STOP=1 --single-transaction -f - < "$UPDATE_SQL"
COMMITTED=true
psql_admin -c "DROP DATABASE \"$VALIDATION_DB\" WITH (FORCE);"
VALIDATION_CREATED=false
if [ "${#RESTART_SERVICES[@]}" -gt 0 ]; then
  "${COMPOSE[@]}" start "${RESTART_SERVICES[@]}"
fi
MAINTENANCE_STARTED=false
echo "コピー完了。更新前DBの退避先: $WORK_DIRECTORY/before.dump"
