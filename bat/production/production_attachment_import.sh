#!/bin/sh

#
# 開発環境から起動して本番環境の添付ファイル群をコピー
#
cd ~/apline-laravel10/storage/app/apline
zip ~/Docker-Laravel-Pgsql/export/archive2023 -r 2023
