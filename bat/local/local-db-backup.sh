#!/bin/bash

# ローカルDBの論理バックアップをホストの export/DailyBackup に保存する。
# 使用例: bash bat/local/local-db-backup.sh [DB名]
# DB名の既定値は laravel12。production を指定すればローカルの本番相当DBを取得する。
# APP_ENV=local の場合のみ実行。既存DBの削除・再作成は行わない。
# DROP IF EXISTS付きプレーンSQL。成功時のみ同じDBの4日以上前のSQLを削除する。
# .env の DATABASE_CONTAINER_NAME が必須。PGDUMP_PASSWORD / SUDO_PASSWORD は任意。
# 保存先の権限に応じてsudoを使用する。既存ディレクトリの権限は変更しない。

set -euo pipefail
umask 077

USER_DIRECTORY=~
ENV_FILE="${USER_DIRECTORY}/Docker-Laravel-Pgsql/.env"
if [ ! -r "$ENV_FILE" ]; then
  echo "設定ファイルを読み込めません: $ENV_FILE" >&2
  exit 1
fi
source "$ENV_FILE"

: "${APP_ENV:?APP_ENV を .env に設定してください}"
: "${DATABASE_CONTAINER_NAME:?DATABASE_CONTAINER_NAME を .env に設定してください}"
# Docker の名前フィルターを完全一致の正規表現として安全に使える文字に限定する。
if [[ ! "$DATABASE_CONTAINER_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
  echo "DATABASE_CONTAINER_NAME が不正です。" >&2
  exit 1
fi

if [ "$APP_ENV" != local ]; then
  echo "APP_ENV=local の場合のみ実行できます。" >&2
  exit 1
fi
if [ "$#" -gt 1 ]; then
  echo "使用方法: $0 [DB名（既定値: laravel12）]" >&2
  exit 1
fi
BACKUP_DATABASE=${1-laravel12}
# ファイル名・削除パターンにも使うため、安全なDB名に限定する。
if [[ ! "$BACKUP_DATABASE" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
  echo "DB名は小文字英数字・アンダースコアの63文字以内で指定してください（先頭は英字またはアンダースコア）。" >&2
  exit 1
fi

# 名前内のドットをエスケープし、部分一致や複数コンテナへの誤実行を防ぐ。
CONTAINER_NAME_PATTERN=${DATABASE_CONTAINER_NAME//./\\.}
CONTAINER_ID=$(docker ps -q --filter "name=^/${CONTAINER_NAME_PATTERN}$")
if [ -z "$CONTAINER_ID" ] || [[ "$CONTAINER_ID" == *$'\n'* ]]; then
  echo "起動中の対象コンテナを一意に特定できません: $DATABASE_CONTAINER_NAME" >&2
  exit 1
fi

# 認証入力とコマンドの標準入力（SQLデータ）を分離する。
# 各操作の前に認証を更新し、長時間のダンプ後もパスワード入力を不要にする。
run_sudo() {
  if [ -n "${SUDO_PASSWORD:-}" ]; then
    if ! sudo -S -p '' -v <<< "$SUDO_PASSWORD"; then
      echo "sudo 認証に失敗しました。SUDO_PASSWORD を確認してください。" >&2
      return 1
    fi
    sudo -n "$@"
  else
    sudo "$@"
  fi
}

SAVEPATH="${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/DailyBackup"
# 保存と世代削除に先立って認証する。認証失敗時はバックアップを開始しない。
run_sudo -v
# コンテナが作成したディレクトリはホストユーザーで書き込めない場合がある。
FILE_COMMAND=()
if [ ! -d "$SAVEPATH" ] || [ ! -w "$SAVEPATH" ] || [ ! -x "$SAVEPATH" ]; then
  FILE_COMMAND=(run_sudo)
fi
"${FILE_COMMAND[@]}" mkdir -p "$SAVEPATH"
CURRENT_DATE=$(date +'%Y%m%d-%H%M%S')
TEMP_FILE=$("${FILE_COMMAND[@]}" mktemp "${SAVEPATH}/${BACKUP_DATABASE}-dbdump-${CURRENT_DATE}-XXXXXX")
# 失敗・中断時は未完成ファイルを削除する。
trap '"${FILE_COMMAND[@]}" rm -f -- "$TEMP_FILE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# パスワードが必要な場合だけ環境変数として渡す（引数に値を含めない）。
# 未指定時はコンテナ内のローカル認証設定を使用する。
DOCKER_EXEC_OPTIONS=()
if [ -n "${PGDUMP_PASSWORD:-}" ]; then
  export PGPASSWORD="$PGDUMP_PASSWORD"
  DOCKER_EXEC_OPTIONS=(-e PGPASSWORD)
fi

# 標準出力をホストに保存するため、コンテナ内の bash やマウント先に依存しない。
if ! docker exec "${DOCKER_EXEC_OPTIONS[@]}" "$CONTAINER_ID" \
  pg_dump -w -U postgres -c --if-exists -d "$BACKUP_DATABASE" | \
  "${FILE_COMMAND[@]}" tee -- "$TEMP_FILE" > /dev/null; then
  echo "バックアップに失敗しました。古いファイルの削除は行いません。" >&2
  exit 1
fi
if ! "${FILE_COMMAND[@]}" test -s "$TEMP_FILE"; then
  echo "バックアップが空のため処理を中止しました。" >&2
  exit 1
fi
SAVEFILE="${TEMP_FILE}.sql"
"${FILE_COMMAND[@]}" mv -- "$TEMP_FILE" "$SAVEFILE"
echo "バックアップを保存しました: $SAVEFILE"

# 当日0時を基準に4日以上経過した、このバッチのSQLファイルだけを削除する。
run_sudo find "$SAVEPATH" -maxdepth 1 -type f -name "${BACKUP_DATABASE}-dbdump-*.sql" \
  -daystart -mtime +3 -exec rm -- {} +
