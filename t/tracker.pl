#!/usr/bin/env perl
#
# A MogileFS tracker, only as much of one as this module's tests need.
#
# The real tracker is a Perl daemon with a database behind it.  This speaks
# the line protocol the module actually sends and nothing else, so a test
# can ask for a key and get an answer without a MogileFS installation.
#
#     t/tracker.pl --port 7001 --store http://127.0.0.1:7002
#
# The protocol is one line each way.  The module sends
#
#     get_paths key=<key>&domain=<domain>[&noverify=1]
#     create_open key=<key>&domain=<domain>
#     create_close key=<key>&domain=<domain>&devid=..&fid=..&path=..&size=..
#     delete key=<key>&domain=<domain>
#
# and a tracker answers either
#
#     OK <url-encoded key=value pairs>
#     ERR <code> <human readable>
#
# WHAT IS COPIED FROM THE REAL TRACKER, AND WHY IT MATTERS.  The shapes
# below are taken from MogileFS::Worker::Query in MogileFS-Server, not
# guessed, because a stand-in that is more forgiving than the real thing
# turns the test suite into a test of the stand-in:
#
#   cmd_create_open answers devid_N / path_N / dev_count only when the
#   client asked for multi_dest; without it, a plain devid and path.  The
#   module does not ask for it, so the plain shape is what it has to cope
#   with -- answering the numbered shape anyway hid a working write path
#   behind a stand-in that was wrong.
#
#   cmd_create_close refuses the request unless it has both devid and
#   path:
#       my $devid = $args->{devid} or return $self->err_line("no_devid");
#       my $path  = $args->{path}  or return $self->err_line("no_path");
#   so this refuses them too.  A module that hands back the parameters
#   under the wrong names fails here, which is the point.
#
#   cmd_get_paths answers paths=N with path1, path2 and so on, no
#   underscore, and defaults to at most two of them.
#
# Keys live in memory for the lifetime of the process.  A key named so that
# it starts with "err-" makes the tracker answer with the error code that
# follows the dash, which is how the tests reach the error paths without
# needing a broken MogileFS.

use strict;
use warnings;
use IO::Socket::INET;
use Getopt::Long;

my $port   = 7001;
my $store  = 'http://127.0.0.1:7002';
my $domain = 'test';

GetOptions(
    'port=i'   => \$port,
    'store=s'  => \$store,
    'domain=s' => \$domain,
) or die "usage: $0 [--port N] [--store URL] [--domain NAME]\n";

# key => [ paths ]
my %keys = (
    'one'    => ["$store/dev1/0/000/000/0000000001.fid"],
    'three'  => [
        "$store/dev1/0/000/000/0000000002.fid",
        "$store/dev2/0/000/000/0000000002.fid",
        "$store/dev3/0/000/000/0000000002.fid",
    ],
);

my $next_fid = 100;

my $listen = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => $port,
    Proto     => 'tcp',
    Listen    => 32,
    ReuseAddr => 1,
) or die "tracker: cannot listen on $port: $!\n";

$SIG{PIPE} = 'IGNORE';
$| = 1;
print "tracker: listening on 127.0.0.1:$port\n";

sub decode {
    my ($s) = @_;
    $s =~ tr/+/ /;
    $s =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    return $s;
}

sub args {
    my ($s) = @_;
    my %a;
    for my $pair (split /&/, $s // '') {
        my ($k, $v) = split /=/, $pair, 2;
        next unless defined $k;
        $a{decode($k)} = decode($v // '');
    }
    return %a;
}

# A key of the form err-<code> is answered with that code, so a test can
# reach every branch of the module's error table.
sub forced_error {
    my ($key) = @_;
    return $key =~ /^err-(.+)$/ ? $1 : undef;
}

while (my $client = $listen->accept) {
    $client->autoflush(1);

    while (defined(my $line = <$client>)) {
        $line =~ s/\r?\n\z//;
        next if $line eq '';

        my ($cmd, $rest) = split / /, $line, 2;
        my %a = args($rest);
        print "tracker: <- $line\n";

        my $reply;

        if (my $code = forced_error($a{key} // '')) {
            $reply = "ERR $code $code";
        }
        elsif (($a{domain} // '') ne $domain) {
            $reply = 'ERR domain_not_found domain_not_found';
        }
        elsif (!length($a{key} // '')) {
            $reply = 'ERR no_key no_key';
        }
        elsif ($cmd eq 'get_paths') {
            my $paths = $keys{ $a{key} };
            if (!$paths) {
                $reply = 'ERR unknown_key unknown_key';
            } else {
                my @kv = ('paths=' . scalar @$paths);
                my $n  = 0;
                push @kv, 'path' . ++$n . '=' . $_ for @$paths;
                $reply = 'OK ' . join '&', @kv;
            }
        }
        elsif ($cmd eq 'create_open') {
            my $fid  = $next_fid++;
            my $path = sprintf '%s/dev1/0/000/000/%010d.fid', $store, $fid;

            # The numbered shape only on request, exactly as the real
            # tracker does it.
            $reply = $a{multi_dest}
                ? sprintf 'OK dev_count=1&devid_1=1&fid=%d&path_1=%s',
                          $fid, $path
                : sprintf 'OK devid=1&fid=%d&path=%s', $fid, $path;
        }
        elsif ($cmd eq 'create_close') {
            if (!length($a{devid} // '')) {
                $reply = 'ERR no_devid no_devid';
            }
            elsif (!length($a{path} // '')) {
                $reply = 'ERR no_path no_path';
            }
            else {
                $keys{ $a{key} } = [ $a{path} ];
                $reply = 'OK ';
            }
        }
        elsif ($cmd eq 'delete') {
            $reply = exists $keys{ $a{key} }
                ? do { delete $keys{ $a{key} }; 'OK ' }
                : 'ERR unknown_key unknown_key';
        }
        else {
            $reply = 'ERR unknown_command unknown_command';
        }

        print "tracker: -> $reply\n";
        print {$client} "$reply\r\n";
    }

    close $client;
}
