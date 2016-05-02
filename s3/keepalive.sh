#!/bin/bash

BASE_DIR=${1-$HOME};

ps -ef | grep -q "[p]erl .*ddwrap.pl" || sudo perl $BASE_DIR/ddwrap.pl &> $BASE_DIR/output-`date "+%Y-%m-%dT%H:%M"`.log&

