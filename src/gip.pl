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
use JSON::XS;
use Locale::Country qw(all_country_codes code2country country2code);
use Net::Netmask;
use Socket qw(AF_INET AF_INET6 inet_pton);
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
use constant RIPE_URL => "https://stat.ripe.net/data/announced-prefixes/data.json?resource=";

# If this disappears, we can switch to fetching the CIDRs ourselves
# using something similar to e.g.,
# https://raw.githubusercontent.com/HackingGate/Country-IP-Blocks/master/generate.sh
use constant CC_CIDR_URL => "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/";

use constant VERSION => 1.7;

###
### Globals
###

my $RESERVED_CIDRS = {
			# shortcuts and aliases first
			"benchmarking" => {
					"v4" => { "198.18.0.0/15" => 1 },
					"v6" => { "2001:2::/48" => 1 },
				},
			"example" => {
					"v4" => {
							"192.0.2.0/24" => 1,
							"198.51.100.0/24" => 1,
							"203.0.113.0/24" => 1,
					       	},
					"v6" => { "2001:db8::/32" => 1 },
				},
			"link-local" => {
					"v4" => { "169.254.0.0/16" => 1 },
					"v6" => { "fe80::/10" => 1 },
				},
			"loopback" => {
					"v4" => { "127.0.0.0/8" => 1 },
					"v6" => { "::1/128" => 1 },
				},
			"multicast" => {
					"v4" => { "224.0.0.0/4" => 1 },
					"v6" => { "ff00::/8" => 1 },
				},
			# https://icann.org/namecollision
			"namecollision" => {
					"v4" => { "127.0.53.53/32" => 1 },
				},
			"unique-local" => {
					"v4" => {
							"10.0.0.0/8" => 1,
							"172.16.0.0/12" => 1,
							"192.168.0.0/16" => 1
						},
					"v6" => { "fc00::/7" => 1 },
				},
			"unspecified" => {
					"v4" => { "0.0.0.0/32" => 1 },
					"v6" => { "::/128" => 1 },
				},
			# RFCs in order
			"rfc919" => {  # Reserved
					"v4" => { "255.255.255.255/32" => 1 },
				},
			"rfc1112" => {  # Reserved
					"v4" => { "240.0.0.0/4" => 1 },
				},
			"rfc1122" => {  # This host on this network
					"v4" => { "0.0.0.0/8" => 1 },
				},
			"rfc1918" => {  # Private Use
					"v4" => {
							"10.0.0.0/8" => 1,
							"172.16.0.0/12" => 1,
							"192.168.0.0/16" => 1,
						},
				},
			"rfc2544" => {  # Benchmarking
					"v4" => { "198.18.0.0/15" => 1 },
				},
			"rfc2928" => {  # IETF Protocol Assignments
					"v6" => { "2001::/23" => 1 },
				},
			"rfc3056" => {  # 6to4
					"v6" => { "2002::/16" => 1 },
				},
			"rfc3068" => {  # 6to4 Relay Anycast
					"v4" => { "192.88.99.0/24" => 1 },
				},
			"rfc3849" => {  # Documentation
					"v6" => { "2001:db8::/32" => 1 },
				},
			"rfc4193" => {  # Unique-Local
					"v6" => { "fc00::/7" => 1 },
					# Note: a more specific CIDR will be
					# generated further down.
				},
			"rfc4380" => {  # TEREDO
					"v6" => { "2001::/32" => 1 },
				     },
			"rfc4843" => {  # ORCHID
					"v6" => { "2001:10::/28" => 1 },
				     },
			"rfc5180" => {  # Benchmarking
					"v6" => { "2001:2::/48" => 1 },
				     },
			"rfc5737" => {  # Documentation
					"v4" => {
							"192.0.2.0/24" => 1,
							"198.51.100.0/24" => 1,
							"203.0.113.0/24" => 1,
				     },
				},
			"rfc6052" => {  # IPv4-IPv6 Translation
					"v6" => { "64:ff9b::/96" => 1 },
				     },
			"rfc6333" => {  # DS-Lite
					"v4" => { "192.0.0.0/29" => 1 },
				},
			"rfc6598" => {  # Shared Address Space
					"v4" => { "100.64.0.0/10" => 1 },
				},
			"rfc6666" => {  # Discard-only
					"v6" => { "100::/64" => 1 },
				     },
			"rfc6890" => {  # IETF Protocol Assignments
					"v4" => { "192.0.0.0/24" => 1 },
				     },
		};

# CIDRS = ( "v4" => ( "1.2.3.4/NM" => 1, ... ), "v6" => ( "1::2/NM" => 1 ) )
my %CIDRS;

# CIDR_DESC = ( "desc1" => ( "cidr1" => 1, "cidr2" => 1, ...), "desc2" => ( "cidr1" => 1, "cidr2" => 2, ...), ... )
my %CIDR_DESC;

my %OPTS = ( "update" => "default",
		"v4"  => "yes",
		"v6"  => "yes" );
my $PROGNAME = basename($0);
my $RETVAL = 0;

###
### Subroutines
###

sub addToCidrMap($$) {
	my ($line, $descr) = @_;
	my $wanted = $OPTS{'net'};

	my $firstWanted = $OPTS{'first'};
	my ($first, $net);
	my $v4 = 0;
	my $v6 = 0;

	if ($line =~ m/:/) {
		$v6 = 1;
	} else {
		$v4 = 1;
	}

	if (($v6 && ($wanted !~ m/:/)) ||
		($v4 && ($wanted =~ m/[^0-9.\/]/))) {
		# CIDR and wanted must both be v4 or both be v6
		return 0;
	}

	$first = "";
	if ($line =~ m/^([0-9]+)\./) {
		$first = $1;
		$net = 32;
	} elsif ($line =~ m/^([0-9a-f]+):/i) {
		$first = $1;
		$net = 128;
	}

	if ($wanted =~ m/.*\/([0-9]+)/) {
		$net = $1;
	}

	if (($v4 && ($net > 7)) || ($v6 && ($net > 15))) {
		if ($first ne $firstWanted) {
			return 0;
		}
	}

	my $block= createNetmask($line);
	if ($block->contains($wanted)) {
		$CIDR_DESC{$descr}{$line} = 1;
		return 1;
	}

	return 0;
}

sub createNetmask($) {
	my ($cidr) = @_;

	my $block;
	eval {
		local $SIG{__WARN__} = sub {};
		$block = Net::Netmask->new($cidr);
	};
	if (!$block || $block->{'ERROR'}) {
		error("Invalid CIDR '$cidr': $!");
	}

	return $block;
}

sub doReverseLookup() {

	my @mappings;
	# Try to get results quickly and check
	# smallest maps first.
	parseReservedCIDRs();
	if (printCidrMappings("reserved") && !$OPTS{'all'}) {
		return;
	}

	%CIDR_DESC = ();
	getAWSIPRanges();
	parseAWSData();
	if (printCidrMappings("aws") && !$OPTS{'all'}) {
		return;
	}

	%CIDR_DESC = ();
	parseAllCountryNetblocks();
	if (printCidrMappings("cc") && !$OPTS{'all'}) {
		return;
	}
}

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
	verbose("Fetching '$url' into '$out'...", 3);

	# We call out to curl(1) because it turns out
	# that the various ways to fetch https resources
	# in Perl across platforms are less uniform or
	# predictable with regards to the presence of
	# a proper CA bundle and support for modern ciphers
	# than curl(1).
	my @cmd = ( "curl", "--fail", "-s", $url, "-o", $out);
	system(@cmd);
	my $rval = ($? >> 8);

	if ($rval != 0) {
		if ($rval == 22) {
			error("Unable to fetch '$url'.", EXIT_FAILURE);
		} else {
			error("Unable to execute curl '" .
				join(" ", @cmd) . "': $! ($rval)", EXIT_FAILURE);
		}
		# NOTREACHED
	}
}

sub fileUpdateNeeded($) {
	my ($file) = @_;

	if ($OPTS{'update'} eq "no") {
		verbose("Skipping updating '$file' because '-U' was specified...");
		return 0;
	}

	my $mtime = (stat($file))[9];
	my $age = 7 * 24 * 60 * 60;
	my $cutoff = time() - $age;

	if (!$mtime && ($OPTS{'update'} eq "no") && !$OPTS{'reverse'}) {
		error("No file '$file' found, but '-U' prohibits me from fetching that file.", EXIT_FAILURE);
		# NOTREACHED
	}

	if (!$mtime || ($mtime < $cutoff) || ($OPTS{'update'} eq "yes")) {
		return 1;
	}

	return 0;
}

sub generateIPv6LinkLocal() {
	verbose("Generating an IPv6 link-local address...", 2);

	my $ip = sprintf("fe80::%02x%02x:%02xff:fe%02x:%02x%02x",
				int(rand(255)),
				int(rand(255)),
				int(rand(255)),
				int(rand(255)),
				int(rand(255)),
				int(rand(255)));
	return $ip;
}

sub generateRFC4193Cidr() {
	# Approximating RFC4193#3.2.2, but note that
	# we're not trying to actually generate a a
	# _unique_ IP, only a _valid_ IP, so we don't
	# have to worry about using a EUI-64 identifier
	# or anything like that.

	verbose("Generating an RFC4193 CIDR...", 2);

	my ($urandom, $bits);

	open($urandom, '<', "/dev/urandom") or die "Unable to open /dev/urandom: $!\n";
	binmode($urandom);
	if (!read($urandom, $bits, 7)) {
		error("Unable to read 7 bytes from /dev/urandom: $!", EXIT_FAILURE);
		# NOTREACHED
	}
	close($urandom);

	my @fields = split(/\./, sprintf("%v02x", $bits));
	my $cidr = "fd" . shift(@fields) . ":";
	while (scalar(@fields)) {
		$cidr .= shift(@fields);
		if (scalar(@fields)%2 == 0) {
			$cidr .= ":";
		}
	}
	$cidr .= ":/64";

	verbose("Using RFC4193 CIDR $cidr...", 3);
	return $cidr;
}

sub getASN() {
	my $file = $OPTS{'dir'} . "/as/" . $OPTS{'asn'} . ".json";
	if (fileUpdateNeeded($file)) {
		fetchFile(RIPE_URL . $OPTS{'asn'}, $file);
	}
}

sub getAWSIPRanges() {
	my $file = $OPTS{'dir'} . "/ip-ranges.json";
	if (fileUpdateNeeded($file)) {
		fetchFile(AWS_URL, $file);
	}
}

sub getCountryNetblocks($$) {
	my ($country, $cc) = @_;

	verbose("Looking up netblocks allocated to $country...", 3);

	my $filev4 = $OPTS{'dir'} . "/v4/$cc.cidr";
	my $filev6 = $OPTS{'dir'} . "/v6/$cc.cidr";

	my @files = ( $filev4, $filev6 );
	if ($OPTS{'reverse'}) {
		@files = ( $filev4 );
		if ($OPTS{'reverse'} =~ /:/) {
			@files = ( $filev6 );
		}
	}

	foreach my $f (@files) {
		if (fileUpdateNeeded($f)) {
			my $n = "4";
			if ($f =~ m|/v6/|) {
				$n = "6";
			}
			verbose("Fetching IPv$n CIDRs for '$cc'...", 4);
			my $url = CC_CIDR_URL . "ipv$n/$cc.cidr";
			my $subdir = $OPTS{'dir'} . "/v$n";
			fetchFile($url, $OPTS{'dir'} . "/v$n/$cc.cidr");
		}
	}

	if ((! -f $filev4) && (! -f $filev6)) {
		# In reverse mode, we may not find country code files
		# but then simply move on.
		if ($OPTS{'reverse'}) {
			return;
		}
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
			"all|a"		=> \$OPTS{'all'},
			"ipv4|4"	=> sub { $OPTS{'v6'} = "no"; },
			"ipv6|6"	=> sub { $OPTS{'v4'} = "no"; },
			"no-update|U"	=> sub { $OPTS{'update'} = "no"; },
			"cidr|c"	=> \$OPTS{'cidr'},
			"dir|d=s"	=> \$OPTS{'dir'},
			"help|h"	=> \$OPTS{'h'},
			"reverse|r"	=> \$OPTS{'reverse'},
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
		error("You didn't give me anything to expand.", EXIT_FAILURE);
		# NOTREACHED
	}

	$OPTS{'input'} = $ARGV[0];
	if ($OPTS{'reverse'}) {
		$OPTS{'reverse'} = $OPTS{'input'};
	}

	if ($OPTS{'dir'} =~ m/(.*)/) {
		# mkdir is safe, so untaint
		$OPTS{'dir'} = $1;
	}

	my @subdirs = ( $OPTS{'dir'}, $OPTS{'dir'} . "/as", $OPTS{'dir'} . "/v4", $OPTS{'dir'} . "/v6" );
	foreach my $d (@subdirs) {
		if (! -d $d) {
			mkdir $d or die("Unable to create '$d': $!");
			$OPTS{'update'} = "yes";
		}
	}
}

sub parseAllCountryNetblocks() {
	verbose("Getting and parsing all country netblocks...");
	foreach my $cc (all_country_codes()) {
		verbose("Getting and parsing $cc netblocks...", 2);
		getCountryNetblocks($cc, $cc);
		if (parseCCCIDRs($cc) && !$OPTS{'all'}) {
			return;
		}
	}
}

sub parseASN() {
	my $file = $OPTS{'dir'} . "/as/" . $OPTS{'asn'} . ".json";
	verbose("Parsing ASN data from $file...");

	%CIDRS = ();
	open(my $fh, "<", $file) or error("Unable to open $file: $!", EXIT_FAILURE);
	local $/;
	my $input = <$fh>;
	close($fh);

	my $rawJson = JSON::XS->new->decode($input);
	my %json = %{$rawJson};

	foreach my $p (@{$json{'data'}{'prefixes'}}) {
		my %prefix = %{$p};
		my $cidr = $prefix{'prefix'};
		if ($cidr =~ m/:/) {
			$CIDRS{'v6'}{$cidr} = 1;
		} else {
			$CIDRS{'v4'}{$cidr} = 1;
		}
	}

	if (!scalar(%CIDRS)) {
		error("No prefixes found in AS" . $OPTS{'asn'} . ".", EXIT_FAILURE);
		# NOTREACHED
	}
}

sub parseAWSData() {
	my $file = $OPTS{'dir'} . "/ip-ranges.json";
	verbose("Parsing AWS IP Ranges from $file...");

	%CIDRS = ();
	open(my $fh, "<", $file) or error("Unable to open $file: $!", EXIT_FAILURE);
	local $/;
	my $input = <$fh>;
	close($fh);

	my $rawJson = JSON::XS->new->decode($input);
	my %json = %{$rawJson};
	if (!$OPTS{'reverse'} || $OPTS{'reverse'} !~ m/:/) {
		foreach my $p (@{$json{'prefixes'}}) {
			my %prefix = %{$p};
			my $c = $OPTS{'input'};
			if ($prefix{'region'} =~ m/^$c/) {
				$CIDRS{'v4'}{$prefix{'ip_prefix'}} = 1;
			}
			if ($OPTS{'reverse'}) {
				if (addToCidrMap($prefix{'ip_prefix'}, $prefix{'region'}) && !$OPTS{'all'}) {
					return;
				}
			}
		}
	}

	if (!$OPTS{'reverse'} || $OPTS{'reverse'} =~ m/:/) {
		foreach my $p (@{$json{'ipv6_prefixes'}}) {
			my %prefix = %{$p};
			my $c = $OPTS{'input'};
			if ($prefix{'region'} =~ m/^$c/) {
				$CIDRS{'v6'}{$prefix{'ipv6_prefix'}} = 1;
			}
			if ($OPTS{'reverse'}) {
				if (addToCidrMap($prefix{'ipv6_prefix'}, $prefix{'region'}) && !$OPTS{'all'}) {
					return;
				}
			}
		}
	}
}

sub parseCCCIDRs($) {
	my ($cc) = @_;

	%CIDRS = ();
	my @versions = ( "v4", "v6" );
	if ($OPTS{'reverse'}) {
		@versions = ( "v4" );
		if ($OPTS{'reverse'} =~ /:/) {
			@versions = ( "v6" );
		}
	}


	foreach my $version (@versions) {
		if ($OPTS{$version} ne "yes") {
			next;
		}

		my $file = $OPTS{'dir'} . "/$version/$cc.cidr";

		if (! -f $file) {
			next;
		}

		verbose("Parsing $version CC CIDRs from $file...", 3);
		open(my $fh, "<", $file) or error("Unable to open $file: $!", EXIT_FAILURE);
		foreach my $line (<$fh>) {
			chomp($line);
			if ($line =~ m/^[0-9a-f.:\/]+$/i) {
				$CIDRS{$version}{$line} = 1;
				if ($OPTS{'reverse'}) {
					if (addToCidrMap($line, $cc) && !$OPTS{'all'}) {
						return 1;
					}
				}
			}
		}
		close($fh);
	}

	return 0;
}

sub parseGivenCIDR() {
	my $cidr = $OPTS{'net'};

	my $block = createNetmask($cidr);

	if ($block->protocol() eq "IPv6") {
		if ($OPTS{"v6"} eq "no") {
			error("You gave me an IPv6 CIDR but asked for IPv4 results.", EXIT_FAILURE);
			# NOTREACHED
		}
		$CIDRS{"v6"}{$cidr} = 1;
	}

	if ($block->protocol() eq "IPv4") {
		if ($OPTS{"v4"} eq "no") {
			error("You gave me an IPv4 CIDR but asked for IPv6 results.", EXIT_FAILURE);
			# NOTREACHED
		}
		$CIDRS{"v4"}{$cidr} = 1;
	}

	if ($OPTS{'cidr'}) {
		my $full = 128;
		my $version = "v6";
		# Expanding all possible subnets takes too long,
		# so let's arbitrarily cut off at 2^14.
		my $max = 14;
		if ($block->protocol() eq "IPv4") {
			$full = 32;
			$version = "v4";
		}

		my $left = $full - $block->bits();
		if ($left > $max) {
			$left = $max;
		}
		my $n = 2 ** int(rand($left));
		my @chopped = $block->split($n);

		foreach my $c (@chopped) {
			$CIDRS{$version}{$c} = 1;
		}
		return;
	}
}

sub parseReservedCIDRs() {
	my @wanted = keys(%{$RESERVED_CIDRS});

	if ($OPTS{'reverse'}) {
		foreach my $k (@wanted) {
			foreach my $v ( "v4", "v6" ) {
				my %rc = %{$RESERVED_CIDRS};
				my %h = %{$rc{$k}};
				if ($h{$v}) {
					foreach my $cidr (keys(%{$h{$v}})) {
						addToCidrMap($cidr, $k);
					}
				}
			}
		}
		return;
	}

	my $reserved = $OPTS{'input'};
	if ($reserved ne "reserved") {
		@wanted = ( $reserved );
	}

	foreach my $k (@wanted) {

		if ($k eq "rfc4193") {
			my $cidr = generateRFC4193Cidr();
			$CIDRS{"v6"}{$cidr} = 1;
			next;
		}

		my $wanted = $RESERVED_CIDRS->{$k};
		foreach my $v ( "v4", "v6" ) {
			my %h = %{$wanted};
			if ($reserved ne "reserved" && !$h{$v} &&
				# only warn when the missing version was explicitly requested
				(($v eq "v4" && ($OPTS{"v6"} eq "no")) ||
				($v eq "v6" && ($OPTS{"v4"} eq "no")))) {
				error("No IP$v CIDRs found for $reserved.");
				next;
			}
			if ($h{$v}) {
				if (exists($CIDRS{$v})) {
					foreach my $cidr (keys(%{$h{$v}})) {
						$CIDRS{$v}{$cidr} = 1;
					}
				} else {
					$CIDRS{$v} = $h{$v};
				}
			}
		}
	}
}

sub prepCountry() {
	verbose("Checking given input " . $OPTS{'input'} . "...");

	my $c = lc($OPTS{'input'});
	my $cc = "";

	# This isn't very useful, but ok.  What else did the user expect?
	if (inet_pton(AF_INET6, $c)) {
		$c = "$c/128";
	} elsif (inet_pton(AF_INET, $c)) {
		$c = "$c/32";
	}

	if ($c =~ m/^.*\/[0-9]+$/) {
		verbose("Selecting from given CIDR '$c'...", 2);
		$OPTS{'net'} = $c;

		# In order to cut down on reverse matching, we extract
		# the first octet / group.
		$OPTS{'first'} = "";
		if ($c =~ m/^([0-9]+)\./) {
			$OPTS{'first'} = $1;
		} elsif ($c =~ m/^([0-9a-f]+):/i) {
			$OPTS{'first'} = $1;
		}
		return;
	} elsif ($OPTS{'reverse'}) {
		error("'-r' requires an IP address or CIDR.", EXIT_FAILURE);
		# NOTREACHED

	}

	if ($RESERVED_CIDRS->{$c} || ($c eq "reserved")) {
		$OPTS{'input'} = $c;
		$OPTS{'reserved'} = 1;
		return;
	}

	if ($c =~ m/^[a-z]+-[a-z]+(-[0-9]+)?$/) {
		verbose("Using AWS region '$c'...", 2);
		$OPTS{'input'} = $c;
		$OPTS{'aws'} = 1;
		return;
	}

	if ($c =~ m/^(asn?)?([0-9]+)$/) {
		my $asn = $2;
		verbose("Using ASN $asn...", 2);
		$OPTS{'asn'} = $2;
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
	$OPTS{'input'} = $country;
	$OPTS{'cc'} = $ccode;
}


sub printCidrMappings($) {
	my ($which) = @_;

	my $prefix = "";
	if ($which eq "aws") {
		$prefix ="AWS ";
	}

	my @mappings = keys(%CIDR_DESC);
	foreach my $mapping (keys(%CIDR_DESC)) {
		my @cidrs = keys(%{$CIDR_DESC{$mapping}});
		if ($which eq "cc") {
			my $country = code2country($mapping);
			if ($country) {
				$prefix = "$country / ";
			}
		}
		print "${prefix}${mapping} (" . join(", ", @cidrs) . ")\n";
	}

	return scalar(@mappings);
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

	if ($cidr eq "fe80::/10") {
		return generateIPv6LinkLocal();
	}

	# IPv6 blocks are too big to enumerate.
	# If we get an IPv6 block, we grab one from a random /120.
	# Likewise, for IPv4 we try to stay between a /24 and a /14
	my $ipv6max = 120;
	my $ipv4max = 14;

	if ($cidr =~ m/^(.*)\/(.*)$/) {
		my $net = $1;
		my $slash = $2;
		if (($net =~ m/:/) && ($slash < $ipv6max)) {
			verbose("A /$slash is too big to iterate, gonna pick a random /$ipv6max instead...", 3);
			my $n = Net::Netmask->new($cidr);
			$cidr = $n->base();

			my @hextets = split(/:/, $cidr);

			# We fill all but two.
			my $fill = 8 - scalar(@hextets) - 2;
			for (my $i = 0; $i < $fill; $i++) {
				$cidr .= sprintf("%x:", int(rand(2**16)));
			}
			$cidr .= "/$ipv6max";
		} elsif ($slash < $ipv4max) {
			my $mask = int(24 - rand(10));
			verbose("A /$slash is too big to iterate, gonna use a /$mask instead...", 3);
			$cidr = "$net/$mask";
		}
	}

	verbose("Selecting an IP from $cidr...");
	my $block = createNetmask($cidr);
	my @ips = $block->enumerate();
	return $ips[rand(@ips)];
}

sub usage($) {
	my ($err) = @_;

	my $FH = $err ? \*STDERR : \*STDOUT;

	print $FH <<EOH
Usage: $PROGNAME [-46UVachruv] [-d dir] country|reserved|cidr
	-4      only return IPv4 results
	-6      only return IPv6 results
	-a      check all country allocations when using '-r'
	-U      don't update local files
	-V      print version number and exit
	-c      return a CIDR subnet instead of an IP address
	-d dir  store CIDR data in this directory (default: ~/.gip)
	-h      print this help and exit
	-r      reverse lookup
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

if ($OPTS{'reverse'}) {
	doReverseLookup();
	exit($RETVAL);
}

if ($OPTS{'reserved'}) {
	parseReservedCIDRs();
} elsif ($OPTS{'net'}) {
	parseGivenCIDR();
} elsif ($OPTS{'aws'}) {
	getAWSIPRanges();
	parseAWSData();
} elsif ($OPTS{'asn'}) {
	getASN();
	parseASN();
} else {
	getCountryNetblocks($OPTS{'input'}, $OPTS{'cc'});
	parseCCCIDRs($OPTS{'cc'});
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
