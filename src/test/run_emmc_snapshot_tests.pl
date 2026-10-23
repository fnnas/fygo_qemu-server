#!/usr/bin/perl

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp;
use JSON qw(decode_json);
use POSIX qw(WNOHANG);
use Test::More;
use Test::MockModule;
use Time::HiRes qw(usleep);

use PVE::QemuServer;
use PVE::QemuServer::Drive qw(parse_drive);
use PVE::QemuServer::QemuImage;
use PVE::Tools qw(run_command);

my $tmp = File::Temp->newdir();
my $root = "$tmp/storage, with spaces";
make_path("$root/images/8006", "$root/images/8007");
my $storecfg = { ids => { local => { type => 'dir', path => $root, content => { images => 1 } } } };
my $source_volid = 'local:8006/vm-8006-disk-0.qcow2';
my $source_path = "$root/images/8006/vm-8006-disk-0.qcow2";
my $snapshot_path = "$root/images/8006/native-snapshot.qcow2";
my $snapshot_size = 26 * 1024**2;
my $current_size = 34 * 1024**2;
my $method = 'qemu';
my ($allocated_size, $target_path, $target_format, $round_target);
my $counter = 0;
my @allocations;
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });
my $storage = Test::MockModule->new('PVE::Storage');
$storage->mock(config => sub { $storecfg });
$storage->mock(activate_volumes => sub { });
$storage->mock(volume_has_feature => sub { 0 });
$storage->mock(volume_qemu_snapshot_method => sub { $method });
$storage->mock(
    path => sub {
        my (undef, $volid, $snapname) = @_;
        return $snapshot_path if $volid eq $source_volid && $snapname && $method ne 'qemu';
        $volid =~ s/^local:/$root\/images\//;
        return $volid;
    },
);
$storage->mock(
    vdisk_alloc => sub {
        my (undef, undef, $vmid, $format, undef, $size_kib) = @_;
        $allocated_size = $size_kib * 1024;
        my $volid = "local:$vmid/vm-$vmid-disk-" . ++$counter . ".$format";
        $target_path = PVE::Storage::path($storecfg, $volid);
        run_command([
            'qemu-img',
            'create',
            '-q',
            '-f',
            $format,
            $target_path,
            $round_target // $allocated_size,
        ]);
        push @allocations, $volid;
        return $volid;
    },
);
my $qemu = Test::MockModule->new('PVE::QemuServer');
$qemu->mock(resolve_dst_disk_format => sub { $target_format });

my $clone = sub {
    my ($cached_size, $new_volumes) = @_;
    my $value = "$source_volid,boot-partition-size=4194304,rpmb-partition-size=2097152";
    $value .= ",size=$cached_size" if defined($cached_size);
    return PVE::QemuServer::clone_disk(
        $storecfg,
        {
            vmid => 8006,
            drivename => 'emmc0',
            running => 1,
            snapname => 'before',
            drive => parse_drive('emmc0', $value),
        },
        { vmid => 8007, drivename => 'emmc0', storage => 'local', format => $target_format },
        1,
        $new_volumes,
        {},
        'complete',
        undef,
        0,
    );
};

for my $backing ('none', 'v2', 'raw', 'chain', 'native') {
    $method = $backing eq 'native' ? 'storage' : 'qemu';
    # qcow2 v2 does not allow resizing an image containing internal snapshots.
    my $active_size = $backing eq 'v2' ? $snapshot_size : $current_size;
    unlink($source_path);
    my @options;
    @options = ('-o', 'compat=0.10') if $backing eq 'v2';
    if ($backing eq 'raw' || $backing eq 'chain') {
        my $base = "$root/images/8006/base.raw";
        run_command(['qemu-img', 'create', '-q', '-f', 'raw', $base, $snapshot_size]);
        run_command(['qemu-io', '-f', 'raw', '-c', 'write -P 0x41 0 26M', $base], quiet => 1);
        if ($backing eq 'chain') {
            my $middle = "$root/images/8006/base.qcow2";
            unlink($middle);
            run_command([
                'qemu-img', 'create', '-q', '-f', 'qcow2', '-F', 'raw', '-b', 'base.raw', $middle,
            ]);
            @options = ('-F', 'qcow2', '-b', 'base.qcow2');
        } else {
            @options = ('-F', 'raw', '-b', 'base.raw');
        }
    }
    run_command([
        'qemu-img', 'create', '-q', '-f', 'qcow2', @options, $source_path, $snapshot_size,
    ]);
    run_command(['qemu-io', '-f', 'qcow2', '-c', 'write -P 0x51 0 1M', $source_path], quiet => 1);
    run_command(['qemu-img', 'snapshot', '-c', 'before', $source_path]);
    if ($backing eq 'native') {
        unlink($snapshot_path);
        run_command([
            'qemu-img', 'convert', '-f', 'qcow2', '-O', 'qcow2', $source_path, $snapshot_path,
        ]);
    }
    run_command(['qemu-img', 'resize', '-q', $source_path, $active_size])
        if $active_size != $snapshot_size;
    run_command(
        ['qemu-io', '-f', 'qcow2', '-c', "write -P 0x42 0 $active_size", $source_path],
        quiet => 1,
    );

    for my $format ('raw', 'qcow2') {
        $target_format = $format;
        for my $cached_size (undef, 1024**2) {
            my $new_volumes = [];
            my $result = eval { $clone->($cached_size, $new_volumes); };
            is($@, '', "$backing snapshot clones to $format without relying on cached size");
            next if !$result;
            is(
                $allocated_size,
                $snapshot_size,
                'allocate the snapshot capacity, not the current capacity',
            );
            is(
                $result->{size},
                $snapshot_size,
                'cloned configuration records the original capacity',
            );
            is(
                $result->{'boot-partition-size'},
                4194304,
                'clone retains the snapshot partition layout',
            );
            is_deeply(
                $new_volumes,
                [$allocations[-1]],
                'target stays registered for worker cleanup',
            );

            for my $read (
                'read -P 0x51 0 1M',
                ($backing eq 'raw' || $backing eq 'chain')
                ? 'read -P 0x41 1M 25M'
                : 'read -P 0x00 1M 25M',
            ) {
                eval {
                    run_command(
                        ['qemu-io', '-f', $format, '-c', $read, $target_path],
                        quiet => 1,
                    );
                };
                is($@, '', 'cloned data comes from the snapshot, including its backing chain');
            }
            eval {
                run_command(
                    [
                        'qemu-io',
                        '-f',
                        'qcow2',
                        '-c',
                        "read -P 0x42 0 $active_size",
                        $source_path,
                    ],
                    quiet => 1,
                );
            };
            is($@, '', 'snapshot cloning never modifies current source data');
            my $info = decode_json(PVE::Storage::Common::qemu_img_info($source_path, 'qcow2', 10));
            is($info->{'virtual-size'}, $active_size, 'current source capacity is unchanged');
            unlink($target_path);
        }
    }
}

{
    # Cloning a snapshot of a running VM must only read the immutable snapshot
    # mapping; restoring current refcounts races with the writer's allocations.
    $method = 'qemu';
    $target_format = 'raw';
    unlink($source_path);
    run_command(['qemu-img', 'create', '-q', '-f', 'qcow2', $source_path, $snapshot_size]);
    run_command(['qemu-io', '-f', 'qcow2', '-c', 'write -P 0x41 0 26M', $source_path], quiet => 1);
    run_command(['qemu-img', 'snapshot', '-c', 'before', $source_path]);
    run_command(['qemu-img', 'resize', '-q', $source_path, $current_size]);
    my $commands = "$tmp/writes.txt";
    my $log = "$tmp/writer.log";
    PVE::Tools::file_set_contents(
        $commands,
        join('', map { 'write -P 0x42 ' . ($_ * 65536 % $snapshot_size) . " 65536\n" } 0 .. 99999),
    );
    local $SIG{CHLD} = 'DEFAULT';
    my $pid = fork() // die "cannot start snapshot test writer: $!\n";

    if (!$pid) {
        eval {
            open(STDIN, '<', $commands) or die "$!\n";
            open(STDOUT, '>', $log) or die "$!\n";
            open(STDERR, '>&', \*STDOUT) or die "$!\n";
            exec('qemu-io', '-f', 'qcow2', $source_path) or die "$!\n";
        };
        warn $@;
        POSIX::_exit(1);
    }
    eval {
        for (1 .. 300) {
            last if -s $log;
            usleep(10_000);
        }
        ok(-s $log && kill(0, $pid), 'a concurrent source writer is active before cloning');
        my $new_volumes = [];
        my $result = eval { $clone->(undef, $new_volumes); };
        is($@, '', 'snapshot cloning succeeds while current image data is changing');
        if ($result) {
            is(
                $result->{size},
                $snapshot_size,
                'concurrent snapshot clone keeps the old capacity',
            );
            eval {
                run_command(
                    ['qemu-io', '-f', 'raw', '-c', 'read -P 0x41 0 26M', $target_path],
                    quiet => 1,
                );
            };
            is($@, '', 'concurrent writes never leak into the cloned snapshot');
            unlink($target_path);
        }
    };
    my $error = $@;
    if (waitpid($pid, WNOHANG) == 0) {
        kill(15, $pid);
        waitpid($pid, 0);
    }
    die $error if $error;
}

{
    $method = 'qemu';
    $target_format = 'raw';
    my $image = Test::MockModule->new('PVE::QemuServer::QemuImage');
    my $view_dir;
    $image->mock(
        convert => sub {
            my (undef, undef, undef, $options) = @_;
            my $path = $options->{'source-image-options'}->{file}->{file}->{filename};
            $view_dir = dirname($path);
            ok(-e $path, 'the private view remains available during conversion');
            die "injected conversion failure\n";
        },
    );
    my $new_volumes = [];
    eval { $clone->(undef, $new_volumes); };
    like($@, qr/injected conversion failure/, 'conversion failure propagates');
    ok(defined($view_dir) && !-e $view_dir, 'failed cloning removes the private view');
    is_deeply(
        $new_volumes,
        [$allocations[-1]],
        'failed target remains registered for normal cleanup',
    );
    unlink($target_path);
}

{
    $round_target = 28 * 1024**2;
    my $new_volumes = [];
    eval { $clone->(undef, $new_volumes); };
    like(
        $@,
        qr/eMMC user area must be a power of two/,
        'invalid storage rounding still rejects a snapshot clone',
    );
    is_deeply($new_volumes, [$allocations[-1]], 'rounded target remains registered for cleanup');
    unlink($target_path);
    $round_target = undef;
}

{
    my $path = "$tmp/invalid.qcow2";
    my $header = pack('N N', 0x514649fb, 3) . ("\0" x 64);
    my $too_many = $header;
    substr($too_many, 60, 4) = pack('N', 65537);
    my $outside = $header;
    substr($outside, 60, 4) = pack('N', 1);
    substr($outside, 64, 8) = pack('Q>', 1024**4);
    my $entry_header = $header;
    substr($entry_header, 24, 8) = pack('Q>', $snapshot_size);
    substr($entry_header, 60, 4) = pack('N', 1);
    substr($entry_header, 64, 8) = pack('Q>', 72);

    for my $case (
        ['truncated header', substr($header, 0, 24), qr/metadata range/],
        ['invalid magic', "\0" x 72, qr/unsupported.*header/],
        ['excessive snapshot count', $too_many, qr/invalid.*snapshot table/],
        ['snapshot table beyond EOF', $outside, qr/metadata range/],
        ['truncated snapshot entry', $entry_header, qr/metadata range/],
        [
            'snapshot name beyond EOF',
            $entry_header . pack('Q> N n n N N Q> N N', 0, 0, 0, 65535, 0, 0, 0, 0, 0),
            qr/metadata range/,
        ],
        [
            'snapshot L1 table beyond EOF',
            $entry_header
                . pack('Q> N n n N N Q> N N', 1024**4, 1, 0, 6, 0, 0, 0, 0, 0)
                . 'before',
            qr/invalid.*L1 table/,
        ],
    ) {
        PVE::Tools::file_set_contents($path, $case->[1]);
        eval { PVE::QemuServer::EMMC::qcow2_snapshot_header($path, 'before'); };
        like($@, $case->[2], "reject $case->[0]");
    }
    my $legacy = $entry_header . pack('Q> N n n N N Q> N N', 0, 0, 0, 6, 0, 0, 0, 0, 0) . 'before';
    PVE::Tools::file_set_contents($path, $legacy);
    my $selected = PVE::QemuServer::EMMC::qcow2_snapshot_header($path, 'before');
    is(
        unpack('Q>', $selected),
        $snapshot_size,
        'legacy snapshot entries use the current capacity like QEMU',
    );
    eval { PVE::QemuServer::EMMC::qcow2_snapshot_header($path, 'missing'); };
    like($@, qr/snapshot 'missing' does not exist/, 'missing snapshots fail before allocation');
}

for my $case (
    [{ 'source-image-options' => 'not a graph' }, qr/must describe a block graph/],
    [
        { 'source-image-options' => {}, snapname => 'before' },
        qr/cannot be combined with snapname/,
    ],
) {
    eval {
        PVE::QemuServer::QemuImage::convert(
            $source_volid, $allocations[-1], $snapshot_size, $case->[0],
        );
    };
    like($@, $case->[1], 'invalid private source graph options are rejected');
}

done_testing();
