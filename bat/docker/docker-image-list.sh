#!/usr/bin/env bash

# ローカルDockerのイメージ名・サイズ・コンテナからの使用状況を表示する。
# 停止中のコンテナも使用中として扱う。削除・変更は行わない。
set -euo pipefail

command -v docker >/dev/null || { echo 'docker が見つかりません。' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 が見つかりません。' >&2; exit 1; }

python3 - <<'PY'
import json
import subprocess
import sys
import unicodedata
from collections import defaultdict


def docker(*args):
    result = subprocess.run(['docker', *args], capture_output=True, text=True)
    if result.returncode:
        print(f'Docker情報の取得に失敗しました: {result.stderr.strip()}', file=sys.stderr)
        sys.exit(result.returncode)
    return result.stdout


def inspect(kind, ids):
    records = []
    for start in range(0, len(ids), 100):
        records.extend(json.loads(docker(kind, 'inspect', *ids[start:start + 100])))
    return records


def size_label(value):
    amount = float(value)
    for unit in ('B', 'KiB', 'MiB', 'GiB', 'TiB'):
        if amount < 1024 or unit == 'TiB':
            return f'{amount:.2f} {unit}'
        amount /= 1024


def width(value):
    return sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in value)


image_ids = list(dict.fromkeys(docker('image', 'ls', '-a', '-q', '--no-trunc').split()))
if not image_ids:
    print('Dockerイメージはありません。')
    sys.exit(0)

images = inspect('image', image_ids)
container_ids = docker('container', 'ls', '-a', '-q', '--no-trunc').split()
users = defaultdict(list)
for container in inspect('container', container_ids):
    # タグは付け替え可能なので、実際の参照先の完全なイメージIDで判定する。
    name = container['Name'].lstrip('/')
    state = container['State']['Status']
    users[container['Image']].append(f'{name} ({state})')

rows = [['イメージ名・タグ', 'イメージID', 'サイズ', '使用状況', '参照コンテナ']]
for image in sorted(images, key=lambda item: item['Size'], reverse=True):
    image_id = image['Id']
    names = ', '.join(image.get('RepoTags') or image.get('RepoDigests') or ['<none>:<none>'])
    containers = users[image_id]
    rows.append([
        names, image_id.removeprefix('sha256:')[:12], size_label(image['Size']),
        '使用中' if containers else '未使用', ', '.join(sorted(containers)) or '-',
    ])

widths = [max(width(row[i]) for row in rows) for i in range(len(rows[0]))]
for row in rows:
    print('  '.join(value + ' ' * (widths[i] - width(value)) for i, value in enumerate(row)).rstrip())

used = sum(bool(users[image['Id']]) for image in images)
print(f'\n合計: {len(images)}イメージ / 使用中: {used} / 未使用: {len(images) - used}')
print('使用中には停止中のコンテナによる参照も含みます。サイズは共有レイヤーを含むため、解放可能な容量とは異なります。')
PY
