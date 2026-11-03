#!/usr/bin/env bash

# 停止中も含むローカルDockerコンテナの一覧を表示する。
# 削除・起動・停止などの変更は行わない。
set -euo pipefail

command -v docker >/dev/null || { echo 'docker が見つかりません。' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 が見つかりません。' >&2; exit 1; }

python3 - <<'PY'
import json
import subprocess
import sys
import unicodedata


def width(value):
    return sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in value)


result = subprocess.run(
    ['docker', 'container', 'ls', '-a', '--size', '--no-trunc', '--format', '{{json .}}'],
    capture_output=True, text=True,
)
if result.returncode:
    print(f'Docker情報の取得に失敗しました: {result.stderr.strip()}', file=sys.stderr)
    sys.exit(result.returncode)

containers = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
if not containers:
    print('Dockerコンテナはありません。')
    sys.exit(0)

rows = [['コンテナ名', 'コンテナID', 'イメージ', '状態', '稼働状況', 'サイズ', 'ポート']]
for container in sorted(containers, key=lambda item: (item['State'] != 'running', item['Names'])):
    rows.append([
        container['Names'], container['ID'][:12], container['Image'],
        container['State'], container['Status'], container['Size'], container['Ports'] or '-',
    ])

widths = [max(width(row[i]) for row in rows) for i in range(len(rows[0]))]
for row in rows:
    print('  '.join(value + ' ' * (widths[i] - width(value)) for i, value in enumerate(row)).rstrip())

running = sum(container['State'] == 'running' for container in containers)
print(f'\n合計: {len(containers)}コンテナ / 起動中: {running} / その他: {len(containers) - running}')
print('サイズは書き込みレイヤー、括弧内のvirtualはイメージを含むサイズです。ボリュームやログの容量は含みません。')
PY
