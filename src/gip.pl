#! /usr/local/bin/perl -Tw
#
# This tool lets you grab an IP address that
# (presumably) belongs to the given country.
#
# This code is beerware:
#
# Originally written by Jan Schaumann
# <jschauma@netmeister.org> in April 2020.
#
# As long as you retain this notice you can
# do whatever you want with this code.  If we
# meet some day, and you think this code is
# worth it, you can buy me a beer in return.

use 5.008;

use strict;
use File::Basename;
use Getopt::Long;
use JSON;
use Locale::Country qw(code2country country2code);
use Net::Netmask;
use URI::Escape;

Getopt::Long::Configure("bundling");

# We untaint the whole path, because we do allow the
# user to change it to point to a curl(1) of their
# preference.
my $safepath = $ENV{PATH};
if ($safepath =~ m/(.*)/) {
	$ENV{PATH} = $1;
}

delete($ENV{CDPATH});
delete($ENV{ENV});

###
### Constants
###

use constant EXIT_FAILURE => 1;
use constant EXIT_SUCCESS => 0;

use constant AWS_URL => "https://ip-ranges.amazonaws.com/ip-ranges.json";
use constant CC_CIDR_URL => "https://www.ipdeny.com/";

use constant VERSION => 1.2;

###
### Globals
###

# CIDRS = ( "v4" => ( "1.2.3.4/NM" => 1, ... ), "v6" => ( "1::2/NM" => 1 ) )
my %CIDRS;
my %OPTS = ( "update" => "default",
		"v4"  => "yes",
		"v6"  => "yes" );
my $PROGNAME = basename($0);
my $RETVAL = 0;

###
### Subroutines
###


sub error($;$) {
	my ($msg, $err) = @_;

	print STDERR "$PROGNAME: $msg\n";
	$RETVAL++;

	if ($err) {
		exit($err);
		# NOTREACHED
	}
}

sub fetchFile($$) {
	my ($url, $out) = @_;
	verbose("Fetching '$url' into '$out'...", 2);

	# We call out to curl(1) because it turns out
	# that the various ways to fetch https resources
	# in Perl across platforms are less uniform or
	# predictable with regards to the presence of
	# a proper CA bundle and support for modern ciphers
	# than curl(1).
	my @cmd = ( "curl", "-s", $url, "-o", $out);
	system(@cmd) == 0 or error ("Unable to execute '" .
						join(" ", @cmd) . "': $!", EXIT_FAILURE);
}

sub fileUpdateNeeded($) {
	my ($file) = @_;

	my $mtime = (stat($file))[9];

	my $age = 7 * 24 * 60 * 60;
	my $cutoff = time() - $age;

	if (!$mtime && ($OPTS{'update'} eq "no")) {
		error("No file '$file' found, but '-U' prohibits me from fetching that file.", EXIT_FAILURE);
		# NOTREACHED
	}

	if ($OPTS{'update'} eq "no") {
		verbose("Skipping updating '$file' because '-U' was specified...");
		return 0;
	}

	if (!$mtime || ($mtime < $cutoff) || ($OPTS{'update'} eq "yes")) {
		return 1;
	}

	return 0;
}

sub getAWSIPRanges() {
	my $file = $OPTS{'dir'} . "/ip-ranges.json";
	if (fileUpdateNeeded($file)) {
		fetchFile(AWS_URL, $file);
	}
}

sub getCountryNetblocks() {
	my $country = $OPTS{'country'};
	verbose("Looking up netblocks allocated to $country...");

	my $filev4 = $OPTS{'dir'} . "/v4/" . $OPTS{'cc'} . ".zone";
	my $filev6 = $OPTS{'dir'} . "/v6/" . $OPTS{'cc'} . ".zone";

	if (fileUpdateNeeded($filev4) || fileUpdateNeeded($filev6)) {
		my @files = ( "all-zones", "ipv6-all-zones" );
		foreach my $f (@files) {
			verbose("Fetching '$f'...", 2);
			$f .= ".tar.gz";
			my $tar = $OPTS{'dir'} . "/$f";

			my $url = CC_CIDR_URL . "ipv6/ipaddresses/blocks";
			my $subdir = $OPTS{'dir'} . "/v6";
			if ($f eq "all-zones.tar.gz") {
				$subdir = $OPTS{'dir'} . "/v4";
				$url = CC_CIDR_URL . "ipblocks/data/countries";
			}

			fetchFile("$url/$f", $tar);
			my @cmd = ( "tar", "zxf", $tar, "-C", $subdir);
			system(@cmd) == 0 or error("Unable to extract '$f': $!", EXIT_FAILURE);
			unlink($tar) or error("Unable to remove '$tar': $!", EXIT_FAILURE);
		}
	}

	if ((! -f $filev4) && (! -f $filev6)) {
		error("Unable to find CIDR blocks for $country (" . $OPTS{'cc'} .").", EXIT_FAILURE);
	}
}

sub init() {
	if (!scalar(@ARGV)) {
		error("I have nothing to do.  Try -h.", EXIT_FAILURE);
		# NOTREACHED
	}

	my $home = (getpwuid($<))[7];
	if (!$home) {
		$home = $ENV{'HOME'};
	}
	$OPTS{'dir'} = "$home/.gip";

	my $ok = GetOptions(
			"ipv4|4"	=> sub { $OPTS{'v6'} = "no"; },
			"ipv6|6"	=> sub { $OPTS{'v4'} = "no"; },
			"no-update|U"	=> sub { $OPTS{'update'} = "no"; },
			"cidr|c"	=> \$OPTS{'cidr'},
			"dir|d=s"	=> \$OPTS{'dir'},
			"help|h"	=> \$OPTS{'h'},
			"update|u"	=> sub { $OPTS{'update'} = "yes"; },
			"verbose|v+"	=> sub { $OPTS{'v'}++; },
			"version|V"	=> \$OPTS{'V'},
		);

	if ($OPTS{'h'} || !$ok) {
		usage($ok);
		exit(!$ok);
		# NOTREACHED
	}

	if ($OPTS{'V'}) {
		print "$PROGNAME " . VERSION . "\n";
		exit(EXIT_SUCCESS);
		# NOTREACHED
	}

	if (scalar(@ARGV) != 1) {
		error("You didn't give me a country name.", EXIT_FAILURE);
		# NOTREACHED
	}

	$OPTS{'country'} = $ARGV[0];

	if ($OPTS{'dir'} =~ m/(.*)/) {
		# mkdir is safe, so untaint
		$OPTS{'dir'} = $1;
	}

	my @subdirs = ( $OPTS{'dir'}, $OPTS{'dir'} . "/v4", $OPTS{'dir'} . "/v6" );
	foreach my $d (@subdirs) {
		if (! -d $d) {
			mkdir $d or die("Unable to create '$d': $!");
			$OPTS{'update'} = "yes";
		}
	}
}

sub parseAWSData() {
	my $file = $OPTS{'dir'} . "/ip-ranges.json";
	verbose("Parsing AWS IP Ranges from $file...");

	my $json = JSON->new->allow_nonref;

	%CIDRS = ();
	open(my $fh, "<", $file) or error("Unable to open $file: $!", EXIT_FAILURE);
	local $/;
	my $input = <$fh>;
	close($fh);

	my $rawJson = JSON->new->decode($input);
	my %json = %{$rawJson};
	foreach my $p (@{$json{'prefixes'}}) {
		my %prefix = %{$p};
		my $c = $OPTS{'country'};
		if ($prefix{'region'} =~ m/^$c/) {
			$CIDRS{'v4'}{$prefix{'ip_prefix'}} = 1;
		}
	}
	foreach my $p (@{$json{'ipv6_prefixes'}}) {
		my %prefix = %{$p};
		my $c = $OPTS{'country'};
		if ($prefix{'region'} =~ m/^$c/) {
			$CIDRS{'v6'}{$prefix{'ipv6_prefix'}} = 1;
		}
	}
}

sub parseCCCIDRs() {

	%CIDRS = ();
	foreach my $version ( "v4", "v6" ) {
		if ($OPTS{$version} ne "yes") {
			next;
		}

		my $file = $OPTS{'dir'} . "/$version/" . $OPTS{'cc'} . ".zone";

		if (! -f $file) {
			verbose("Skipping $file because it doesn't exist...");
			next;
		}

		verbose("Parsing $version CC CIDRs from $file...");
		open(my $fh, "<", $file) or error("Unable to open $file: $!", EXIT_FAILURE);
		foreach my $line (<$fh>) {
			chomp($line);
			$CIDRS{$version}{$line} = 1;
		}
		close($fh);
	}
}

sub prepCountry() {
	verbose("Checking given country input " . $OPTS{'country'} . "...");

	my $c = lc($OPTS{'country'});
	my $cc = "";

	if ($c =~ m/^[a-z]+-[a-z]+(-[0-9]+)?$/) {
		verbose("Using AWS region '$c'...", 2);
		$OPTS{'country'} = $c;
		$OPTS{'aws'} = 1;
		$cc = $c;
		return;
	}

	# Catch a few common cases, even if some of those
	# are not correct or may infuriate people.
	if (($c eq "antigua") || ($c eq "barbuda")) {
		$c = "Antigua and Barbuda";
		$cc = "ag";
	} elsif (($c eq "ac") || ($c eq "ascension island")) {
		$c = "Saint Helena, Ascension and Tristan da Cunha";
		$cc = "sh";
	} elsif (($c eq "bonaire") || ($c eq "sint eustatius") || ($c eq "saba") || ($c eq "carribean netherlands")) {
		$c = "Bonaire, Sint Eustatius and Saba";
		$cc = "bq";
	} elsif (($c eq "bosnia") || ($c eq "herzegovina")) {
		$c = "Bosnia and Herzegovina";
		$cc = "ba";
	} elsif ($c eq "ivory coast") {
		$c = "Cote d'Ivoire";
		$cc = "ci";
	} elsif (($c eq "diego garcia") || ($c eq "dg") || ($c eq "biot") || ($c eq "british indian ocean territory")) {
		$c = "British Indian Ocean Territory";
		$cc = "io";
	} elsif (($c eq "england") || ($c eq "uk") || ($c eq "northern ireland")) {
		$c = "United Kingdom";
		$cc = "uk";
	} elsif (($c eq "european union") || ($c eq "eu")) {
		my @members = ( "at", "be", "bg", "hr", "cy", "cz", "dk", "ee",
				"fi", "fr", "de", "gr", "hu", "ie", "it", "lv",
				"lt", "lu", "mt", "nl", "pl", "pt", "ro", "sk",
				"si", "es", "se" );
		$c = "European Union";
		$cc = $members[rand(@members)];
	} elsif (($c eq "falkland islands") || ($c eq "malvinas")) {
		$c = "The Falkland Islands";
		$cc = "fk";
	} elsif ($c eq "korea") {
		$c = "The Republic of Korea";
		$cc = "kr";
	} elsif ($c eq "north korea") {
		$c = "Democratic People's Republic Of Korea";
		$cc = "kp";
	} elsif ($c eq "russia") {
		$c = "Russian Federation";
		$cc = "ru";
	} elsif (($c eq "saint kitts") || ($c eq "nevis")) {
		$c = "Saint Kitts and Nevis";
		$cc = "kn";
	} elsif (($c eq "saint pierre") || ($c eq "miquelon")) {
		$c = "Saint Pierre and Miquelon";
		$cc = "pm";
	} elsif (($c eq "saint vincent") || ($c eq "grenadines")) {
		$c = "Saint Vincent and Grenadines";
		$cc = "vc";
	} elsif (($c eq "sao tome") || ($c eq "principe")) {
		$c = "Sao Tome and Principe";
		$cc = "st";
	} elsif (($c eq "south georgia") || ($c =~ m/(south )?sandwich islands/)) {
		$c = "South Georgia and the South Sandwich Islands";
		$cc = "gs";
	} elsif ($c eq "syria") {
		$c = "Syrian Arab Republic";
		$cc = "sy";
	} elsif (($c eq "trinidad") || ($c eq "tobago")) {
		$c = "Trinidad and Tobago";
		$cc = "tt";
	} elsif ($c eq "turks and caicos") {
		$c = "Turks and Caicos Islands";
		$cc = "tc";
	} elsif ($c eq "usa") {
		$c = "United States";
		$cc = "us";
	} elsif ($c eq "vietnam") {
		$c = "Viet Nam";
		$cc = "vn";
	}

	my $country = code2country($c);
	if (!$country) {
		$country = $c;
	}

	my $ccode = country2code($country);
	if (!$ccode) {
		if (!$cc) {
			error("Unable to determine country code from input '$c'.", EXIT_FAILURE);
		}
		$ccode = $cc;
	}

	# Yes, yes, not 100% correct, but good enough.
	$country =~ s/\b(\w)/\U$1/g;

	verbose("Using country '$country ($ccode)'...", 2);
	$OPTS{'country'} = $country;
	$OPTS{'cc'} = $ccode;
}

sub selectCIDR($) {
	my ($version) = @_;

	if ($OPTS{$version} ne "yes") {
		return;
	}

	verbose("Selecting a random $version CIDR from the results...");
	my @keys = keys(%{$CIDRS{$version}});
	return $keys[rand(@keys)];

}

sub selectIP($) {
	my ($cidr) = @_;

	# IPv6 blocks are too big to enumerate.
	# If we get an IPv6 block, we grab one from the first /120.
	if ($cidr =~ m/^(.*:.*)\/(.*)$/) {
		my $slash = $2;
		if ($slash < 120) {
			$cidr = "$1/120";
		}
	}

	verbose("Selecting an IP from the given $cidr...");
	my $block;
	eval {
		local $SIG{__WARN__} = sub {};
		$block = Net::Netmask->new($cidr);
	};
	if (!$block || $block->{'ERROR'}) {
		error("Invalid CIDR '$cidr': $!");
	}

	my @ips = $block->enumerate();
	return $ips[rand(@ips)];
}

sub usage($) {
	my ($err) = @_;

	my $FH = $err ? \*STDERR : \*STDOUT;

	print $FH <<EOH
Usage: $PROGNAME [-46UVchuv] [-d dir] country
	-4      only return IPv4 results
	-6      only return IPv6 results
	-U      don't update local files
	-V      print version number and exit
	-c      return a CIDR subnet instead of an IP address
	-d dir  store CIDR data in this directory (default: ~/.gip)
	-h      print this help and exit
	-u      update local files
	-v      be verbose
EOH
	;
}

sub verbose($;$) {
	my ($msg, $level) = @_;
	my $char = "=";

	return unless $OPTS{'v'};

	$char .= "=" x ($level ? ($level - 1) : 0 );

	if (!$level || ($level <= $OPTS{'v'})) {
		print STDERR "$char> $msg\n";
	}
}


###
### Main
###

init();
prepCountry();

if ($OPTS{'aws'}) {
	getAWSIPRanges();
	parseAWSData();
} else {
	getCountryNetblocks();
	parseCCCIDRs();
}

my $v4cidr = selectCIDR("v4");
my $v6cidr = selectCIDR("v6");

if ($OPTS{'cidr'}) {
	if (($OPTS{'v4'} eq "yes") && ($v4cidr)) {
		print "$v4cidr\n";
	}
	if (($OPTS{'v6'} eq "yes") && ($v6cidr)) {
		print "$v6cidr\n";
	}
} else {
	if (($OPTS{'v4'} eq "yes") && ($v4cidr)) {
		print selectIP($v4cidr) . "\n";
	}
	if (($OPTS{'v6'} eq "yes") && ($v6cidr)) {
		print selectIP($v6cidr) . "\n";
	}
}


exit($RETVAL);
