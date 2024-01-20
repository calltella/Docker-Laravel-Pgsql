#!/bin/sh

# FJ001のリブート時間20:50

set -e

cd /home/ec2-user/Docker-Laravel-Pgsql

/home/ec2-user/.local/bin/docker-compose stop

sleep 60


cd /home/ec2-user/phpipam

/home/ec2-user/.local/bin/docker-compose stop

sleep 60

sudo shutdown now
