#!/bin/sh

#
# 開発環境から起動して本番環境の添付ファイル群をコピー
#


arg1=$1

USER_DIRECTORY=~

ATTACH_DIRECTORY="${USER_DIRECTORY}/apline-laravel10/storage/app/apline/${arg1}"

#cd "${USER_DIRECTORY}/apline-laravel10/storage/app/apline"

#echo "${USER_DIRECTORY}/apline-laravel10/storage/app/apline"
echo $ATTACH_DIRECTORY
zip "${USER_DIRECTORY}/Docker-Laravel-Pgsql/export/archive${arg1}.zip" -r $ATTACH_DIRECTORY
