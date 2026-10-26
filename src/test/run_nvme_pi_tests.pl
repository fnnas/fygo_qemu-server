#!/usr/bin/perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use Test::MockModule;

use PVE::QemuServer;
use PVE::QemuServer::Drive qw(parse_drive);
use PVE::QemuServer::QemuImage;
use PVE::Tools qw(run_command);

my $directory = tempdir(CLEANUP => 1);
make_path("$directory/images/8006");
my $storecfg = {
    ids => {
        local => { type => 'dir', path => $directory, content => { images => 1 } },
    },
};
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });

my $run = sub {
    my ($command) = @_;
    my $output = '';
    eval {
        run_command($command, outfunc => sub { $output .= "$_[0]\n"; });
    };
    my $err = $@;
    diag($output, $err) if $err;
    return !$err;
};

my $size = 64 * 1024**2 + 512;
for my $unmanaged (0, 1) {
    for my $format (qw(raw qcow2)) {
        my $filename = "vm-8006-disk-0.$format";
        my $path = "$directory/images/8006/$filename";
        for my $options (
            'ms=8,pi=1',
            'ms=8,pi=1,mset=1,ro=1,snapshot=1,cache=unsafe,aio=native',
            'ms=16,pi=2,pil=1',
            'ms=8,pi=3,logical_block_size=4096',
            'ms=16,pi=1,pif=2,logical_block_size=4096',
            'ms=64,pi=3,pif=2,pil=1,logical_block_size=4096',
            'ms=64,pi=1', # More than one bounded metadata write.
        ) {
            unlink($path) if -e $path;
            my $volume = $unmanaged ? "$path,format=$format" : "local:8006/$filename";
            my $drive = parse_drive('nvme0', "$volume,$options");
            ok($drive, "$volume PI configuration is valid: $options") or next;
            my $block = $drive->{logical_block_size} // 512;
            my $lbas = int($size / ($block + $drive->{ms}));
            my $data_end = $lbas * $block;
            my $metadata_length = $lbas * $drive->{ms};
            my $padding_offset = $data_end + $metadata_length;
            ok(
                $run->(['/usr/bin/qemu-img', 'create', '-q', '-f', $format, $path, $size]),
                'create an empty test image',
            ) or next;
            ok(
                $run->([
                    '/usr/bin/qemu-io',
                    '-f',
                    $format,
                    '-c',
                    'write -q -P 90 0 512',
                    '-c',
                    'write -q -P 90 ' . ($data_end - 512) . ' 512',
                    $path,
                ]),
                'place sentinels at both user-data boundaries',
            ) or next;

            eval { PVE::QemuServer::QemuImage::initialize_nvme_pi($storecfg, $drive); };
            is($@, '', 'initialize the actual allocated image with VM options excluded');
            my $command = [
                '/usr/bin/qemu-io',
                '-f',
                $format,
                '-c',
                'read -q -P 90 0 512',
                '-c',
                'read -q -P 0 512 ' . ($data_end - 1024),
                '-c',
                'read -q -P 90 ' . ($data_end - 512) . ' 512',
                '-c',
                "read -q -P 255 $data_end $metadata_length",
            ];
            push @$command, '-c', "read -q -P 0 $padding_offset " . ($size - $padding_offset)
                if $size > $padding_offset;
            push @$command, $path;
            ok($run->($command),
                'all metadata is initialized and user data and padding are intact');
            ok(
                $run->(['/usr/bin/qemu-img', 'check', '-q', '-f', $format, $path]),
                'qcow2 container is consistent after metadata initialization',
            ) if $format eq 'qcow2';
        }
    }
}

{
    my $blockdev = Test::MockModule->new('PVE::QemuServer::Blockdev');
    $blockdev->mock(
        generate_drive_blockdev => sub {
            return {
                driver => 'blkdebug',
                image =>
                    { driver => 'file', filename => "$directory/images/8006/vm-8006-disk-0.raw" },
                'inject-error' => [{ event => 'pwritev', iotype => 'write', errno => 5 }],
            };
        },
    );
    eval {
        PVE::QemuServer::QemuImage::initialize_nvme_pi(
            $storecfg,
            parse_drive('nvme0', 'local:8006/vm-8006-disk-0.raw,ms=8,pi=1'),
        );
    };
    like(
        $@,
        qr/initializing NVMe protection information failed/,
        'real metadata write failures propagate to allocation cleanup',
    );
}

{
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(activate_volumes => sub { die "unexpected activation\n"; });
    eval {
        PVE::QemuServer::QemuImage::initialize_nvme_pi(
            $storecfg,
            { file => 'local:8006/vm-8006-disk-0.raw', ms => 8, pi => 0 },
        );
    };
    is($@, '', 'metadata without PI is left untouched');
}

done_testing();
