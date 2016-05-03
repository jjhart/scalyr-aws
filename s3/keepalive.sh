#!/bin/bash

BASE_DIR=${1-$HOME};

[ -d /var/log/s3bench ] || mkdir -p /var/log/s3bench

ps -ef | grep -q "[p]erl .*ddwrap.pl" || sudo perl $BASE_DIR/ddwrap.pl &>> /var/log/s3bench/s3bench.log&

