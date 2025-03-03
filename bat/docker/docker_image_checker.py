#!/usr/bin/env python3

# Source
# https://gist.github.com/peisuke/df5d9af77fb086e9faad739fc8e5cdc7
# dockerイメージと紐づいているコンテナを調査します
# 紐づいてないイメージを削除してディスク容量を節約します
# docker image rm 199b8ca63523 a67d330eef3b

import subprocess

def get_docker_images():
    """DockerイメージのIDと名前を取得します。"""
    images = {}
    cmd = ['docker', 'images', '--no-trunc', '--format', '{{.ID}} {{.Repository}}:{{.Tag}}']
    result = subprocess.run(cmd, capture_output=True, text=True)
    for line in result.stdout.strip().split('\n'):
        if line:
            image_id_full, name = line.strip().split(' ', 1)
            # 'sha256:' を取り除き、先頭12桁を使用
            if image_id_full.startswith('sha256:'):
                image_id_full = image_id_full[7:]
            image_id = image_id_full[:12]
            images[image_id] = {
                'name': name,
                'id_full': image_id_full,
                'referrers': set(),
                'containers': [],
                'can_delete': True,
                'parent_ids': set(),
                'parent_names': set()
            }
    return images

def get_containers():
    """すべてのコンテナの情報を取得します。"""
    containers = []
    cmd = ['docker', 'ps', '-a', '--no-trunc', '--format', '{{.ID}} {{.Image}} {{.Names}} {{.Status}}']
    result = subprocess.run(cmd, capture_output=True, text=True)
    for line in result.stdout.strip().split('\n'):
        if line:
            parts = line.strip().split(' ', 3)
            container_id_full = parts[0]
            image_name = parts[1]
            container_name = parts[2]
            status = parts[3]
            container_id = container_id_full[:12]
            containers.append({
                'id': container_id,
                'image_name': image_name,
                'name': container_name,
                'status': status
            })
    return containers

def get_image_history(image_id_full):
    """指定されたイメージの履歴からレイヤーのIDを取得します。"""
    cmd = ['docker', 'history', '--no-trunc', '--format', '{{.ID}}', image_id_full]
    result = subprocess.run(cmd, capture_output=True, text=True)
    history_ids = []
    for line in result.stdout.strip().split('\n'):
        if line and line != '<missing>':
            layer_id_full = line.strip()
            if layer_id_full.startswith('sha256:'):
                layer_id_full = layer_id_full[7:]
            layer_id = layer_id_full[:12]
            history_ids.append(layer_id)
    return history_ids

def main():
    # 色の定義
    red = '\033[31m'     # 参照されているイメージを赤色で表示
    yellow = '\033[33m'  # コンテナを黄色で表示
    green = '\033[32m'   # ベースイメージを緑色で表示
    reset = '\033[0m'    # 色のリセット

    # イメージ情報の取得（タグ付きのイメージのみ）
    images = get_docker_images()

    # コンテナ情報の取得
    containers = get_containers()
    for container in containers:
        image_name = container['image_name']
        container_info = {
            'name': container['name'],
            'id': container['id'],
            'status': container['status']
        }
        # イメージIDを取得
        cmd = ['docker', 'images', '--no-trunc', '--format', '{{.ID}} {{.Repository}}:{{.Tag}}', image_name]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.stdout.strip():
            image_id_full, _ = result.stdout.strip().split(' ', 1)
            if image_id_full.startswith('sha256:'):
                image_id_full = image_id_full[7:]
            image_id = image_id_full[:12]
            if image_id in images:
                images[image_id]['containers'].append(container_info)
                images[image_id]['can_delete'] = False  # コンテナが紐づいているので削除不可
        else:
            # イメージが存在しない場合（<none>:<none> など）
            continue

    # 各イメージの履歴を解析して参照関係を構築
    for image_id, info in images.items():
        history_ids = get_image_history(info['id_full'])
        # イメージ自身を除く
        parent_layers = history_ids[1:] if len(history_ids) > 1 else []
        for parent_id in parent_layers:
            if parent_id in images:
                images[parent_id]['referrers'].add(f"{info['name']} ({image_id})")
                images[parent_id]['can_delete'] = False  # 他のイメージから参照されているので削除不可
                info['parent_ids'].add(parent_id)
                info['parent_names'].add(images[parent_id]['name'])
            else:
                # 親イメージが docker images に存在しない場合は無視
                continue

    # 出力
    for image_id, info in images.items():
        status = 'o' if info['can_delete'] else 'x'
        print(f"{status} {info['name']}, {image_id}")
        if not info['can_delete']:
            if info['referrers']:
                print("  参照されているイメージ:")
                for referrer in info['referrers']:
                    print(f"\t- {red}{referrer}{reset}")
            if info['containers']:
                print("  紐づいているコンテナ:")
                for container in info['containers']:
                    print(f"\t- {yellow}{container['name']} ({container['id']}) [{container['status']}] {reset}")
        else:
            if info['containers']:
                print("  紐づいているコンテナ:")
                for container in info['containers']:
                    print(f"\t- {yellow}{container['name']} ({container['id']}) [{container['status']}] {reset}")
        # ベースイメージを表示
        if info['parent_names']:
            print("  ベースイメージ:")
            for parent_name, parent_id in zip(info['parent_names'], info['parent_ids']):
                print(f"\t- {green}{parent_name} ({parent_id}){reset}")

if __name__ == '__main__':
    main()