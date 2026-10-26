#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use JSON qw(to_json);
use Test::More;
use Test::MockModule;
use URI::Escape qw(uri_unescape);

use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Drive qw(parse_drive);
use PVE::QemuServer::Machine;
use PVE::API2::Qemu::Machine;

my $type = 'azw-me-pro-6';
my $conf = { machine => $type };
my $volume = 'local:8006/vm-8006-disk-0.raw';
my $schema = {
    type => 'object',
    additionalProperties => 0,
    properties => PVE::QemuServer::json_config_properties({}, 0),
};

for my $machine ($type, "$type+pve0", "$type,viommu=intel,aw-bits=48") {
    eval { PVE::JSONSchema::validate({ machine => $machine }, $schema); };
    is($@, '', "API accepts custom machine $machine");
}
for my $machine ('azw-me-pro', "$type+pve1", 'azw-unknown', "${type}suffix") {
    eval { PVE::JSONSchema::validate({ machine => $machine }, $schema); };
    like($@, qr/invalid format/, "API rejects unregistered machine $machine");
}

ok(PVE::QemuServer::Machine::machine_type_is_custom($conf), 'custom machine is recognized');
ok(PVE::QemuServer::Machine::machine_type_is_q35($conf), 'custom platform inherits Q35 behavior');
ok(PVE::QemuServer::Machine::machine_supports_flag($type, 'hpet'), 'custom platform supports HPET');
is(PVE::QemuServer::Machine::extract_version($type, '11.1.1'), '11.0', 'base version stays pinned');
is(
    PVE::QemuServer::Machine::extract_version("$type+pve0", '12.0'),
    '11.0',
    'explicit revision stays pinned',
);
is(PVE::QemuServer::Machine::get_vm_machine($conf), "$type+pve0", 'command uses PVE revision zero');
is(
    PVE::QemuServer::Machine::check_and_pin_machine_string($type, 'win11', 'x86_64'),
    $type,
    'Windows pinning preserves custom model',
);
eval {
    PVE::QemuServer::Machine::assert_valid_machine_property({
        type => $type,
        viommu => 'intel',
    });
};
is($@, '', 'Intel IOMMU accepts the Q35 custom platform');
for my $operation (
    sub { PVE::QemuServer::Machine::get_vm_machine({ %$conf, arch => 'aarch64' }); },
    sub { PVE::QemuServer::Machine::check_and_pin_machine_string($type, 'l26', 'aarch64'); },
) {
    eval { $operation->(); };
    like($@, qr/only supported on x86_64/, 'reject custom machine on ARM');
}
is_deeply(
    PVE::QemuServer::Machine::get_power_state_flags(
        { type => $type, 'enable-s3' => 0, 'enable-s4' => 0 },
        'x86_64',
        sub { return 1; },
    ),
    ['-global', 'ICH9-LPC.disable_s3=1', '-global', 'ICH9-LPC.disable_s4=1'],
    'power flags address the Q35 LPC',
);

my $filename = '/etc/pve/qemu-server/8006.conf';
my $raw = "machine: $type,viommu=intel\n\n[PENDING]\nmachine: $type+pve0\n\n"
    . "[snapshot]\nmachine: $type\nsnaptime: 1\n";
my $parsed = PVE::QemuServer::parse_vm_config($filename, $raw, 1);
my $roundtrip = PVE::QemuServer::parse_vm_config(
    $filename, PVE::QemuServer::write_vm_config($filename, $parsed), 1,
);
is($roundtrip->{machine}, "$type,viommu=intel", 'custom machine survives configuration round trip');
is($roundtrip->{pending}->{machine}, "$type+pve0", 'pending machine survives round trip');
is($roundtrip->{snapshots}->{snapshot}->{machine}, $type, 'snapshot machine survives round trip');

{
    my $tools = Test::MockModule->new('PVE::Tools');
    my $api = Test::MockModule->new('PVE::API2::Qemu::Machine');
    my $calls = 0;
    my $available = 1;
    $tools->mock(
        run_command => sub {
            my ($cmd, %opts) = @_;
            $calls++;
            is_deeply([@$cmd[1, 2]], ['-machine', 'help'], 'probe the installed emulator');
            $opts{outfunc}->('pc-q35-11.0 Standard PC');
            $opts{outfunc}->("$type AZW ME Pro-6") if $available;
        },
    );
    $api->mock(
        file_get_contents => sub {
            return to_json([
                { id => 'pc-q35-11.0', type => 'q35', version => '11.0' },
                { id => 'pc-i440fx-11.0', type => 'i440fx', version => '11.0' },
            ]);
        },
    );
    my $machines = PVE::API2::Qemu::Machine->types({ node => 'localhost', arch => 'x86_64' });
    is_deeply(
        [grep { $_->{type} eq 'custom' } @$machines],
        [{ id => $type, type => 'custom', version => 'azw-me-pro' }],
        'node capabilities include the installed custom machine',
    );
    ok(
        grep({ $_->{id} eq 'pc-q35-11.0+pve2' } @$machines),
        'ordinary machine revisions are preserved',
    );
    $available = 0;
    is_deeply(
        PVE::QemuServer::Machine::installed_custom_machines('x86_64'),
        [],
        'stock QEMU exposes no custom machine',
    );
    my $before = $calls;
    is_deeply(
        PVE::QemuServer::Machine::installed_custom_machines('aarch64'),
        [],
        'ARM has no custom model',
    );
    is($calls, $before, 'ARM capabilities do not execute an x86 binary');
}

my @buses = ('pcie.00.1c.0', 'pcie.00.1c.6', 'pcie.00.1d.0');
for my $index (0 .. 2) {
    my $id = "nvme$index";
    my $disk = parse_drive($id, $volume);
    my $device = PVE::QemuServer::DriveDevice::print_drivedevice_full(
        {}, $conf, 8006, $disk, 'x86_64', $type,
    );
    like($device, qr/\Q,bus=$buses[$index],addr=0x0\E/, "$id uses its fixed PCIe port");
    unlike($device, qr/,serial=/, 'machine supplies the topology serial');
    $disk->{serial} = 'LAB%2C0';
    like(
        PVE::QemuServer::DriveDevice::print_drivedevice_full(
            {}, $conf, 8006, $disk, 'x86_64', $type,
        ),
        qr/,serial=LAB,,0/,
        'explicit serial remains escaped and preserved',
    );
}
eval { PVE::QemuServer::Machine::custom_nvme_pci_address($conf, 3); };
like(
    $@,
    qr/supports NVMe controllers nvme0 through nvme2/,
    'extra controllers cannot leave the fixed topology',
);
my $namespace_conf =
    { %$conf, nvme0 => "$volume,subsystem=1", nvme12 => "$volume,nvme-controller=0,nsid=12" };
my @controllers = PVE::QemuServer::NVMe::controller_devices($namespace_conf, 8006, 'x86_64', $type);
like(
    join(' ', @controllers),
    qr/id=nvme-ctrl-nvme0,.*bus=pcie\.00\.1c\.0/,
    'namespace controller uses fixed port',
);
unlike(
    join(' ', @controllers),
    qr/,serial=/,
    'explicit subsystem preserves automatic platform serial',
);
$namespace_conf->{nvme0} .= ',nvme-paths=2';
@controllers = PVE::QemuServer::NVMe::controller_devices($namespace_conf, 8006, 'x86_64', $type);
is(
    scalar(grep { /,serial=00:1c\.0-01:00\.0(?:,|$)/ } @controllers),
    2,
    'multipath controllers share the first path topology serial',
);
my $namespace = PVE::QemuServer::NVMe::namespace_device(
    $namespace_conf, 8006, parse_drive('nvme12', $namespace_conf->{nvme12}), 'x86_64',
);
like(
    $namespace,
    qr/bus=nvme-ctrl-nvme0,nsid=12/,
    'higher namespace index can share a fixed controller',
);

{
    my $cluster = Test::MockModule->new('PVE::Cluster');
    $cluster->mock(cfs_read_file => sub { return {}; });
    for my $survivor (1, 12) {
        for my $slot (0, 2) {
            for my $serial ('', ',serial=Custom') {
                my $id = "nvme$survivor";
                my $raw =
                    "machine: $type\nboot: order=$id\n"
                    . "#nvme0: $volume,backup=0,subsystem=1,nvme-paths=2,nvme-slot=$slot$serial\n"
                    . "$id: $volume,nvme-controller=0\n";
                my $restored = PVE::QemuServer::restore_merge_config($filename, $raw, {});
                ok(
                    exists($restored->{$id}) && !exists($restored->{nvme0}),
                    'partial restore keeps namespace disk and backup stream IDs',
                );
                is($restored->{boot}, "order=$id", 'partial restore keeps boot references');
                my $owner = parse_drive($id, $restored->{$id});
                is(
                    $owner->{'nvme-slot'},
                    $slot,
                    'partial restore retains the original physical slot',
                );
                is(
                    uri_unescape($owner->{serial}),
                    $serial ? 'Custom' : PVE::QemuServer::Machine::custom_nvme_serial($conf, $slot),
                    'partial restore preserves explicit or topology serial',
                );
                my @devices = PVE::QemuServer::NVMe::controller_devices(
                    $restored, 8006, 'x86_64', $type,
                );
                is(
                    scalar(grep { /\Q,bus=$buses[$slot],addr=0x0\E/ } @devices),
                    2,
                    'restored multipath controllers use the original slot',
                );
                unlike(
                    join(' ', @devices),
                    qr/,nvme-slot=/,
                    'placement is not a QEMU device property',
                );
                like(
                    PVE::QemuServer::NVMe::namespace_device($restored, 8006, $owner, 'x86_64'),
                    qr/,nsid=@{[$survivor + 1]},/,
                    'partial restore preserves the implicit namespace ID',
                );
                my $again = PVE::QemuServer::parse_vm_config(
                    $filename, PVE::QemuServer::write_vm_config($filename, $restored), 1,
                );
                is_deeply(
                    PVE::QemuServer::NVMe::topology($again),
                    PVE::QemuServer::NVMe::topology($restored),
                    'restored controller placement survives configuration round trip',
                );
            }
        }
    }
    my $restored = PVE::QemuServer::restore_merge_config(
        $filename,
        "machine: $type\n#nvme0: $volume,backup=0\nnvme12: $volume,nvme-controller=0\n",
        {},
    );
    is(
        parse_drive('nvme12', $restored->{nvme12})->{'nvme-slot'},
        0,
        'partial restore preserves an originally implicit slot',
    );
    my $second = PVE::QemuServer::restore_merge_config(
        $filename,
        "machine: $type\n#nvme12: $restored->{nvme12},backup=0\n"
            . "nvme13: $volume,nvme-controller=12\n",
        {},
    );
    is(
        parse_drive('nvme13', $second->{nvme13})->{'nvme-slot'},
        0,
        'a second partial restore retains the original physical slot',
    );
}

my $relocated = { %$conf, nvme12 => "$volume,nvme-slot=2" };
like(
    PVE::QemuServer::DriveDevice::print_drivedevice_full(
        {},
        $relocated,
        8006,
        parse_drive('nvme12', $relocated->{nvme12}),
        'x86_64',
        $type,
    ),
    qr/bus=pcie\.00\.1d\.0,addr=0x0/,
    'a dedicated controller honors an explicitly retained slot',
);
eval { PVE::QemuServer::NVMe::topology({ %$relocated, nvme2 => $volume }); };
like($@, qr/use the same custom machine slot 2/, 'duplicate physical slots are rejected');
eval {
    PVE::QemuServer::NVMe::topology({
        %$conf,
        nvme0 => "$volume,subsystem=1",
        nvme12 => "$volume,nvme-controller=0,nvme-slot=2",
    });
};
like($@, qr/configure controller options on nvme0: nvme-slot/,
    'children cannot override placement');

for my $case (
    [
        { machine => 'q35', nvme3 => $volume },
        { machine => $type },
        [],
        qr/supports NVMe controllers/,
    ],
    [
        { %$conf, nvme0 => $volume, pending => { nvme1 => "$volume,nvme-slot=0" } },
        {},
        [],
        qr/use the same custom machine slot 0/,
    ],
    [
        { %$conf, map { ("sata$_" => $volume) } 0 .. 5 },
        { ide2 => 'none,media=cdrom' },
        [],
        qr/only six shared SATA\/IDE ports/,
    ],
    [{ arch => 'aarch64' }, { machine => $type }, [], qr/only supported on x86_64/],
) {
    eval { PVE::QemuServer::NVMe::validate_update(@$case[0 .. 2]); };
    like($@, $case->[3], 'validate effective machine topology before saving');
}
eval {
    PVE::QemuServer::NVMe::validate_update(
        {
            %$conf,
            nvme0 => $volume,
            pending => { nvme1 => "$volume,nvme-slot=0", delete => 'nvme0' },
        },
        {},
        [],
    );
};
is($@, '', 'pending removals free controller slots');

for my $index (0 .. 5) {
    is(
        PVE::QemuServer::Machine::custom_sata_address($conf, "sata$index"),
        ',bus=asm' . int($index / 2) . '.' . ($index % 2) . ',unit=0',
        "sata$index names a physical port",
    );
}
my $sata_conf = {
    %$conf,
    sata0 => $volume,
    sata2 => $volume,
    ide0 => 'none,media=cdrom',
    ide2 => 'none,media=cdrom',
};
is(
    PVE::QemuServer::Machine::custom_sata_address($sata_conf, 'ide0'),
    ',bus=asm0.1,unit=0',
    'IDE skips SATA ports',
);
is(
    PVE::QemuServer::Machine::custom_sata_address($sata_conf, 'ide2'),
    ',bus=asm1.1,unit=0',
    'empty optical drives reserve ports',
);
eval {
    PVE::QemuServer::Machine::custom_sata_address(
        { %$conf, map { ("sata$_" => $volume) } 0 .. 5 }, 'ide2',
    );
};
like($@, qr/only six shared SATA\/IDE ports/, 'shared port limit is enforced');

my $usb_conf = { %$conf, usb0 => 'host=spice', usb13 => 'host=1234:5678' };
my @usb = PVE::QemuServer::USB::get_usb_controllers($usb_conf, 'x86_64', '11.0');
like(join(' ', @usb), qr/id=pve-xhci,/, 'host USB uses an extra controller');
unlike(join(' ', @usb), qr/id=xhci(?:,|$)/, 'built-in xHCI is not duplicated');
@usb = PVE::QemuServer::USB::get_usb_devices($usb_conf, {}, {}, '11.0');
like(
    join(' ', @usb),
    qr/usbredirdev0,bus=pve-xhci\.0,port=1/,
    'SPICE avoids the built-in read-only USB',
);
like(join(' ', @usb), qr/usb-host,bus=pve-xhci\.0,port=14/,
    'host USB uses the last supported port');
is(
    PVE::QemuServer::print_tabletdevice_full($conf, 'x86_64'),
    'usb-tablet,id=tablet,bus=xhci.0,port=2',
    'tablet leaves platform USB port one free',
);

{
    my $server = Test::MockModule->new('PVE::QemuServer');
    my @added;
    my @unplugged;
    my $devices = { xhci => 1 };
    $server->mock(vm_devices_list => sub { return $devices; });
    $server->mock(assert_pci_bridge_present => sub { return; });
    $server->mock(vm_deviceunplug => sub { push @unplugged, $_[2]; });
    $server->mock(qemu_deviceadd => sub { push @added, $_[1]; });
    $server->mock(qemu_spice_usbredir_chardev_add => sub { return; });
    PVE::QemuServer::qemu_usb_hotplug(
        {},
        $conf,
        8006,
        'usb13',
        { host => '1234:5678' },
        'x86_64',
        $type,
    );
    like(
        $added[0],
        qr/id=pve-xhci,/,
        'first hotplug creates the host USB controller even with built-in xHCI',
    );
    like($added[1], qr/bus=pve-xhci\.0,port=14/, 'hotplug uses the same controller as cold start');
    @added = ();
    $devices->{'pve-xhci'} = 1;
    PVE::QemuServer::vm_deviceplug({}, $conf, 8006, 'usbredirdev0', {}, 'x86_64', $type);
    like($added[0], qr/bus=pve-xhci\.0,port=1/, 'SPICE hotplug uses the separate controller');
    delete $devices->{'pve-xhci'};
    $server->mock(qemu_deviceadd => sub { die "injected failure\n" if $_[1] =~ /^usb-host/; });
    eval {
        PVE::QemuServer::qemu_usb_hotplug(
            {},
            $conf,
            8006,
            'usb0',
            { host => '1234:5678' },
            'x86_64',
            $type,
        );
    };
    like($@, qr/injected failure/, 'hotplug error propagates');
    is($unplugged[-1], 'pve-xhci', 'failed hotplug cleans up only the PVE controller');
    ok(!grep({ $_ eq 'xhci' } @unplugged), 'platform controller is never unplugged');
}

done_testing();
