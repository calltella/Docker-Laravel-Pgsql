#!/bin/bash

# R2のバックアップからローカル環境のDBを復元するLaravelコマンドを実行する。
# Docker用.envとLaravelのキャッシュ済み設定の両方が local の場合のみ許可する。
# 復元先はローカルComposeの postgres:5432 に限定し、DB名は
# Docker用.envの R2_RESTORE_DATABASE と一致することを事前確認してから php artisan で実行する。
# 使用方法: bash bat/local/cloudflareR2-production-restore.sh [Laravel/バックアップ.zip | --list]
# 引数なしは最新世代。--list は世代一覧のみ表示し、サービス停止・復元は行わない。
#
# 世代一覧を表示（復元・サービス停止はしません）
# bash bat/local/cloudflareR2-production-restore.sh --list
#
# 一覧に表示されたR2パスを指定して復元
# bash bat/local/cloudflareR2-production-restore.sh 'Laravel/バックアップ名.zip'
#
# 引数なしは従来どおり最新世代
# bash bat/local/cloudflareR2-production-restore.sh
#
# PHPは実行用に残し、入口・ワーカー・スケジューラー等の停止確認後に復元する。

set -euo pipefail
if [ "$#" -gt 1 ]; then
  echo "使用方法: $0 [Laravel/バックアップ.zip | --list]" >&2
  exit 1
fi
BACKUP_PATH=${1-}
if [ "$#" -eq 1 ] && [ "$BACKUP_PATH" != --list ] && \
   [[ ! "$BACKUP_PATH" =~ ^Laravel/[^/]+\.[zZ][iI][pP]$ ]]; then
  echo "ERROR: --list または Laravel/ 直下のZIPファイルのパスを指定してください。" >&2
  exit 1
fi
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

if [ "$BACKUP_PATH" = --list ]; then
  docker exec --workdir /var/www/html/laravel "$LARAVEL_CONTAINER_ID" \
    php artisan app:restore-database-command --list-backups --no-interaction
  exit $?
fi
RESTORE_OPTIONS=()
if [ -n "$BACKUP_PATH" ]; then
  RESTORE_OPTIONS=("--backup=$BACKUP_PATH")
  printf '復元するR2ファイル: %s\n' "$BACKUP_PATH"
else
  echo "復元するR2ファイル: 最新世代"
fi

# 同じバッチ同士の停止・再開の競合も防ぐ。
exec 9>"${PROJECT_DIRECTORY}/.r2-restore.lock"
if ! flock -n 9; then
  echo "ERROR: 別のR2復元バッチが実行中です。" >&2
  exit 1
fi

# Laravelの設定キャッシュも含めた実効設定を事前確認する。
# 診断には確認対象の値だけを出力し、パスワード等は出力しない。
if ! docker exec -i --workdir /var/www/html/laravel "$LARAVEL_CONTAINER_ID" \
  php /dev/stdin "$R2_RESTORE_DATABASE" "$BACKUP_PATH" <<'PHP'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();
$allowedDatabase = $argv[1];
$host = config('database.connections.pgsql.host');
$port = config('database.connections.pgsql.port');
$database = config('database.restore_db_database');
$checks = [
    ['Laravel環境 (APP_ENV)', 'local', $app->environment()],
    ['DBホスト (database.connections.pgsql.host)', 'postgres', $host],
    ['DBポート (database.connections.pgsql.port)', '5432', (string) $port],
    ['復元先DB (database.restore_db_database / 期待値: Docker用.envのR2_RESTORE_DATABASE)', $allowedDatabase, $database],
];
$hasMismatch = false;
foreach ($checks as [$label, $expected, $actual]) {
    if ($actual !== $expected) {
        $hasMismatch = true;
    }
}
if ($hasMismatch) {
    fwrite(STDERR, "ERROR: Laravelの環境・DB接続先・復元先DBが許可条件と一致しません。\n");
    foreach ($checks as [$label, $expected, $actual]) {
        // JSON表記で未設定(null)・空文字・改行を区別する。
        fwrite(STDERR, sprintf(
            "  [%s] %s: 期待値=%s / 実際値=%s\n",
            $actual === $expected ? '一致' : '不一致',
            $label,
            json_encode($expected, JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE),
            json_encode($actual, JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE)
        ));
    }
    fwrite(STDERR, '  Laravel設定キャッシュ: ' . ($app->configurationIsCached() ? 'あり' : 'なし') . "\n");
    exit(1);
}
if ($argv[2] !== '') {
    $disk = Illuminate\Support\Facades\Storage::disk('r2');
    if (! in_array($argv[2], $disk->files('Laravel'), true)) {
        fwrite(STDERR, "ERROR: 指定したR2バックアップが存在しません。\n");
        exit(1);
    }
}
printf("Laravel環境: local / 復元先: postgres:5432/%s\n", $allowedDatabase);
PHP
then
  echo "ERROR: Laravelの事前確認に失敗しました。サービス停止・復元は実行していません。" >&2
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

# Artisanの終了コードを確認し、成功時のみ停止前に起動していたサービスを再開する。
if docker exec --workdir /var/www/html/laravel "$LARAVEL_CONTAINER_ID" \
  php artisan app:restore-database-command "${RESTORE_OPTIONS[@]}" --services-stopped --no-interaction; then
  if [ "${#RESTART_SERVICES[@]}" -gt 0 ]; then
    "${COMPOSE[@]}" start "${RESTART_SERVICES[@]}"
  fi
else
  status=$?
  echo "ERROR: 復元に失敗しました。DB状態とログを確認してください。サービスは停止状態のままです。" >&2
  exit "$status"
fi
