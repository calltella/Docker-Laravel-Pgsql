#!/bin/bash

# 
PERIOD='+3'

# 
DATE=`date '+%Y%m%d-%H%M%S'`

# 
# SAVEPATH='/home/ec2-user/Docker-Laravel-Pgsql/postgersBackup/back/'
SAVEPATH='/home/ec2-user/apline_laravel9/storage/app/backup/'
# 
PREFIX='production-dbdump-'

# 
EXT='.zip'

# 
CONTENERNAME='postgres'

# 
#docker exec $CONTENERNAME pg_dumpall -U postgres > $SAVEPATH$PREFIX$DATE$EXT
docker exec $CONTENERNAME pg_dump -c --if-exists -U postgres production > $SAVEPATH$PREFIX$DATE
zip --junk-paths --encrypt --password 9G7V94%n $SAVEPATH$PREFIX$DATE$EXT $SAVEPATH$PREFIX$DATE
# 
find $SAVEPATH -name $PREFIX$DATE -type f -exec rm -f {} \;
find $SAVEPATH -type f -daystart -mtime $PERIOD -exec rm {} \;
