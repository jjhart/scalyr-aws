#!/usr/bin/env perl
use strict;
use warnings;

use POSIX qw(strftime);

$> and die("Must run as root, quitting\n");
$| = 1; # turn off buffering

my ($dev) = @ARGV;
$dev ||= '/dev/sdb';


my ($VERSION, $MNT) = qw(2 /media/instance-test);

system("umount /media/ephemeral0 $MNT");

only_once("$ENV{HOME}/prewarm-complete", sub {
	block_write($dev, 'prewarm-write');
	block_read($dev, 'prewarm-read');
	});


while (1) {
	system("umount $MNT");  
	block_write($dev);
	block_read($dev);

	-d $MNT or mkdir($MNT);
	system("mke2fs -F -F -j $dev") and die("Error creating filesystem on $dev: $!");
	system("mount $dev $MNT") and die("Error mounting $dev on $MNT: $!");

	fs_writes($MNT, 400); # 100 = how many 1GB files to write?
	timed('fs-sync', sub { system('sync') });
	fs_reads($MNT); 
	}

exit(0);




#--------------------------------------------------------------------------------
# primary commands
#--------------------------------------------------------------------------------
sub block_write {
	my ($of, $label) = @_;
	my $fmt = reformatter($label || 'block-write', 1);
	refmt_pipe($fmt, "dd bs=1M if=/dev/zero of=$of 2>&1", \&ping_long_dd);
	}

sub block_read {
	my ($if, $label) = @_;
	my $fmt = reformatter($label || 'block-read', 1);
	refmt_pipe($fmt, "dd bs=1M if=$if of=/dev/null 2>&1", \&ping_long_dd);
	}

sub fs_writes {
	my ($dir, $fileCount) = @_;
	my $fmt = reformatter('fs-write', 0);
	map { refmt_pipe($fmt, "dd bs=1M if=/dev/zero of=${dir}/dd.$_.out count=1024 2>&1") } (1..$fileCount);
	}

sub fs_reads {
	my ($dir) = @_;
	my $fmt = reformatter('fs-read', 0);
	map { -s and refmt_pipe($fmt, "dd bs=1M if=$_ of=/dev/null 2>&1") } (<$dir/dd.*.out>);
	}


#--------------------------------------------------------------------------------
# helpers
#--------------------------------------------------------------------------------
sub timed {
	my ($label, $f) = @_;
	my $tm = time();
	$f->();
	$tm = time() - $tm;
	printf("%s version=%s label=%s tm=%d\n", tm8601(), $VERSION, $label, $tm);
	}

sub only_once {
	my ($gatefile, $f) = @_;
	print("$gatefile exists, skipping gated step\n"), return if -f $gatefile;
	$f->();
	touch($gatefile);
	}

sub touch { 
	my ($file) = @_;
	my $now = time; 
	local (*TMP); 

	utime ($now, $now, $file) 
		|| open (TMP, ">>$file") 
		|| warn ("Couldn't touch file: $!\n"); 
	} 

sub ping_long_dd {
	my ($pid) = @_;
	sleep(1);
	kill('USR1', $pid);
	}

sub refmt_pipe {
	my ($fmt, $cmd, $ping) = (@_, sub { }); # ping is no-op
	my $pid = open(PIPE, '-|', $cmd) // die("Could not open pipe: $!");

	$ping->($pid);
	while (my $line = <PIPE>) {
		$fmt->($line) and $ping->($pid);
		}

	close (PIPE);
	}

sub reformatter {
	my ($label, $longwrite) = @_;
	my ($aggBytes, $aggTm, $aggRate) = (0, 0);
	my ($curBytes, $curTm, $curRate) = (0, 0);
	
	return sub {
		local ($_) = @_;

		return 0 if /records (in|out)/;
		return 0 if /No space left on device/;
		print($_), return 0 unless /copied,/;

		my ($bytes, $tm) = (m~^(\d+) bytes .* copied, ([0-9.]+) s, [0-9.]+ .B/s~)
			or return print("unrecognized line: $_"); # will return 1

		if ($longwrite) {                      # getting overall stats for one long write; must calculate current rate
			$curBytes = $bytes - $aggBytes;
			$curTm    = $tm    - $aggTm;
			($aggBytes, $aggTm) = ($bytes, $tm);
			}
		else {                                 # getting summary info for N separate writes; must calculate overall stats
			$aggBytes += $bytes;
			$aggTm    += $tm;
			($curBytes, $curTm) = ($bytes, $tm);
			}

		return 1 if ($curBytes == 0 && $curTm < 1); # final summary line can simply repeat previous

		$aggRate = mbs($aggBytes, $aggTm);
		$curRate = mbs($curBytes, $curTm);

		printf("%s version=%s label=%s aggBytes=%d aggTm=%.2f aggMBs=%.2f curBytes=%d curTm=%.2f curMBs=%.2f\n"
			,tm8601(), $VERSION, $label
			,$aggBytes, $aggTm, $aggRate
			,$curBytes, $curTm, $curRate
			);

		return 1;
		}
	}

sub tm8601 {
	strftime("%Y-%m-%dT%H:%M:%S+00:00", gmtime());
	}

# SI MBs/
sub mbs {
	my ($bytes, $tm) = @_;
	$bytes / ($tm*1000*1000);	
	}
