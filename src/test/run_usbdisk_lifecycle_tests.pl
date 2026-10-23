#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;

use PVE::API2::Qemu;
use PVE::QemuConfig;
use PVE::QemuMigrate;
use PVE::QemuServer;
use PVE::QemuServer::USB;

my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { return {}; });

{
    my $usb = Test::MockModule->new('PVE::QemuServer::USB');
    my $devices = [];
    my $queries = 0;
    $usb->mock(
        mon_cmd => sub {
            my ($vmid, $command, %args) = @_;
            is($vmid, 8006, 'inspect the source VM');
            is($command, 'qom-list', 'query realized USB hardware');
            is($args{path}, '/machine/peripheral', 'query the peripheral container');
            $queries++;
            return $devices;
        },
    );
    is(
        PVE::QemuServer::USB::get_usbdisk_controller_override(8006, {}),
        0,
        'a running VM without a controller returns an explicit absence override',
    );
    $devices = [{ name => 'xhci' }, { name => 'usbdisk-xhci-other' }];
    ok(
        !PVE::QemuServer::USB::get_usbdisk_controller_override(8006, {}),
        'host USB controllers do not count',
    );
    $devices = [{ name => 'usbdisk-xhci' }];
    ok(
        PVE::QemuServer::USB::get_usbdisk_controller_override(8006, { usbdisk0 => undef }),
        'empty storage controller must survive state transfer',
    );
    $queries = 0;
    ok(
        !defined(PVE::QemuServer::USB::get_usbdisk_controller_override(
            8006,
            { usbdisk7 => 'local:disk.raw' },
        )),
        'configured disks already recreate their controller',
    );
    is($queries, 0, 'active disks require no additional query or migration flag');
    $usb->mock(mon_cmd => sub { die "topology query failed\n"; });
    eval { PVE::QemuServer::USB::get_usbdisk_controller_override(8006, {}); };
    is($@, "topology query failed\n", 'query failure cannot silently omit migration state');
}

for my $arch ('x86_64', 'aarch64') {
    my @controllers = PVE::QemuServer::USB::get_usb_controllers({}, $arch, '9.2', 1);
    is(
        scalar(grep(/id=usbdisk-xhci,/, @controllers)),
        1,
        "restore an empty storage controller ($arch)",
    );
    @controllers =
        PVE::QemuServer::USB::get_usb_controllers({ usbdisk0 => 'local:disk.raw' }, $arch, '9.2',
            1);
    is(
        scalar(grep(/id=usbdisk-xhci,/, @controllers)),
        1,
        "force flag does not duplicate an active controller ($arch)",
    );
    for my $q35 ($arch eq 'x86_64' ? (0, 1) : (0)) {
        my $bridges =
            PVE::QemuServer::PCI::get_pci_bridges({}, $arch, $q35, 0, sub { 0 }, undef, 1);
        is(
            scalar(grep(/id=pci\.4,/, @$bridges)),
            1,
            "restore the storage controller's bridge on older machines ($arch, q35=$q35)",
        );
    }
}

for my $machine ('pc-i440fx-9.2', 'pc-q35-9.2') {
    for my $force (0, 1) {
        my $cmd = PVE::QemuServer::config_to_command(
            {},
            8006,
            {
                kvm => 0,
                machine => $machine,
                memory => 64,
                vga => 'none',
            },
            PVE::QemuServer::load_defaults(),
            { 'dry-run' => 1, 'force-usbdisk-controller' => $force },
        );
        is(
            scalar(grep(/id=usbdisk-xhci,/, @$cmd)),
            $force,
            "complete command recreates only the requested empty controller ($machine)",
        );
        is(
            scalar(grep(/id=pci\.4,/, @$cmd)),
            $force,
            "complete command keeps its required PCI bridge ($machine)",
        );
    }
}

{
    my $machine = Test::MockModule->new('PVE::QemuServer::Machine');
    $machine->mock(get_current_qemu_machine => sub { 'pc-i440fx-9.2+pve0' });
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    $helpers->mock(vm_running_locally => sub { 12345 });
    my $cpu = Test::MockModule->new('PVE::QemuServer::CPUConfig');
    $cpu->mock(get_cpu_from_running_vm => sub { 'qemu64' });
    my $network = Test::MockModule->new('PVE::QemuServer::Network');
    $network->mock(get_nets_host_mtu => sub { 'net0=1500' });
    my $usb = Test::MockModule->new('PVE::QemuServer::USB');
    my $empty_controller = 1;
    $usb->mock(
        mon_cmd => sub {
            die "topology unavailable\n" if !defined($empty_controller);
            return $empty_controller ? [{ name => 'usbdisk-xhci' }] : [];
        },
    );
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(storage_config => sub { { path => '/tmp' } });
    $storage->mock(config => sub { {} });
    my $allocations = 0;
    $storage->mock(vdisk_alloc => sub { $allocations++; 'local:8006/state.raw' });

    for my $suspend (0, 1) {
        for my $present (0, 1) {
            $empty_controller = $present;
            my $conf =
                { memory => 64, snapshots => { saved => {} }, 'running-usbdisk-controller' => 1 };
            my $state = PVE::QemuConfig->__snapshot_save_vmstate(
                8006, $conf, 'saved', {}, 'local', $suspend,
            );
            my $saved = $suspend ? $conf : $conf->{snapshots}->{saved};
            ok(
                defined($saved->{'running-usbdisk-controller'}),
                'saved state explicitly records controller presence or absence',
            );
            is($state, 'local:8006/state.raw', 'save VM state through the normal storage path');
            is(
                $saved->{'running-usbdisk-controller'} // 0,
                $present,
                "record actual empty controller topology (suspend=$suspend)",
            );
            my $raw = PVE::QemuServer::write_vm_config('/etc/pve/qemu-server/8006.conf', $conf);
            my $parsed =
                PVE::QemuServer::parse_vm_config('/etc/pve/qemu-server/8006.conf', $raw, 1);
            my $restored = $suspend ? $parsed : $parsed->{snapshots}->{saved};
            ok(
                defined($restored->{'running-usbdisk-controller'}),
                'the explicit absence marker survives configuration serialization',
            );
            is(
                $restored->{'running-usbdisk-controller'} // 0,
                $present,
                'saved hardware topology survives a strict configuration round trip',
            );

            my $data = {};
            PVE::QemuConfig->__snapshot_rollback_hook(8006, $restored, $saved, 0, $data);
            ok(
                !exists($restored->{'running-usbdisk-controller'}),
                'rollback removes runtime metadata from active config',
            );
            my $qemu = Test::MockModule->new('PVE::QemuServer');
            my $start;
            $qemu->mock(vm_start => sub { $start = $_[2]; });
            PVE::QemuConfig->__snapshot_rollback_vm_start(8006, $state, $data);
            ok(
                defined($start->{'usbdisk-controller'}),
                'rollback forwards an explicit zero override as well as presence',
            );
            is(
                $start->{'usbdisk-controller'} // 0,
                $present,
                'rollback forwards the saved controller to VM startup',
            );
        }
    }
    $empty_controller = undef;
    my $before = $allocations;
    eval {
        PVE::QemuConfig->__snapshot_save_vmstate(
            8006,
            { memory => 64 },
            'saved',
            {},
            'local',
            1,
        );
    };
    is($@, "topology unavailable\n", 'snapshot aborts when runtime topology is unknown');
    is($allocations, $before, 'query failure leaves no orphaned state volume');
}

{
    my $config = Test::MockModule->new('PVE::QemuConfig');
    my $snapshot;
    $config->mock(
        load_config => sub {
            return { snapshots => { saved => {%$snapshot} } };
        },
    );
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    $qemu->mock(load_defaults => sub { {} });
    my $forced;
    $qemu->mock(config_to_command =>
        sub { $forced = $_[4]->{'force-usbdisk-controller'}; return (['qemu-test']); });
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    $helpers->mock(vm_running_locally => sub { 1 });
    for my $case (
        [{ 'running-usbdisk-controller' => 1 }, 1],
        [{ 'running-usbdisk-controller' => 0 }, 0],
        [{ vmstate => 'local:8006/old-state.raw' }, 0],
        [{}, undef],
    ) {
        ($snapshot, my $expected) = @$case;
        like(
            PVE::QemuServer::vm_commandline({}, 8006, 'saved'),
            qr/qemu-test/,
            'snapshot command generation succeeds',
        );
        is(
            $forced,
            $expected,
            'snapshot showcmd preserves saved topology, including legacy state without a marker',
        );
        my $restored = {%$snapshot};
        my $data = {};
        PVE::QemuConfig->__snapshot_rollback_hook(8006, $restored, $snapshot, 0, $data);
        is(
            $data->{'usbdisk-controller'},
            $expected,
            'rollback applies the same topology default as snapshot command generation',
        );
    }
}

{
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    $helpers->mock(qsd_running_locally => sub { undef });
    my $cloudinit = Test::MockModule->new('PVE::QemuServer::Cloudinit');
    $cloudinit->mock(apply_cloudinit_config => sub { 0 });
    my $guest = Test::MockModule->new('PVE::GuestHelpers');
    $guest->mock(exec_hookscript => sub { });
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(activate_volumes => sub { });
    $storage->mock(deactivate_volumes => sub { });
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    $qemu->mock(clear_reboot_request => sub { });
    $qemu->mock(load_defaults => sub { {} });
    $qemu->mock(cleanup_pci_devices => sub { });
    my $forced;
    $qemu->mock(
        config_to_command => sub {
            $forced = $_[4]->{'force-usbdisk-controller'};
            die "startup options captured\n";
        },
    );
    for my $resume (0, 1) {
        eval {
            PVE::QemuServer::vm_start_nolock(
                {},
                8006,
                {
                    pending => {},
                    'running-usbdisk-controller' => 1,
                },
                { resume => $resume },
                {},
            );
        };
        like($@, qr/startup options captured/, 'inspect actual startup before spawning a VM');
        is(
            $forced // 0,
            $resume,
            'hibernation restores saved topology while cold boot ignores stale metadata',
        );
    }
    for my $saved ({}, { 'running-usbdisk-controller' => 0 }) {
        eval {
            PVE::QemuServer::vm_start_nolock(
                {},
                8006,
                { pending => {}, %$saved },
                { resume => 1 },
                {},
            );
        };
        like(
            $@,
            qr/startup options captured/,
            'inspect resume of old or explicitly empty USB topology',
        );
        is($forced, 0, 'legacy hibernation never gains a controller while loading old VM state');
    }
}

{
    my $tunnel = Test::MockModule->new('PVE::Tunnel');
    $tunnel->mock(
        write_tunnel => sub {
            my (undef, undef, $command, $params) = @_;
            is($command, 'start', 'start target through the cluster tunnel');
            is(
                $params->{start_params}->{'usbdisk-controller'},
                1,
                'remote migration transmits empty controller topology',
            );
            return {
                drives => {},
                migrate => { proto => 'unix', addr => '/run/qemu-server/8007.migrate' },
            };
        },
    );
    my $migration = bless { vmconf => { memory => 64 }, opts => { remote => { vmid => 8007 } } },
        'PVE::QemuMigrate';
    my ($result) = $migration->phase2_start_remote_cluster(
        8006,
        {
            start_params => { 'usbdisk-controller' => 1 },
            migrate_opts => { type => 'websocket' },
        },
    );
    is(
        $result->{addr},
        '/run/qemu-server/8007.migrate',
        'remote migration target response is preserved',
    );
}

done_testing();
