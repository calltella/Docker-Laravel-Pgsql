# Laravel開発環境@Docker

## 概要
DockerでLaravelを手軽に使用出来る様に
(Docker側のみphp,nodeを起動させる想定です。)

### Docker環境
 - Docker v25.0.6
 - docker-compose v2.29.1

### 構築環境
 - php:8.1.6-fpm
 - nginx:1.21.6
 - PostgreSQL:14.3 (PGroonga:2.3.7 日本語全文検索)
 - node:18.2.0

## 手順

### Git clone

```
$ git clone https://github.com/calltella/Docker-Laravel-Pgsql.git
```

### 環境変数コピー
```
$ cd Docker-Laravel-Pgsql
$ cp .env.example .env
```
### Docker起動
```
$ docker-compose up -d
```
### php と legacy のファイル共有

両コンテナの `/var/www/html/shared` は、同じ名前付きボリューム
`php_legacy_shared` を使用します。ここに保存したファイルは相互に読み書きできます。
初回は共有ディレクトリの所有者を設定したイメージをビルドして起動します。

```sh
docker-compose up -d --build php legacy
```

データはコンテナを再作成しても保持されます。`docker-compose down -v` は
この共有ボリュームも削除するため、保存データが必要な場合は実行しないでください。

### laravelプロジェクト配置
```
$ docker-compose exec laravel bash
# rm -f .gitignore //フォルダの中身が空じゃないとエラーになる
# composer create-project laravel/laravel .
# composer create-project "laravel/laravel=9.1.*" . //バージョン指定したい場合(v9.2からlaravel-mix廃止)
```

### laravelインストール後
```
# php artisan key:generate
# chown -R nginx:nginx storage
# exit
```
### この状態で動きますがlaravel編集しにくいので修正するフォルダの権限を変更します。
```
$ USERNAME=$(whoami)
$ sudo chown -R $USERNAME:$USERNAME laravel/app
$ sudo chown -R $USERNAME:$USERNAME laravel/routes
$ sudo chown -R $USERNAME:$USERNAME laravel/resources
$ sudo chown -R $USERNAME:$USERNAME laravel/config
```

### PGroonga（ピージールンガ）使う場合は
Postgresに管理者でログインして'CREATE EXTENSION pgroonga;'
