#!/bin/bash

BASE_DIR=$1
if [ -z "$1" ]; then
   BASE_DIR=$HOME 
fi

ps -ef | grep "[j]ava.*s3bench" &> /dev/null
if [ $? -ne 0 ]; then
    $BASE_DIR/run.sh $BASE_DIR/s3bench-1.0.6-jar-with-dependencies.jar $BASE_DIR/instance.properties &> $BASE_DIR/output-`date "+%Y-%m-%dT%H:%M"`.log&
fi

