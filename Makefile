
.PHONY: s3

s3:
	aws s3 cp --sse s3/install-scalyr-agent-2.sh s3://com.scalyr.s3bench/
	aws s3 cp --sse s3/keepalive.sh s3://com.scalyr.s3bench/
	aws s3 cp --sse s3/dd_keepalive.sh s3://com.scalyr.s3bench/
	aws s3 cp --sse s3/ddwrap.pl s3://com.scalyr.s3bench/
	aws s3 cp --sse s3/lib/Proc/ParallelLoop.pm s3://com.scalyr.s3bench/lib/Proc/ParallelLoop.pm
	aws s3 cp --sse s3/run.sh s3://com.scalyr.s3bench/
	aws s3 cp --sse s3/log4j2.xml s3://com.scalyr.s3bench/
	aws s3 cp --sse s3/s3bench-1.0.10-jar-with-dependencies.jar s3://com.scalyr.s3bench/

all: s3
