
.PHONY: s3

s3:
	aws s3 cp --sse s3/install-scalyr-agent-2.sh s3://com.scalyr.s3bench/
	aws s3 cp --sse s3/keepalive.sh s3://com.scalyr.s3bench/
	aws s3 cp --sse s3/run.sh s3://com.scalyr.s3bench/
	aws s3 cp --sse s3/s3bench-1.0.5-jar-with-dependencies.jar s3://com.scalyr.s3bench/

all: s3
