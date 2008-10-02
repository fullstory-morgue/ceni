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
		open my $iwgetid, '-|', "iwgetid --protocol " . $iface
		        or carp "W: could not execute iwgetid --protocol $iface: $!\n";
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
	my $udevinfo_cmd = (-x '/sbin/udevadm') ? 'udevadm info' : 'udevinfo';

	$i{$_}{'sysfs'} = '/sys/class/net/' . $_ for map {
		s|.*/||;
		grep(!/^(lo|br|sit|tap|vmnet)\d*/, $_);
	} </sys/class/net/*>;

	for my $if (sort keys %i) {
		my ($bus, $desc);

		open my $udevinfo, '-|', "$udevinfo_cmd -a -p " . $i{$if}{'sysfs'}
		        or carp "E: could not execute $udevinfo_cmd -a -p "
		        . $i{$if}{'sysfs'} . ": $!\n";
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

			$desc = `lspci -d $vendor:$device 2>/dev/null`;
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
	        or croak "E: failed to open " . $self->{'file'};

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
	        or carp "E: failed to open " . $self->{'file'} . ": $!\n";

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

	if (-w $self->{'file'}) {
		chmod 0640, $self->{'file'}
		        or carp "E: failed to chmod 0640 " . $self->{'file'}
			. ": $!\n";
	}
}

sub rem_iface_conf {
	my ($self, $iface) = (shift, shift);

	$self->set_iface_conf($iface, {});
}

sub ifupdown {
	my ($self, $iface, $action) = (shift, shift, shift);
	my @cmd = ("/sbin/if" . $action, $iface, "-i", $self->{'file'}, "-v");

	if (not $self->{'act'}) {
		push @cmd, "-n";
	}

	if ($action eq 'down') {
		push @cmd, "--force";
	}

	if ($self->{'_data'}->{'eni'}->{$iface}->{'method'}) {
		$self->debug(\@cmd, 'cmd');
		my $ret = system(@cmd);

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
	}
	else {
		carp "$iface has no ifupdown method";
	}

	sleep 1;
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
	my $ret;

	if (-x '/bin/ip') {
		$ret = system("/bin/ip link set $iface up 2>/dev/null");
	}
	else {
		$ret = system("/sbin/ifconfig $iface up 2>/dev/null");
	}

	if ($ret != 0) {
		if (($? & 127) == 2) {
			carp "W: ifconfig $iface up interupted";
		}
		else {
			carp "W: ifconfig $iface up failed due to error";
		}
	}

	sleep 1;

	open my $fh, '-|', "/sbin/iwlist $iface scan"
	        or carp "E: iwlist $iface scan failed: $!\n";
	my @s = <$fh>;
	chomp @s;
	close $fh;

	my $l = 0;
	my %w;

	while (defined $s[$l]) {
		$self->debug("| $l " . $s[$l]);

		if ($s[$l] =~ m/cell\s+(\d+)\s+-\s+address:\s+([0-9A-F:]+)/i) {
			my $c = $1;
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
				elsif ($s[$l] =~ m/^\s*encryption key:([^\s]+)/i) {
					$w{$c}{'enc'} = $1;
				}
				elsif ($s[$l] =~ m/wpa(2)? version/i) {
					$w{$c}{'wpa'}++;
				}
				elsif ($s[$l] =~ m/^\s*quality=([^\s]+)/i) {
					$w{$c}{'qual'} = $1;
				}
			}
		}

	}
	continue {
		$l++;
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

sub prep_wpa_roam {
	my $self = shift;
	my $wpa_roam_ex    = '/usr/share/doc/wpasupplicant/examples/wpa-roam.conf';
	my $wpa_roam_cf    = '/etc/wpa_supplicant/wpa-roam.conf';

	if (not -s $wpa_roam_ex) {
		croak "W: wpa-roam template not found: " . $wpa_roam_ex . "\n";
	}

	if (not -s $wpa_roam_cf) {
		tie(my @wpa, 'Tie::File', $wpa_roam_cf)
			or croak "E: failed to open " . $wpa_roam_cf . ": $!\n";

		open my $example, '<', $wpa_roam_ex
			or croak "E: failed to open " . $wpa_roam_ex . ": $!\n";
		while (<$example>) {
			chomp;
			s/^#\s*update_config=.*/update_config=1/;
			m/^#/ and next;
			m/./ or next;
			push @wpa, $_;
		}
		close $example;

		chmod 0600, $wpa_roam_cf;
	}
}

sub conf_wpa_roam {
	my ($self, $iface) = (shift, shift);

	$self->set_iface_conf(
		$iface, {
			'class'  => 'allow-hotplug',
			'method' => 'manual',
			'stanza' => {
				'wpa-roam' => '/etc/wpa_supplicant/wpa-roam.conf',
			},
		}
	);

	if (not $self->get_iface_conf('default')) {
		$self->set_iface_conf('default', { 'method' => 'dhcp', }, );
	}

	$self->parse_eni();
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
