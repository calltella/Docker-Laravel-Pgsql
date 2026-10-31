#!/bin/bash

# R2のバックアップからローカル環境のDBを復元するLaravelコマンドを実行する。
# Docker用.envとLaravelのキャッシュ済み設定の両方が local の場合のみ許可する。
# 復元先はローカルComposeの postgres:5432 に限定し、DB名は
# Docker用.envの R2_RESTORE_DATABASE と一致することを事前確認してから php artisan で実行する。
# PHPは実行用に残し、入口・ワーカー・スケジューラー等の停止確認後に復元する。

set -euo pipefail
USER_DIRECTORY=~
PROJECT_DIRECTORY="${USER_DIRECTORY}/Docker-Laravel-Pgsql"
ENV_FILE="${PROJECT_DIRECTORY}/.env"
if [ ! -r "$ENV_FILE" ]; then
  echo "ERROR: 設定ファイルを読み込めません: $ENV_FILE" >&2
  exit 1
fi
source "$ENV_FILE"
: "${APP_ENV:?APP_ENV を .env に設定してください}"
: "${LARAVEL_CONTAINER_NAME:?LARAVEL_CONTAINER_NAME を .env に設定してください}"
: "${R2_RESTORE_DATABASE:?R2_RESTORE_DATABASE に復元を許可するDB名を設定してください}"
if [ "$APP_ENV" != local ]; then
  echo "ERROR: APP_ENV=local の場合のみ実行できます。" >&2
  exit 1
fi
if [[ ! "$LARAVEL_CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
  echo "ERROR: LARAVEL_CONTAINER_NAME が不正です。" >&2
  exit 1
fi
if [[ ! "$R2_RESTORE_DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]] || \
  [[ "$R2_RESTORE_DATABASE" = postgres || "$R2_RESTORE_DATABASE" = template* ]]; then
  echo "ERROR: R2_RESTORE_DATABASE が不正です。" >&2
  exit 1
fi
CONTAINER_NAME_PATTERN=${LARAVEL_CONTAINER_NAME//./\\.}
LARAVEL_CONTAINER_ID=$(docker ps --no-trunc -q --filter "name=^/${CONTAINER_NAME_PATTERN}$")
if [ -z "$LARAVEL_CONTAINER_ID" ] || [[ "$LARAVEL_CONTAINER_ID" == *$'\n'* ]]; then
  echo "ERROR: 起動中のコンテナを一意に特定できません: $LARAVEL_CONTAINER_NAME" >&2
  exit 1
fi
# 別プロジェクトのPHPコンテナへの誤実行を防ぐ。
COMPOSE=(docker compose --project-directory "$PROJECT_DIRECTORY" --env-file "$ENV_FILE" -f "$PROJECT_DIRECTORY/compose.yaml")
COMPOSE_PHP_ID=$("${COMPOSE[@]}" ps -q php)
COMPOSE_DB_ID=$("${COMPOSE[@]}" ps -q postgres)
if [ -z "$COMPOSE_PHP_ID" ] || [ -z "$COMPOSE_DB_ID" ]; then
  echo "ERROR: このプロジェクトの php / postgres が起動していません。" >&2
  exit 1
fi
if [ "$(docker inspect --format '{{.Id}}' "$COMPOSE_PHP_ID")" != "$LARAVEL_CONTAINER_ID" ]; then
  echo "ERROR: 指定コンテナとComposeのphpが一致しません。" >&2
  exit 1
fi
printf '対象コンテナ: %s (%s)\n' "$LARAVEL_CONTAINER_NAME" "$LARAVEL_CONTAINER_ID"

# 同じバッチ同士の停止・再開の競合も防ぐ。
exec 9>"${PROJECT_DIRECTORY}/.r2-restore.lock"
if ! flock -n 9; then
  echo "ERROR: 別のR2復元バッチが実行中です。" >&2
  exit 1
fi

# php / postgres / redis は残す。phpにはホスト公開ポートがなく、入口はnginx。
# Compose外のクライアント・手動起動したワーカーは実行者が事前に停止する。
STOP_SERVICES=(nginx apline-sync-worker scheduler legacy pgadmin4)
RUNNING_SERVICES=$("${COMPOSE[@]}" ps --status running --services)
RESTART_SERVICES=()
for service in "${STOP_SERVICES[@]}"; do
  if [[ $'\n'"$RUNNING_SERVICES"$'\n' == *$'\n'"$service"$'\n'* ]]; then
    RESTART_SERVICES+=("$service")
  fi
done
# 失敗時は自動再開しない。確認・手動復旧後に再開する。
echo "入口・ワーカー・スケジューラー等を停止します。失敗時は停止状態を維持します。"
"${COMPOSE[@]}" stop "${STOP_SERVICES[@]}"
for service in "${STOP_SERVICES[@]}"; do
  ids=$("${COMPOSE[@]}" ps -a -q "$service")
  for id in $ids; do
    if [ "$(docker inspect --format '{{.State.Running}}' "$id")" != false ]; then
      echo "ERROR: $service の停止を確認できません。復元は実行しません。" >&2
      exit 1
    fi
  done
done
if [ "$(docker inspect --format '{{.State.Running}}' "$LARAVEL_CONTAINER_ID")" != true ] || \
   [ "$(docker inspect --format '{{.State.Running}}' "$COMPOSE_DB_ID")" != true ]; then
  echo "ERROR: 復元用php / postgres が停止しています。" >&2
  exit 1
fi

# Laravelの設定キャッシュも含めた実効設定を事前確認する。
# パスワード等の接続情報は出力しない。
if ! docker exec -i --workdir /var/www/html/laravel "$LARAVEL_CONTAINER_ID" \
  php /dev/stdin "$R2_RESTORE_DATABASE" <<'PHP'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();
$allowedDatabase = $argv[1];
$host = config('database.connections.pgsql.host');
$port = config('database.connections.pgsql.port');
$database = config('database.restore_db_database');
if ($app->environment() !== 'local'
    || $host !== 'postgres'
    || (string) $port !== '5432'
    || $database !== $allowedDatabase) {
    fwrite(STDERR, "ERROR: Laravelの環境・DB接続先・復元先DBが許可条件と一致しません。\n");
    exit(1);
}
printf("Laravel環境: local / 復元先: postgres:5432/%s\n", $allowedDatabase);
PHP
then
  echo "ERROR: Laravelの事前確認に失敗しました。サービスは停止状態のままです。" >&2
  exit 1
fi

# Artisanの終了コードを確認し、成功時のみ停止前に起動していたサービスを再開する。
if docker exec --workdir /var/www/html/laravel "$LARAVEL_CONTAINER_ID" \
  php artisan app:restore-database-command --services-stopped --no-interaction; then
  if [ "${#RESTART_SERVICES[@]}" -gt 0 ]; then
    "${COMPOSE[@]}" start "${RESTART_SERVICES[@]}"
  fi
else
  status=$?
  echo "ERROR: 復元に失敗しました。DB状態とログを確認してください。サービスは停止状態のままです。" >&2
  exit "$status"
fi
