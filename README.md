# gip -- get an IP in a geographical location or country

`gip(1)` is a tool to let you grab an IP address or
CIDR subnet that belongs to the given geographical
location as derived from external sources of truth.

This can be useful for example in the context of
making DNS queries using the EDNS Client Subnet
extension to determine whether the authoritative name
server might return different results based on the
client's geographical location.

Please see the [manual
page](https://github.com/jschauma/gip/blob/master/doc/gip.1.txt)
for details.

`gip(1)` has a web interface at
https://www.netmeister.org/gip/.

## Requirements

`gip(1)` is old-school.  You'll need to have Perl
and the following modules installed:

* JSON
* Net::Netmask

## Installation

You can install `gip(1)` by running `make install`.
The Makefile defaults to '/usr/local' as the prefix,
but you can change that, if you like:

```
$ make PREFIX=~ install
```

---
```
NAME
     gip -- get an IP in a geographical location or country

SYNOPSIS
     gip [-46UVchuv] [-d dir] country

DESCRIPTION
     The gip tool lets you grab an IP address or CIDR subnet that belongs to
     the given geographical location as derived from external sources of
     truth.  This is not particularly bulletproof, and obviously subject to
     change at any given time, but may come in handy when you're looking to
     pick an IP in a given country.

OPTIONS
     The following options are supported by gip:

     -4	      Only return IPv4 results.

     -6	      Only return IPv6 results.

     -U	      Do not update local files.

     -V	      Print version number and exit.

     -c	      Return a CIDR subnet instead of an IP address.

     -d dir   Use the given directory to store CIDR data.  If not specified,
	      default to ~/.gip.

     -h	      Display help and exit.

     -u	      Update local files from their remote sources of truth.

     -v	      Be verbose.  Can be specified multiple times.

DETAILS
     gip takes as argument a country and will attempt to find an IP address
     from that geographical region.  By default, gip will attempt to find both
     an IPv4 and an IPv6 address, but will only print one of the other if only
     that is available.

     The country can be specified as:

     aws-region	  An AWS region.  For example, 'eu-west-1'.  gip will also
		  accept e.g. 'eu-west' and then pick one of the matching
		  regions at random.

     CC		  An ISO-3166-1 Alpha-2 country code.  For example, 'de' for
		  Germany.  For most countries, this will be their ccTLD; gip
		  also accepts 'uk' for Great Britain, as well as 'eu' to let
		  it pick a random country from the European Union, but gip
		  will not accept IDN ccTLDs.

     country	  An English country name.  For example, 'Germany'.  For coun-
		  tries with a name consisting of multiple words, make sure to
		  quote this argument.

     gip will attempt to determine an IP range for the given argument by
     retrieving sources of truth to map your input.  These sources of truth
     include:

     AWS     The IP ranges published by AWS at:
	     https://ip-ranges.amazonaws.com/ip-ranges.json

     CIDRs   Address blocks by CIDR from:
	     https://www.ipdeny.com/

     gip will look for these input files in the directory ~/.gip.  If no files
     are found, or the files found are older than 7 days, or if the -u flag is
     specified, gip will attempt to fetch these files.	This can be disabled
     by specifying the -U flag.

EXAMPLES
     The following examples illustrate common usage of this tool.

     To get an IP address presumed to be in Germany:

	   gip germany

     To get an IPv6 CIDR for the AWS region 'sa-east-1' without updating the
     local data files regardless of age:

	   gip -U -6 -c sa-east-1

     To verbosely get an IPv4 address presumed to be in Czechia:

	   gip -v -v -4 "Czech Republic"

FILES
     gip keeps copies of the data it looked up in the directory ~/.gip.	 In
     there, it will store the files:

     ip-ranges.json	  The list of IP ranges published by AWS.

     <version>/<cc>.zone  The per country code CIDRs.

EXIT STATUS
     The gip utility exits 0 on success, and >0 if an error occurs.

SEE ALSO
     https://xkcd.com/195/

HISTORY
     gip was originally written by Jan Schaumann <jschauma@netmeister.org> in
     April 2020.

BUGS
     Please file bugs and feature requests by emailing the author.

NetBSD 8.0			April 29, 2020			    NetBSD 8.0
```
