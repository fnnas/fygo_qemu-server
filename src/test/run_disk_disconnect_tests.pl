use strict;
use warnings;

use File::Temp qw(tempfile);
use PVE::QemuServer;
use PVE::QemuServer::Blockdev;
use PVE::QemuServer::Drive qw(parse_drive print_drive);
use Test::MockModule;
use Test::More;

my ($volume_fh, $volume) = tempfile(SUFFIX => '.raw', UNLINK => 1);
my ($other_fh, $other_volume) = tempfile(SUFFIX => '.raw', UNLINK => 1);
truncate($volume_fh, 1024 * 1024) or die "unable to prepare test disk: $!\n";
truncate($other_fh, 1024 * 1024) or die "unable to prepare test disk: $!\n";
my $vmid = 8006;
my $machine = 'pc-q35-11.0';
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });

for my $key (qw(scsi0 virtio0 usbdisk0 sata0 ide0 nvme0 emmc0 sdcard0)) {
    my $drive = parse_drive($key, "$volume,disconnected=1");
    ok($drive->{disconnected}, "$key accepts the disk connection flag");
    like(print_drive($drive), qr/disconnected=1/, "$key preserves the disk connection flag");
}
ok(!parse_drive('ide2', 'none,media=cdrom,disconnected=1'), 'CD-ROMs keep their eject semantics');

my $conf = {
    arch => 'x86_64',
    machine => $machine,
    kvm => 0,
    memory => 128,
    vga => 'none',
    scsi0 => "$volume,disconnected=1",
    virtio0 => $other_volume,
    boot => 'order=scsi0;virtio0',
};
is_deeply(
    PVE::QemuServer::get_default_bootdevices($conf),
    ['virtio0'],
    'skip disconnected disks in default boot order',
);
is_deeply(
    PVE::QemuServer::device_bootorder($conf),
    { virtio0 => 100 },
    'skip disconnected disks in explicit boot order',
);

for my $version ($machine, 'pc-q35-9.2') {
    my $cmd = PVE::QemuServer::config_to_command(
        {},
        $vmid,
        { %$conf, machine => $version },
        PVE::QemuServer::load_defaults(),
        { 'dry-run' => 1 },
    );
    my @backends;
    my @devices;
    for my $i (0 .. $#$cmd - 1) {
        push @backends, $cmd->[$i + 1] if $cmd->[$i] eq '-blockdev' || $cmd->[$i] eq '-drive';
        push @devices, $cmd->[$i + 1] if $cmd->[$i] eq '-device';
    }
    ok(grep(/drive-scsi0/, @backends), "disconnected disk keeps its block graph ($version)");
    ok(!grep(/(?:^|,)id=scsi0(?:,|$)/, @devices), "disconnected disk has no frontend ($version)");
    ok(grep(/(?:^|,)id=virtio0(?:,|$)/, @devices), "other disk still connected ($version)");
}

my $qemu = Test::MockModule->new('PVE::QemuServer');
my $blockdev = Test::MockModule->new('PVE::QemuServer::Blockdev');
my @calls;
$blockdev->mock(get_named_node => sub { return { 'node-name' => $_[1] }; });
$qemu->mock(vm_deviceplug => sub { push @calls, ['plug', $_[3], $_[7]]; });
$qemu->mock(vm_deviceunplug => sub { push @calls, ['unplug', $_[2], $_[3]]; });
$qemu->mock(qemu_drivedel => sub { die "must keep the block backend\n"; });
$qemu->mock(vmconfig_register_unused_drive => sub { die "must keep the drive configuration\n"; });

for my $key (qw(scsi0 virtio0 usbdisk0)) {
    @calls = ();
    my $connected = { $key => $volume };
    my $disconnected = { $key => "$volume,disconnected=1" };
    PVE::QemuServer::vmconfig_update_disk(
        {}, $connected, 1, $vmid, $key, $disconnected->{$key}, 'x86_64', $machine,
    );
    PVE::QemuServer::vmconfig_update_disk(
        {}, $disconnected, 1, $vmid, $key, $connected->{$key}, 'x86_64', $machine,
    );
    is_deeply(\@calls, [['unplug', $key, 1], ['plug', $key, 1]], "$key toggles only the frontend");
}

for my $case (
    ['scsi0', 'discard=ignore,ssd=0,iothread=0,ro=0'],
    ['virtio0', 'discard=ignore,iothread=0,ro=0'],
    ['usbdisk0', 'discard=ignore,removable=1,ro=0'],
) {
    my ($key, $defaults) = @$case;
    @calls = ();
    my $connected = "$volume,$defaults";
    my $disconnected = "$volume,disconnected=1";
    PVE::QemuServer::vmconfig_update_disk(
        {}, { $key => $connected }, 1, $vmid, $key, $disconnected, 'x86_64', $machine,
    );
    PVE::QemuServer::vmconfig_update_disk(
        {}, { $key => $disconnected }, 1, $vmid, $key, $connected, 'x86_64', $machine,
    );
    is_deeply(
        \@calls,
        [['unplug', $key, 1], ['plug', $key, 1]],
        "$key toggles when one config omits defaults",
    );
}

{
    my @monitor_calls;
    $qemu->unmock('vm_deviceunplug');
    $qemu->mock(vm_devices_list => sub { return { virtio0 => 1 }; });
    $qemu->mock(mon_cmd => sub { push @monitor_calls, [@_[1 .. $#_]]; });
    $qemu->mock(qemu_devicedelverify => sub { push @monitor_calls, ['verify absent', @_[1, 2]]; });
    PVE::QemuServer::vm_deviceunplug($vmid, { virtio0 => $volume }, 'virtio0', 1);
    is_deeply(
        \@monitor_calls,
        [['device_del', 'id', 'virtio0'], ['verify absent', 'virtio0', 15]],
        'VirtIO disconnect waits for PCI slot power-off without deleting the block node',
    );
    $qemu->unmock(qw(vm_devices_list mon_cmd qemu_devicedelverify));
    $qemu->mock(vm_deviceunplug => sub { push @calls, ['unplug', $_[2], $_[3]]; });
}

{
    my $disk = "$volume,nvme-dock=tbdock0,serial=DOCKDISK";
    my $present = {
        arch => 'x86_64',
        machine => $machine,
        kvm => 0,
        memory => 128,
        vga => 'none',
        thunderbolt0 => 'tb3-titan-ridge',
        tbdock0 => 'host=thunderbolt0,port=1',
        nvme0 => $disk,
    };
    my $disconnected = { %$present, nvme0 => "$disk,disconnected=1" };
    my $cmd = PVE::QemuServer::config_to_command(
        {}, $vmid, $disconnected, PVE::QemuServer::load_defaults(), { 'dry-run' => 1 },
    );
    ok(
        grep(/id=tbdock0,.*drive=drive-nvme0,x-dock-nvme-hotplug=on,x-nvme-disconnected=on/, @$cmd),
        'a dock with a disconnected disk remembers its backend when starting',
    );
    my $supported = 1;
    my $backend = 'drive-nvme0';
    my @changes;
    $qemu->mock(
        mon_cmd => sub {
            my (undef, $command, %opts) = @_;
            is($opts{path}, '/machine/peripheral/tbdock0', 'operate on the selected dock');
            if ($command eq 'qom-get') {
                return $supported if $opts{property} eq 'x-dock-nvme-hotplug';
                return $backend if $opts{property} eq 'drive';
            }
            if ($command eq 'qom-set') {
                push @changes, [$opts{property}, !!$opts{value}];
                return;
            }
            die "unexpected QMP command '$command'\n";
        },
    );
    $qemu->mock(qemu_devicedelverify => sub { push @calls, ['verify absent', $_[1]]; });
    $qemu->mock(qemu_deviceaddverify => sub { push @calls, ['verify attached', $_[1]]; });
    @calls = ();
    PVE::QemuServer::vmconfig_update_disk(
        {}, $present, 1, $vmid, 'nvme0', $disconnected->{nvme0}, 'x86_64', $machine,
    );
    PVE::QemuServer::vmconfig_update_disk(
        {}, $disconnected, 1, $vmid, 'nvme0', $disk, 'x86_64', $machine,
    );
    is_deeply(
        \@changes,
        [['x-nvme-disconnected', 1], ['x-nvme-disconnected', '']],
        'built-in NVMe changes only the namespace connection on the dock',
    );
    is_deeply(
        \@calls,
        [['verify absent', 'nvme0'], ['verify attached', 'nvme0']],
        'verify namespace rather than dock removal',
    );

    @changes = ();
    for my $case ([0, $backend, 'older process'], [1, 'drive-nvme1', 'different disk']) {
        ($supported, $backend, my $reason) = @$case;
        eval {
            PVE::QemuServer::vmconfig_update_disk(
                {}, $present, 1, $vmid, 'nvme0', $disconnected->{nvme0}, 'x86_64', $machine,
            );
        };
        is($@, "skip\n", "connection change remains pending ($reason)");
    }
    is_deeply(\@changes, [], 'no monitor mutation if the live disk cannot be targeted');
    $qemu->unmock(qw(mon_cmd qemu_devicedelverify qemu_deviceaddverify));
}

@calls = ();
for my $case (
    [0, $machine, 'scsi0', {}, 'hotplug disabled'],
    [1, 'pc-q35-9.2', 'virtio0', {}, 'legacy drive backend'],
    [1, $machine, 'sata0', {}, 'cold-only bus'],
    [1, $machine, 'scsi0', { boot => 'order=scsi0' }, 'active boot drive'],
    [1, $machine, 'scsi0', {}, 'simultaneous backend change', ',cache=writeback'],
    [1, $machine, 'scsi0', {}, 'simultaneous discard change', ',discard=on'],
    [1, $machine, 'usbdisk0', {}, 'simultaneous USB media change', ',removable=0'],
) {
    my ($hotplug, $version, $key, $extra, $reason, $options) = @$case;
    eval {
        PVE::QemuServer::vmconfig_update_disk(
            {},
            { %$extra, $key => $volume },
            $hotplug,
            $vmid,
            $key,
            "$volume,disconnected=1" . ($options // ''),
            'x86_64',
            $version,
        );
    };
    is($@, "skip\n", "connection change stays pending ($reason)");
}
is_deeply(\@calls, [], 'pending changes do not unplug or replace any drive');

my @storage_updates;
my $storage = Test::MockModule->new('PVE::Storage');
$storage->mock(volume_resize => sub { push @storage_updates, 'resize'; });
my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
$helpers->mock(vm_running_locally => sub { 1 });
$blockdev->mock(
    mon_cmd => sub {
        my (undef, $cmd) = @_;
        return [] if $cmd eq 'query-block';
        return if $cmd eq 'block_resize';
        die "unexpected QMP command '$cmd'\n";
    },
);
$blockdev->mock(
    get_named_node => sub {
        return {
            'node-name' => 'drive-scsi0',
            drv => 'throttle',
            children => [{ child => 'file', 'node-name' => 'format-node' }],
        };
    },
);
is(
    PVE::QemuServer::Blockdev::get_node_name_below_throttle(
        { type => 'qmp', id => $vmid },
        'drive-scsi0',
        1,
    ),
    'format-node',
    'block operations find the retained named node without a frontend',
);
PVE::QemuServer::Blockdev::resize($vmid, 'drive-scsi0', {}, $volume, 2 * 1024 * 1024, 1);
is_deeply(\@storage_updates, ['resize'], 'resize of the disconnected disk keeps its live node');

$blockdev->mock(get_named_node => sub { return; });
eval { PVE::QemuServer::Blockdev::resize($vmid, 'drive-scsi0', {}, $volume, 2 * 1024 * 1024, 1); };
like($@, qr/cannot resize disconnected disk/, 'missing node is rejected before resizing');
is_deeply(\@storage_updates, ['resize'], 'failed lookup does not change the backing volume');

done_testing();
