#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use PVE::JSONSchema;
use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Drive qw(is_valid_drivename parse_drive print_drive);
use PVE::QemuServer::DriveDevice qw(print_drivedevice_full);
use PVE::QemuServer::SDCard;

my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });
my $volume = 'local:8006/vm-8006-disk-0.raw';
my $cid = '03534453443332478535bca2a70195df';
my $value = "$volume,cid=$cid,sd-spec-version=3";
my $drive = parse_drive('sdcard0', $value);
ok($drive, 'SD CID and specification are accepted');
is(print_drive($drive), $value, 'SD configuration round trip preserves options');

for my $index (0 .. 3) {
    ok(is_valid_drivename("sdcard$index"), "SD slot $index is registered");
}
for my $invalid ('sdcard4', 'sdcard01', 'sdcard-1') {
    ok(!is_valid_drivename($invalid), "reject invalid SD slot $invalid");
}
for my $with_alloc (0, 1) {
    eval {
        PVE::JSONSchema::validate(
            { sdcard0 => $value, bootdisk => 'sdcard0' },
            {
                type => 'object',
                additionalProperties => 0,
                properties => PVE::QemuServer::json_config_properties({}, $with_alloc),
            },
        );
    };
    is($@, '', "SD card is part of the API schema (allocation=$with_alloc)");
}
ok(parse_drive('sdcard0', 'local:0,import-from=/tmp/sd.raw', 1), 'SD image imports are supported');
for my $bad (
    'media=cdrom',
    'ro=1',
    'ssd=1',
    'iothread=1',
    'discard=on',
    'serial=foo',
    'rerror=stop',
    'werror=stop',
    'boot-config=0',
    'boot-partition-size=0',
    'rpmb-partition-size=0',
    'auth-key=' . ('a' x 64),
    'sd-spec-version=1',
    'sd-spec-version=4',
    'cid=',
    'cid=' . ('a' x 31),
    'cid=' . ('g' x 32),
    "cid=$cid\n",
) {
    ok(!parse_drive('sdcard0', "$volume,$bad"), "reject unsupported SD option $bad");
}
for my $file ('none', 'cdrom', 'local:vm-8006-cloudinit.raw') {
    ok(!parse_drive('sdcard0', $file), "SD card requires a normal disk: $file");
}
for my $id ('virtio0', 'scsi0', 'usbdisk0', 'nvme0', 'emmc0') {
    ok(
        !parse_drive($id, "$volume,sd-spec-version=3"),
        "SD specification is exclusive to SD cards: $id",
    );
}
for my $bytes (256 * 1024, 2 * 1024**2, 64 * 1024**2, 2 * 1024**3, 3 * 1024**3, 2 * 1024**4) {
    is(
        PVE::QemuServer::SDCard::validate_size($drive, $bytes),
        $bytes,
        "accept representable SD size $bytes",
    );
}
for my $bytes (undef, 0, 128 * 1024, 3 * 1024**2, 2 * 1024**3 + 512, 2 * 1024**4 + 512 * 1024) {
    eval { PVE::QemuServer::SDCard::validate_size($drive, $bytes); };
    like($@, qr/SD card image/, 'reject unknown or unrepresentable SD capacity');
}
for my $arch ('x86_64', 'aarch64') {
    is(
        print_drivedevice_full({}, {}, 8006, $drive, $arch, 'pc-q35-11.0'),
        "sd-card,id=sdcard0,drive=drive-sdcard0,bus=pci.4/sdhci-sdcard0/sd-bus,cid=$cid,spec_version=3",
        "native SD device is used on $arch",
    );
}
is(
    print_drivedevice_full({}, {}, 8006, parse_drive('sdcard0', $volume), 'x86_64', 'pc-q35-11.0'),
    'sd-card,id=sdcard0,drive=drive-sdcard0,bus=pci.4/sdhci-sdcard0/sd-bus',
    'omitted CID and specification retain QEMU defaults',
);
like(
    print_drivedevice_full({}, { template => 1 }, 8006, $drive, 'x86_64', 'pc-q35-11.0'),
    qr/^virtio-blk-pci,id=sdcard0,drive=drive-sdcard0,bus=pci\.4,addr=0x19$/,
    'template backups use a frontend compatible with read-only base volumes',
);
for my $suffix ('', '/virtio-backend') {
    is(
        PVE::QemuServer::Blockdev::qdev_id_to_drive_id("/machine/peripheral/sdcard0$suffix"),
        'sdcard0',
        'block queries identify SD runtime and template frontends',
    );
}
is(PVE::QemuServer::verify_bootdev('sdcard0', 1), 'sdcard0', 'SD card can be in boot order');
is(
    PVE::QemuServer::Drive::verify_bootdisk('sdcard0', 1),
    'sdcard0',
    'legacy SD bootdisk is accepted',
);
is_deeply(
    PVE::QemuServer::device_bootorder({
        boot => 'order=sdcard3;sdcard0',
        sdcard0 => $value,
        sdcard3 => $volume,
    }),
    { sdcard3 => 100, sdcard0 => 101 },
    'boot order retains individual SD slots',
);
my $filename = '/qemu-server/8006.conf';
my $conf = PVE::QemuServer::parse_vm_config(
    $filename,
    "sdcard0: $value\n\n[PENDING]\nsdcard3: $volume\n\n[snapshot]\nsdcard0: $value\n",
    1,
);
my $roundtrip = PVE::QemuServer::parse_vm_config(
    $filename, PVE::QemuServer::write_vm_config($filename, $conf), 1,
);
is($roundtrip->{sdcard0}, $value, 'strict VM configuration retains SD cards');
is($roundtrip->{pending}->{sdcard3}, $volume, 'pending SD card survives serialization');
is(
    $roundtrip->{snapshots}->{snapshot}->{sdcard0},
    $value,
    'snapshot retains SD CID and specification',
);
my @volumes;
PVE::QemuConfig->foreach_volume($conf, sub { push @volumes, $_[0]; });
is_deeply(\@volumes, ['sdcard0'], 'backup and replication discover SD volumes');
is(
    PVE::QemuServer::restore_update_config_line(
        {},
        { sdcard0 => 'target:disk.raw' },
        "sdcard0: $value\n",
        0,
    ),
    "sdcard0: target:disk.raw,cid=$cid,sd-spec-version=3\n",
    'restore remaps SD volumes and preserves identity',
);
is(
    PVE::QemuServer::restore_update_config_line({}, {}, "sdcard0: $volume,backup=0\n", 0),
    "#sdcard0: $volume,backup=0\n",
    'restore honors SD backup exclusion',
);
is_deeply(
    [PVE::QemuMigrate::Helpers::check_non_migratable_resources({ sdcard0 => $value }, 1, 1)],
    [],
    'SD cards have no RPMB migration restriction',
);

{
    my @calls;
    my $tools = Test::MockModule->new('PVE::Tools');
    my %supported;
    my $failure;
    $tools->mock(
        run_command => sub {
            my ($cmd, %opts) = @_;
            push @calls, $cmd;
            $opts{outfunc}->("$supported{$cmd->[2]}=<str>") if $supported{ $cmd->[2] };
            die "probe failed\n" if $failure;
        },
    );
    PVE::QemuServer::SDCard::assert_qemu_support({}, 'x86_64');
    is_deeply(\@calls, [], 'default SD cards require no optional-property probe');
    eval { PVE::QemuServer::SDCard::assert_qemu_support($drive, 'x86_64'); };
    like($@, qr/sd-card.cid/, 'missing CID capability has an actionable error');
    $supported{'sd-card,help'} = 'cid';
    eval { PVE::QemuServer::SDCard::assert_qemu_support($drive, 'x86_64', 100); };
    like($@, qr/sdhci-pci.bootindex/, 'boot capability is checked independently');
    $supported{'sdhci-pci,help'} = 'bootindex';
    eval { PVE::QemuServer::SDCard::assert_qemu_support($drive, 'aarch64', 100); };
    is($@, '', 'complete capabilities permit custom CID and ordered boot');
    like($calls[-1]->[0], qr/qemu-system-aarch64$/, 'probe uses the target architecture');
    $failure = 1;
    eval { PVE::QemuServer::SDCard::assert_qemu_support($drive, 'x86_64'); };
    like($@, qr/requires a QEMU build/, 'failed probes do not accept partial output');
}
{
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    my @calls;
    $qemu->mock(vm_deviceplug => sub { push @calls, 'plug'; });
    $qemu->mock(vm_deviceunplug => sub { push @calls, 'unplug'; });
    $qemu->mock(vmconfig_delete_or_detach_drive => sub { push @calls, 'detach'; });
    for my $change ({ cid => 'aa' x 16 }, { cid => undef }, { 'sd-spec-version' => 2 }) {
        eval {
            PVE::QemuServer::vmconfig_update_disk(
                {},
                { sdcard0 => $value },
                1,
                8006,
                'sdcard0',
                print_drive({ %$drive, %$change }),
                'x86_64',
                'pc-q35-11.0',
            );
        };
        is($@, "skip\n", 'SD identity and specification changes wait for shutdown');
    }
    eval {
        PVE::QemuServer::vmconfig_update_disk(
            {}, {}, 1, 8006, 'sdcard0', $value, 'x86_64', 'pc-q35-11.0',
        );
    };
    is($@, "skip\n", 'adding SD hardware waits for shutdown');
    is_deeply(\@calls, [], 'pending SD changes never replug hardware');
    my @throttles;
    my $blockdev = Test::MockModule->new('PVE::QemuServer::Blockdev');
    $blockdev->mock(set_io_throttle => sub { push @throttles, [@_]; });
    eval {
        PVE::QemuServer::vmconfig_update_disk(
            {},
            { sdcard0 => $value },
            1,
            8006,
            'sdcard0',
            "$value,iops_rd=100",
            'x86_64',
            'pc-q35-11.0',
        );
    };
    is($@, '', 'SD bandwidth limits can be changed while running');
    is_deeply(
        [@{ $throttles[0] }[0, 1, 6]],
        [8006, 'drive-sdcard0', 100],
        'SD bandwidth updates target the existing block node',
    );
    my $config_mock = Test::MockModule->new('PVE::QemuConfig');
    $config_mock->mock(write_config => sub { });
    my $cgroup = Test::MockModule->new('PVE::QemuServer::CGroup');
    $cgroup->mock(new => sub { bless {}, 'PVE::QemuServer::CGroup' });
    my $pending = { sdcard0 => $value, pending => { delete => 'sdcard0' } };
    my $errors = {};
    PVE::QemuServer::vmconfig_hotplug_pending(8006, $pending, {}, undef, $errors);
    is_deeply($errors, {}, 'pending SD removal is not a hotplug error');
    is($pending->{sdcard0}, $value, 'pending SD removal retains running hardware');
    is($pending->{pending}->{delete}, 'sdcard0', 'SD removal waits for shutdown');
    is_deeply(\@calls, [], 'pending SD removal never unplugs or detaches the image');
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    $helpers->mock(vm_running_locally => sub { 1 });
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(volume_resize => sub { push @calls, 'resize'; });
    eval { PVE::QemuServer::Blockdev::resize(8006, 'drive-sdcard0', {}, $volume, 128 * 1024**2); };
    like($@, qr/cannot resize SD card.*shut down/, 'live SD resize is rejected');
    is_deeply(\@calls, [], 'live SD resize leaves storage untouched');
}

done_testing();
