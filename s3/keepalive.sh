#!/bin/bash

BASE_DIR=${1-$HOME};

[ -d /var/log/s3bench ] || mkdir -p /var/log/s3bench

# run.sh execs 'java ... -jar s3bench "$@"'
ps -ef | grep -q "[j]ava.*s3bench" || $BASE_DIR/run.sh $BASE_DIR/instance.properties &> $BASE_DIR/output-`date "+%Y-%m-%dT%H:%M"`.log&

