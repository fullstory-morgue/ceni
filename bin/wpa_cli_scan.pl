#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use Curses::UI;
use Expect;

my $ceni = new Curses::UI(
	-color_support => 1,
	-mouse_support => 1,
	-clear_on_exit => 1,
);

$ceni->set_binding(sub { exit 1; }, "\cC", "\cQ");
$ceni->status('Scanning for wireless networks...');

my $iface = $ARGV[0];
$iface or die("iface must be first arg\n");

# Spawn an unconfigured wpa_supplicant process to prepare the interface for
# scanning. Using the background (-B) option ensures return value indicates
# if the interface was successfully setup (or not). The use of system(),
# however, means we must also determine the process id from a pid file.
my @ver = split(/\./, `/sbin/wpa_supplicant -v | sed -n "s/^wpa_supplicant v//p"`);
my $driver = ($ver[0] == 0 and $ver[1] <= 6) ? 'wext' : 'nl80211,wext';
system("/sbin/wpa_supplicant -B -i $iface -D $driver " .
       "-P /run/wpa_supplicant.$iface.pid " .
       "-C /run/wpa_supplicant") == 0
	or die($!);

# Grab the wpa_supplicant process id from pid file. We may have to wait for it
# to be created though...
sleep 1 until -f "/run/wpa_supplicant.$iface.pid";
open my $wpasup_pid_fh, '<', "/run/wpa_supplicant.$iface.pid" or die($!);
my $wpasup_pid = <$wpasup_pid_fh>;
close $wpasup_pid_fh;
chomp $wpasup_pid;

# Start wpa_cli interactive session and communicate with it via Expect
my $wpacli = new Expect;
$wpacli->raw_pty(1);
$wpacli->log_stdout(0);
#$wpacli->log_file("/tmp/test.log");
$wpacli->spawn("/sbin/wpa_cli", "-i", $iface);

# Trigger a scan and wait for scan result notification for up to 30 seconds
$wpacli->send("SCAN\n");
$wpacli->expect(30, -re => ".*CTRL-EVENT-SCAN-RESULTS");

my %scan;
for my $bss (0..100) {
	my ($reply, %data);

	$wpacli->clear_accum();
	$wpacli->send("BSS $bss\n");
	$wpacli->expect(1, -re => "^>");
	
	$reply = $wpacli->exp_before();
	last if length($reply) == 0;

	for (split "\n", $reply) {
		next unless m/=/;
		my ($key, undef) = split(/=/);
		my $val = substr($_, length($key) + 1);
		$data{$key} = $val;
	}
	$scan{sprintf "%02d", $bss} = \%data;
}
$wpacli->hard_close();
$ceni->leave_curses();

# Kill wpa_supplicant process.
kill 'TERM', $wpasup_pid;

print Dumper(\%scan);
