#!/bin/bash

# Docker-Laravel-Pgsql と phpipam が共有して使用しているネットワーク
# このネットワークを作り直すと他のDockerも一度、Downが必要


network_name="phpipam-network"
subnet="192.168.10.64/27"

# Check if the network exists
if docker network inspect "$network_name" &> /dev/null; then
    echo "Network '$network_name' exists."
else
    echo "Network '$network_name' does not exist."
    docker network create "$network_name" --subnet="$subnet"
fi

#docker network create phpipam-network --subnet=192.168.10.64/27



