#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./script.sh export_apline_base.sql
#
# Behavior:
#   - SRC:   引数で受け取ったファイル (例: export_apline_base.sql)
#   - Table: 引数名から "export_" を除き拡張子を外したもの (例: apline_base)
#   - OUT:   Table 名 + ".sql" (例: apline_base.sql)
#
#   内容は:
#     - 文単位で抽出 (区切り: "; + 改行")
#     - CR 除去 & 先頭空白除去
#     - INSERT INTO 文のみ通過
#     - "public.export_XXX" または "ONLY public.export_XXX" を "DEST_TABLE" に置換
#
# Notes:
#   - GNU awk (gawk) 前提
#   - sed は -E (拡張正規表現) を使用

print_usage() {
  cat >&2 <<'EOF'
Usage:
  ./pgdump_to_d1sqlite.sh export_<table>.sql

Examples:
  ./pgdump_to_d1sqlite.sh export_apline_base.sql

Description:
  - Input filename must start with "export_" and end with ".sql".
  - The output filename will be "<table>.sql" (e.g., "apline_base.sql").
  - INSERT INTO public.export_<table> (ONLY 含む) を INSERT INTO <table> に置換します。
EOF
}

# 引数チェック
if [[ "${1-}" == "" || "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  print_usage
  exit 1
fi

SRC="$1"

# 入力ファイル存在チェック
if [[ ! -f "$SRC" ]]; then
  echo "Error: file not found: $SRC" >&2
  exit 1
fi

# ベース名抽出（ディレクトリ切り離し）
src_base="$(basename -- "$SRC")"

# 形式検証: export_*.sql
if [[ ! "$src_base" =~ ^export_.+\.sql$ ]]; then
  echo "Error: input filename must match pattern: export_<table>.sql" >&2
  echo "Actual: $src_base" >&2
  exit 1
fi

# テーブル名抽出: "export_" を外し、拡張子 .sql を外す
DEST_TABLE="${src_base#export_}"
DEST_TABLE="${DEST_TABLE%.sql}"

# 出力ファイル名設定
OUT="${DEST_TABLE}.sql"

# 置換対象（スキーマ付きでマッチ）
#   public.export_<table> を public\.export_<table> としてエスケープ
escaped_src_table_pattern="public\.export_${DEST_TABLE}"

# 実行
gawk '
  BEGIN {
    RS=";[ \t]*\n";  # 1文の区切りを「; + 改行」に
    ORS=";\n";
  }
  {
    stmt = $0
    gsub(/\r/, "", stmt)          # CR除去（混入対策）
    sub(/^[ \n\t\r]+/, "", stmt)  # 先頭空白・改行を除去
    if (stmt ~ /^INSERT[[:space:]]+INTO[[:space:]]+/) {
      print stmt
    }
  }
' "$SRC" \
| sed -E "s/^INSERT[[:space:]]+INTO[[:space:]]+ONLY[[:space:]]+${escaped_src_table_pattern}/INSERT INTO ${DEST_TABLE}/" \
| sed -E "s/^INSERT[[:space:]]+INTO[[:space:]]+${escaped_src_table_pattern}/INSERT INTO ${DEST_TABLE}/" \
> "$OUT"

echo "written: $OUT"