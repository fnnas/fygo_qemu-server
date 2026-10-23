#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON qw(decode_json encode_json);
use POSIX qw(_exit);
use Socket qw(SOCK_STREAM);
use Test::More;
use Test::MockModule;

use PVE::QMPClient;
use PVE::QemuServer::QMPHelpers;

my $directory = tempdir(CLEANUP => 1);
my $socket = "$directory/monitor.sock";
my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
$helpers->mock(qmp_socket => sub { $socket });
my $text = "USB 中文 é 😀";

for my $type (qw(qmp qsd qga qga-eof qmp-large qmp-oversize)) {
    unlink $socket;
    my $server = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $socket, Listen => 1)
        or die "cannot create monitor socket: $!";
    my $pid = fork();
    die "fork failed: $!" if !defined($pid);
    if (!$pid) {
        my $ok = eval {
            local $SIG{ALRM} = sub { die "test monitor timeout\n"; };
            local $SIG{PIPE} = 'IGNORE';
            alarm($type =~ /^qmp-/ ? 35 : 8);
            my $connection = $server->accept() or die "accept failed: $!";
            $connection->autoflush(1);
            my $qga = $type =~ /^qga/;
            print $connection encode_json({ QMP => {} }) . "\r\n" if !$qga;
            my $decoder = JSON->new->utf8(1);
            my $completed;
            SERVE: while (sysread($connection, my $chunk, 8192)) {
                for my $request ($decoder->incr_parse($chunk)) {
                    if ($request->{execute} eq 'qmp_capabilities') {
                        print $connection encode_json({ return => {}, id => $request->{id} })
                            . "\r\n";
                        next;
                    }
                    if ($request->{execute} eq 'guest-sync-delimited') {
                        print $connection "\xff"
                            . encode_json({ return => $request->{arguments}->{id} }) . "\r\n";
                        next;
                    }
                    die "Unicode request changed in transit\n"
                        if $request->{arguments}->{text} ne $text;
                    if ($type ne 'qga-eof') {
                        print $connection encode_json({
                            event => 'UNICODE',
                            data => { text => $text },
                        })
                            . "\r\n"
                            if !$qga && $type !~ /^qmp-/;
                        # Fragment in the middle of multibyte data, as real sockets can.
                        my $reply_text =
                            $type eq 'qmp-large' ? '中' x (8 * 1024 * 1024)
                            : $type eq 'qmp-oversize' ? '中' x (15 * 1024 * 1024)
                            : $text;
                        my $reply =
                            encode_json({ return => { text => $reply_text }, id => $request->{id} })
                            . "\r\n";
                        print $connection substr($reply, 0, 25);
                        print $connection substr($reply, 25);
                    }
                    close($connection);
                    $completed = 1;
                    last SERVE;
                }
            }
            die "monitor closed without receiving the request\n" if !$completed;
            1;
        };
        warn $@ if !$ok;
        _exit($ok ? 0 : 1);
    }
    close($server);
    my @events;
    my $client = PVE::QMPClient->new(sub { push @events, $_[0]; });
    my $peer_type = $type eq 'qga-eof' ? 'qga' : $type =~ /^qmp-/ ? 'qmp' : $type;
    my $peer = { id => 8006, name => 'Unicode test', type => $peer_type };
    my $command = $type eq 'qga-eof' ? 'guest-shutdown' : 'echo';
    my $result = eval {
        $client->cmd(
            $peer,
            { execute => $command, arguments => { text => $text } },
            $type =~ /^qmp-/ ? 30 : 3,
        );
    };
    if ($type eq 'qmp-oversize') {
        like(
            $@,
            qr/response is bigger than the allowed maximum/,
            'oversized UTF-8 responses are still rejected',
        );
    } else {
        is($@, '', "$type sends Unicode over a byte socket without timing out");
    }

    if ($type eq 'qga-eof') {
        ok(!defined($result),
            'guest shutdown still accepts EOF after the synchronization response');
    } elsif ($type eq 'qmp-large') {
        is(
            length($result->{text} // ''),
            8 * 1024 * 1024,
            'a 24 MiB UTF-8 payload stays below the 43 MiB limit',
        );
        is(substr($result->{text} // '', 0, 1), '中', 'large responses are decoded as characters');
    } elsif ($type eq 'qmp-oversize') {
        ok(!defined($result), 'oversized response is not returned as successful data');
    } else {
        is($result->{text}, $text, "$type decodes Unicode responses exactly once");
    }
    if ($type eq 'qmp' || $type eq 'qsd') {
        is(scalar(@events), 1, "$type delivers the asynchronous event");
        is($events[0]->{data}->{text}, $text, "$type decodes Unicode event data");
    }
    waitpid($pid, 0);
    is($?, 0, "$type peer received the unchanged Unicode request");
}

{
    my $monitor = Test::MockModule->new('PVE::QemuServer::Monitor');
    my @commands;
    $monitor->mock(hmp_cmd => sub { push @commands, $_[1]; return ''; });
    my $device = "usb-storage,id=usbdisk0,serial=$text";
    my $bytes = $device;
    utf8::encode($bytes);
    PVE::QemuServer::QMPHelpers::qemu_deviceadd(8006, $bytes);
    PVE::QemuServer::QMPHelpers::qemu_deviceadd(8006, $device);
    is_deeply(
        \@commands,
        [("device_add \"driver=$device\"") x 2],
        'hotplug accepts UTF-8 command-line bytes and existing character strings without double decoding',
    );
}

done_testing();
