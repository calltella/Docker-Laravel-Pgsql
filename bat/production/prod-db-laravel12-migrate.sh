#!/bin/bash

# production.public.migrate_apline_base_model と PostgreSQL用に変換済みの
# export/pgsql/apline_file_store_backup.sql を laravel12 の2テーブルへ取り込む。
# APP_ENV / DATABASE_CONTAINER_NAME 必須。PGDUMP_PASSWORD はDB認証が必要な場合のみ。
# 信頼できる入力SQLのみ使用すること（postgres権限で実行される）。
# 全環境で copy laravel12 の確認を要求し、起動中のアプリ関連サービスを停止する。
# 入力SQLは一意な検証用DBで実行し、テーブルを抽出してから対象DBへ取り込む。
# 更新前のDB全体を退避し、データ・索引・設定の変更を単一トランザクションで実行。
# 同じIDはUPDATE、新規IDはINSERTし、既存IDに紐づくお気に入り等を維持する。
# コピー元にないIDはDELETE。削除時の関連データの扱いは既存の外部キー定義に従う。
# 外部キーで削除を拒否された場合はトランザクション全体を中止する。
# 最終状態を単一ダンプに保存し、検証用DBへ復元して全ユーザーテーブルの件数を比較する。
# laravel12_BK は上書きしない。成功時のみ今回停止したサービスを再開する。
# 失敗時はサービス停止を維持。コミット後の検証失敗でも自動ロールバックはしない。
# 退避・完成ダンプと失敗時の作業ファイルは export/pgsql/production-db-copy.XXXXXXXX に保持。
# before.dump が更新前、after.dump が更新後（.partial は未完成）。復旧は復元バッチの手順を参照。
# 同じホストユーザーの同時実行を flock で防止。別ホスト・別ユーザーからは同時実行しないこと。
# 外部からのDB書き込みも事前に停止すること。Docker操作権限と検証用DBの作成権限が必要。

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


# ホストユーザー単位のロック。スクリプト終了時に自動解放される。
exec 9>"${TMPDIR:-/tmp}/production-db-copy-${UID}.lock"
if ! flock -n 9; then
  echo "同じユーザーによるコピー処理が既に実行中です。" >&2
  exit 1
fi
INPUT_SQL=/tmp/pgsql/apline_file_store_backup.sql
container_exec test -r "$INPUT_SQL"
container_exec test -s "$INPUT_SQL"
container_exec psql -X -w -U postgres -d production -v ON_ERROR_STOP=1 \
  -c 'SELECT id FROM public.migrate_apline_base_model LIMIT 0;' > /dev/null
container_exec psql -X -w -U postgres -d laravel12 -v ON_ERROR_STOP=1 \
  -c 'SELECT id FROM public.l12_apline_base_model LIMIT 0;' \
  -c 'SELECT id FROM public.l12_apline_file_store LIMIT 0;' > /dev/null
# 作業用テーブルと既存のユーザーテーブルの衝突は、削除せずに中止する。
COLLISION=$(container_exec psql -X -w -U postgres -d laravel12 -v ON_ERROR_STOP=1 -tAc \
  "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname IN ('migrate_apline_base_model','apline_file_store');")
if [ "$COLLISION" != 0 ]; then
  echo "laravel12 に作業用と同名のテーブルが存在します。内容を確認してください。" >&2
  exit 1
fi
RUNNING_SERVICES=$("${COMPOSE[@]}" ps --services --status running)
STOPPED_SERVICES=()
while IFS= read -r service; do
  case "$service" in
    nginx|php|legacy|scheduler|apline-sync-worker) STOPPED_SERVICES+=("$service") ;;
  esac
done <<< "$RUNNING_SERVICES"
printf '環境: %s\nコンテナ: %s\nコピー元: production + %s\n更新先: laravel12\n停止対象: %s\n' \
  "$APP_ENV" "$DATABASE_CONTAINER_NAME" "$INPUT_SQL" "${STOPPED_SERVICES[*]:-なし}"
if ! read -r -p '更新前DBを退避してコピーします。続行する場合は copy laravel12 と入力してください: ' CONFIRM_EXECUTION || [ "$CONFIRM_EXECUTION" != 'copy laravel12' ]; then
  echo "処理を中止しました。" >&2
  exit 1
fi

WORK_DIRECTORY=$(container_exec mktemp -d /tmp/pgsql/production-db-copy.XXXXXXXX)
VALIDATION_DB="dbcopy_$(date +%Y%m%d%H%M%S)_$$"
VALIDATION_CREATED=false
MAINTENANCE_STARTED=false
COMMITTED=false
on_exit() {
  local status=$?
  trap - EXIT
  if [ "$VALIDATION_CREATED" = true ]; then
    psql_admin -c "DROP DATABASE IF EXISTS \"$VALIDATION_DB\" WITH (FORCE);" || \
      echo "検証用DBの手動削除が必要です: $VALIDATION_DB" >&2
  fi
  if [ "$status" -ne 0 ]; then
    echo "処理失敗。作業・退避先（コンテナ内）: $WORK_DIRECTORY" >&2
    if [ "$MAINTENANCE_STARTED" = true ]; then
      echo "サービスは自動再開していません: ${STOPPED_SERVICES[*]:-なし}" >&2
    fi
    echo "更新トランザクションのコミット済み: $COMMITTED" >&2
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 入力は固定名から実行専用ディレクトリへコピーし、このスナップショットを検証・使用する。
container_exec cp -- "$INPUT_SQL" "$WORK_DIRECTORY/input.sql"
psql_admin -c "CREATE DATABASE \"$VALIDATION_DB\" TEMPLATE template0;"
VALIDATION_CREATED=true
container_exec psql -X -w -U postgres -d "$VALIDATION_DB" -v ON_ERROR_STOP=1 \
  -f "$WORK_DIRECTORY/input.sql"
container_exec pg_dump -w -U postgres -d "$VALIDATION_DB" \
  -Fc --table=public.apline_file_store -f "$WORK_DIRECTORY/files.dump"
container_exec pg_dump -w -U postgres -d production \
  -Fc --table=public.migrate_apline_base_model -f "$WORK_DIRECTORY/tickets.dump"

# 作業用テーブルに索引・外部キーは不要。post-data を除外して既存名との衝突を防ぐ。
# pre-data と data は同じアーカイブから抽出し、定義とデータの整合を維持する。
for table_dump in files tickets; do
  container_exec pg_restore --exit-on-error --no-owner --no-privileges \
    --section=pre-data --section=data \
    -f "$WORK_DIRECTORY/${table_dump}.sql" "$WORK_DIRECTORY/${table_dump}.dump"
done

MAINTENANCE_STARTED=true
if [ "${#STOPPED_SERVICES[@]}" -gt 0 ]; then
  "${COMPOSE[@]}" stop "${STOPPED_SERVICES[@]}"
fi
container_exec pg_dump -w -U postgres -d laravel12 -Fc -f "$WORK_DIRECTORY/before.partial"
container_exec test -s "$WORK_DIRECTORY/before.partial"
container_exec pg_restore --list "$WORK_DIRECTORY/before.partial" > /dev/null
container_exec mv -- "$WORK_DIRECTORY/before.partial" "$WORK_DIRECTORY/before.dump"
echo "更新前DBの退避完了: $WORK_DIRECTORY/before.dump"

# psql自身の --single-transaction で、取り込みから最終設定変更までをまとめる。
docker exec -i "${DOCKER_EXEC_OPTIONS[@]}" "$DATABASE_CONTAINER_ID" \
  psql -X -w -U postgres -d laravel12 -v ON_ERROR_STOP=1 --single-transaction -f - <<SQL
SET LOCAL search_path = public;
\i $WORK_DIRECTORY/tickets.sql
\i $WORK_DIRECTORY/files.sql
SET LOCAL search_path = public;
-- 並行書き込みを防ぎ、関連行が参照する既存のIDは削除せず更新する。
LOCK TABLE public.l12_apline_base_model, public.l12_apline_file_store IN EXCLUSIVE MODE;
INSERT INTO l12_apline_base_model (id, ticket_number, title, status_id, customer_organization, customer_contact_name, reception_content, investigation_result, resolution_content, received_at, started_at, resolved_at, occurred_at, customer_impact, remediation_note, created_at, updated_at, is_received_by_email, accepted_by_user_id, created_by_user_id, updated_by_user_id, request_type_id, failure_component_id, severity_id, business_system_id, emergency_id, impact_id, priority_id, cause_id, resolution_type_id, subsystem_id)
SELECT id, apid, title, status_id, organization, responsible, work_content, surveyresults, dealanswer, reception, work_start_time, work_end_time, occurrencedate, customerimpact, correspondingnote, created_at, updated_at, mailflag, acceptance_id, slipissuance_id, itemupdater_id, request_category_id, classification_id, severity_id, business_id, emergency_id, impact_id, priority_id, cause_id, deal_id, subsystem_id
FROM migrate_apline_base_model WHERE true
ON CONFLICT (id) DO UPDATE SET
  ticket_number = EXCLUDED.ticket_number,
  title = EXCLUDED.title,
  status_id = EXCLUDED.status_id,
  customer_organization = EXCLUDED.customer_organization,
  customer_contact_name = EXCLUDED.customer_contact_name,
  reception_content = EXCLUDED.reception_content,
  investigation_result = EXCLUDED.investigation_result,
  resolution_content = EXCLUDED.resolution_content,
  received_at = EXCLUDED.received_at,
  started_at = EXCLUDED.started_at,
  resolved_at = EXCLUDED.resolved_at,
  occurred_at = EXCLUDED.occurred_at,
  customer_impact = EXCLUDED.customer_impact,
  remediation_note = EXCLUDED.remediation_note,
  created_at = EXCLUDED.created_at,
  updated_at = EXCLUDED.updated_at,
  is_received_by_email = EXCLUDED.is_received_by_email,
  accepted_by_user_id = EXCLUDED.accepted_by_user_id,
  created_by_user_id = EXCLUDED.created_by_user_id,
  updated_by_user_id = EXCLUDED.updated_by_user_id,
  request_type_id = EXCLUDED.request_type_id,
  failure_component_id = EXCLUDED.failure_component_id,
  severity_id = EXCLUDED.severity_id,
  business_system_id = EXCLUDED.business_system_id,
  emergency_id = EXCLUDED.emergency_id,
  impact_id = EXCLUDED.impact_id,
  priority_id = EXCLUDED.priority_id,
  cause_id = EXCLUDED.cause_id,
  resolution_type_id = EXCLUDED.resolution_type_id,
  subsystem_id = EXCLUDED.subsystem_id;
INSERT INTO l12_apline_file_store (id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type)
SELECT id, folder, file_path, file_name, ext, size, md5_hash, join_id, download_key, temp_key, created_at, updated_at, deleted_at, content_type FROM apline_file_store WHERE true
ON CONFLICT (id) DO UPDATE SET
  folder = EXCLUDED.folder,
  file_path = EXCLUDED.file_path,
  file_name = EXCLUDED.file_name,
  ext = EXCLUDED.ext,
  size = EXCLUDED.size,
  md5_hash = EXCLUDED.md5_hash,
  join_id = EXCLUDED.join_id,
  download_key = EXCLUDED.download_key,
  temp_key = EXCLUDED.temp_key,
  created_at = EXCLUDED.created_at,
  updated_at = EXCLUDED.updated_at,
  deleted_at = EXCLUDED.deleted_at,
  content_type = EXCLUDED.content_type;

-- 対象外IDだけを削除。参照制約に違反すれば全更新がロールバックされる。
DELETE FROM public.l12_apline_file_store AS target
WHERE NOT EXISTS (SELECT 1 FROM public.apline_file_store AS source WHERE source.id = target.id);
DELETE FROM public.l12_apline_base_model AS target
WHERE NOT EXISTS (SELECT 1 FROM public.migrate_apline_base_model AS source WHERE source.id = target.id);

DO \$\$
BEGIN
  IF (SELECT count(*) FROM public.l12_apline_base_model) <> (SELECT count(*) FROM public.migrate_apline_base_model)
     OR (SELECT count(*) FROM public.l12_apline_file_store) <> (SELECT count(*) FROM public.apline_file_store) THEN
    RAISE EXCEPTION '取り込み元と更新先の件数が一致しません';
  END IF;
END \$\$;
DROP TABLE public.migrate_apline_base_model;
DROP TABLE public.apline_file_store;
DO \$\$
DECLARE seq_name text; next_id bigint;
BEGIN
  seq_name := pg_get_serial_sequence('public.l12_apline_base_model', 'id');
  SELECT COALESCE(MAX(id) + 1, 1) INTO next_id FROM public.l12_apline_base_model;
  IF seq_name IS NULL THEN RAISE EXCEPTION 'idシーケンスがありません: l12_apline_base_model'; END IF;
  EXECUTE format('ALTER SEQUENCE %s RESTART WITH %s', seq_name, next_id);
END \$\$;
DO \$\$
DECLARE seq_name text; next_id bigint;
BEGIN
  seq_name := pg_get_serial_sequence('public.l12_apline_file_store', 'id');
  SELECT COALESCE(MAX(id) + 1, 1) INTO next_id FROM public.l12_apline_file_store;
  IF seq_name IS NULL THEN RAISE EXCEPTION 'idシーケンスがありません: l12_apline_file_store'; END IF;
  EXECUTE format('ALTER SEQUENCE %s RESTART WITH %s', seq_name, next_id);
END \$\$;
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
COMMITTED=true

# 索引・設定の変更を含めた最終状態を一つのスナップショットで取得する。
container_exec pg_dump -w -U postgres -d laravel12 -Fc -f "$WORK_DIRECTORY/after.partial"
container_exec test -s "$WORK_DIRECTORY/after.partial"
container_exec mv -- "$WORK_DIRECTORY/after.partial" "$WORK_DIRECTORY/after.dump"
psql_admin -c "DROP DATABASE \"$VALIDATION_DB\" WITH (FORCE);"
VALIDATION_CREATED=false
psql_admin -c "CREATE DATABASE \"$VALIDATION_DB\" TEMPLATE template0;"
VALIDATION_CREATED=true
container_exec pg_restore -w -U postgres -d "$VALIDATION_DB" \
  --exit-on-error --single-transaction "$WORK_DIRECTORY/after.dump"

# PGroonga等のインデックス経由の計数差を避け、全行走査で実データ件数を比較する。
compare_counts() {
  docker exec -i "${DOCKER_EXEC_OPTIONS[@]}" "$DATABASE_CONTAINER_ID" \
    psql -X -w -qAt -U postgres -d "$1" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_indexonlyscan = off;
SET LOCAL enable_bitmapscan = off;
SELECT format('SELECT %L, count(*) FROM %I.%I;', schemaname || '.' || tablename, schemaname, tablename)
FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY schemaname, tablename
\gexec
COMMIT;
SQL
}
LIVE_COUNTS=$(compare_counts laravel12)
RESTORED_COUNTS=$(compare_counts "$VALIDATION_DB")
# 調査用の件数一覧は、実行専用ディレクトリに残す。
printf '%s\n' "$LIVE_COUNTS" | docker exec -i "$DATABASE_CONTAINER_ID" \
  tee "$WORK_DIRECTORY/live-counts.txt" > /dev/null
printf '%s\n' "$RESTORED_COUNTS" | docker exec -i "$DATABASE_CONTAINER_ID" \
  tee "$WORK_DIRECTORY/restored-counts.txt" > /dev/null
if [ "$LIVE_COUNTS" != "$RESTORED_COUNTS" ]; then
  echo "復元検証でテーブル件数の不一致を検出しました。" >&2
  container_exec diff -u "$WORK_DIRECTORY/live-counts.txt" "$WORK_DIRECTORY/restored-counts.txt" >&2 || true
  echo "比較結果の保存先: $WORK_DIRECTORY/{live-counts,restored-counts}.txt" >&2
  exit 1
fi
# 正常終了前に検証用DBを削除。失敗した場合はサービスを再開しない。
psql_admin -c "DROP DATABASE \"$VALIDATION_DB\" WITH (FORCE);"
VALIDATION_CREATED=false
if [ "${#STOPPED_SERVICES[@]}" -gt 0 ]; then
  "${COMPOSE[@]}" start "${STOPPED_SERVICES[@]}"
fi
MAINTENANCE_STARTED=false
printf 'コピーと復元検証が完了しました。\n更新前: %s/before.dump\n更新後: %s/after.dump\n' "$WORK_DIRECTORY" "$WORK_DIRECTORY"
