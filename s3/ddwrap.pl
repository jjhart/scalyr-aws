#!/usr/bin/env perl
use strict;
use warnings;

use POSIX qw(strftime);

$> and die("Must run as root, quitting\n");
$| = 1; # turn off buffering

my ($dev) = @ARGV;
$dev ||= '/dev/sdb';


my ($VERSION, $MNT) = qw(3 /media/instance-test);

system("umount /media/ephemeral0 $MNT");

only_once("$ENV{HOME}/prewarm-complete", sub {
	block_write($dev, 'prewarm-write');
	# block_read($dev, 'prewarm-read');  # unnecessary: after prewarm-write all reads are stable
	});


while (1) {
	system("umount $MNT");  
	block_write($dev);
	block_read($dev);

	-d $MNT or mkdir($MNT);
	system("mke2fs -F -F -j $dev") and die("Error creating filesystem on $dev: $!");
	system("mount $dev $MNT") and die("Error mounting $dev on $MNT: $!");

	fs_writes($MNT, 400); # tried to write 400 1GiB files
	timed('fs-sync', sub { system('sync') and die("Error syncing filesystem: $!") });
	timed('fs-drop-caches', sub { system('echo 3 > /proc/sys/vm/drop_caches') and die("Error dropping caches: $!"); });
	fs_reads($MNT); 
	}

exit(0);




#--------------------------------------------------------------------------------
# primary commands
#--------------------------------------------------------------------------------
sub block_write {
	my ($of, $label) = @_;
	my $fmt = reformatter($label || 'block-write', 1);
	refmt_pipe($fmt, dd('w', $of), \&ping_long_dd);
	}

sub block_read {
	my ($if, $label) = @_;
	my $fmt = reformatter($label || 'block-read', 1);
	refmt_pipe($fmt, dd('r', $if), \&ping_long_dd);
	}

sub fs_writes {
	my ($dir, $fileCount) = @_;
	my $fmt = reformatter('fs-write', 0);
	map { refmt_pipe($fmt, dd('w', "${dir}/dd.$_.out", 'count=1024')) } (1..$fileCount);
	}

sub fs_reads {
	my ($dir) = @_;
	my $fmt = reformatter('fs-read', 0);
	map { -s and refmt_pipe($fmt, dd('r', $_)) } (<$dir/dd.*.out>);
	}


#--------------------------------------------------------------------------------
# helpers
#--------------------------------------------------------------------------------

# Generate our desired dd command for 'r' or 'w' modes
#
# Flags used:
#
# Writing:
#   conv=fsync   : "Synchronize output data and metadata just before finishing. This forces a physical write of output data and metadata."
#   oflag=dsync  : "Use synchronized I/O for data. For the output file, this forces a physical write of output data on each write ... metadata is not necessarily synchronized"
#
# Reading:
#   iflag=direct : "use direct I/O for data, avoiding the buffer cache"
#
# So, on write, we sync after writing each block (of size=1M) *and* at the end of the entire operation (for metadata sync)
# This sync-after-each-MB pattern is most closely aligned with our anticipated use
sub dd {
	my ($rw, $file, $opts) = (@_, '');
	$opts .= ' iflag=direct' if ($rw eq 'r' && $file !~ m~/dev/~);  # flag not valid for block device reads
	$rw eq 'r'
		? "dd bs=1MiB if=$file $opts of=/dev/null 2>&1"
		: "dd bs=1MiB of=$file $opts if=/dev/zero oflag=dsync conv=fsync 2>&1";
	}



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

		$aggRate = mibs($aggBytes, $aggTm);
		$curRate = mibs($curBytes, $curTm);

		printf("%s version=%s label=%s aggBytes=%d aggTm=%.2f aggMiBs=%.2f curBytes=%d curTm=%.2f curMiBs=%.2f\n"
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

sub mibs {
	my ($bytes, $tm) = @_;
	$bytes / ($tm*1024*1024);	
	}
