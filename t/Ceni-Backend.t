# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Ceni-Backend.t'

#########################

use Test::More tests => 2;

BEGIN { use_ok('Ceni::Backend') };

use Ceni::Backend;

my $bend = Ceni::Backend->new({
	file => '/dev/null',
});

ok(defined $bend, 'Ceni::Backend->new returned an object');
