#!/usr/bin/env perl
use strict;
use warnings;

use POSIX qw(strftime);

$> and die("Must run as root, quitting\n");
$| = 1; # turn off buffering

my (@DEVS) = grep { -e } (</dev/sd{b,c,d,e}>);
my ($VERSION, $DEV, $MNT) = qw(7 /dev/md0 /media/instance-test);

maybe_create_md0($DEV, @DEVS);

# in case any are mounted
map { -e and system("umount $_") } ($MNT, map { "/media/ephemeral$_" } qw(0..3));

only_once("prewarm-complete", sub {
	block_write($DEV, 'prewarm-write');
	block_read($DEV, 'prewarm-read');  # after prewarm-write all reads are stable ... but reinstating in case it helps next block write
	});


while (1) {
	system("umount $MNT");  
	block_write($DEV);
	block_read($DEV);

	mkfs($DEV, $MNT);

	fs_writes($MNT, 400); # tried to write 400 1GiB files
	timed('fs-sync', sub { system('sync') and die("Error syncing filesystems: $!") });
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
	$fmt->(); # print final stats
	}

sub block_read {
	my ($if, $label) = @_;
	my $fmt = reformatter($label || 'block-read', 1);
	refmt_pipe($fmt, dd('r', $if), \&ping_long_dd);
	$fmt->(); # print final stats
	}

sub fs_writes {
	my ($dir, $fileCount) = @_;
	my $fmt = reformatter('fs-write', 0);
	map { refmt_pipe($fmt, dd('w', sprintf("%s/dd.%03d.out", $dir, $_), 'count=1024')) } (1..$fileCount);
	$fmt->(); # print final stats
	}

sub fs_reads {
	my ($dir) = @_;
	my $fmt = reformatter('fs-read', 0);
	map { -s and refmt_pipe($fmt, dd('r', $_)) } (<$dir/dd.*.out>);
	$fmt->(); # print final stats
	}


#--------------------------------------------------------------------------------
# helpers
#--------------------------------------------------------------------------------

sub maybe_create_md0 {
 	my ($create, @from) = @_;

	print("$create already exists\n"), return if -e $create;
	printf("Creating %s from %s\n", $create, join(', ', @from));

	system(sprintf('mdadm --create %s --level=0 -c256 --raid-devices=%d %s', $create, scalar(@from), join(' ', @from)))
		and die("Could not create $create: $!");
	}

sub mkfs {
	my ($dev, $mnt) = @_;
	-d $mnt or mkdir($mnt);
	map { system($_) and die("Error running '$_': $!") } (
		 "mkfs -t ext4 $dev"
		,"mount -t ext4 -o noatime $dev $mnt"
		);
	}

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
	my ($gate, $f) = @_;
	my $gatefile = $ENV{HOME} . '/' . $gate;
	print("$gate already done, skipping\n"), return if -f $gatefile;
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
	sleep(10);
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
	my ($agg, $cur) = ({ bytes => 0, tm => 0}, { bytes => 0, tm => 0 });
	
	return sub {
		# sentinel: empty input list input means "just dump current 'agg' state as 'total'"
		@_ or return printf("%s version=%s label=%s totalBytes=%d totalTm=%.2f totalMiBs=%.2f\n"
			,tm8601(), $VERSION, $label
			,$agg->{bytes}, $agg->{tm}, mibs($agg)
			);

		local ($_) = @_;

		return 0 if /records (in|out)/;
		return 0 if /No space left on device/;
		print($_), return 0 unless /copied,/;

		my ($bytes, $tm) = (m~^(\d+) bytes .* copied, ([0-9.]+) s, [0-9.]+ .B/s~)
			or return print("unrecognized line: $_"); # will return 1

		if ($longwrite) {                      # getting overall stats for one long write; must calculate current rate
			$cur->{bytes} = $bytes - $agg->{bytes};
			$cur->{tm}    = $tm    - $agg->{tm};
			$agg->{bytes} = $bytes;
			$agg->{tm}    = $tm;
			}
		else {                                 # getting summary info for N separate writes; must calculate overall stats
			$agg->{bytes} += $bytes;
			$agg->{tm}    += $tm;
			$cur->{bytes}  = $bytes;
			$cur->{tm}     = $tm;
			}

		return 1 if ($cur->{bytes} == 0 && $cur->{tm} < 1); # final summary line can simply repeat previous

		printf("%s version=%s label=%s aggBytes=%d aggTm=%.2f aggMiBs=%.2f curBytes=%d curTm=%.2f curMiBs=%.2f\n"
			,tm8601(), $VERSION, $label
			,$agg->{bytes}, $agg->{tm}, mibs($agg)
			,$cur->{bytes}, $cur->{tm}, mibs($cur)
			);

		return 1;
		}
	}

sub tm8601 {
	strftime("%Y-%m-%dT%H:%M:%S+00:00", gmtime());
	}

sub mibs {
	my ($hash) = @_;
	return 0 if $hash->{tm} == 0;
	$hash->{bytes} / ($hash->{tm}*1024*1024);	
	}
