#!/bin/bash

# 開発環境で取得したカスタム形式のダンプを、このホストの laravel12 DB に復元する。
# ダンプを事前に ~/Docker-Laravel-Pgsql/export/pgsql/laravel12.dump へ転送すること。
# コンテナ内では compose.yaml のマウント先 /tmp/pgsql/laravel12.dump を使用する。
# .env の APP_ENV / DATABASE_CONTAINER_NAME は必須。PGDUMP_PASSWORD は認証が必要な場合のみ指定。
# ファイル・形式・接続・ComposeのDBコンテナを検証し、環境と対象を表示して確認する。
# 確認後、起動中のアプリ関連サービスを停止し、既存DBを同じ export/pgsql 配下へ退避する。
# 退避成功後に既存DBの接続を強制切断して削除・再作成し、単一トランザクションで復元する。
# 成功時のみ、今回停止したサービスを再開する。失敗時は停止を維持し、退避ファイルを保持する。
# 外部からDBへ接続する処理は別途停止すること。実行にはDockerの操作権限が必要。
# 入力のない自動実行では確認を通過できないため中止する。
#
# 【退避バックアップに戻す手順】
# 1. プロジェクト直下へ移動し、戻したい退避ファイルを確認する。
#    cd ~/Docker-Laravel-Pgsql
#    sudo ls -lht export/pgsql/laravel12-before-restore-*.dump
#    拡張子が .dump でないファイルは作成途中の可能性があるため使用しない。
# 2. 現在の復元用ダンプを保存する（存在する場合）。
#    sudo cp -p export/pgsql/laravel12.dump \
#      "export/pgsql/laravel12.dump.saved-$(date +%Y%m%d-%H%M%S)"
# 3. 選んだ退避ファイルを復元用ダンプにコピーする。
#    XXXXXXXX は手順1で確認した実際のファイル名に合わせて置き換える。
#    sudo cp -p export/pgsql/laravel12-before-restore-XXXXXXXX.dump \
#      export/pgsql/laravel12.dump
# 4. このバッチを再実行し、確認画面で restore laravel12 と入力する。
#    ./bat/production/prod-db-laravel12-restore.sh
#    現在の laravel12 は再度退避され、選んだバックアップで置き換えられる。
# 5. 前回の失敗で停止したままのサービスは今回の自動再開対象に含まれない。
#    復元成功を確認した後、必要なサービスだけ手動で再開する。
#    docker compose start apline-sync-worker legacy nginx php scheduler

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

DUMP_FILE=/tmp/pgsql/laravel12.dump
container_exec test -r "$DUMP_FILE"
container_exec test -s "$DUMP_FILE"
# 目次の検証は形式確認。データ部分の完全性は実際の復元時に検証される。
container_exec pg_restore --list "$DUMP_FILE" > /dev/null
DB_EXISTS=$(psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname = 'laravel12';")
RUNNING_SERVICES=$("${COMPOSE[@]}" ps --services --status running)
STOPPED_SERVICES=()
while IFS= read -r service; do
  case "$service" in
    nginx|php|legacy|scheduler|apline-sync-worker) STOPPED_SERVICES+=("$service") ;;
  esac
done <<< "$RUNNING_SERVICES"

printf '環境: %s\nコンテナ: %s\n削除・復元対象DB: laravel12\n復元ファイル: %s\n' \
  "$APP_ENV" "$DATABASE_CONTAINER_NAME" "${PROJECT_DIRECTORY}/export/pgsql/laravel12.dump"
printf '停止・成功後に再開するサービス: %s\n' "${STOPPED_SERVICES[*]:-なし}"
if ! read -r -p '既存DBを退避後に削除して復元します。続行する場合は restore laravel12 と入力してください: ' CONFIRM_EXECUTION || [ "$CONFIRM_EXECUTION" != 'restore laravel12' ]; then
  echo "処理を中止しました。" >&2
  exit 1
fi

BACKUP_FILE=''
MAINTENANCE_STARTED=false
on_exit() {
  local status=$?
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
  PARTIAL_FILE=$(container_exec mktemp /tmp/pgsql/laravel12-before-restore-XXXXXXXX)
  container_exec pg_dump -w -U postgres -d laravel12 -Fc -f "$PARTIAL_FILE"
  container_exec test -s "$PARTIAL_FILE"
  container_exec pg_restore --list "$PARTIAL_FILE" > /dev/null
  BACKUP_FILE="${PARTIAL_FILE}.dump"
  container_exec mv -- "$PARTIAL_FILE" "$BACKUP_FILE"
  echo "既存DBを退避しました: ${PROJECT_DIRECTORY}/export/pgsql/${BACKUP_FILE##*/}"
fi

psql_admin -c 'DROP DATABASE IF EXISTS "laravel12" WITH (FORCE);'
psql_admin -c 'CREATE DATABASE "laravel12";'
container_exec pg_restore -w -U postgres -d laravel12 \
  --exit-on-error --single-transaction "$DUMP_FILE"
# 復元後にDBへの接続と簡単な問い合わせが成功することを確認する。
container_exec psql -X -w -U postgres -d laravel12 -v ON_ERROR_STOP=1 -c 'SELECT 1;' > /dev/null
if [ "${#STOPPED_SERVICES[@]}" -gt 0 ]; then
  "${COMPOSE[@]}" start "${STOPPED_SERVICES[@]}"
fi
MAINTENANCE_STARTED=false
echo "laravel12 の復元が完了しました。退避ファイルは自動削除しません。"
