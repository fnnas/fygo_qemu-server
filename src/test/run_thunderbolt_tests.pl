use strict;
use warnings;

use PVE::JSONSchema;
use PVE::QemuMigrate::Helpers;
use PVE::QemuServer;
use PVE::QemuServer::NVMe;
use PVE::QemuServer::Thunderbolt;
use Test::MockModule;
use Test::More;

my $conf = {
    arch => 'x86_64',
    machine => 'q35',
    thunderbolt0 => 'usb4-generic',
    thunderbolt1 => 'tb3-alpine-ridge',
    tbdock0 => 'host=thunderbolt0,port=2',
    tbdock1 => 'host=thunderbolt1,port=1',
    nvme0 => 'local:vm-100-disk-0,nvme-dock=tbdock0,serial=Dock%201',
    nvme1 => 'local:vm-100-disk-1',
};

PVE::JSONSchema::validate(
    $conf,
    { type => 'object', properties => PVE::QemuServer::json_config_properties({}, 1) },
);
my $groups = PVE::QemuServer::NVMe::topology($conf);
ok(!$groups->{nvme0} && $groups->{nvme1}, 'a dock disk does not allocate a direct NVMe controller');
is_deeply(
    PVE::QemuServer::get_default_bootdevices($conf),
    ['nvme1'],
    'the direct disk remains the default boot device',
);

my ($hosts, $docks, $order) = PVE::QemuServer::Thunderbolt::topology(
    $conf,
    { nvme0 => PVE::QemuServer::Drive::parse_drive('nvme0', $conf->{nvme0}) },
);
my $devices = join("\n", PVE::QemuServer::Thunderbolt::devices($hosts, $docks, $order, undef, 1));
like($devices, qr/tunnel-port2=thunderbolt0-port2/, 'the second port has its own tunnel');
like($devices, qr/id=thunderbolt0-port2,.*usb4-port=2/, 'USB4 ACPI port numbering is one-based');
like(
    $devices,
    qr/usb4-host,id=thunderbolt1,.*ports=1,profile=tb3-alpine-ridge/,
    'Alpine Ridge profile',
);
like(
    $devices,
    qr/usb4-tb3-tunnel-dsp,id=thunderbolt1-port1,bus=thunderbolt1-switch/,
    'Alpine Ridge places the tunnel below the discrete controller switch',
);
unlike($devices, qr/id=thunderbolt1-port2\b/, 'Alpine Ridge has only one tunnel port');
like(
    $devices,
    qr/usb4-device,id=tbdock0,bus=thunderbolt0\.0,port=2,dock=on,downstream-ports=3,serial=Dock 1,drive=drive-nvme0/,
    'the dock references the existing block backend and uses the decoded serial',
);

{
    my ($titan_hosts, $titan_docks, $titan_order) = PVE::QemuServer::Thunderbolt::topology(
        {
            machine => 'azw-me-pro-6',
            thunderbolt0 => 'tb3-titan-ridge',
            thunderbolt1 => 'tb3-titan-ridge',
            tbdock0 => 'host=thunderbolt0,port=2',
        },
        { nvme0 => { 'nvme-dock' => 'tbdock0' } },
    );
    my $cmd = join(
        "\n",
        PVE::QemuServer::Thunderbolt::devices(
            $titan_hosts, $titan_docks, $titan_order, undef, 1,
        ),
    );
    for my $host (qw(thunderbolt0 thunderbolt1)) {
        like($cmd, qr/usb4-tr-usp,id=$host-switch,bus=$host-root/,
            "$host has a Titan Ridge switch");
        like(
            $cmd,
            qr/usb4-tr-dsp,id=$host-nhi,bus=$host-switch/,
            "$host routes the NHI via its switch",
        );
        like(
            $cmd,
            qr/usb4-host,id=$host,bus=$host-nhi,.*profile=tb3-titan-ridge/,
            "$host attaches the NHI",
        );
        like($cmd, qr/usb4-tr-xhci,id=$host-xhci,bus=$host-xhci-port/, "$host has a separate xHCI");
        for my $port (1, 2) {
            like(
                $cmd,
                qr/usb4-tr-tunnel-dsp,id=$host-port$port,bus=$host-switch.*usb4-port=$port/,
                "$host tunnel $port uses its own downstream switch port",
            );
        }
    }
    my @chassis = $cmd =~ /\bchassis=(\d+)/g;
    my %chassis = map { $_ => 1 } @chassis;
    is(scalar(keys %chassis), scalar(@chassis), 'dual controllers use distinct PCIe chassis IDs');
    like(
        $cmd,
        qr/id=tbdock0,bus=thunderbolt0\.0,port=2,.*drive=drive-nvme0/,
        'disk stays on dock port 2',
    );
}

{
    my $tools = Test::MockModule->new('PVE::Tools');
    my $probe_mode = 'supported';
    $tools->mock(
        run_command => sub {
            my ($command, %options) = @_;
            is_deeply([@$command[0, 1]], ['/usr/bin/kvm', '-device'], 'probes the selected binary');
            if ($command->[2] eq 'help') {
                die "QEMU probe terminated by signal\n" if $probe_mode eq 'crash';
                $options{outfunc}->('name "usb4-device", bus usb4-bus');
                $options{outfunc}->('name "usb4-tunnel-port", bus PCI');
                $options{outfunc}->('name "usb4-host", bus PCI') if $probe_mode ne 'missing';
                for my $type (qw(usp dsp tunnel-dsp xhci)) {
                    next if $probe_mode eq 'missing-switch' && $type eq 'tunnel-dsp';
                    $options{outfunc}->(qq(name "usb4-tb3-$type", bus PCI));
                }
            } elsif ($command->[2] eq 'usb4-tunnel-dsp,help') {
                $options{outfunc}->('  x-reserve-for-dock=<bool>');
            } elsif ($command->[2] eq 'usb4-device,help') {
                $options{outfunc}->('  x-dock-nvme-hotplug=<bool>') if $probe_mode eq 'supported';
                $options{outfunc}->('  x-cable=<bool>') if $probe_mode eq 'supported';
            } else {
                die "unexpected QEMU probe: @$command\n";
            }
        },
    );

    my @args = ($hosts, $docks, $order, '/usr/bin/kvm', 0);
    my @live_devices = PVE::QemuServer::Thunderbolt::devices(@args);
    is_deeply(\@live_devices, [split("\n", $devices)], 'the registered devices pass the probe');

    $probe_mode = 'missing';
    eval { PVE::QemuServer::Thunderbolt::devices(@args) };
    like($@, qr/missing: usb4-host/, 'an incomplete device list fails even with exit status zero');

    $probe_mode = 'missing-switch';
    eval { PVE::QemuServer::Thunderbolt::devices(@args) };
    like($@, qr/missing: usb4-tb3-tunnel-dsp/, 'the selected switch type is required');

    $probe_mode = 'crash';
    eval { PVE::QemuServer::Thunderbolt::devices(@args) };
    like($@, qr/Could not query.*terminated by signal/, 'probe failures retain the actual error');
}

my $chain = {
    %$conf,
    tbdock0 => 'parent=tbdock2,port=3',
    tbdock2 => 'host=thunderbolt0,port=2',
    nvme1 => 'local:vm-100-disk-1,nvme-dock=tbdock2,nvme-dock-port=1,serial=One%252C',
    nvme2 => 'local:vm-100-disk-2,nvme-dock=tbdock2,nvme-dock-port=2,serial=Two%2C',
};
PVE::JSONSchema::validate(
    $chain,
    { type => 'object', properties => PVE::QemuServer::json_config_properties({}, 1) },
);
is_deeply(PVE::QemuServer::NVMe::topology($chain), {}, 'all disks use the Thunderbolt fabric');
my %chain_drives =
    map { $_ => PVE::QemuServer::Drive::parse_drive($_, $chain->{$_}) } qw(nvme0 nvme1 nvme2);
my ($chain_hosts, $chain_docks, $chain_order) =
    PVE::QemuServer::Thunderbolt::topology($chain, \%chain_drives);
my $chain_cmd = join(
    "\n",
    PVE::QemuServer::Thunderbolt::devices($chain_hosts, $chain_docks, $chain_order, undef, 1),
);
{
    my $detached = { %$chain, tbdock2 => "$chain->{tbdock2},disconnected=1" };
    PVE::JSONSchema::validate(
        $detached,
        { type => 'object', properties => PVE::QemuServer::json_config_properties({}, 1) },
    );
    my ($h, $d, $o) = PVE::QemuServer::Thunderbolt::topology($detached, \%chain_drives);
    my $cmd = join("\n", PVE::QemuServer::Thunderbolt::devices($h, $d, $o, undef, 1));
    like($cmd, qr/id=tbdock2,.*x-cable=off/, 'a disconnected dock starts with its cable out');
    unlike($cmd, qr/id=thunderbolt0-port2,.*x-force-tunnel=on/, 'no forced tunnel for a detached dock');
    like($cmd, qr/id=tbdock0,.*parent=tbdock2/, 'the downstream dock stays configured');
    like($cmd, qr/id=tb-nvme1,.*drive=drive-nvme1/, 'the disk stays configured');
    eval {
        PVE::QemuServer::NVMe::validate_update(
            $detached, { tbdock1 => 'host=thunderbolt0,port=2' }, [],
        );
    };
    like($@, qr/port 2 already has a dock/, 'a disconnected dock keeps its upstream port');

    my $qemu = Test::MockModule->new('PVE::QemuServer');
    my $config = Test::MockModule->new('PVE::QemuConfig');
    my $cgroup = Test::MockModule->new('PVE::QemuServer::CGroup');
    $config->mock(write_config => sub { });
    $cgroup->mock(new => sub { return bless {}, 'PVE::QemuServer::CGroup'; });
    my $cable = 1;
    my @changes;
    my @removed;
    $qemu->mock(
        mon_cmd => sub {
            my (undef, $command, %args) = @_;
            is($args{path}, '/machine/peripheral/tbdock2', 'operate on the selected dock');
            is($args{property}, 'x-cable', 'use the virtual cable');
            return $cable if $command eq 'qom-get';
            die "unexpected QMP command '$command'" if $command ne 'qom-set';
            $cable = $args{value};
            push @changes, $cable ? 1 : 0;
        },
    );
    $qemu->mock(qemu_devicedelverify => sub { push @removed, $_[1]; });
    my $running = { %$chain, hotplug => 'disk,usb', pending => {} };
    my $toggle = sub {
        my ($value) = @_;
        $running->{pending}->{tbdock2} = $value;
        my $errors = {};
        PVE::QemuServer::vmconfig_hotplug_pending(8006, $running, {}, undef, $errors);
        is_deeply($errors, {}, 'dock connection change reports no hotplug errors');
    };
    $toggle->($detached->{tbdock2});
    is($running->{tbdock2}, $detached->{tbdock2}, 'dock reports disconnected after drain');
    is_deeply([sort @removed], [qw(nvme0 nvme1 nvme2)], 'wait for disks throughout the subtree');
    $toggle->($chain->{tbdock2});
    is_deeply(\@changes, [0, 1], 'reconnecting restores the same dock');
    is($running->{tbdock2}, $chain->{tbdock2}, 'upstream connection is preserved');
    is($running->{nvme0}, $chain->{nvme0}, 'child disk configuration is preserved');
    is_deeply($running->{pending}, {}, 'both connection changes apply immediately');

    $running->{hotplug} = 'disk';
    $toggle->($detached->{tbdock2});
    is($running->{pending}->{tbdock2}, $detached->{tbdock2}, 'USB hotplug disabled defers the change');
    is_deeply(\@changes, [0, 1], 'no runtime cable change when hotplug is disabled');
}

cmp_ok(
    index($chain_cmd, 'usb4-device,id=tbdock2,'),
    '<',
    index($chain_cmd, 'usb4-device,id=tbdock0,'),
    'parent dock precedes its child regardless of config index',
);
like(
    $chain_cmd,
    qr/id=tb-nvme1,bus=thunderbolt0\.0,parent=tbdock2,port=1,drive=drive-nvme1,serial=One%2C/,
    'a downstream disk keeps its own backend and serial is decoded once',
);
like(
    $chain_cmd,
    qr/id=tb-nvme2,bus=thunderbolt0\.0,parent=tbdock2,port=2,drive=drive-nvme2,serial=Two,,/,
    'different ports carry independent storage and commas are escaped',
);

for my $case (
    [{ tbdock2 => 'parent=tbdock0,port=1' }, [], qr/cannot form a cycle/],
    [{ tbdock2 => 'host=thunderbolt0,parent=tbdock0,port=2' }, [], qr/specify exactly one/],
    [{ tbdock2 => 'host=thunderbolt0,port=3' }, [], qr/has only two ports/],
    [{ tbdock3 => 'parent=tbdock0,port=1' }, [], qr/only one level of Thunderbolt dock cascading/],
    [{ tbdock3 => 'parent=tbdock2,port=1' }, [], qr/already has a chained dock/],
    [
        { nvme2 => 'local:vm-100-disk-2,nvme-dock=tbdock2,nvme-dock-port=3' },
        [],
        qr/already in use/,
    ],
    [
        { nvme2 => 'local:vm-100-disk-2,nvme-dock=tbdock2,nvme-dock-port=1' },
        [],
        qr/already in use/,
    ],
    [{ nvme2 => 'local:vm-100-disk-2,nvme-dock-port=1' }, [], qr/requires nvme-dock/],
    [{ tbdock0 => 'parent=tbdock1,port=1' }, [], qr/chained docks require a USB4 controller/],
    [
        { nvme2 => 'local:vm-100-disk-2,nvme-dock=tbdock1,nvme-dock-port=1' },
        [],
        qr/downstream storage ports require a USB4 controller/,
    ],
    [{}, ['tbdock2'], qr/dock 'tbdock2' does not exist/],
) {
    my ($changes, $deletions, $expected) = @$case;
    eval { PVE::QemuServer::NVMe::validate_update($chain, $changes, $deletions) };
    like($@, $expected, "chained topology rejects $expected");
}

for my $case (
    [{}, ['thunderbolt0'], qr/controller 'thunderbolt0' does not exist/],
    [{}, ['tbdock0'], qr/dock 'tbdock0' does not exist/],
    [{ machine => 'pc' }, [], qr/requires an x86_64 Q35/],
    [{ tbdock0 => 'host=thunderbolt1,port=2' }, [], qr/Alpine Ridge has only port 1/],
    [{ tbdock1 => 'host=thunderbolt0,port=2' }, [], qr/port 2 already has a dock/],
    [{ nvme1 => 'local:vm-100-disk-1,nvme-dock=tbdock0' }, [], qr/already has an NVMe disk/],
    [{ nvme1 => 'local:vm-100-disk-1,nvme-controller=0' }, [], qr/cannot own another disk/],
    [
        { nvme0 => 'local:vm-100-disk-0,nvme-dock=tbdock0,model=Example' },
        [],
        qr/do not support model/,
    ],
    [{ boot => 'order=nvme0' }, [], qr/remove the Thunderbolt disk from the boot order/],
) {
    my ($changes, $deletions, $expected) = @$case;
    eval { PVE::QemuServer::NVMe::validate_update($conf, $changes, $deletions) };
    like($@, $expected, "reject $expected");
}

my @blockers = PVE::QemuMigrate::Helpers::check_non_migratable_resources(
    { thunderbolt0 => 'usb4-generic' },
    1,
    1,
);
is_deeply(\@blockers, ['thunderbolt0'], 'a controller without a disk still blocks RAM state');

my $blockdev = Test::MockModule->new('PVE::QemuServer::Blockdev');
$blockdev->mock(
    mon_cmd => sub {
        return [
            {
                qdev => '/machine/peripheral/thunderbolt0-port2-dock1-nvme/legacy[0]',
                inserted => { 'node-name' => 'drive-nvme0' },
            },
            {
                qdev => '/machine/peripheral/thunderbolt1-port1-dock1-nvme/legacy[0]',
                device => 'drive-nvme1',
                inserted => { 'node-name' => '#block123' },
            },
            {
                qdev => 'ide2',
                device => 'drive-ide2',
            },
        ];
    },
);
my $block_info = PVE::QemuServer::Blockdev::get_block_info(100);
is(
    $block_info->{nvme0}->{inserted}->{'node-name'},
    'drive-nvme0',
    'block queries find a dock disk despite the QEMU frontend name',
);
is($block_info->{nvme1}->{device}, 'drive-nvme1', 'also find disks with a legacy block backend');
ok(exists($block_info->{ide2}) && !exists($block_info->{ide2}->{inserted}), 'ejected CD is empty');
done_testing();
