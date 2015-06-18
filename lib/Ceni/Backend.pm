package Ceni::Backend;

use strict;
use warnings;

use Carp;
use Data::Dumper;
use Expect;
use Fcntl 'O_RDONLY';
use Tie::File;

our $VERSION = '1';

sub new {
	my ($class, $opts) = @_;
	my $self = {};

	while (my ($key, $value) = each %{$opts}) {
		$self->{$key} = $value;
	}

	bless($self, $class);

	return $self;
}

sub is_iface_wireless {
	my ($self, $iface) = (shift, shift);
	my $retval = 0;

	if (-d "/sys/class/net/$iface/phy80211") {
		$retval++;
	}
	elsif (-x "/sbin/iwgetid") {
		open my $iwgetid, '-|', "/sbin/iwgetid --protocol " . $iface
		        or carp "W: could not execute iwgetid --protocol $iface: $!";
		while (<$iwgetid>) {
			chomp;
			m/^$iface/ and $retval++;
		}
		close $iwgetid;
	}

	return $retval;
}

sub nic_info {
	my ($self) = (shift);

	my %i;
	my $udevinfo_cmd = (-x '/sbin/udevadm') ? '/sbin/udevadm info' : 'udevinfo';

	$i{$_}{'sysfs'} = '/sys/class/net/' . $_ for map {
		s|.*/||;
		grep(!/^(lo|br|sit|tap|vmnet)\d*/, $_);
	} </sys/class/net/*>;

	for my $if (sort keys %i) {
		my ($bus, $desc);

		open my $udevinfo, '-|', "$udevinfo_cmd -a -p " . $i{$if}{'sysfs'}
		        or carp "E: could not execute $udevinfo_cmd -a -p "
		        . $i{$if}{'sysfs'} . ": $!";
		while (<$udevinfo>) {
			chomp;
			$self->debug($_);
			if (m/^\s+([A-Z]+({(.+)})?)=="([^"]+)"$/) {
				$3 ? $i{$if}{ lc $3 } ||= $4 : $i{$if}{ lc $1 } ||= $4;
				# ssb first KERNELS is useless to us, we want the second
				($1 eq 'KERNELS')&&($4=~/^ssb/)&&(delete($i{$if}{'kernels'}));
			}
		}
		close $udevinfo;

		if ($i{$if}{'subsystems'}) {
			$bus = $i{$if}{'subsystems'};
			$i{$if}{'connection_type'} =
			        $self->is_iface_wireless($if) ? 'wireless' : 'ethernet';
		}
		else {
			delete $i{$if};
			next;
		}

		open $udevinfo, '-|', "$udevinfo_cmd -p " . $i{$if}{'sysfs'}
		        or carp "E: could not execute $udevinfo_cmd -p "
		        . $i{$if}{'sysfs'} . ": $!";
		while (<$udevinfo>) {
			chomp;
			$self->debug($_);
			s/^[A-Z]\:\s//;
			if (m/^([A-Z_]+)=(.+?)$/) {
				$i{$if}{ lc $1 } ||= $2;
			}
		}
		close $udevinfo;

		if (-e $i{$if}{'sysfs'}."/address") {
			open my $sysinfo, $i{$if}{'sysfs'}."/address"
			or carp "E: could not open ".$i{$if}{'sysfs'}."/address: $!";
			my $address=<$sysinfo>;
			close($sysinfo);
			chomp($address);
			$i{$if}{'address'}=$address;
		}

		if ($bus eq 'pci' or $bus eq 'ssb') {
			$desc = `lspci -s $i{$if}{'kernels'} 2>/dev/null | head -n1`;
			$desc ||= "PCI device ".$i{$if}{'kernels'};

			chomp($desc);
			$desc =~ s/^.+:\s+//;
		}
		elsif ($bus eq 'usb' or $bus eq 'pcmcia') {
			my ($manu, $prod) = @{ $i{$if} }{ 'id_vendor_from_database', 'id_model_from_database' };

			if ($manu =~ m/^linux/i or $prod =~ m/^$manu/i) {
				$desc = $prod;
			}
			else {
				$desc = "$manu $prod";
			}
		}
		elsif ($bus eq 'virtio') {
			$desc = "KVM Virtio network device";
		}

		# FireWire IEEE 1394 Ethernet <- who cares?

		if ($desc) {
			$desc =~ s/(\s+)?(adapter|corporation|communications|connection|controller|ethernet|integrated|manufacturer|network|semiconductor|systems|technologies|technology|group|inc\.|ltd\.|co\.|\(.+\)),?//gi;
			$desc =~ s/\s+/\ /g;
			$desc =~ s/^\s+//;
			$desc =~ s/\s+$//;
			$i{$if}{'desc'} = $desc;
		}
		else {
			$i{$if}{'desc'} = "Unknown description";
		}
	}

	$self->debug(\%i, "i");

	%{ $self->{'_data'}->{'nicinfo'} } = %i;

	return 1;
}

sub get_iface_info {
	my ($self, $iface) = (shift, shift);

	if ($iface and $self->{'_data'}->{'nicinfo'}->{$iface}) {
		return $self->{'_data'}->{'nicinfo'}->{$iface};
	}
	elsif ($self->{'_data'}->{'nicinfo'}) {
		return $self->{'_data'}->{'nicinfo'};
	}

	return undef;
}

sub is_iface_valid {
	my ($self, $iface) = (shift, shift);

	if ($iface and $self->{'_data'}->{'nicinfo'}->{$iface}) {
		return 1;
	}

	return 0;
}

sub parse_eni {
	my $self = shift;

	$self->{'file'} ||= '/etc/network/interfaces';

	tie(my @eni, 'Tie::File', $self->{'file'}, mode => O_RDONLY)
	        or croak "E: failed to open " . $self->{'file'} . ": $!";

	my %e;
	my $l = 0;

	while (defined $eni[$l]) {
		$self->debug("| $l " . $eni[$l]);

		if ($eni[$l] =~ m/^\s*#/) {
			;
		}
		elsif ($eni[$l] =~ m/^(auto|allow-.+)\s+(.+)/) {
			$e{$_}{'class'} = $1 for (split /\s/, $2);
		}
		elsif ($eni[$l] =~ m/^iface\s+(.+)\s+inet\s+(.+)/) {
			my ($i, $m) = ($1, $2);
			$e{$i}{'method'} = $m;

			$self->debug("+ $l");

			while (defined $eni[ ++$l ]) {
				$self->debug("> $l " . $eni[$l]);

				if ($eni[$l] =~ m/^#?\s*(iface|auto|allow-.+|mapping)/) {
					$self->debug("- $l");
					$l-- and last;
				}
				elsif ($eni[$l] =~ m/^\s*#/) {
					push @{ $e{$i}{'comment'} }, $eni[$l];
				}
				elsif ($eni[$l] =~ m/^\s*(pre-|post-)?(up|down)\s+(.+)/) {
					if ($1) {
						push @{ $e{$i}{ $1 . $2 } }, $3;
					}
					else {
						push @{ $e{$i}{$2} }, $3;
					}
				}
				elsif ($eni[$l] =~ m/^\s*([^\s]+)\s+(.+)/) {
					my ($k, $v) = ($1, $2);
					$k =~ s/_/-/g;
					$e{$i}{'stanza'}{$k} = $v;
				}
			}
		}
	}
	continue {
		$l++;
	}

	$self->debug(\%e, "e");

	%{ $self->{'_data'}->{'eni'} } = %e;

	return 1;
}

sub get_iface_conf {
	my ($self, $iface) = (shift, shift);

	if ($iface and $self->{'_data'}->{'eni'}->{$iface}) {
		return $self->{'_data'}->{'eni'}->{$iface};
	}
	elsif (not $iface) {
		return $self->{'_data'}->{'eni'};
	}

	return undef;
}

sub is_iface_configured {
	my ($self, $iface) = (shift, shift);

	if ($self->get_iface_conf($iface) and
	    $self->get_iface_conf($iface)->{'method'}) {
		return 1;
	}

	return 0;
}

sub set_iface_conf {
	my ($self, $iface, $conf) = (shift, shift, shift);

	$self->{'file'} ||= '/etc/network/interfaces';

	tie(my @eni, 'Tie::File', $self->{'file'})
	        or carp "E: failed to open " . $self->{'file'} . ": $!";

	my @block;

	if ($conf->{'class'} and $conf->{'class'} ne 'manual') {
		push @block, $conf->{'class'} . " $iface";
		delete $conf->{'class'};
	}

	if ($conf->{'method'}) {
		push @block, "iface $iface inet " . $conf->{'method'};
		delete $conf->{'method'};
	}

	if ($conf->{'stanza'}) {
		for my $k (sort keys %{ $conf->{'stanza'} }) {
			push @block, "\t$k " . $conf->{'stanza'}->{$k};
		}
		delete $conf->{'stanza'};
	}

	for my $p ('pre-up', 'up', 'post-up', 'pre-down', 'down', 'post-down') {
		if ($conf->{$p}) {
			for my $c (@{ $conf->{$p} }) {
				push @block, "\t$p $c";
			}
			delete $conf->{$p};
		}
	}

	if ($conf->{'comment'}) {
		for my $c (@{ $conf->{'comment'} }) {
			push @block, $c;
		}
		delete $conf->{'comment'};
	}

	if (@block) {
		push @block, '';
	}

	$self->debug(\@block, 'block');

	my $l = 0;

	while (defined $eni[$l]) {
		$self->debug("| $l " . $eni[$l]);

		if ($eni[$l] =~ m/^\s*#/) {
			;
		}
		elsif ($eni[$l] =~ m/^(auto|allow-.+).*\s+$iface/) {
			$eni[$l] =~ s/\s*$iface//;
			$self->debug("> $l " . $eni[$l]);

			if (not $eni[$l] =~ m/^(auto|allow-.+)\s+.+$/) {
				$self->debug("* $l");
				splice @eni, $l--, 1;
			}
		}
		elsif ($eni[$l] =~ m/^iface\s+$iface\s+inet\s+(.+)$/) {
			$self->debug("* $l " . $eni[$l]);
			splice @eni, $l--, 1;

			while (defined $eni[ ++$l ]) {
				if ($eni[$l] =~ m/^#?\s*(iface|auto|allow-.+|mapping)/) {
					$self->debug("- $l");
					$l-- and last;
				}
				else {
					$self->debug("* $l " . $eni[$l]);
					splice @eni, $l--, 1;
				}
			}

			if (@block) {
				$l++;
				for my $b (@block) {
					$self->debug("+ $l " . $b);
					splice @eni, $l++, 0, $b;
				}
				@block = ();
			}
		}
	}
	continue {
		$l++;
	}

	if (@eni and @block) {
		if ($eni[-1] =~ m/^\s*\S.*$/) {
			push @eni, '';
		}
		push @eni, @block;
	}

	chmod 0640, $self->{'file'}
	        or carp "E: failed to chmod " . $self->{'file'} . ": $!";
}

sub rem_iface_conf {
	my ($self, $iface) = (shift, shift);

	$self->set_iface_conf($iface, {});
}

sub ifupdown {
	my ($self, $iface, $action) = (shift, shift, shift);
	my ($ret, @cmd);
	
	if ($action eq 'down' and $self->wpa_action($iface, 'check') == 0) {
		$ret = $self->{'act'} ? $self->wpa_action($iface, 'down') : 0;
	}
	elsif ($self->{'_data'}->{'eni'}->{$iface}->{'method'}) {
		@cmd = ("/sbin/if" . $action, $iface, "-i", $self->{'file'}, "-v");
		$self->{'act'} or push @cmd, "-n";
		$ret = system(@cmd);
	}
	else {
		carp "$iface has no ifupdown method";
	}

	if ($ret != 0) {
		if (($? & 127) == 2) {
			carp "W: $action $iface interupted";
		}
		else {
			carp "W: $action $iface failed due to error";
		}
	}
	else {
		$self->{'_data'}->{'ifupdown'}->{$iface} = $action;
	}

	sleep 1;

	return $ret;
}

sub ifup {
	my ($self, $iface) = (shift, shift);

	return $self->ifupdown($iface, 'up');
}

sub ifdown {
	my ($self, $iface) = (shift, shift);

	return $self->ifupdown($iface, 'down');
}

sub ifstate {
	my ($self, $iface) = (shift, shift);

	if ($iface and $self->{'_data'}->{'ifupdown'}->{$iface}) {
		return $self->{'_data'}->{'ifupdown'}->{$iface};
	}

	return undef;
}

sub wireless_scan {
	my ($self, $iface) = (shift, shift);
	my ($wpacli, $ret, $cmd, %scan, @ver, $driver);
	my ($wpasup_pid_fh, $wpasup_pid);

	#return 1 unless $self->{'act'};

	# Recent versions of wpa_supplicant support cycling through driver
	# wrappers until one succeeds, so try nl80211 first and fallback to
	# wext.
	@ver = split(/\./, `/sbin/wpa_supplicant -v | sed -n "s/^wpa_supplicant v//p"`);
	$driver = ($ver[0] == 0 and $ver[1] <= 6) ? 'wext' : 'nl80211,wext';

	# Spawn an unconfigured wpa_supplicant process to prepare the
	# interface for scanning. Using the background (-B) option ensures
	# return value indicates if the interface was successfully setup
	# (or not). The use of system(), however, means we must also determine
	# the process id from a pid file.
	$cmd = "/sbin/wpa_supplicant -B -i $iface -D $driver " .
	       "-P /run/wpa_supplicant.$iface.pid " .
	       "-C /run/wpa_supplicant";

	$ret = system($cmd);

	if ($ret != 0) {
		if (($? & 127) == 2) {
			carp "W: '$cmd' interupted\n";
		}
		else {
			carp "W: '$cmd' failed due to error: $!";
		}
	}

	# Grab the wpa_supplicant process id from pid file. We have to wait
	# for it to be created ... a bit sloppy.
	sleep 1 until -s "/run/wpa_supplicant.$iface.pid";
	open $wpasup_pid_fh, '<', "/run/wpa_supplicant.$iface.pid"
		or carp "W: failed to open /run/wpa_supplicant.$iface.pid: $!";
	$wpasup_pid = <$wpasup_pid_fh>;
	close $wpasup_pid_fh;
	chomp $wpasup_pid;

	# Start wpa_cli interactive session and communicate with it via Expect
	$wpacli = new Expect;
	$wpacli->raw_pty(1);
	$wpacli->log_stdout(0);
	$wpacli->log_file("/tmp/ceni.wpacli.log", "w") if $self->{'debug'};
	$wpacli->spawn("/sbin/wpa_cli", "-i", $iface);

	# Trigger a scan and wait for scan result notification for up to 30s
	$wpacli->send("SCAN\n");
	$wpacli->expect(30, -re => ".*CTRL-EVENT-SCAN-RESULTS");

	# Gather scan data per BSS
	for my $bss (0..100) {
		my ($reply, %data);

		# Clear previously accumulated output
		$wpacli->clear_accum();

		# Request BSS data
		$wpacli->send("BSS $bss\n");
		$wpacli->expect(1, -re => "^>");

		# Process reply
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

	# Kill wpa_cli process
	$wpacli->hard_close();

	# Kill wpa_supplicant process.
	kill 'TERM', $wpasup_pid;

	$self->debug(\%scan, 'scan');

	%{ $self->{'_data'}->{'scan'} } = %scan;

	return 1;
}

sub get_scan_res {
	my ($self, $cell) = (shift, shift);

	if (defined $cell and $self->{'_data'}->{'scan'}->{$cell}) {
		return $self->{'_data'}->{'scan'}->{$cell};
	}
	elsif ($self->{'_data'}->{'scan'}) {
		return $self->{'_data'}->{'scan'};
	}

	return undef;
}

sub wpa_action {
	my ($self, $iface, $action) = (shift, shift, shift);
	my $ret;

	$ret = $self->{'act'} ? system("wpa_action $iface check") : 0;

	if ($ret != 0) {
		if (($? & 127) == 2) {
			carp "W: ifconfig $iface up interupted";
		}
	}

	return $ret;
}

sub wpa_mappings {
	my ($self, $wpa_roam_cf) = (shift, shift);
	my @mappings;

	open my $wpa, '<', $wpa_roam_cf
		or carp "E: failed to read $wpa_roam_cf: $!";
	while (<$wpa>) {
		chomp;
		if (m/^\s*id_str="?([^"\s]+)"?/) {
			push @mappings, $1;
		}
	}
	close $wpa;

	return @mappings;
}

sub prep_wpa_roam {
	my ($self, $wpa_roam_ex, $wpa_roam_cf) = (shift, shift, shift);

	if (not -s $wpa_roam_ex) {
		croak "W: wpa-roam template not found: " . $wpa_roam_ex;
	}

	if (not -s $wpa_roam_cf) {
		tie(my @wpa, 'Tie::File', $wpa_roam_cf)
			or return 0;

		open my $example, '<', $wpa_roam_ex
			or return 0;
		while (<$example>) {
			chomp;
			s/^#\s*update_config=.*/update_config=1/;
			push @wpa, $_;
		}
		close $example;

		chmod 0640, $wpa_roam_cf
			or carp "E: failed to chmod $wpa_roam_cf: $!";
	}

	return 1;
}

sub debug {
	my ($self, $data, $name) = (shift, shift, shift);

	return unless $self->{'debug'};

	if (ref $data) {
		print STDERR "D: ";
		print STDERR Data::Dumper->Dump([$data], ["*$name"]);
	}
	else {
		print STDERR "D: $data\n";
	}
}

1;

__END__

=head1 NAME

Ceni::Backend - Perl extension for Ceni

=head1 SYNOPSIS

  use Ceni::Backend;

  my $ceni = Ceni::Backend->new( \%options );

=head1 DESCRIPTION

This is the backend for Ceni(8), it is not provided for use by scripts
not provided by the ceni package, therefore remains undocuemnted.

=head1 AUTHOR

Kel Modderman, E<lt>kel@otaku42.deE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 - 2010 by Kel Modderman

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this package; if not, see <http://www.gnu.org/licenses>

On Debian GNU/Linux systems, the text of the GPL-2 license can be
found in /usr/share/common-licenses/GPL-2.

=cut
