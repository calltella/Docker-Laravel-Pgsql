#!/bin/bash


# ユーザーディレクトリを取得
USER_DIRECTORY=~

# envファイルから環境変数を読込
source "${USER_DIRECTORY}/Docker-Laravel-Pgsql/.env"

# コンテナIDを取得
CONTAINER_ID=$(docker ps -q --filter name="${DATABASE_CONTAINER_NAME}")

# コンテナが起動しているか確認
if [ -z "$CONTAINER_ID" ]; then
  echo "Container $DATABASE_CONTAINER_NAME is not running."
  exit 1  # 終了コード 1 でスクリプトを終了
else
  echo "Container $DATABASE_CONTAINER_NAME is running with ID: $CONTAINER_ID"
fi


# 日付と時間をファイルネームに
CURRENT_DATE=$(date +'%Y%m%d-%H%M%S')

# セーブパスの結合
SAVEPATH="${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/DailyBackup"

# ファイルネームを作成
SAVEFILE="production-dbdump-${CURRENT_DATE}"

# データベースをダンプ
# pg_dumpがファイルはバイナリファイルなので圧縮できない
docker exec $CONTAINER_ID bash -c 'set PGPASSWORD="${PGDUMP_PASSWORD}"'
docker exec $CONTAINER_ID bash -c "/usr/local/bin/pg_dump -U postgres -c --if-exists -d production -f /tmp/DailyBackup/${SAVEFILE}.sql"

# 過去３日以上経過したファイルは削除
sudo find $SAVEPATH -type f -daystart -mtime +3 -exec rm {} \;



