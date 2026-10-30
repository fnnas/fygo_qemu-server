#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
use Test::MockModule;

use PVE::JSONSchema;
use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Drive qw(is_valid_drivename parse_drive print_drive);
use PVE::QemuServer::DriveDevice qw(print_drivedevice_full);
use PVE::QemuServer::EMMC;

my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { return {}; });
my $volume = 'local:8006/vm-8006-disk-0.raw';
my $key = '0123456789abcdef' x 4;
my $cid = '15010043494431323310012345672900';
my $options = "boot-config=74,boot-partition-size=1048576,cid=$cid,rpmb-partition-size=2097152";
my $value = "$volume,auth-key=$key,$options";

ok(is_valid_drivename('emmc0'), 'first eMMC slot is valid');
ok(is_valid_drivename('emmc3'), 'last eMMC slot is valid');
ok(!is_valid_drivename('emmc4'), 'eMMC slot limit is enforced');
ok(!is_valid_drivename('emmc01'), 'eMMC slot indices are canonical');
my $drive = parse_drive('emmc0', $value);
ok($drive, 'parse partitions, partition access, boot ACK and preset RPMB key');
is(print_drive($drive), $value, 'eMMC properties survive printing');
my $zeroes = "$volume,boot-config=0,boot-partition-size=0,rpmb-partition-size=0";
is(print_drive(parse_drive('emmc0', $zeroes)), $zeroes, 'explicit zeroes survive printing');
ok(
    parse_drive('emmc3', 'local:0,import-from=/tmp/emmc.raw', 1),
    'complete image import is supported',
);

for my $with_alloc (0, 1) {
    my $schema = {
        type => 'object',
        additionalProperties => 0,
        properties => PVE::QemuServer::json_config_properties({}, $with_alloc),
    };
    eval { PVE::JSONSchema::validate({ emmc0 => $value }, $schema); };
    is($@, '', "eMMC passes API schema validation (allocation=$with_alloc)");
}

{
    my $padded_key = '00000aBc' x 8;
    my $padded_cid = '00000aBc' x 4;
    for my $case (
        ["cid=$padded_cid", "cid=$padded_cid", 0],
        ['boot-partition-size=04194304', 'boot-partition-size=4194304', 2 * 4194304],
        [
            "auth-key=$padded_key,rpmb-partition-size=00131072",
            "auth-key=$padded_key,rpmb-partition-size=131072",
            131072,
        ],
        [
            'boot-config=010,boot-partition-size=4194304',
            'boot-config=10,boot-partition-size=4194304',
            2 * 4194304,
        ],
        [
            "auth-key=$padded_key,boot-config=010,boot-partition-size=04194304,rpmb-partition-size=00131072",
            "auth-key=$padded_key,boot-config=10,boot-partition-size=4194304,rpmb-partition-size=131072",
            2 * 4194304 + 131072,
        ],
        [
            'boot-config=000,boot-partition-size=000,rpmb-partition-size=000',
            'boot-config=0,boot-partition-size=0,rpmb-partition-size=0',
            0,
        ],
    ) {
        my ($input, $canonical, $aux) = @$case;
        my $parsed = parse_drive('emmc0', "$volume,$input");
        ok($parsed, "accept decimal eMMC integers with leading zeroes: $input");
        is(
            print_drive($parsed),
            "$volume,$canonical",
            'printing normalizes integers and preserves authentication key bytes',
        );
        my %expected = map { split('=', $_, 2) } split(',', $canonical);
        my $device = 'emmc,id=emmc0,drive=drive-emmc0,bus=pci.4/sdhci-emmc0/sd-bus';
        for my $option (qw(boot-partition-size rpmb-partition-size boot-config auth-key cid)) {
            $device .= ",$option=$expected{$option}" if defined($expected{$option});
        }
        is(
            print_drivedevice_full({}, {}, 8006, $parsed, 'x86_64', 'pc-q35-11.1'),
            $device,
            'QEMU receives decimal integers without octal prefixes and the unmodified key',
        );
        is(
            PVE::QemuServer::EMMC::validate_size($parsed, 1024**3 + $aux),
            1024**3,
            'layout validation uses the same decimal partition sizes as QEMU',
        );
        for my $with_alloc (0, 1) {
            my $schema = {
                type => 'object',
                additionalProperties => 0,
                properties => PVE::QemuServer::json_config_properties({}, $with_alloc),
            };
            eval { PVE::JSONSchema::validate({ emmc0 => "$volume,$input" }, $schema); };
            is($@, '', "leading zeroes pass API validation (allocation=$with_alloc)");
        }
    }
    my $omitted = parse_drive('emmc0', $volume);
    is(print_drive($omitted), $volume, 'omitted eMMC integers remain omitted');
    is(
        print_drivedevice_full({}, {}, 8006, $omitted, 'x86_64', 'pc-q35-11.1'),
        'emmc,id=emmc0,drive=drive-emmc0,bus=pci.4/sdhci-emmc0/sd-bus',
        'omitted eMMC options are not added to the QEMU command',
    );
}

for my $bad (
    'media=cdrom',
    'serial=foo',
    'ro=1',
    'ssd=1',
    'iothread=1',
    'discard=on',
    'rerror=stop',
    'werror=stop',
    'removable=1',
    'queues=2',
    'boot-partition-size=1',
    'boot-partition-size=00001',
    'boot-partition-size=33554432',
    'rpmb-partition-size=1',
    'rpmb-partition-size=00001',
    'rpmb-partition-size=16908288',
    'boot-config=1',
    'boot-config=8',
    'boot-config=3',
    'boot-config=24',
    'boot-config=00024',
    'boot-config=4',
    'boot-config=128',
    'auth-key=abcd',
    "auth-key=$key",
    'cid=',
    'cid=' . ('a' x 31),
    'cid=' . ('a' x 33),
    'cid=' . ('g' x 32),
    'cid=0x' . ('a' x 30),
    "cid=$cid\n",
) {
    local $SIG{__WARN__} = sub { };
    ok(!parse_drive('emmc0', "$volume,$bad"), "reject invalid or unsupported options: $bad");
}
for my $bad ('', 'a' x 31, 'a' x 33, 'g' x 32, "$cid\n") {
    eval { PVE::QemuServer::EMMC::validate_options({ cid => $bad }); };
    like(
        $@,
        qr/cid must contain exactly 32 hexadecimal characters/,
        'internal CID validation is strict',
    );
}
for my $id ('scsi0', 'nvme0', 'usbdisk0') {
    local $SIG{__WARN__} = sub { };
    ok(!parse_drive($id, "$volume,cid=$cid"), "CID is restricted to eMMC: $id");
}
for my $file ('none', 'cdrom', 'local:vm-8006-cloudinit') {
    ok(!parse_drive('emmc0', $file), "eMMC requires a disk image: $file");
}
ok(parse_drive('emmc0', "$volume,boot-config=56"), 'user-area boot needs no boot partitions');
ok(
    parse_drive('emmc0', "$volume,boot-config=3,rpmb-partition-size=131072"),
    'RPMB partition access',
);

my $aux = 4 * 1024**2;
for my $user (2 * 1024**2, 4 * 1024**2, 1024**3, 2 * 1024**3, 2 * 1024**3 + 512, 32 * 1024**3) {
    is(
        PVE::QemuServer::EMMC::validate_size($drive, $user + $aux),
        $user,
        "image layout exposes $user user bytes",
    );
}
for my $reserved (
    {},
    { 'boot-partition-size' => 4194304 },
    { 'boot-partition-size' => 4194304, 'rpmb-partition-size' => 2097152 },
) {
    my $drive = {%$reserved};
    my $offset =
        2 * ($drive->{'boot-partition-size'} // 0) + ($drive->{'rpmb-partition-size'} // 0);
    for my $user (512, 131072, 262144, 524288, 1024**2, 2 * 1024**2 - 512) {
        eval { PVE::QemuServer::EMMC::validate_size($drive, $offset + $user); };
        like(
            $@,
            qr/eMMC user area must be at least 2 MiB/,
            'reject user capacity below the minimum represented correctly by QEMU CSD',
        );
    }
    my $minimum = $drive->{'boot-partition-size'} || 2 * 1024**2;
    is(
        PVE::QemuServer::EMMC::validate_size($drive, $offset + $minimum),
        $minimum,
        'the minimum user area accounts for both CSD capacity and boot partition size',
    );
}
for my $rpmb (0, 2097152) {
    for my $case (
        [131072, 2 * 1024**2, 1],
        [2 * 1024**2, 2 * 1024**2, 1],
        [4 * 1024**2, 2 * 1024**2, 0],
        [4 * 1024**2, 4 * 1024**2, 1],
        [16 * 1024**2, 8 * 1024**2, 0],
        [16 * 1024**2, 16 * 1024**2, 1],
        [32640 * 1024, 16 * 1024**2, 0],
        [32640 * 1024, 32 * 1024**2, 1],
    ) {
        my ($boot, $user, $allowed) = @$case;
        my $drive = { 'boot-partition-size' => $boot, 'rpmb-partition-size' => $rpmb };
        eval { PVE::QemuServer::EMMC::validate_size($drive, 2 * $boot + $rpmb + $user); };
        if ($allowed) {
            is($@, '', 'user area at least as large as BOOT1/BOOT2 remains valid');
        } else {
            like(
                $@,
                qr/eMMC user area must be at least as large as each boot partition/,
                'reject user areas which prevent reading the end of BOOT1/BOOT2',
            );
        }
    }
}
for my $size (
    undef, 0, $aux - 512, $aux, $aux + 513,
    $aux + 3 * 1024**2,
    $aux + 2 * 1024**3 + 1,
    $aux + 2 * 1024**4,
) {
    eval { PVE::QemuServer::EMMC::validate_size($drive, $size); };
    ok($@, 'reject an empty, undersized or unaligned image');
}
{
    my $storage = Test::MockModule->new('PVE::Storage');
    my $actual = 1024**3 + $aux;
    $storage->mock(volume_size_info => sub { return $actual; });
    my $stored = { %$drive, size => 32 * 1024**3 };
    is(
        PVE::QemuServer::EMMC::validate_image({}, $stored),
        1024**3,
        'startup validates the actual volume, ignoring informational size',
    );
    $actual += 4 * 1024**2;
    eval { PVE::QemuServer::EMMC::validate_image({}, $stored); };
    like(
        $@,
        qr/user area must be a power of two/,
        'reject incompatible storage allocation rounding',
    );
    $storage->mock(
        file_size_info => sub {
            is_deeply(
                [@_],
                ['/tmp/emmc.qcow2', undef, 'qcow2'],
                'unmanaged image uses its explicit format',
            );
            return 8 * 1024**3;
        },
    );
    is(
        PVE::QemuServer::EMMC::image_size({}, { file => '/tmp/emmc.qcow2', format => 'qcow2' }),
        8 * 1024**3,
        'unmanaged qcow2 image uses virtual size',
    );
}
{
    my $tools = Test::MockModule->new('PVE::Tools');
    my %supported;
    my $probe_count = 0;
    my $probe_error = 0;
    $tools->mock(
        run_command => sub {
            my ($cmd, %opts) = @_;
            $probe_count++;
            is_deeply(
                [@$cmd[1 .. $#$cmd]],
                ['-device', 'emmc,help'],
                'capability probe contains no configured values',
            );
            $opts{outfunc}->("  $_=<str>") for sort keys %supported;
            die "probe failed\n" if $probe_error;
        },
    );
    PVE::QemuServer::EMMC::assert_qemu_support({}, 'x86_64');
    is($probe_count, 0, 'default eMMC requires no optional QEMU capability probe');
    eval { PVE::QemuServer::EMMC::assert_qemu_support($drive, 'x86_64'); };
    like(
        $@,
        qr/requires a QEMU build with the emmc.auth-key property/,
        'old QEMU gets an actionable error',
    );
    unlike($@, qr/$key/, 'unsupported-property error contains no authentication key');
    eval { PVE::QemuServer::EMMC::assert_qemu_support({ cid => $cid }, 'x86_64'); };
    like(
        $@,
        qr/requires a QEMU build with the emmc.cid property/,
        'CID gets an actionable capability error',
    );
    $supported{'auth-key'} = 1;
    eval { PVE::QemuServer::EMMC::assert_qemu_support($drive, 'x86_64'); };
    like(
        $@,
        qr/requires a QEMU build with the emmc.cid property/,
        'auth-key support does not imply CID support',
    );
    $supported{cid} = 1;

    for my $arch ('x86_64', 'aarch64') {
        eval { PVE::QemuServer::EMMC::assert_qemu_support($drive, $arch); };
        is($@, '', "accept a QEMU build advertising both properties: $arch");
    }
    $probe_error = 1;
    eval { PVE::QemuServer::EMMC::assert_qemu_support({ cid => $cid }, 'x86_64'); };
    like(
        $@,
        qr/requires a QEMU build with the emmc.cid property/,
        'failed probe does not accept partial output',
    );
}

my $filename = '/etc/pve/qemu-server/8006.conf';
my $raw = "emmc0: $value\n\n[PENDING]\nemmc3: $volume\n\n[snapshot]\nemmc0: $value\nsnaptime: 1\n";
my $config = PVE::QemuServer::parse_vm_config($filename, $raw, 1);
my $roundtrip = PVE::QemuServer::parse_vm_config(
    $filename, PVE::QemuServer::write_vm_config($filename, $config), 1,
);
is($roundtrip->{emmc0}, $value, 'strict configuration round trip preserves eMMC');
is($roundtrip->{pending}->{emmc3}, $volume, 'pending eMMC survives a round trip');
is($roundtrip->{snapshots}->{snapshot}->{emmc0}, $value, 'snapshot preserves eMMC layout and key');
my @volumes;
PVE::QemuConfig->foreach_volume($config, sub { push @volumes, $_[0]; });
is_deeply(\@volumes, ['emmc0'], 'backup and volume operations include eMMC');
is(
    PVE::QemuServer::restore_update_config_line(
        {},
        { emmc0 => 'target:disk.raw' },
        "emmc0: $value\n",
        0,
    ),
    "emmc0: target:disk.raw,auth-key=$key,$options\n",
    'restore remaps the image and preserves eMMC options',
);
is(
    PVE::QemuServer::restore_update_config_line({}, {}, "emmc0: $volume,backup=0\n", 0),
    "#emmc0: $volume,backup=0\n",
    'restore honors excluded eMMC volumes',
);

ok(!PVE::QemuServer::Drive::verify_bootdisk('emmc0', 1), 'eMMC has no firmware bootdisk property');
ok(!PVE::QemuServer::verify_bootdev('emmc0', 1), 'eMMC cannot be added to boot order');
is_deeply(
    PVE::QemuServer::get_default_bootdevices({ emmc0 => $volume }),
    [],
    'default firmware boot order excludes eMMC',
);
is_deeply(
    PVE::QemuServer::bootorder_from_legacy({ emmc0 => $volume }),
    {},
    'legacy boot order excludes eMMC',
);

is_deeply(
    [PVE::QemuMigrate::Helpers::check_non_migratable_resources({ emmc0 => $value }, 1, 1)],
    ['emmc0'],
    'RPMB blocks RAM snapshots, live migration and hibernation',
);
is_deeply(
    [PVE::QemuMigrate::Helpers::check_non_migratable_resources({ emmc0 => $value }, 0, 1)],
    [],
    'RPMB permits disk-only snapshots and offline migration',
);
is_deeply(
    [PVE::QemuMigrate::Helpers::check_non_migratable_resources({ emmc0 => $volume }, 1, 1)],
    [],
    'eMMC without RPMB has migratable RAM state',
);
eval { PVE::QemuMigrate::Helpers::check_non_migratable_resources({ emmc0 => $value }, 1, 0); };
like(
    $@,
    qr/Cannot live-migrate, snapshot.*hibernate.*emmc0/s,
    'unsupported RPMB state operations fail before saving unusable state',
);

for my $machine ('pc-i440fx-9.2', 'pc-q35-11.1') {
    my $cmd =
        print_drivedevice_full({}, {}, 8006, { %$drive, bootindex => 100 }, 'x86_64', $machine);
    like(
        $cmd,
        qr/^emmc,id=emmc0,drive=drive-emmc0,bus=pci\.4\/sdhci-emmc0\/sd-bus,/,
        "dedicated SDHCI bus for $machine",
    );
    like($cmd, qr/boot-config=74/, 'native EXT_CSD boot configuration is passed');
    like($cmd, qr/auth-key=$key/, 'preset RPMB key is passed');
    like($cmd, qr/cid=$cid(?:,|$)/, 'custom CID is passed without changing its bytes');
    unlike(
        $cmd,
        qr/bootindex|serial|write-cache|rerror|werror/,
        'only supported eMMC properties are emitted',
    );
}
like(
    print_drivedevice_full({}, { template => 1 }, 8006, $drive, 'x86_64', 'pc-i440fx-11.1'),
    qr/^virtio-blk-pci,id=emmc0,drive=drive-emmc0,bus=pci\.4,addr=0x15$/,
    'template backup has a frontend compatible with read-only base volumes',
);
is(
    PVE::QemuServer::Blockdev::qdev_id_to_drive_id('/machine/peripheral/emmc0'),
    'emmc0',
    'block queries map the QEMU eMMC path',
);
is(
    PVE::QemuServer::Blockdev::qdev_id_to_drive_id('/machine/peripheral/emmc0/virtio-backend'),
    'emmc0',
    'block queries map template backup frontend',
);

{
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    my @calls;
    $qemu->mock(vm_deviceplug => sub { push @calls, 'plug'; });
    $qemu->mock(vm_deviceunplug => sub { push @calls, 'unplug'; });
    $qemu->mock(vmconfig_delete_or_detach_drive => sub { push @calls, 'detach'; });
    for my $conf ({}, { emmc0 => $value }) {
        for my $new (
            "$volume,boot-partition-size=2097152", 'local:8006/vm-8006-disk-1.raw',
        ) {
            eval {
                PVE::QemuServer::vmconfig_update_disk(
                    {}, $conf, 1, 8006, 'emmc0', $new, 'x86_64', 'pc-i440fx-11.1',
                );
            };
            is($@, "skip\n", 'eMMC attach, replacement and property changes stay pending');
        }
    }
    for my $same ($value, "$value,backup=0", "$value,replicate=0") {
        eval {
            PVE::QemuServer::vmconfig_update_disk(
                {},
                { emmc0 => $value },
                1,
                8006,
                'emmc0',
                $same,
                'x86_64',
                'pc-i440fx-11.1',
            );
        };
        is($@, '', 'unchanged device and backup/replication metadata need no restart');
    }
    for my $option (
        ['boot-partition-size', 2097152],
        ['rpmb-partition-size', 4194304],
        ['boot-config', 75],
        ['auth-key', 'cd' x 32],
        ['cid', '00aAbBcC' x 4],
        ['cid', undef],
    ) {
        my $changed = { %$drive, $option->[0] => $option->[1] };
        eval {
            PVE::QemuServer::vmconfig_update_disk(
                {},
                { emmc0 => $value },
                1,
                8006,
                'emmc0',
                print_drive($changed),
                'x86_64',
                'pc-i440fx-11.1',
            );
        };
        is($@, "skip\n", "eMMC native property change stays pending: $option->[0]");
    }
    my @throttles;
    my $blockdev = Test::MockModule->new('PVE::QemuServer::Blockdev');
    $blockdev->mock(set_io_throttle => sub { push @throttles, [@_]; });
    eval {
        PVE::QemuServer::vmconfig_update_disk(
            {},
            { emmc0 => $value },
            1,
            8006,
            'emmc0',
            "$value,iops_rd=100",
            'x86_64',
            'pc-i440fx-11.1',
        );
    };
    is($@, '', 'eMMC block throttling can change while running');
    is_deeply(
        [@{ $throttles[0] }[0, 1, 6]],
        [8006, 'drive-emmc0', 100],
        'live throttling targets the existing eMMC block backend',
    );
    my $config_mock = Test::MockModule->new('PVE::QemuConfig');
    $config_mock->mock(write_config => sub { });
    my $cgroup = Test::MockModule->new('PVE::QemuServer::CGroup');
    $cgroup->mock(new => sub { return bless {}, 'PVE::QemuServer::CGroup'; });
    my $pending = { emmc0 => $value, pending => { delete => 'emmc0' } };
    my $errors = {};
    PVE::QemuServer::vmconfig_hotplug_pending(8006, $pending, {}, undef, $errors);
    is_deeply($errors, {}, 'pending removal is not reported as a hotplug error');
    is($pending->{emmc0}, $value, 'running eMMC remains attached');
    is($pending->{pending}->{delete}, 'emmc0', 'eMMC removal stays pending until shutdown');
    is_deeply(\@calls, [], 'pending changes never replug or detach eMMC');
}
{
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    my $running = 1;
    $helpers->mock(vm_running_locally => sub { return $running; });
    my $storage = Test::MockModule->new('PVE::Storage');
    my @calls;
    $storage->mock(volume_resize => sub { push @calls, [@_]; });
    eval { PVE::QemuServer::Blockdev::resize(8006, 'drive-emmc0', {}, $volume, 8 * 1024**3); };
    like(
        $@,
        qr/cannot resize eMMC disk.*shut down/,
        'live resize is blocked before touching storage',
    );
    is_deeply(\@calls, [], 'live resize refusal leaves storage intact');
    $running = 0;
    PVE::QemuServer::Blockdev::resize(8006, 'drive-emmc0', {}, $volume, 8 * 1024**3);
    is_deeply(\@calls, [[{}, $volume, 8 * 1024**3, 0]], 'offline resize uses the storage layer');
}

done_testing();
