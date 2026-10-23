#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;

use PVE::API2::Qemu;
use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::USB;

my $volume = 'local:8006/vm-8006-disk-0.raw';
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });

for my $machine ('pc-i440fx-9.2', 'pc-q35-9.2', 'pc-i440fx-11.1', 'virt-11.1') {
    my $arch = $machine =~ /^virt/ ? 'aarch64' : 'x86_64';
    for my $hotplug (undef, '1', 'usb', 'disk,usb', 'disk', '0') {
        my $enabled = !defined($hotplug) || $hotplug eq '1' || $hotplug =~ /usb/ ? 1 : 0;
        my $conf = { arch => $arch, machine => $machine, memory => 64, kvm => 0, vga => 'none' };
        $conf->{hotplug} = $hotplug if defined($hotplug);
        my $cmd = PVE::QemuServer::config_to_command(
            {},
            8006,
            $conf,
            PVE::QemuServer::load_defaults(),
            { 'dry-run' => 1 },
        );
        is(
            scalar(grep(/id=usbdisk-xhci,/, @$cmd)),
            $enabled,
            "empty VM reserves USB storage controller ($machine, hotplug="
                . ($hotplug // 'default') . ')',
        );
        ok(
            !$enabled || grep(/id=pci\.4,/, @$cmd),
            'reserved controller has its required PCI bridge',
        );
        if ($enabled) {
            my $old_cmd = PVE::QemuServer::config_to_command(
                {},
                8006,
                $conf,
                PVE::QemuServer::load_defaults(),
                { 'dry-run' => 1, 'force-usbdisk-controller' => 0 },
            );
            ok(
                !grep(/id=usbdisk-xhci,/, @$old_cmd),
                'an old running VM can preserve controller absence',
            );
            my $needs_bridge = $machine =~ /11\.1/ ? 1 : 0;
            is(
                scalar(grep(/id=pci\.4,/, @$old_cmd)),
                $needs_bridge,
                'absence override also preserves the older PCI bridge layout',
            );
        }
    }
}

{
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    my $config = Test::MockModule->new('PVE::QemuConfig');
    $config->mock(write_config => sub { });
    my $machine = Test::MockModule->new('PVE::QemuServer::Machine');
    $machine->mock(get_current_qemu_machine => sub { 'pc-i440fx-11.1' });
    my $cgroup = Test::MockModule->new('PVE::QemuServer::CGroup');
    $cgroup->mock(new => sub { bless {}, 'PVE::QemuServer::CGroup' });
    my $storage = Test::MockModule->new('PVE::Storage');
    my @calls;
    $storage->mock(activate_volumes => sub { push @calls, 'activate'; });
    $qemu->mock(vm_devices_list => sub { { 'usbdisk-xhci' => 1 } });
    $qemu->mock(vm_deviceplug => sub { push @calls, 'plug'; });
    $qemu->mock(vm_deviceunplug => sub { push @calls, 'unplug'; });
    $qemu->mock(vmconfig_delete_or_detach_drive => sub { push @calls, 'detach'; });

    for my $hotplug ('usb', 'disk,usb', 'disk', '0', '1') {
        my $enabled = $hotplug eq '1' || $hotplug =~ /usb/ ? 1 : 0;
        @calls = ();
        my $conf = { hotplug => $hotplug, pending => { usbdisk0 => $volume } };
        my $errors = {};
        PVE::QemuServer::vmconfig_hotplug_pending(8006, $conf, {}, undef, $errors);
        is_deeply($errors, {}, "USB hot-add has no unexpected errors (hotplug=$hotplug)");
        is(
            defined($conf->{usbdisk0}) ? 1 : 0,
            $enabled,
            'USB storage uses the USB switch independently of the disk switch',
        );
        is(
            defined($conf->{pending}->{usbdisk0}) ? 1 : 0,
            !$enabled ? 1 : 0,
            'only disabled USB hotplug leaves the disk pending',
        );
        is_deeply(
            \@calls,
            $enabled ? ['activate', 'plug'] : [],
            'disabled USB hotplug has no disk activation or device side effects',
        );

        @calls = ();
        $conf = { hotplug => $hotplug, usbdisk0 => $volume, pending => { delete => 'usbdisk0' } };
        $errors = {};
        PVE::QemuServer::vmconfig_hotplug_pending(8006, $conf, {}, undef, $errors);
        is_deeply($errors, {}, "USB removal has no unexpected errors (hotplug=$hotplug)");
        is(
            defined($conf->{usbdisk0}) ? 1 : 0,
            !$enabled ? 1 : 0,
            'USB removal obeys the same USB switch',
        );
        is_deeply(
            \@calls,
            $enabled ? ['unplug', 'detach'] : [],
            'only enabled USB hotplug detaches the old volume',
        );
    }

    my $devices = { 'pci.4' => 1 };
    $qemu->mock(vm_devices_list => sub { $devices });
    $qemu->mock(
        qemu_deviceadd => sub {
            like(
                $_[1],
                qr/^qemu-xhci,id=usbdisk-xhci,.*bus=pci\.4,/,
                'legacy recovery hot-adds the dedicated controller on its reserved bridge',
            );
            $devices->{'usbdisk-xhci'} = 1;
            push @calls, 'controller';
        },
    );
    $qemu->mock(
        qemu_deviceaddverify => sub {
            is($_[1], 'usbdisk-xhci', 'verify controller realization before attaching a disk');
            push @calls, 'verify-controller';
        },
    );
    @calls = ();
    PVE::QemuServer::vmconfig_update_disk(
        {}, {}, 1, 8006, 'usbdisk0', $volume, 'x86_64', 'pc-i440fx-11.1',
    );
    is_deeply(
        \@calls,
        ['controller', 'verify-controller', 'activate', 'plug'],
        'an older running VM can hot-add its first USB disk when bridge 4 exists',
    );
}

{
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    my $config = Test::MockModule->new('PVE::QemuConfig');
    $config->mock(write_config => sub { });
    my $machine = Test::MockModule->new('PVE::QemuServer::Machine');
    $machine->mock(get_current_qemu_machine => sub { 'pc-q35-11.1' });
    my $cgroup = Test::MockModule->new('PVE::QemuServer::CGroup');
    $cgroup->mock(new => sub { bless {}, 'PVE::QemuServer::CGroup' });
    my $storage = Test::MockModule->new('PVE::Storage');
    my ($attached, @effects);
    $storage->mock(activate_volumes => sub { push @effects, 'activate'; });
    $qemu->mock(vm_devices_list => sub { { 'usbdisk-xhci' => 1 } });
    $qemu->mock(vm_deviceplug => sub { $attached = $_[4]->{file}; push @effects, 'plug'; });
    $qemu->mock(vm_deviceunplug => sub { $attached = undef; push @effects, 'unplug'; });
    $qemu->mock(vmconfig_delete_or_detach_drive => sub { });
    $qemu->mock(vmconfig_register_unused_drive => sub { $_[2]->{unused0} = $_[3]->{file}; });
    my $new_volume = 'local:8006/vm-8006-disk-1.raw';

    for my $case (
        ['0', 'usb', 1, 0, 'usb'],
        ['usb', '0', 0, 0, '0'],
        ['0', undef, 1, 0, undef],
        ['0', 'usb', 0, 1, '0'],
        ['usb', '0', 1, 1, 'usb'],
        ['0', 'usb,cpu', 0, 0, '0'],
        ['usb,cpu', '0', 1, 0, 'usb,cpu'],
        ['memory', 'usb', 0, 0, 'memory'],
        ['0', 'usb,memory', 0, 0, '0'],
    ) {
        my ($old, $new, $enabled, $select_disk, $effective) = @$case;
        for my $action (qw(add remove replace)) {
            my $conf = { hotplug => $old, pending => {} };
            $conf->{pending}->{hotplug} = $new if defined($new);
            my @delete = defined($new) ? () : ('hotplug');
            $conf->{usbdisk0} = $volume if $action ne 'add';
            if ($action eq 'remove') {
                push @delete, 'usbdisk0';
            } else {
                $conf->{pending}->{usbdisk0} = $new_volume;
            }
            $conf->{pending}->{delete} = join(',', @delete) if @delete;
            $attached = $action eq 'add' ? undef : $volume;
            @effects = ();
            my $errors = {};
            my $selection = $select_disk ? { usbdisk0 => 1 } : undef;
            PVE::QemuServer::vmconfig_hotplug_pending(8006, $conf, {}, $selection, $errors);
            my $description = "$action USB disk with hotplug=$old -> " . ($new // 'default');
            is_deeply($errors, {}, "$description has no unexpected errors");
            is(
                $conf->{hotplug},
                $effective,
                'effective hotplug settings are applied before device updates',
            );
            my $expected =
                $enabled
                ? ($action eq 'remove' ? undef : $new_volume)
                : ($action eq 'add' ? undef : $volume);
            is($attached, $expected, 'physical USB device follows the effective setting');
            is($conf->{usbdisk0}, $expected, 'active disk configuration matches the device');
            my $pending =
                $action eq 'remove'
                ? !!PVE::QemuConfig->parse_pending_delete($conf->{pending}->{delete})->{usbdisk0}
                : defined($conf->{pending}->{usbdisk0});
            is($pending ? 1 : 0, $enabled ? 0 : 1, 'only disallowed device updates remain pending');
            is_deeply(\@effects, [], 'disallowed update has no storage or device effects')
                if !$enabled;

            if ($select_disk || ($old =~ /cpu|memory/) || (defined($new) && $new =~ /cpu|memory/)) {
                is(
                    $conf->{pending}->{hotplug},
                    $new,
                    'unselected or CPU/memory settings remain pending',
                );
            } else {
                ok(
                    !exists($conf->{pending}->{hotplug}),
                    'applied hotplug setting is no longer pending',
                );
            }
        }
    }
}

{

    package USBDiskHotplugRPC;
    sub get_user { 'user@pve' }
}
{
    my $rpc = Test::MockModule->new('PVE::RPCEnvironment');
    $rpc->mock(get => sub { bless {}, 'USBDiskHotplugRPC' });
    for my $presence (0, 1) {
        eval {
            PVE::API2::Qemu->map_method_by_name('vm_start')->{code}
                ->({ node => 'pve', vmid => 8006, 'usbdisk-controller' => $presence });
        };
        like(
            $@,
            qr/Only root may use this option/,
            'both presence and absence overrides are internal privileged startup options',
        );
    }
}

done_testing();
