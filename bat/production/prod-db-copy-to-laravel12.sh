#!/bin/bash

# production の migrate_apline_base_model を列変換して laravel12 へコピーする。
# 添付情報は export/pgsql/apline_file_store_backup.sql（PostgreSQL形式）から取得する。
# 使用例: bash bat/production/prod-db-copy-to-laravel12.sh
# .env の APP_ENV / DATABASE_CONTAINER_NAME が必須。PGDUMP_PASSWORD は任意。
# production環境でも必ず copy laravel12 の確認入力が必要。引数は受け付けない。
# ComposeのDB一致確認後、関連サービスを停止し、laravel12 と既存laravel12_BKを退避する。
# コピー先2テーブル・索引・設定・シーケンスは単一トランザクションで更新する。
# 対象外へのCASCADEは行わない。外部キーで拒否された場合は更新を中止する。
# 成功後にスキーマ/データSQLを保存し、laravel12_BKを再作成して復元を検証する。
# 失敗時はサービスを停止したままにする。更新コミット後の失敗は自動で戻さない。
# 作業/退避先: export/pgsql/prod-db-copy.XXXXXXXX（自動削除しない）。
# before.dump が更新前laravel12、before-bk.dump が更新前laravel12_BK（存在時）。
# before.dump の手動復元には pg_restore を使う。外部クライアントは事前に停止する。
# 添付SQLはpostgres権限で検証DBに読み込むため、信頼できるファイルのみ使用する。

set -euo pipefail
umask 077
if [ "$#" -ne 0 ]; then
  echo "使用方法: $0" >&2
  exit 1
fi

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

exec 9>"${PROJECT_DIRECTORY}/.prod-db-copy.lock"
if ! flock -n 9; then
  echo "別の本番DBコピーが実行中です。" >&2
  exit 1
fi
INPUT_SQL=/tmp/pgsql/apline_file_store_backup.sql
container_exec test -r "$INPUT_SQL"
container_exec test -s "$INPUT_SQL"
# 元DBとコピー先DBへの接続を更新前に確認する。
container_exec psql -X -w -U postgres -d production -v ON_ERROR_STOP=1 -c 'SELECT 1;' > /dev/null
container_exec psql -X -w -U postgres -d laravel12 -v ON_ERROR_STOP=1 -c 'SELECT 1;' > /dev/null
BK_EXISTS=$(psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname='laravel12_BK';")
RUNNING_SERVICES=$("${COMPOSE[@]}" ps --services --status running)
STOPPED_SERVICES=()
while IFS= read -r service; do
  case "$service" in
    nginx|php|legacy|scheduler|apline-sync-worker|pgadmin4) STOPPED_SERVICES+=("$service") ;;
  esac
done <<< "$RUNNING_SERVICES"
printf '環境: %s\nコンテナ: %s\nコピー元: production\n更新先: laravel12 / laravel12_BK\n添付SQL: %s\n停止対象: %s\n' \
  "$APP_ENV" "$DATABASE_CONTAINER_NAME" "$INPUT_SQL" "${STOPPED_SERVICES[*]:-なし}"
if ! read -r -p 'DBを退避してコピーします。続行する場合は copy laravel12 と入力してください: ' CONFIRM || [ "$CONFIRM" != 'copy laravel12' ]; then
  echo "処理を中止しました。" >&2
  exit 1
fi
WORK_DIRECTORY=$(container_exec mktemp -d /tmp/pgsql/prod-db-copy.XXXXXXXX)
LOCAL_WORK=$(mktemp -d)
VALIDATION_DB="prodcopy_$(date +%Y%m%d%H%M%S)_$$"
VALIDATION_CREATED=false
MAINTENANCE_STARTED=false
COMMITTED=false
on_exit() {
  local status=$?
  trap - EXIT
  if [ "$VALIDATION_CREATED" = true ]; then
    psql_admin -c "DROP DATABASE IF EXISTS \"$VALIDATION_DB\" WITH (FORCE);" || echo "検証DBを手動削除してください: $VALIDATION_DB" >&2
  fi
  rm -rf -- "$LOCAL_WORK"
  if [ "$status" -ne 0 ]; then
    echo "失敗。作業/退避先: $WORK_DIRECTORY / laravel12更新コミット済み: $COMMITTED" >&2
    if [ "$MAINTENANCE_STARTED" = true ]; then
      echo "サービスは自動再開していません: ${STOPPED_SERVICES[*]:-なし}" >&2
    fi
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 添付SQLは更新先へ直接読み込まず、一意な検証DBで確認する。
container_exec cp -- "$INPUT_SQL" "$WORK_DIRECTORY/input.sql"
psql_admin -c "CREATE DATABASE \"$VALIDATION_DB\" TEMPLATE template0;"
VALIDATION_CREATED=true
container_exec psql -X -w -U postgres -d "$VALIDATION_DB" -v ON_ERROR_STOP=1 -f "$WORK_DIRECTORY/input.sql"
container_exec psql -X -w -U postgres -d production -v ON_ERROR_STOP=1 \
  -c "\copy (SELECT id, apid, title, status_id, organization, responsible, work_content, surveyresults, dealanswer, reception, work_start_time, work_end_time, occurrencedate, customerimpact, correspondingnote, created_at, updated_at, mailflag, acceptance_id, slipissuance_id, itemupdater_id, request_category_id, classification_id, severity_id, business_id, emergency_id, impact_id, priority_id, cause_id, deal_id, subsystem_id FROM public.migrate_apline_base_model) TO '$WORK_DIRECTORY/base.csv' WITH (FORMAT csv, HEADER true)"
container_exec psql -X -w -U postgres -d "$VALIDATION_DB" -v ON_ERROR_STOP=1 \
  -c "\copy (SELECT id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type FROM public.apline_file_store) TO '$WORK_DIRECTORY/files.csv' WITH (FORMAT csv, HEADER true)"
cat > "$LOCAL_WORK/update.sql" <<SQL
SET LOCAL search_path=public;
CREATE TEMP TABLE stage_base ON COMMIT DROP AS SELECT id, ticket_number, title, status_id, customer_organization, customer_contact_name, reception_content, investigation_result, resolution_content, received_at, started_at, resolved_at, occurred_at, customer_impact, remediation_note, created_at, updated_at, is_received_by_email, accepted_by_user_id, created_by_user_id, updated_by_user_id, request_type_id, failure_component_id, severity_id, business_system_id, emergency_id, impact_id, priority_id, cause_id, resolution_type_id, subsystem_id FROM public.l12_apline_base_model WITH NO DATA;
CREATE TEMP TABLE stage_files ON COMMIT DROP AS SELECT id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type FROM public.l12_apline_file_store WITH NO DATA;
\copy stage_base FROM '$WORK_DIRECTORY/base.csv' WITH (FORMAT csv, HEADER true)
\copy stage_files FROM '$WORK_DIRECTORY/files.csv' WITH (FORMAT csv, HEADER true)
TRUNCATE TABLE public.l12_apline_base_model, public.l12_apline_file_store;
INSERT INTO public.l12_apline_base_model (id, ticket_number, title, status_id, customer_organization, customer_contact_name, reception_content, investigation_result, resolution_content, received_at, started_at, resolved_at, occurred_at, customer_impact, remediation_note, created_at, updated_at, is_received_by_email, accepted_by_user_id, created_by_user_id, updated_by_user_id, request_type_id, failure_component_id, severity_id, business_system_id, emergency_id, impact_id, priority_id, cause_id, resolution_type_id, subsystem_id) OVERRIDING SYSTEM VALUE SELECT * FROM stage_base;
INSERT INTO public.l12_apline_file_store (id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type) OVERRIDING SYSTEM VALUE SELECT * FROM stage_files;
SQL
for table in l12_apline_base_model l12_apline_file_store; do
  cat >> "$LOCAL_WORK/update.sql" <<SQL
DO \$\$
DECLARE seq_name text; next_id bigint;
BEGIN
  seq_name := pg_get_serial_sequence('public.$table', 'id');
  IF seq_name IS NOT NULL THEN
    SELECT COALESCE(MAX(id)+1,1) INTO next_id FROM public.$table;
    EXECUTE format('ALTER SEQUENCE %s RESTART WITH %s',seq_name,next_id);
  END IF;
END \$\$;
SQL
done
cat >> "$LOCAL_WORK/update.sql" <<'SQL'
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
MAINTENANCE_STARTED=true
if [ "${#STOPPED_SERVICES[@]}" -gt 0 ]; then
  "${COMPOSE[@]}" stop "${STOPPED_SERVICES[@]}"
  for service in "${STOPPED_SERVICES[@]}"; do
    ids=$("${COMPOSE[@]}" ps -a -q "$service")
    for id in $ids; do
      if [ "$(docker inspect --format '{{.State.Running}}' "$id")" != false ]; then
        echo "サービスの停止を確認できません: $service" >&2
        exit 1
      fi
    done
  done
fi
backup_database() {
  local database=$1 name=$2
  container_exec pg_dump -w -U postgres -d "$database" -Fc -f "$WORK_DIRECTORY/$name.partial"
  container_exec test -s "$WORK_DIRECTORY/$name.partial"
  container_exec pg_restore --list "$WORK_DIRECTORY/$name.partial" > /dev/null
  container_exec mv -- "$WORK_DIRECTORY/$name.partial" "$WORK_DIRECTORY/$name.dump"
}
backup_database laravel12 before
if [ "$BK_EXISTS" = 1 ]; then
  backup_database laravel12_BK before-bk
fi
docker exec -i "$DATABASE_CONTAINER_ID" tee "$WORK_DIRECTORY/update.sql" < "$LOCAL_WORK/update.sql" > /dev/null
docker exec -i "${DOCKER_EXEC_OPTIONS[@]}" "$DATABASE_CONTAINER_ID" \
  psql -X -w -U postgres -d laravel12 -v ON_ERROR_STOP=1 --single-transaction -f - < "$LOCAL_WORK/update.sql"
COMMITTED=true
# 完了したDBを出力し、元バッチ同様にBKで復元検証する。
container_exec pg_dump -w -U postgres -d laravel12 --schema-only -f "$WORK_DIRECTORY/l12_backup_db_schema_only.partial"
container_exec test -s "$WORK_DIRECTORY/l12_backup_db_schema_only.partial"
container_exec mv -- "$WORK_DIRECTORY/l12_backup_db_schema_only.partial" "$WORK_DIRECTORY/l12_backup_db_schema_only.sql"
container_exec pg_dump -w -U postgres -d laravel12 --data-only -f "$WORK_DIRECTORY/l12_backup_db_data_only.partial"
container_exec test -s "$WORK_DIRECTORY/l12_backup_db_data_only.partial"
container_exec mv -- "$WORK_DIRECTORY/l12_backup_db_data_only.partial" "$WORK_DIRECTORY/l12_backup_db_data_only.sql"
backup_database laravel12 after
psql_admin -c 'DROP DATABASE IF EXISTS "laravel12_BK" WITH (FORCE);'
psql_admin -c 'CREATE DATABASE "laravel12_BK";'
container_exec pg_restore -w -U postgres -d laravel12_BK --exit-on-error --single-transaction "$WORK_DIRECTORY/after.dump"
container_exec psql -X -w -U postgres -d laravel12_BK -v ON_ERROR_STOP=1 -c 'SELECT 1;' > /dev/null
psql_admin -c "DROP DATABASE \"$VALIDATION_DB\" WITH (FORCE);"
VALIDATION_CREATED=false
if [ "${#STOPPED_SERVICES[@]}" -gt 0 ]; then
  "${COMPOSE[@]}" start "${STOPPED_SERVICES[@]}"
fi
MAINTENANCE_STARTED=false
echo "コピー完了。作業/退避先: $WORK_DIRECTORY"
