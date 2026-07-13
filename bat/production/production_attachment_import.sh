#!/bin/sh

#
# 開発環境から起動して本番環境の添付ファイル群をコピー
#

# コマンドライン引数の取得
arg1=$1

# 引数がなかった場合は今年をセット
if [ -z "$arg1" ]; then
  CURRENT_YEAR=$(date +'%Y')
else
  CURRENT_YEAR=$arg1
fi

USER_DIRECTORY=~

ATTACH_DIRECTORY="${USER_DIRECTORY}/apline_laravel10/storage/app/apline/${arg1}"

FILE_STORE_DIRECTORY="${USER_DIRECTORY}/apline_laravel10/storage/app/filestore/"

echo $ATTACH_DIRECTORY
zip "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/archive${arg1}.zip" -r $ATTACH_DIRECTORY

echo $FILE_STORE_DIRECTORY
zip "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/filestore.zip" -r $FILE_STORE_DIRECTORY
