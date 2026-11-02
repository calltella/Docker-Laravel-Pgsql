#!/bin/bash

# local-db-backup.sh / prod-db-production-backup.sh のプレーンSQLをローカルDBへ復元する。
# 使用方法: bash bat/local/local-db-restore.sh SQLファイル [復元先DB名（既定値: laravel12）]
# APP_ENV=local とComposeのpostgresコンテナ一致を必須とする。
# 信頼できるpg_dumpのSQLだけを指定すること（postgres権限で実行する）。
# 確認後に関連サービスを停止し、既存DBを export/pgsql/*.dump へ退避する。
# 既存DBを削除・再作成後、SQLを単一トランザクションで実行する。
# 失敗時はサービス停止を維持する。DB削除はロールバックされないため、退避を使って復旧する。
# カスタム形式の退避を戻す場合はpg_restoreを使用する（このバッチの入力はSQLのみ）。
# Compose外のクライアントは事前に停止する。退避ファイルは自動削除しない。

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
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "使用方法: $0 SQLファイル [復元先DB名（既定値: laravel12）]" >&2
  exit 1
fi
INPUT_FILE=$1
RESTORE_DATABASE=${2-laravel12}
if [[ ! "$RESTORE_DATABASE" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || \
   [[ "$RESTORE_DATABASE" = postgres || "$RESTORE_DATABASE" = template* ]]; then
  echo "復元先DB名が不正、またはシステムDBです。" >&2
  exit 1
fi
run_sudo() {
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    sudo -S -p '' -v <<< "$SUDO_PASSWORD" || return 1
    sudo -n "$@"
  else
    sudo "$@"
  fi
}
READ_COMMAND=()
if [ ! -r "$INPUT_FILE" ]; then
  READ_COMMAND=(run_sudo)
fi
"${READ_COMMAND[@]}" test -f "$INPUT_FILE"
"${READ_COMMAND[@]}" test -s "$INPUT_FILE"

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

# コピー・R2復元バッチとも排他し、同時更新を防ぐ。
exec 8>"${PROJECT_DIRECTORY}/.local-db-copy.lock"
exec 9>"${PROJECT_DIRECTORY}/.r2-restore.lock"
if ! flock -n 8 || ! flock -n 9; then
  echo "別のローカルDB更新バッチが実行中です。" >&2
  exit 1
fi
# ホストのSQLをコンテナへ固定し、確認後に入力元が変わる影響を避ける。
DUMP_FILE=$(container_exec mktemp /tmp/pgsql/local-restore-input-XXXXXXXX)
trap 'container_exec rm -f -- "$DUMP_FILE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"${READ_COMMAND[@]}" cat -- "$INPUT_FILE" | docker exec -i "$DATABASE_CONTAINER_ID" tee "$DUMP_FILE" > /dev/null
container_exec test -s "$DUMP_FILE"
DB_EXISTS=$(psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname = '${RESTORE_DATABASE}';")
RUNNING_SERVICES=$("${COMPOSE[@]}" ps --services --status running)
STOPPED_SERVICES=()
while IFS= read -r service; do
  case "$service" in
    nginx|php|legacy|scheduler|apline-sync-worker|pgadmin4) STOPPED_SERVICES+=("$service") ;;
  esac
done <<< "$RUNNING_SERVICES"

printf '環境: %s\nコンテナ: %s\n削除・復元対象DB: %s\n復元ファイル: %s\n' \
  "$APP_ENV" "$DATABASE_CONTAINER_NAME" "$RESTORE_DATABASE" "$INPUT_FILE"
printf '停止・成功後に再開するサービス: %s\n' "${STOPPED_SERVICES[*]:-なし}"
if ! read -r -p "既存DBを退避後に削除して復元します。続行する場合は restore ${RESTORE_DATABASE} と入力してください: " CONFIRM_EXECUTION || [ "$CONFIRM_EXECUTION" != "restore ${RESTORE_DATABASE}" ]; then
  echo "処理を中止しました。" >&2
  exit 1
fi

BACKUP_FILE=''
MAINTENANCE_STARTED=false
on_exit() {
  local status=$?
  container_exec rm -f -- "$DUMP_FILE" || true
  if [ "$status" -ne 0 ] && [ "$MAINTENANCE_STARTED" = true ]; then
    echo "処理に失敗しました。アプリ関連サービスは自動再開していません。" >&2
    echo "停止対象: ${STOPPED_SERVICES[*]:-なし}" >&2
    if [ -n "$BACKUP_FILE" ]; then
      echo "既存DBの退避先（コンテナ内）: $BACKUP_FILE" >&2
    fi
  fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
MAINTENANCE_STARTED=true
if [ "${#STOPPED_SERVICES[@]}" -gt 0 ]; then
  "${COMPOSE[@]}" stop "${STOPPED_SERVICES[@]}"
fi

if [ "$DB_EXISTS" = 1 ]; then
  # Alpine / BusyBox の mktemp に合わせ、テンプレートは X で終える。
  # 未完成の退避ファイルは拡張子なしで保持し、成功時のみ .dump に変更する。
  PARTIAL_FILE=$(container_exec mktemp "/tmp/pgsql/${RESTORE_DATABASE}-before-restore-XXXXXXXX")
  container_exec pg_dump -w -U postgres -d "$RESTORE_DATABASE" -Fc -f "$PARTIAL_FILE"
  container_exec test -s "$PARTIAL_FILE"
  container_exec pg_restore --list "$PARTIAL_FILE" > /dev/null
  BACKUP_FILE="${PARTIAL_FILE}.dump"
  container_exec mv -- "$PARTIAL_FILE" "$BACKUP_FILE"
  echo "既存DBを退避しました: ${PROJECT_DIRECTORY}/export/pgsql/${BACKUP_FILE##*/}"
fi

psql_admin -c "DROP DATABASE IF EXISTS \"${RESTORE_DATABASE}\" WITH (FORCE);"
psql_admin -c "CREATE DATABASE \"${RESTORE_DATABASE}\";"
container_exec psql -X -w -U postgres -d "$RESTORE_DATABASE" \
  -v ON_ERROR_STOP=1 --single-transaction -f "$DUMP_FILE"
# 復元後にDBへの接続と簡単な問い合わせが成功することを確認する。
container_exec psql -X -w -U postgres -d "$RESTORE_DATABASE" -v ON_ERROR_STOP=1 -c 'SELECT 1;' > /dev/null
if [ "${#STOPPED_SERVICES[@]}" -gt 0 ]; then
  "${COMPOSE[@]}" start "${STOPPED_SERVICES[@]}"
fi
MAINTENANCE_STARTED=false
echo "${RESTORE_DATABASE} の復元が完了しました。退避ファイルは自動削除しません。"
