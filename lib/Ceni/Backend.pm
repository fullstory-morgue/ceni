package Ceni::Backend;

use strict;
use warnings;

use Carp;
use Data::Dumper;
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
	else {
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
			}
		}
		close $udevinfo;

		if ($i{$if}{'type'} == 1 and $i{$if}{'subsystems'}) {
			$bus = $i{$if}{'subsystems'};
			$i{$if}{'connection_type'} =
			        $self->is_iface_wireless($if) ? 'wireless' : 'ethernet';
		}
		else {
			delete $i{$if};
			next;
		}

		if ($bus eq 'pci' or $bus eq 'ssb') {
			my ($vendor, $device) = @{ $i{$if} }{ 'vendor', 'device' };

			$desc = `lspci -d $vendor:$device 2>/dev/null | head -n1`;
			$desc ||= "PCI device $vendor:$device";

			chomp($desc);
			$desc =~ s/^.+:\s+//;
		}
		elsif ($bus eq 'usb') {
			my ($manu, $prod) = @{ $i{$if} }{ 'manufacturer', 'product' };

			if ($manu =~ m/^linux/i or $prod =~ m/^$manu/i) {
				$desc = $prod;
			}
			else {
				$desc = "$manu $prod";
			}
		}
		elsif ($bus eq 'pcmcia') {
			my ($prod1, $prod2) = @{ $i{$if} }{ 'prod_id1', 'prod_id2' };

			if ($prod2 =~ m/^$prod1/i) {
				$desc = $prod2;
			}
			else {
				$desc = "$prod1 $prod2";
			}
		}

		# FireWire IEEE 1394 Ethernet <- who cares?

		if ($desc) {
			$desc =~ s/(\s+)?(adapter|corporation|communications|connection|controller|ethernet|integrated|network|semiconductor|systems|technologies|technology|group|inc\.|ltd\.|co\.|\(.+\)),?//gi;
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

sub iwlist_scan {
	my ($self, $iface) = (shift, shift);
	my ($ret, $cmd, $fh, @s, $c, $l, %w);

	if (-x '/bin/ip') {
		$cmd = "/bin/ip link set $iface up";
	}
	else {
		$cmd = "/sbin/ifconfig $iface up";
	}

	$ret = $self->{'act'} ? system($cmd) : 0;

	if ($ret != 0) {
		if (($? & 127) == 2) {
			carp "W: '$cmd' interupted\n";
		}
		else {
			carp "W: '$cmd' failed due to error: $!";
		}
	}

	sleep 1;

	if (-x '/usr/bin/iw') {
		open $fh, '-|', "/usr/bin/iw dev $iface scan"
			or carp "E: iwlist $iface scan failed: $!";
		my @s = <$fh>;
		chomp @s;
		close $fh;

		my $cells = 0;
		$l = 0;
		while (defined $s[$l]) {
			$self->debug("| $l " . $s[$l]);

			if ($s[$l] =~ m/^bss\s+([0-9A-F:]+)\s+.*/i) {
				$c = sprintf("%02s", ++$cells);
				$w{$c}{'bssid'} = $1;

				$self->debug("> $l " . $s[$l]);

				while (defined $s[ ++$l ] and $c) {
					$self->debug("> $l " . $s[$l]);

					if ($s[$l] =~ m/^bss/i) {
						$l--;
						last;
					}
					elsif ($s[$l] =~ m/\s*freq:\s+(\d+)/i) {
						$w{$c}{'freq'} = $1;
					}
					elsif ($s[$l] =~ m/^\s*ssid:\s+(.+)/i) {
						$w{$c}{'ssid'} = $1;
					}
					elsif ($s[$l] =~ m/\s*ds paramater set:\s+.*channel\s+(\d+)/i) {
						$w{$c}{'chan'} = $1;
					}
					elsif ($s[$l] =~ m/\s*wpa:/i or $s[$l] =~ m/\s*rsn:/i) {
						$w{$c}{'enc'}++;
						$w{$c}{'wpa'}++;
					}
					elsif ($s[$l] =~ m/^\s*signal:\s+(.+)\s+.*/i) {
						$w{$c}{'signal'} = $1;
					}
				}

				if (not $w{$c}{'mode'}) {
					$w{$c}{'mode'} = 'master';
				}
			}
		}
		continue {
			$l++;
		}
	}

	if (not $l) {
		open $fh, '-|', "/sbin/iwlist $iface scan"
			or carp "E: iwlist $iface scan failed: $!";
		@s = <$fh>;
		chomp @s;
		close $fh;

		$l = 0;
		while (defined $s[$l]) {
			$self->debug("| $l " . $s[$l]);

			if ($s[$l] =~ m/cell\s+(\d+)\s+-\s+address:\s+([0-9A-F:]+)/i) {
				$c = $1;
				$w{$c}{'bssid'} = $2;

				$self->debug("> $l " . $s[$l]);

				while (defined $s[ ++$l ] and $c) {
					$self->debug("> $l " . $s[$l]);

					if ($s[$l] =~ m/\s*cell\s+\d+/i) {
						$l--;
						last;
					}
					elsif ($s[$l] =~ m/^\s*essid:"(.+)"/i) {
						$w{$c}{'ssid'} = $1;
					}
					elsif ($s[$l] =~ m/^\s*protocol:(ieee\s*)?(.+)/i) {
						$w{$c}{'proto'} = $2;
					}
					elsif ($s[$l] =~ m/^\s*mode:([^\s]+)/i) {
						$w{$c}{'mode'} = lc $1;
					}
					elsif ($s[$l] =~ m/\s*frequency:([^\s]+).*channel\s+(\d+)/i) {
						$w{$c}{'freq'} = $1;
						$w{$c}{'chan'} = $2;
					}
					elsif ($s[$l] =~ m/^\s*encryption key:\s*on/i) {
						$w{$c}{'enc'}++;
					}
					elsif ($s[$l] =~ m/wpa(2)? version/i) {
						$w{$c}{'wpa'}++;
					}
					elsif ($s[$l] =~ m/^\s*quality=([^\s]+)/i) {
						$w{$c}{'signal'} = $1;
					}
				}
			}
		}
		continue {
			$l++;
		}
	}

	$self->debug(\%w, 'w');

	%{ $self->{'_data'}->{'iwlist'} } = %w;

	return 1;
}

sub get_iwlist_res {
	my ($self, $cell) = (shift, shift);

	if ($cell and $self->{'_data'}->{'iwlist'}->{$cell}) {
		return $self->{'_data'}->{'iwlist'}->{$cell};
	}
	elsif ($self->{'_data'}->{'iwlist'}) {
		return $self->{'_data'}->{'iwlist'};
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

sub wpa_drivers {
	my $self = shift;
	my ($d, @drivers);

	open my $wpas, '-|', 'wpa_supplicant -h'
		or carp "W: unable to get driver list from wpa_supplicant: $!";
	while (<$wpas>) {
		chomp;
		/^drivers:/ and $d++;
		/^options:/ and last;
		if ($d and m/\s+([^\s]+)\s+=\s+(.*)$/) {
			if ($1 and $1 ne 'wired') {
				push @drivers, $1;
			}
		}
	}
	close $wpas;

	return @drivers;
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

Copyright (C) 2007 by Kel Modderman

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this package; if not, write to the Free Software
Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
MA 02110-1301, USA.

On Debian GNU/Linux systems, the text of the GPL-2 license can be
found in /usr/share/common-licenses/GPL-2.

=cut
