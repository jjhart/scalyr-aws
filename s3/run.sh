#!/bin/bash

#--------------------------------------------------------------------------------
# vars provided by provision.sh (which overwrites this file on benchmark machines
#--------------------------------------------------------------------------------
export scalyr_writelog_token='%writeLogToken%'
export serverHost='%serverHost%'
BASE_DIR='%baseDir%'
MIN_HEAP=%minHeap%
MAX_HEAP=%maxHeap%
#--------------------------------------------------------------------------------
# /var section
#--------------------------------------------------------------------------------

LOG_CONFIG="${BASE_DIR}/log4j2.xml"
LOG_FLAGS="-Dlog4j.configurationFile=$LOG_CONFIG"

HEAP_FLAGS="-Xms$MIN_HEAP -Xmx$MAX_HEAP"

GC_LOG="/var/log/s3bench/s3_garbage_collection.log"
GC_FLAGS="-verbosegc -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -XX:+PrintGCDateStamps -XX:+PrintClassHistogramAfterFullGC -XX:PrintCMSStatistics=2 -Xloggc:$GC_LOG"

# use "latest" (alphasort - not ideal) jarfile in case of > 1.  Should only be one, as "provision.sh" copies only one to local machine
JARFILE=$(ls -1 ${BASE_DIR}/s3bench-*-jar-with-dependencies.jar | tail -1)

java $LOG_FLAGS $HEAP_FLAGS $GC_FLAGS -jar $JARFILE "$@"
