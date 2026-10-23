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

my $volume = 'local:8006/vm-8006-disk-0.raw';
my $value = "$volume,max_ioqpairs=4,mdts=9,msix_qsize=5,serial=custom%2Cserial,use-intel-id=0";

ok(is_valid_drivename('nvme0'), 'first NVMe disk is valid');
ok(is_valid_drivename('nvme15'), 'last NVMe disk is valid');
ok(!is_valid_drivename('nvme16'), 'NVMe disk limit is enforced');
ok(!is_valid_drivename('nvme01'), 'NVMe indices must be canonical');
is(PVE::QemuServer::Drive::verify_bootdisk('nvme0'), 'nvme0', 'NVMe boot disk is valid');

my $drive = parse_drive('nvme0', $value);
ok($drive, 'parse NVMe controller options');
is(print_drive($drive), $value, 'controller options survive printing, including zero values');

my $allocation = parse_drive('nvme0', 'local:1,import-from=/tmp/disk.raw,mdts=9', 1);
ok($allocation, 'NVMe supports disk allocation and import');
is(
    print_drive($allocation, 1),
    'local:1,import-from=/tmp/disk.raw,mdts=9',
    'allocation options survive printing',
);

for my $with_alloc (0, 1) {
    my $schema = {
        type => 'object',
        additionalProperties => 0,
        properties => PVE::QemuServer::json_config_properties({}, $with_alloc),
    };
    my $disk_value = $with_alloc ? 'local:1,import-from=/tmp/disk.raw,mdts=9' : $value;
    eval { PVE::JSONSchema::validate({ bootdisk => 'nvme0', nvme0 => $disk_value }, $schema); };
    is($@, '', "NVMe disk and boot disk pass API validation (allocation=$with_alloc)");
}

for my $options (
    'max_ioqpairs=0', 'max_ioqpairs=65536',
    'msix_qsize=0', 'msix_qsize=2049',
    'mdts=-1', 'mdts=0', 'mdts=10', 'mdts=256',
    'media=cdrom', 'iothread=1', 'rerror=stop', 'werror=stop',
) {
    ok(!parse_drive('nvme0', "$volume,$options"), "reject unsupported NVMe options: $options");
}
ok(!parse_drive('nvme0', 'none'), 'NVMe requires a backing disk');
ok(!parse_drive('nvme0', 'local:vm-8006-cloudinit'), 'NVMe cannot be used as a cloud-init CD-ROM');

my $raw = "boot: order=nvme0\nbootdisk: nvme0\nnvme0: $value\n\n"
    . "[PENDING]\nnvme15: $volume\n\n[snapshot]\nnvme0: $value\nsnaptime: 1\n";
my $filename = '/etc/pve/qemu-server/8006.conf';
my $config = PVE::QemuServer::parse_vm_config($filename, $raw, 1);
my $written = PVE::QemuServer::write_vm_config($filename, $config);
my $roundtrip = PVE::QemuServer::parse_vm_config($filename, $written, 1);
is($roundtrip->{nvme0}, $value, 'NVMe configuration survives a strict round trip');
is($roundtrip->{pending}->{nvme15}, $volume, 'pending NVMe disk survives a round trip');
is(
    $roundtrip->{snapshots}->{snapshot}->{nvme0},
    $value,
    'NVMe snapshot configuration survives a round trip',
);

my @volumes;
PVE::QemuConfig->foreach_volume($config, sub { push @volumes, $_[0]; });
is_deeply(\@volumes, ['nvme0'], 'volume operations include NVMe disks');
is_deeply(
    [PVE::QemuMigrate::Helpers::check_non_migratable_resources($config, 1, 1)],
    ['nvme0'],
    'NVMe blocks migration of VM state',
);
is_deeply(
    [PVE::QemuMigrate::Helpers::check_non_migratable_resources($config, 0, 1)],
    [],
    'NVMe allows disk-only snapshots and offline migration',
);
eval { PVE::QemuMigrate::Helpers::check_non_migratable_resources($config, 1, 0); };
like(
    $@,
    qr/Cannot live-migrate, snapshot \(with RAM\), or hibernate a VM with: nvme0/,
    'reject saving NVMe VM state',
);

my $qemu_mock = Test::MockModule->new('PVE::QemuServer');
$qemu_mock->mock(vm_deviceplug => sub { die "unexpected device plug\n"; });
$qemu_mock->mock(vm_deviceunplug => sub { die "unexpected device unplug\n"; });
my $storage_mock = Test::MockModule->new('PVE::Storage');
$storage_mock->mock(activate_volumes => sub { die "unexpected volume activation\n"; });

my $update = sub {
    my ($conf, $new_value) = @_;
    PVE::QemuServer::vmconfig_update_disk({}, $conf, 1, 8006, 'nvme0', $new_value, 'x86_64', 'pc');
};
eval { $update->({}, $volume); };
is($@, "skip\n", 'new NVMe disk remains pending while the VM is running');
eval { $update->({ nvme0 => $volume }, 'local:8006/vm-8006-disk-1.raw'); };
is($@, "skip\n", 'NVMe disk replacement remains pending');
for my $option ('serial=new', 'max_ioqpairs=4', 'msix_qsize=5', 'mdts=9', 'use-intel-id=0') {
    eval { $update->({ nvme0 => $volume }, "$volume,$option"); };
    is($@, "skip\n", "NVMe controller change remains pending: $option");
}
eval { $update->({ nvme0 => $volume }, "$volume,backup=0"); };
is($@, '', 'NVMe backup metadata can be updated while running');

my $config_mock = Test::MockModule->new('PVE::QemuConfig');
$config_mock->mock(write_config => sub { });
my $cgroup_mock = Test::MockModule->new('PVE::QemuServer::CGroup');
$cgroup_mock->mock(new => sub { return bless {}, 'PVE::QemuServer::CGroup'; });
my $pending_delete = { nvme0 => $volume, pending => { delete => 'nvme0' } };
my $errors = {};
PVE::QemuServer::vmconfig_hotplug_pending(8006, $pending_delete, {}, undef, $errors);
is_deeply($errors, {}, 'pending NVMe removal does not cause a hotplug error');
is($pending_delete->{nvme0}, $volume, 'pending NVMe removal retains the active disk');
is($pending_delete->{pending}->{delete}, 'nvme0', 'NVMe removal waits until the VM is stopped');

my $helpers_mock = Test::MockModule->new('PVE::QemuServer::Helpers');
my $running = 1;
$helpers_mock->mock(vm_running_locally => sub { return $running; });
my @resize_calls;
$storage_mock->mock(volume_resize => sub { push @resize_calls, [@_]; });
eval { PVE::QemuServer::Blockdev::resize(8006, 'drive-nvme0', {}, $volume, 2 * 1024**3); };
like($@, qr/cannot resize NVMe disk 'nvme0' while the VM is running/, 'reject online NVMe resize');
is(scalar(@resize_calls), 0, 'online NVMe resize does not modify the backing volume');
$running = 0;
PVE::QemuServer::Blockdev::resize(8006, 'drive-nvme0', {}, $volume, 2 * 1024**3);
is_deeply(
    \@resize_calls,
    [[{}, $volume, 2 * 1024**3, 0]],
    'offline NVMe resize delegates to the storage layer',
);

done_testing();
