#!/bin/bash

BASE_DIR=$1
if [ -z "$1" ]; then
   BASE_DIR=$HOME 
fi

# use "latest" (alphasort) jarfile in case of > 1.  Should only be one, as "provision.sh" copies only one to local machine
JARFILE=$(ls -1 $BASE_DIR/s3bench-1.0.?-jar-with-dependencies.jar | tail -1)


ps -ef | grep "[j]ava.*s3bench" &> /dev/null
if [ $? -ne 0 ]; then
    $BASE_DIR/run.sh $JARFILE $BASE_DIR/instance.properties &> $BASE_DIR/output-`date "+%Y-%m-%dT%H:%M"`.log&
fi

