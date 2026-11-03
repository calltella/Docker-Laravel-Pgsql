#!/usr/bin/env bash

# ローカルDockerのネットワーク・コンテナからの使用状況を表示する。
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


resource_ids = docker('network', 'ls', '-q').split()
if not resource_ids:
    print('Dockerネットワークはありません。')
    sys.exit(0)
resources = inspect('network', resource_ids)
container_ids = docker('container', 'ls', '-a', '-q', '--no-trunc').split()
users = defaultdict(set)
# 停止中のコンテナの接続設定も、完全なIDまたは名前で照合する。
by_name = {resource['Name']: resource['Id'] for resource in resources}
for container in inspect('container', container_ids):
    label = f"{container['Name'].lstrip('/')} ({container['State']['Status']})"
    for name, settings in (container.get('NetworkSettings', {}).get('Networks') or {}).items():
        network_id = settings.get('NetworkID') or by_name.get(name)
        if network_id:
            users[network_id].add(label)

rows = [['ネットワーク名', 'ネットワークID', 'ドライバー', 'スコープ', '内部専用', 'サブネット', 'ゲートウェイ', '使用状況', '参照コンテナ']]
for resource in sorted(resources, key=lambda item: item['Name']):
    containers = users[resource['Id']]
    local_names = {label.rsplit(' (', 1)[0] for label in containers}
    for endpoint in (resource.get('Containers') or {}).values():
        name = endpoint.get('Name') or '不明な接続先'
        if name not in local_names:
            containers.add(f'{name} (接続先)')
    configs = resource.get('IPAM', {}).get('Config') or []
    rows.append([
        resource['Name'], resource['Id'][:12], resource['Driver'], resource.get('Scope', '-'),
        'はい' if resource.get('Internal') else 'いいえ',
        ', '.join(config['Subnet'] for config in configs if config.get('Subnet')) or '-',
        ', '.join(config['Gateway'] for config in configs if config.get('Gateway')) or '-',
        '使用中' if containers else '未使用', ', '.join(sorted(containers)) or '-',
    ])
used = sum(bool(users[resource['Id']]) for resource in resources)

widths = [max(width(row[i]) for row in rows) for i in range(len(rows[0]))]
for row in rows:
    print('  '.join(value + ' ' * (widths[i] - width(value)) for i, value in enumerate(row)).rstrip())

print(f'\n合計: {len(resources)}ネットワーク / 使用中: {used} / 未使用: {len(resources) - used}')
print('使用中には停止中のコンテナによる参照も含みます。')
PY
