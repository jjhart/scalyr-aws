#!/bin/bash

mkdir -p /tmp/provision
cd /tmp/provision

#--------------------------------------------------------------------------------
# Provision ephemeral SSD if available.  
#--------------------------------------------------------------------------------

# Look for 2 SSDs and mount them as RAID 0 if available
lsblk | grep nvme1n1
if [ $? -eq 0 ]; then
   yes | sudo mdadm --create /dev/md0 --level=0 -c256 --raid-devices=2 /dev/nvme0n1 /dev/nvme1n1
   mkfs -E nodiscard -t ext4 /dev/md0
   mount -t ext4 -o noatime /dev/md0 /mnt
   chmod 777 /mnt
fi

#--------------------------------------------------------------------------------
# install dependencies
#--------------------------------------------------------------------------------

# upgrade to java 1.8 if not already; using hard path as found on CNC server post-upgrade
install_java_1_8() {
	echo $(date) ' ... checking for java 1.8'
	java -version 2>&1 | fgrep -q 'build 1.8' && echo 'Java 1.8 found' && return 0
	echo 'installing java 1.8'
	yes | yum install java-1.8.0
	/usr/sbin/alternatives --set java /usr/lib/jvm/jre-1.8.0-openjdk.x86_64/bin/java
	}

install_java_1_8 >> install.java.log 2>&1

yes | yum install 'perl(Time::HiRes)' &>> install.perl-libs.log

#--------------------------------------------------------------------------------
# setup scalyr-agent
#--------------------------------------------------------------------------------
aws s3 cp s3://com.scalyr.s3bench/install-scalyr-agent-2.sh . && \
  /bin/bash ./install-scalyr-agent-2.sh

read -d '' AGENT_JSON << EOF
%agent.json%
EOF

echo "$AGENT_JSON" > agent.json

GROUP_NAME=%groupId%
INSTANCE_ID=`curl http://169.254.169.254/latest/meta-data/instance-id`

TAG_NAME="GroupIndex"
REGION=`curl http://169.254.169.254/latest/dynamic/instance-identity/document|grep region|awk -F\" '{print $4}'`
SPOT_REQUEST=$(aws ec2 describe-spot-instance-requests --region="us-east-1" --filters "Name=instance-id,Values=`curl http://169.254.169.254/latest/meta-data/instance-id`" --output text | grep SPOTINSTANCEREQUESTS | cut -f 6)
GROUP_INDEX=`aws ec2 describe-tags --filters "Name=resource-id,Values=$SPOT_REQUEST" "Name=key,Values=$TAG_NAME" --region $REGION --output text | cut -f 5`

if [ -z "$GROUP_INDEX" ]; then
    GROUP_INDEX=$INSTANCE_ID
fi

SERVER_HOST="s3-benchmark-$GROUP_NAME-$GROUP_INDEX"

sed -i "s/%instanceId%/$INSTANCE_ID/" agent.json
sed -i "s/%groupIndex%/$GROUP_INDEX/" agent.json
sed -i "s/%serverHost%/$SERVER_HOST/" agent.json

cp agent.json /etc/scalyr-agent-2/agent.json

LOG_DIR=/var/log/s3bench
mkdir -p $LOG_DIR
chown ec2-user:ec2-user $LOG_DIR

scalyr-agent-2 start


#--------------------------------------------------------------------------------
# add additional authorized_keys (from s3)
#--------------------------------------------------------------------------------
KFILE=/home/ec2-user/.ssh/authorized_keys
mkdir -p $(dirname $KFILE)
aws s3 cp s3://com.scalyr.s3bench/authorized_keys .
cat authorized_keys >> $KFILE
chmod 0600 $KFILE


#--------------------------------------------------------------------------------
# setup the s3bench directory
#--------------------------------------------------------------------------------
BASE_DIR=/home/ec2-user/s3bench
mkdir -p "$BASE_DIR"

cd "$BASE_DIR"

mkdir -p lib/Proc/

aws s3 cp s3://com.scalyr.s3bench/run.sh .
aws s3 cp s3://com.scalyr.s3bench/ddwrap.pl .
aws s3 cp s3://com.scalyr.s3bench/dd_keepalive.sh .
aws s3 cp s3://com.scalyr.s3bench/lib/Proc/ParallelLoop.pm lib/Proc/
aws s3 cp s3://com.scalyr.s3bench/log4j2.xml .
aws s3 cp s3://com.scalyr.s3bench/s3bench-1.0.10-jar-with-dependencies.jar .
aws s3 cp s3://com.scalyr.s3bench/keepalive.sh .

chmod u+x $BASE_DIR/run.sh
chmod u+x $BASE_DIR/keepalive.sh

MIN_HEAP=`free -m | grep Mem | awk '{print int($2*.80) "m"}'`
MAX_HEAP=`free -m | grep Mem | awk '{print int($2*.85) "m"}'`


# note that scalyr-aws generates provision.sh from within python (replacing 'apiKey' below, eg)
# provision.sh is then uploaded as the AWS user-content file & executed, thus generating other files
sed -i "s#%baseDir%#$BASE_DIR#" $BASE_DIR/run.sh
sed -i "s/%minHeap%/$MIN_HEAP/" $BASE_DIR/run.sh
sed -i "s/%maxHeap%/$MAX_HEAP/" $BASE_DIR/run.sh
sed -i "s~%writeLogToken%~%apiKey%~" $BASE_DIR/run.sh
sed -i "s~%serverHost%~$SERVER_HOST~" $BASE_DIR/run.sh

echo "serverHost = $SERVER_HOST" > $BASE_DIR/instance.properties
echo "sizesAndThreads = '%sizes_and_threads%'" >> $BASE_DIR/instance.properties

chown -R ec2-user:ec2-user /home/ec2-user

KEEPALIVE='keepalive.sh'
#KEEPALIVE='dd_keepalive.sh' # COMMENT OUT TO RUN THE S3 BENCHMARK

echo "SHELL=\"/bin/bash\"
* * * * * /bin/bash $BASE_DIR/$KEEPALIVE $BASE_DIR" | crontab -u ec2-user -
