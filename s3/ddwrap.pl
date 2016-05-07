#!/usr/bin/env perl
use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/lib";

use POSIX qw(strftime);
use Proc::ParallelLoop qw(pareach);
use Time::HiRes qw(gettimeofday tv_interval);


#--------------------------------------------------------------------------------
# constants & globals
#--------------------------------------------------------------------------------
$> and die("Must run as root, quitting\n");

$| = 1; # turn off buffering

$Proc::ParallelLoop::DEFAULT_MAX_WORKERS = get_thread_count();

my (@DEVS) =  grep { -e } (</dev/xvd{b,c,d,e,f,g,h,i}>);  # support up to 8 ephemeral drives as mounted by scalyr-aws
my ($VERSION, $DEV, $MNT) = qw(9 /dev/md0 /media/instance-test);

# hardcode SI sizes: 1MB x 1000 = 1GB
my ($DD_BS, $DD_COUNT) = (1_000_000, 1000);
my $MAXFILES = 1000; # up to 1TB of files


#--------------------------------------------------------------------------------
# main program - prewarm & RAID setup
#--------------------------------------------------------------------------------

# in case any are mounted
map { -e and system("umount $_") } ($MNT, map { "/media/ephemeral$_" } (0..3));

maybe_prewarm(@DEVS);
maybe_create_md0($DEV, @DEVS);

#--------------------------------------------------------------------------------
# main loop
#--------------------------------------------------------------------------------
while (1) {
	system("umount $MNT");  
	block_dd('w', 'block-write', $DEV);
	block_dd('r', 'block-read' , $DEV);

	mkfs($DEV, $MNT);
	touch_fs_files($MNT, dev_size($DEV)); # precreate $MNT/dd.000.out, $MNT/dd.001.out, etc up to as many would fit on $DEV once written

	fs_dd('w', 'fs-write', $MNT);
	info_timed('fs-drop-caches', sub { system('echo 3 > /proc/sys/vm/drop_caches') and die("Error dropping caches: $!"); });
	fs_dd('r', 'fs-read', $MNT);
	}

exit(0);



#--------------------------------------------------------------------------------
# dd invocation
#--------------------------------------------------------------------------------

# $MNT size:
# fs-* can just use parallelloop in place of map
# block-* needs to determine target size, divvy up by N threads, and then go
# both need to use Time::HiRes for wall clock, plus sum the threads byte counts

# run N dd commands, comprising $bytes total bytes, via ParallelLoop
# then run 'sync' and time the whole thing, output stats
sub dds {
	my ($label, $bytes, @cmds) = @_;
	info("starting %s", $label);

	my $tm = timed(sub {
		pareach(\@cmds, sub {
			my ($cmd) = @_;
			my $r = dd($cmd);
			$r->{error} and die($r->{error});
			info("label=%s-unit unitBytes=%d unitTm=%.2f unitMiBs=%.2f"
				,$label, $r->{bytes}, $r->{tm}, mibs($r)
				);
			});
		info_timed("$label-sync", sub { system('sync') and die("Error syncing filesystems: $!") });
		});

	info("label=%s totalBytes=%d totalTm=%.2f totalMiBs=%.2f"
		,$label, $bytes, $tm, mibs({ bytes => $bytes, tm => $tm})
		);
	}

# execute one dd command & parse its output
sub dd {
	my $out = qx(@_);
	dd_parse($out);
	}

# Generate the read/write call for [the Nth chunk of] $file
sub dd_cmd {
	my ($rw, $file, $n) = (@_);

	my $opts = '';
	$opts .= ' seek=' . ($n*$DD_COUNT) if $n && 'w' eq $rw;  # seek past X bytes for Nth chunk
	$opts .= ' skip=' . ($n*$DD_COUNT) if $n && 'r' eq $rw;  # skip past X bytes for Nth chunk
	$opts .= ' oflag=dsync conv=fsync' if 'w' eq $rw;  # sync after each 1MB block and at end of dd invocation
	$opts .= ' iflag=direct'           if 'r' eq $rw && $file !~ m~/dev/~; # skip filesystem cache; can only be specified for non-block-device reads

	# specify a 1_000_000 block size (1MB, SI)
	# **except** for fs-read, whose iflag=direct flag mandates 512-byte-aligned block sizes
	# for that we use 1MiB (works great even though only a multiple of 1MB was actually written)
	my $bs = $opts =~ /iflag=direct/ ? '1MiB' : $DD_BS;

	$rw eq 'r'
		? "dd bs=$bs count=$DD_COUNT if=$file $opts of=/dev/null 2>&1"
		: "dd bs=$bs count=$DD_COUNT of=$file $opts if=/dev/zero 2>&1";
	}


# parse dd output & return { bytes => 100000, tm => 1.02 }
sub dd_parse {
	local ($_) = @_;
	my ($bytes, $tm) = (m~^(\d+) bytes .* copied, ([0-9.]+) s, [0-9.]+ .B/s~m)
		or return { error => "unparseable: $_" };
	return { bytes => $bytes, tm => $tm };
	}



#--------------------------------------------------------------------------------
# primary commands
#--------------------------------------------------------------------------------
sub maybe_prewarm {
	my (@devs) = @_;
	info("i2 instance, skipping prewarm"), return if is_i2_instance();
	only_once("prewarm-complete", sub {
		prewarm('prewarm-write-pass-1', @DEVS);
		prewarm('prewarm-write-pass-2', @DEVS);
		});
	}

sub prewarm {
	my ($label, @devs) = @_;
	dds($label, dev_size(@devs), map { "dd bs=1MiB if=/dev/zero of=$_ conv=fsync 2>&1" } @devs);
	}

sub block_dd {
	my ($rw, $label, $dev) = @_;
	my $bytes = dev_size($dev);
	my $units = $bytes / ($DD_BS * $DD_COUNT);
	dds($label, dev_size($dev), map { dd_cmd($rw, $dev, $_) } (0..($units-1)));
	}

sub touch_fs_files {
	my ($dir, $maxbytes) = @_;
	my $filect = ($maxbytes / ($DD_BS * $DD_COUNT)) - 1;
	$filect = $MAXFILES if $filect > $MAXFILES;
	map { touch(sprintf("%s/dd.%03d.out", $dir, $_)) } (0..($filect-1));
	}

sub fs_dd {
	my ($rw, $label, $dir) = @_;
	my @files = (<$dir/dd.*.out>);
	# note we just assume that the file sizes are all correct for our final "dds" output
	dds($label, $DD_BS * $DD_COUNT * scalar(@files), map { dd_cmd($rw, $_) } @files);
	}


#--------------------------------------------------------------------------------
# logging, helpers
#--------------------------------------------------------------------------------
sub info {
	my ($fmt, @args) = @_;
	printf("%s version=%s threads=%d $fmt\n", tm8601(), $VERSION, $Proc::ParallelLoop::DEFAULT_MAX_WORKERS, @args);
	}

sub info_timed {
	my ($label, $f) = @_;
	info("label=%s tm=%.2f", $label, timed($f));
	}

sub tm8601 {
	strftime("%Y-%m-%dT%H:%M:%S+00:00", gmtime());
	}

sub mibs {
	my ($hash) = @_;
	return 0 if $hash->{tm} == 0;
	$hash->{bytes} / ($hash->{tm}*1024*1024);	
	}

sub timed {
	my ($f) = @_;
	my $tm = [ gettimeofday() ];
	$f->();
	tv_interval($tm);
	}

sub only_once {
	my ($gate, $f) = @_;
	my $gatefile = $ENV{HOME} . '/' . $gate;
	info("$gate already done, skipping"), return if -f $gatefile;
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

#--------------------------------------------------------------------------------
# linuxy stuff
#--------------------------------------------------------------------------------

# get the total size, in bytes, of the given devices
sub dev_size {
	my $ret = 0;
	map { my $bytes = `blockdev --getsize64 $_`; chomp($bytes); $ret += $bytes; } @_;
	$ret;
	}

# use 2 * CPUCOUNT threads, up to a maximum of 32
sub get_thread_count {
	my $cpus = scalar(grep(/^processor\t:/, (qx(cat /proc/cpuinfo))));
	$cpus > 16 ? 32 : 2 * $cpus;
	}

sub maybe_create_md0 {
 	my ($create, @from) = @_;

	info("$create already exists"), return if -e $create;
	info("creating %s from %s", $create, join(', ', @from));

	system(sprintf('mdadm --create %s --run --level=0 -c256 --raid-devices=%d %s', $create, scalar(@from), join(' ', @from)))
		and die("Could not create $create: $!");
	}

sub mkfs {
	my ($dev, $mnt) = @_;
	-d $mnt or mkdir($mnt);
	map { system($_) and die("Error running '$_': $!") } (
		 "yes | mkfs -t ext4 -E nodiscard $dev"     # skip block discard step - very slow on i2 instances
		,"mount -t ext4 -o noatime $dev $mnt"
		);
	}

sub is_i2_instance {
	-f '/tmp/provision/agent.json' && qx(curl -s http://169.254.169.254/latest/meta-data/instance-type) =~ /^i2./;
	}

