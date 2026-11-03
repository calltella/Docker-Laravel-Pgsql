#!/usr/bin/env bash

# ローカルDockerのボリューム・コンテナからの使用状況を表示する。
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


def width(value):
    return sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in value)


resource_ids = docker('volume', 'ls', '-q').split()
if not resource_ids:
    print('Dockerボリュームはありません。')
    sys.exit(0)
resources = inspect('volume', resource_ids)
# Dockerホスト側で集計するため、リモート接続でもマウント先を直接読む必要はない。
volume_usage = json.loads(docker('system', 'df', '-v', '--format', '{{json .Volumes}}')) or []
sizes = {volume['Name']: volume.get('Size') or '不明' for volume in volume_usage}
container_ids = docker('container', 'ls', '-a', '-q', '--no-trunc').split()
users = defaultdict(set)
for container in inspect('container', container_ids):
    label = f"{container['Name'].lstrip('/')} ({container['State']['Status']})"
    for mount in container.get('Mounts', []):
        if mount['Type'] == 'volume':
            users[mount['Name']].add(label)

rows = [['ボリューム名', 'サイズ', 'ドライバー', 'スコープ', '使用状況', '参照コンテナ', 'マウント先']]
for resource in sorted(resources, key=lambda item: item['Name']):
    containers = users[resource['Name']]
    rows.append([
        resource['Name'], sizes.get(resource['Name'], '不明'), resource['Driver'], resource.get('Scope', '-'),
        '使用中' if containers else '未使用', ', '.join(sorted(containers)) or '-',
        resource.get('Mountpoint') or '-',
    ])
used = sum(bool(users[resource['Name']]) for resource in resources)

widths = [max(width(row[i]) for row in rows) for i in range(len(rows[0]))]
for row in rows:
    print('  '.join(value + ' ' * (widths[i] - width(value)) for i, value in enumerate(row)).rstrip())

print(f'\n合計: {len(resources)}ボリューム / 使用中: {used} / 未使用: {len(resources) - used}')
print('使用中には停止中のコンテナによる参照も含みます。')
print('バインドマウントとtmpfsは対象外です。マウント先はDockerホスト上のパスです。')
print('サイズはDockerの集計値です。サイズの取得には時間がかかる場合があります。')
PY
