#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
use Test::MockModule;

use PVE::JSONSchema;
use PVE::QemuConfig;
use PVE::QemuMigrate::Helpers;
use PVE::QemuServer;
use PVE::QemuServer::Drive qw(is_valid_drivename parse_drive print_drive);
use PVE::QemuServer::DriveDevice qw(print_drivedevice_full);
use PVE::QemuServer::PCI;
use PVE::QemuServer::USB;

my $cluster_config = Test::MockModule->new('PVE::Cluster');
$cluster_config->mock(cfs_read_file => sub { return {}; });

my $volume = 'local:8006/vm-8006-disk-0.raw';
my $value = "$volume,discard=on,removable=0,ro=1,serial=custom%2Cserial";

for my $arch ('x86_64', 'aarch64') {
    my $conf = { template => 1, usbdisk0 => undef, nvme0 => undef, emmc0 => undef };
    my @controllers = PVE::QemuServer::USB::get_usb_controllers($conf, $arch, '9.2');
    ok(
        !grep(/id=usbdisk-xhci,/, @controllers),
        "undefined template disks do not create a USB storage controller ($arch)",
    );
    $conf->{usbdisk0} = $volume;
    @controllers = PVE::QemuServer::USB::get_usb_controllers($conf, $arch, '9.2');
    is(
        scalar(grep(/id=usbdisk-xhci,/, @controllers)),
        1,
        "configured template USB disk keeps its storage controller ($arch)",
    );

    for my $q35 ($arch eq 'x86_64' ? (0, 1) : (0)) {
        my $bridges = PVE::QemuServer::PCI::get_pci_bridges(
            { nvme0 => undef, usbdisk0 => undef, emmc0 => undef },
            $arch,
            $q35,
            0,
            sub { return 0; },
        );
        ok(
            !grep(/id=pci\.4,/, @$bridges),
            "undefined template disks do not require bridge 4 ($arch, q35=$q35)",
        );
        for my $id ('nvme0', 'usbdisk0', 'emmc0') {
            $bridges = PVE::QemuServer::PCI::get_pci_bridges(
                { $id => $volume },
                $arch,
                $q35,
                0,
                sub { return 0; },
            );
            ok(
                scalar(grep(/id=pci\.4,/, @$bridges)),
                "configured $id requires bridge 4 ($arch, q35=$q35)",
            );
        }
    }
}

ok(is_valid_drivename('usbdisk0'), 'first USB disk is valid');
ok(is_valid_drivename('usbdisk7'), 'last USB disk is valid');
ok(!is_valid_drivename('usbdisk8'), 'USB disk limit is enforced');
ok(!is_valid_drivename('usbdisk01'), 'USB disk indices must be canonical');
ok(!is_valid_drivename('usb0'), 'USB passthrough is not a virtual disk');
is(PVE::QemuServer::Drive::verify_bootdisk('usbdisk0'), 'usbdisk0', 'USB boot disk is valid');

my $drive = parse_drive('usbdisk0', $value);
ok($drive, 'parse USB storage options');
is(print_drive($drive), $value, 'USB options survive printing, including zero values');
my $allocation = parse_drive('usbdisk0', 'local:1,import-from=/tmp/disk.raw,removable=0', 1);
ok($allocation, 'USB supports disk allocation and import');
is(
    print_drive($allocation, 1),
    'local:1,import-from=/tmp/disk.raw,removable=0',
    'allocation options survive printing',
);

for my $with_alloc (0, 1) {
    my $schema = {
        type => 'object',
        additionalProperties => 0,
        properties => PVE::QemuServer::json_config_properties({}, $with_alloc),
    };
    my $disk_value = $with_alloc ? 'local:1,import-from=/tmp/disk.raw' : $value;
    eval {
        PVE::JSONSchema::validate(
            { bootdisk => 'usbdisk0', usbdisk0 => $disk_value, usb0 => 'host=1234:5678' },
            $schema,
        );
    };
    is($@, '', "USB storage and passthrough pass API validation (allocation=$with_alloc)");
}

for my $options ('media=cdrom', 'iothread=1', 'ssd=1', 'queues=2', 'max_ioqpairs=4') {
    ok(!parse_drive('usbdisk0', "$volume,$options"), "reject unsupported USB options: $options");
}
for my $file ('none', 'cdrom', 'local:vm-8006-cloudinit') {
    ok(!parse_drive('usbdisk0', $file), "USB storage requires a backing disk: $file");
}

my $raw = "boot: order=usbdisk0\nbootdisk: usbdisk0\nusbdisk0: $value\nusb0: host=1234:5678\n\n"
    . "[PENDING]\nusbdisk7: $volume\n\n[snapshot]\nusbdisk0: $value\nsnaptime: 1\n";
my $filename = '/etc/pve/qemu-server/8006.conf';
my $config = PVE::QemuServer::parse_vm_config($filename, $raw, 1);
my $written = PVE::QemuServer::write_vm_config($filename, $config);
my $roundtrip = PVE::QemuServer::parse_vm_config($filename, $written, 1);
is($roundtrip->{usbdisk0}, $value, 'USB configuration survives a strict round trip');
is($roundtrip->{usb0}, 'host=1234:5678', 'USB passthrough configuration is preserved');
is($roundtrip->{pending}->{usbdisk7}, $volume, 'pending USB disk survives a round trip');
is($roundtrip->{snapshots}->{snapshot}->{usbdisk0}, $value, 'USB snapshot survives a round trip');
my @volumes;
PVE::QemuConfig->foreach_volume($config, sub { push @volumes, $_[0]; });
is_deeply(\@volumes, ['usbdisk0'], 'backup and volume operations include USB disks');
is_deeply(
    PVE::QemuServer::Drive::get_bootdisks($config),
    ['usbdisk0'],
    'USB boot order is detected',
);

my $restored = 'target:8006/vm-8006-disk-0.qcow2';
is(
    PVE::QemuServer::restore_update_config_line(
        {},
        { usbdisk0 => $restored },
        "usbdisk0: $value,format=raw\n",
        0,
    ),
    "usbdisk0: $restored,discard=on,removable=0,ro=1,serial=custom%2Cserial\n",
    'restore remaps USB volumes and preserves device options',
);
is(
    PVE::QemuServer::restore_update_config_line(
        {}, {}, "usbdisk0: $volume,backup=0\n", 0,
    ),
    "#usbdisk0: $volume,backup=0\n",
    'restore comments out USB disks excluded from backup',
);

{
    my $cluster = Test::MockModule->new('PVE::Cluster');
    $cluster->mock(get_nodelist => sub { return ['localhost']; });
    my @mappings = map { Test::MockModule->new("PVE::Mapping::$_") } qw(Dir PCI USB);
    $_->mock(config => sub { return { ids => {} }; }) for @mappings;
    for my $state (0, 1) {
        my $conf = { usbdisk0 => $value };
        is_deeply(
            scalar(PVE::QemuMigrate::Helpers::check_local_resources($conf, $state, 1)),
            [],
            "USB storage is migratable and not host USB (state=$state)",
        );
        $conf->{usb0} = 'host=1234:5678';
        is_deeply(
            scalar(PVE::QemuMigrate::Helpers::check_local_resources($conf, $state, 1)),
            ['usb0'],
            "USB passthrough remains a local resource (state=$state)",
        );
    }
}

my $qdev_path = '/machine/peripheral/usbdisk0/usbdisk0.0/legacy[0]';
is(
    PVE::QemuServer::Blockdev::qdev_id_to_drive_id($qdev_path),
    'usbdisk0',
    'map the nested QEMU USB block device to its configuration key',
);
{
    my $monitor = Test::MockModule->new('PVE::QemuServer::Blockdev');
    $monitor->mock(
        mon_cmd => sub {
            return [{ qdev => $qdev_path, inserted => { 'node-name' => 'drive-usbdisk0' } }];
        },
    );
    ok(
        PVE::QemuServer::Blockdev::get_block_info(8006)->{usbdisk0},
        'block operations find USB storage',
    );
}

{
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    $qemu->mock(
        mon_cmd => sub {
            my (undef, $cmd) = @_;
            return [{ qdev => $qdev_path }] if $cmd eq 'query-block';
            return [{ name => 'usbdisk1' }, { name => 'usb0' }, { name => 'usbredirdev1' }]
                if $cmd eq 'qom-list';
            return [] if $cmd eq 'query-pci' || $cmd eq 'query-mice';
            die "unexpected monitor command: $cmd\n";
        },
    );
    is_deeply(
        PVE::QemuServer::vm_devices_list(8006),
        { usbdisk0 => 1, usbdisk1 => 1, usb0 => 1, usbredirdev1 => 1 },
        'device enumeration finds USB storage with and without inserted media, passthrough and SPICE',
    );
}

for my $machine ('pc-i440fx-9.2', 'pc-i440fx-11.1') {
    my $default =
        print_drivedevice_full({}, {}, 8006, parse_drive('usbdisk0', $volume), 'x86_64', $machine);
    like(
        $default,
        qr/^usb-storage,id=usbdisk0,drive=drive-usbdisk0,bus=usbdisk-xhci\.0,port=1,removable=on,serial=usbdisk0/,
        "default USB device on $machine",
    );
    my $custom = print_drivedevice_full({}, {}, 8006, $drive, 'x86_64', $machine);
    like(
        $custom,
        qr/removable=off,serial=custom,,serial/,
        "custom USB options and escaped serial on $machine",
    );
    for my $serial ('0', '%30') {
        like(
            print_drivedevice_full(
                {},
                {},
                8006,
                parse_drive('usbdisk0', "$volume,serial=$serial"),
                'x86_64',
                $machine,
            ),
            qr/(?:^|,)serial=0(?:,|$)/,
            "USB preserves a zero serial on $machine: $serial",
        );
    }
}

{
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    my $devices = {};
    $qemu->mock(vm_devices_list => sub { return $devices; });
    my @calls;
    $qemu->mock(vm_deviceplug => sub { push @calls, 'plug'; });
    $qemu->mock(vm_deviceunplug => sub { push @calls, 'unplug'; });
    $qemu->mock(vmconfig_register_unused_drive => sub { push @calls, 'unused'; });
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(activate_volumes => sub { push @calls, 'activate'; });
    my $update = sub {
        my ($conf, $value, $hotplug) = @_;
        PVE::QemuServer::vmconfig_update_disk(
            {},
            $conf,
            $hotplug // 1,
            8006,
            'usbdisk0',
            $value,
            'x86_64',
            'pc-i440fx-11.1',
        );
    };
    eval { $update->({}, $volume); };
    is($@, "skip\n", 'first USB disk stays pending until its controller is available');
    is_deeply(\@calls, [], 'missing controller has no storage or device side effects');
    $devices->{'usbdisk-xhci'} = 1;
    eval { $update->({}, $volume, 0); };
    is($@, "skip\n", 'USB disk hotplug respects the disk hotplug setting');
    is_deeply(\@calls, [], 'disabled hotplug has no side effects');
    eval { $update->({}, $volume); };
    is($@, '', 'USB disk can be hotplugged with an existing controller');
    is_deeply(
        \@calls,
        ['activate', 'plug'],
        'hotplug activates the backing volume before adding the device',
    );
    @calls = ();
    eval { $update->({ usbdisk0 => $volume }, 'local:8006/vm-8006-disk-1.raw'); };
    is($@, '', 'USB disk replacement can be hotplugged');
    is_deeply(
        \@calls,
        ['unplug', 'unused', 'activate', 'plug'],
        'replacement preserves the old backing volume',
    );
    @calls = ();

    for my $option ('serial=new', 'removable=0', 'ro=1', 'rerror=stop', 'werror=stop') {
        eval { $update->({ usbdisk0 => $volume }, "$volume,$option"); };
        is($@, "skip\n", "USB device property change remains pending: $option");
    }
    eval { $update->({ usbdisk0 => $volume }, "$volume,backup=0"); };
    is($@, '', 'USB backup metadata can change while running');
    is_deeply(\@calls, [], 'metadata and pending properties do not replug the device');

    my $config_mock = Test::MockModule->new('PVE::QemuConfig');
    $config_mock->mock(write_config => sub { });
    my $cgroup = Test::MockModule->new('PVE::QemuServer::CGroup');
    $cgroup->mock(new => sub { return bless {}, 'PVE::QemuServer::CGroup'; });
    $qemu->mock(vmconfig_delete_or_detach_drive => sub { push @calls, 'detach'; });
    my $pending_delete = { usbdisk0 => $volume, pending => { delete => 'usbdisk0' } };
    my $errors = {};
    PVE::QemuServer::vmconfig_hotplug_pending(8006, $pending_delete, {}, undef, $errors);
    is_deeply($errors, {}, 'pending USB removal does not cause a hotplug error');
    is_deeply(\@calls, ['unplug', 'detach'], 'pending USB removal unplugs and detaches the volume');
    ok(!exists($pending_delete->{usbdisk0}),
        'hot-unplug removes the active USB disk configuration');
    ok(!$pending_delete->{pending}->{delete}, 'completed USB removal clears its pending entry');
}

{
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    my @calls;
    $qemu->mock(vm_devices_list => sub { return { 'usbdisk-xhci' => 1 }; });
    $qemu->mock(qemu_driveadd => sub { push @calls, 'backend-add'; });
    $qemu->mock(qemu_deviceadd => sub { push @calls, 'device-add'; });
    my $added = 1;
    $qemu->mock(
        qemu_deviceaddverify => sub {
            push @calls, 'verify-add';
            die "USB device was not added\n" if !$added;
        },
    );
    $qemu->mock(qemu_findorcreatescsihw => sub { die "unexpected SCSI controller\n"; });
    PVE::QemuServer::vm_deviceplug({}, {}, 8006, 'usbdisk0', $drive, 'x86_64', 'pc-i440fx-11.1');
    is_deeply(
        \@calls,
        ['backend-add', 'device-add', 'verify-add'],
        'USB plug adds a block backend and confirms the USB frontend',
    );
    @calls = ();
    $qemu->mock(qemu_deviceadd => sub { die "device-add failed\n"; });
    $qemu->mock(qemu_drivedel => sub { push @calls, 'backend-delete'; });
    eval {
        PVE::QemuServer::vm_deviceplug(
            {}, {}, 8006, 'usbdisk0', $drive, 'x86_64', 'pc-i440fx-11.1',
        );
    };
    is($@, "device-add failed\n", 'USB hotplug propagates a frontend error');
    is_deeply(
        \@calls,
        ['backend-add', 'backend-delete'],
        'failed hotplug cleans up its block backend',
    );
    @calls = ();
    $qemu->mock(qemu_deviceadd => sub { push @calls, 'device-add'; });
    $added = 0;
    eval {
        PVE::QemuServer::vm_deviceplug(
            {}, {}, 8006, 'usbdisk0', $drive, 'x86_64', 'pc-i440fx-11.1',
        );
    };
    is($@, "USB device was not added\n", 'USB realization failure reaches the caller');
    is_deeply(
        \@calls,
        ['backend-add', 'device-add', 'verify-add', 'backend-delete'],
        'USB realization failure cleans up its block backend',
    );
    @calls = ();
    $qemu->mock(vm_devices_list => sub { return { usbdisk0 => 1, 'usbdisk-xhci' => 1 }; });
    $qemu->mock(qemu_devicedel => sub { push @calls, 'device-delete'; });
    $qemu->mock(qemu_devicedelverify => sub { push @calls, 'verify-delete'; });
    $qemu->mock(qemu_deletescsihw => sub { die "unexpected SCSI controller removal\n"; });
    PVE::QemuServer::vm_deviceunplug(8006, { usbdisk0 => $volume }, 'usbdisk0');
    is_deeply(
        \@calls,
        ['device-delete', 'verify-delete', 'backend-delete'],
        'USB unplug removes the frontend before its block backend',
    );
    @calls = ();
    eval { PVE::QemuServer::vm_deviceunplug(8006, $config, 'usbdisk0'); };
    like($@, qr/can't unplug bootdisk 'usbdisk0'/, 'USB boot disks cannot be hot-unplugged');
    is_deeply(\@calls, [], 'boot disk protection runs before removing the device');
}

{
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    my $running = 1;
    $helpers->mock(vm_running_locally => sub { return $running; });
    my $storage = Test::MockModule->new('PVE::Storage');
    my @calls;
    $storage->mock(volume_resize => sub { push @calls, ['storage', @_]; });
    my $blockdev = Test::MockModule->new('PVE::QemuServer::Blockdev');
    $blockdev->mock(
        mon_cmd => sub {
            my ($vmid, $cmd) = @_;
            return [{ qdev => $qdev_path, inserted => { 'node-name' => 'drive-usbdisk0' } }]
                if $cmd eq 'query-block';
            push @calls, ['monitor', @_];
        },
    );
    my $size = 2 * 1024**3;
    PVE::QemuServer::Blockdev::resize(8006, 'drive-usbdisk0', {}, $volume, $size);
    is_deeply(
        \@calls,
        [
            ['storage', {}, $volume, $size, 1],
            [
                'monitor', 8006, 'block_resize',
                'node-name' => 'drive-usbdisk0',
                size => $size,
                timeout => 60,
            ],
        ],
        'online USB resize updates the backing volume and the correct block node',
    );
    @calls = ();
    $running = 0;
    PVE::QemuServer::Blockdev::resize(8006, 'drive-usbdisk0', {}, $volume, $size);
    is_deeply(
        \@calls,
        [['storage', {}, $volume, $size, 0]],
        'offline USB resize only updates storage',
    );
}

done_testing();
