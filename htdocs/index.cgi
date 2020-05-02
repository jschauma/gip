#! /usr/pkg/bin/perl -Tw
#
# Originally written by Jan Schaumann
# <jschauma@netmeister.org> in April 2020.
#
# This CGI provides a web frontend to gip(1):
# https://github.com/jschauma/gip

use strict;
use CGI qw(:standard);
use IPC::Open3;

###
### Globals
###

my $GIP = "/usr/local/bin/gip";
my $DATADIR= "/usr/local/share/gip";
my @CMD = ( $GIP, "-U", "-d", $DATADIR );

$ENV{'PATH'} = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/pkg/bin";

my $CGI = new CGI;

###
### Functions
###

sub runGip() {
	my (@error, @output);

	my $name = $CGI->param('location');
	if (!$name) {
		print $CGI->header(
			-status => '400 Bad Request',
			-type   => 'text/plain',
			);
		push(@error, "Missing location.");
	}

	if ($CGI->param('output') && ($CGI->param('output') eq "cidr")) {
		push(@CMD, "-c");
	}

	if ($CGI->param('ip')) {
		if ($CGI->param('ip') eq "v4") {
			push(@CMD, "-4");
		} elsif ($CGI->param('ip') eq "v6") {
			push(@CMD, "-6");
		}
	}

	if ($name =~ m/^([a-z0-9 .-]+)$/i) {
		$name = $1;
	} else {
		print $CGI->header(
			-status => '400 Bad Request',
			-type   => 'text/plain',
			);
		push(@error, "Invalid name: '$name'.");
	}
	push(@CMD, $name);

	if (!scalar(@error)) {
		my $rdr;
		my $pid = open3(undef, $rdr, undef, @CMD);
		waitpid($pid, 0);
		@output = <$rdr>;
		if ($? > 0) {
			push(@error, @output);
		}
	}

	if (scalar(@error)) {
		print $CGI->header(
			-status => '404 Not Found',
			-type   => 'text/plain',
			);
		my $err = join("", @error);
		$err =~ s/^gip: //;
		print "Error: $err";
	} else {
		print $CGI->header(
			-type   => 'text/plain',
			);
		print join("", @output);
	}
}

sub printHead() {

	print "Content-Type: text/html; charset=utf-8\n\n";

	print <<EOD
<HTML>
  <HEAD>
    <TITLE>gip -- get an IP in a geographical location or country</TITLE>
    <link rel="stylesheet" type="text/css" href="/index.css">
  </HEAD>
  <BODY>
  <h2>gip -- get an IP in a geographical location or country</h2>
  <hr>
EOD
;
}

sub printInstructions() {
	print <<EOD
  <p>
Sometimes you want to see what a service would do if
you fed it an IP address in a different geographic
location (e.g., EDNS Client Subnet).  The <a
href="https://github.com/jschauma/gip">gip(1)</a>
tool lets you get an IP address or CIDR subnet in a
given location.  Please see <a
href="https://github.com/jschauma/gip/blob/master/doc/gip.1.txt">the
manual page</a> for full details.
  </p>
  <hr width="75%">
EOD
;
}

sub printFoot() {
	print <<EOD
  <hr>
  [Made by <a href="https://twitter.com/jschauma">\@jschauma</a>]&nbsp;|&nbsp;[<a href="/blog/">Other Signs of Triviality</a>]&nbsp;|&nbsp;[<a href="/">main page</a>]
  </BODY>
</HTML>
EOD
;
}

sub printForm() {
	print <<EOD
  <h3>HTML Form</h3>
  <p>
Knowing that people are <em>very</em> lazy and often
times don't want to even install a trivial
command-line tool, here's an HTML form for you:
  </p>
  <FORM ACTION="index.cgi">
    <table border="0">
      <tr>
        <td>Country name, country code, or AWS region to look up:</td>
        <td><input type="text" name="location" width="30"></td>
      </tr>
      <tr>
        <td>Output:</td>
        <td><input type="radio" name="output" value="ip" checked>IP Address<br>
	    <input type="radio" name="output" value="cidr">CIDR subnet<br>
      </tr>
      <tr>
        <td>Include results:</td>
        <td><input type="radio" name="ip" value="both" checked>both IPv4 and IPv6<br>
	    <input type="radio" name="ip" value="v4">only IPv4<br>
	    <input type="radio" name="ip" value="v6">only IPv6<br>
      </tr>
      <tr>
        <td colspan="2">
          <input type="submit" value="Submit">
        </td>
      </tr>
    </table>
  </FORM>
EOD
;
}

sub printCurlExamples() {
	print <<EOD
  <h3><tt>curl(1)</tt> Examples</h3>
  <p>Ah, yes, people can be even lazier! Why use
a browser when you have <tt>curl(1)</tt>?  Ok, ok,
we'll keep it simple.  Here are some examples:
  </p>
  <p>
  <blockquote><tt><pre>\$ curl https://www.netmeister.org/gip/?location=de
45.137.202.112
2a09:d180::79
\$ curl "https://www.netmeister.org/gip/?location=sa-east-1&output=cidr&ip=v6"
2600:1f01:4840::/47
\$ curl "https://www.netmeister.org/gip/?location=Czech+Republic&ip=v4"
5.183.13.0
\$ </pre></tt></blockquote>
  </p>
EOD
;
}

###
### Main
###

if (!$CGI->param('location')) {
	printHead();
	printInstructions();
	printForm();
	printCurlExamples();
	printFoot();
} else {
	runGip();
}