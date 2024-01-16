#!/bin/sh

#
# 開発環境から起動して本番環境の添付ファイル群をコピー
#ssh sailpreserver20 ~/Docker-Laravel-Pgsql/bat/production/production_attachment_import_2024.sh # 本番環境の添付ファイルをZIP圧縮
cd ~/apline-laravel10/storage/app/apline
zip ~/Docker-Laravel-Pgsql/export/archive2024 -r 2024
