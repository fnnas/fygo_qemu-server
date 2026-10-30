#!/usr/bin/perl

use v5.36;
use lib qw(..);
use Test::More;
use Test::MockModule;
use PVE::QemuServer;
use PVE::QemuServer::PCI;

my %pci = (
    '0000:00:02.0' => { class => '0x030000', vendor => '0x8086' },
    '0000:01:00.0' => { class => '0x030200', vendor => '0x10de', nvidia => 1 },
    '0000:01:00.1' => { class => '0x040300', vendor => '0x10de' },
    '0000:02:00.0' => { class => '0x020000', vendor => '0x8086' },
);
my $sysfs = Test::MockModule->new('PVE::SysFSTools');
$sysfs->mock(
    lspci => sub($filter) {
        return [
            map { { id => $_, $pci{$_}->%* } }
            sort grep { index($_, $filter) == 0 } keys %pci
        ];
    },
);
my @alternatives = ('0000:00:02.0', '0000:01:00.0');
my $mapping = Test::MockModule->new('PVE::Mapping::PCI');
$mapping->mock(
    find_on_current_node => sub {
        return [map { { path => $_ } } @alternatives];
    },
);
$mapping->mock(config => sub { return { ids => { gpu => {} } }; });
$mapping->mock(assert_valid => sub { return; });

sub command($conf, $vga = { type => 'mdev' }, $arch = 'x86_64') {
    my $devices = [];
    PVE::QemuServer::PCI::print_hostpci_devices(
        8006,
        { machine => 'pc', bios => 'ovmf', %$conf },
        $devices,
        $vga,
        0,
        $arch,
        {},
        1,
    );
    return join(' ', @$devices);
}

my $mixed = {
    hostpci0 => '0000:00:02.0,mdev=i915-GVTg_V5_4,display=1,ramfb=1',
    hostpci1 => '0000:02:00.0',
};
my $cmd = command($mixed);
like(
    $cmd,
    qr/vfio-pci-nohotplug,sysfsdev=.*?,id=hostpci0.*?,display=on,ramfb=on,x-igd-opregion=on/,
    'Intel mdev uses the managed UUID and receives display, RAMFB and opregion',
);
like($cmd, qr/vfio-pci,host=0000:02:00.0,id=hostpci1/, 'NIC keeps ordinary VFIO driver');
unlike($cmd, qr/host=0000:02:00.0\S*(?:display|ramfb|opregion)/, 'NIC gets no display properties');

$cmd = command({ hostpci0 => '0000:01:00,display=1' });
like($cmd, qr/id=hostpci0\.0\S*,display=on/, 'graphics function is displayed');
unlike(
    $cmd,
    qr/id=hostpci0\.1\S*(?:display|ramfb|opregion)/,
    'audio function gets no display flags',
);
unlike($cmd, qr/nohotplug/, 'display without RAMFB keeps normal VFIO type');
$cmd = command({ hostpci0 => '0000:01:00.0,mdev=nvidia-123,display=1,ramfb=1' });
like(
    $cmd,
    qr/vfio-pci-nohotplug,host=0000:01:00.0/,
    'new NVIDIA VF mode preserves display selection',
);
unlike($cmd, qr/x-igd-opregion/, 'NVIDIA receives no Intel-only property');

$cmd = command($mixed, { type => 'std' });
unlike(
    $cmd,
    qr/display=on|ramfb=on|nohotplug|opregion/,
    'other VGA modes do not activate VFIO display',
);
$cmd = command({ hostpci0 => 'mapping=gpu,display=1' });
like($cmd, qr/display=on/, 'mapped graphics assignment works');

for my $case (
    [{}, qr/requires a graphics hostpci/, 'missing display device'],
    [{ hostpci0 => '0000:02:00.0,display=1' }, qr/requires a PCI graphics/, 'NIC display'],
    [
        { hostpci0 => '0000:02:00.0,mdev=accelerator,display=1' },
        qr/requires a PCI graphics/,
        'non-GPU mdev',
    ],
    [
        { hostpci0 => '0000:00:02.0,ramfb=1' },
        qr/ramfb requires display=1/,
        'RAMFB without display',
    ],
    [
        { hostpci0 => '0000:00:02.0,display=1,legacy-igd=1' },
        qr/not compatible with legacy-igd/,
        'legacy IGD conflict',
    ],
    [{ %$mixed, bios => 'seabios' }, qr/requires UEFI/, 'legacy firmware with RAMFB'],
    [
        { %$mixed, hostpci2 => '0000:01:00.0,display=1,ramfb=1' },
        qr/only one VFIO/,
        'duplicate firmware framebuffer',
    ],
) {
    eval { command($case->[0]); };
    like($@, $case->[1], "reject $case->[2]");
}
push @alternatives, '0000:02:00.0';
eval { command({ hostpci0 => 'mapping=gpu,mdev=i915-test,display=1' }); };
like($@, qr/requires a PCI graphics/, 'reject a non-graphics alternative before mdev selection');
pop @alternatives;

my $tools = Test::MockModule->new('PVE::Tools');
$tools->mock(dir_glob_regex => sub { return 1; });
is(
    PVE::QemuServer::print_egl_headless({ type => 'mdev' }),
    'egl-headless,gl=core',
    'DMA-BUF rendering is enabled by default',
);
is(
    PVE::QemuServer::print_egl_headless({ type => 'mdev', gl => 0 }),
    undef,
    'CPU region display can explicitly disable EGL',
);
is(
    PVE::QemuServer::print_egl_headless({ type => 'mdev', rendernode => '/dev/dri/renderD129' }),
    'egl-headless,gl=core,rendernode=/dev/dri/renderD129',
    'explicit host render node is passed',
);
is(
    PVE::QemuServer::print_egl_headless({ type => 'virtio-gl' }),
    'egl-headless,gl=core',
    'VirGL keeps its EGL backend',
);
$tools->mock(dir_glob_regex => sub { return 0; });
eval { PVE::QemuServer::print_egl_headless({ type => 'mdev' }); };
like($@, qr/no DRM render node/, 'missing host render node has an actionable error');

for my $type (qw(mdev ramfb virtio virtio-gl qxl qxl4)) {
    ok(PVE::QemuServer::vga_uses_spice({ type => $type }), "$type enables the SPICE console");
}
for my $type (qw(std none serial0)) {
    ok(!PVE::QemuServer::vga_uses_spice({ type => $type }),
        "$type keeps its previous console mode");
}
is(PVE::QemuServer::vga_conf_has_spice('mdev'), 0, 'mdev is never treated as a QXL monitor count');
is(PVE::QemuServer::vga_conf_has_spice('qxl4'), 4, 'QXL monitor count is preserved');
is(
    PVE::QemuServer::print_vga_device({ bios => 'ovmf' }, { type => 'ramfb' }, 'x86_64', '11.0'),
    'ramfb,id=vga',
    'standalone RAMFB has no PCI properties',
);
eval { PVE::QemuServer::print_vga_device({}, { type => 'ramfb' }, 'x86_64', '11.0'); };
like($@, qr/requires UEFI/, 'standalone RAMFB rejects legacy firmware');

my $schema = {
    type => 'object',
    additionalProperties => 0,
    properties => PVE::QemuServer::json_config_properties({}, 0),
};
for my $vga ('mdev', 'mdev,gl=0', 'mdev,rendernode=/dev/dri/renderD128', 'ramfb') {
    eval { PVE::JSONSchema::validate({ vga => $vga }, $schema); };
    is($@, '', "API accepts $vga");
}
eval {
    PVE::JSONSchema::validate({ vga => 'mdev,rendernode=/dev/dri/renderD128,foo=bar' },
        $schema);
};
ok($@, 'API rejects unknown display properties');
eval { PVE::JSONSchema::validate({ vga => 'mdev,rendernode=/tmp/renderD128' }, $schema); };
ok($@, 'API rejects non-DRM render paths');
my $filename = '/etc/pve/qemu-server/8006.conf';
my $raw = "vga: mdev,gl=0\nhostpci0: $mixed->{hostpci0}\n\n[PENDING]\nvga: ramfb\n\n"
    . "[snap]\nvga: mdev,rendernode=/dev/dri/renderD128\nhostpci0: $mixed->{hostpci0}\nsnaptime: 1\n";
my $config = PVE::QemuServer::parse_vm_config($filename, $raw, 1);
my $roundtrip = PVE::QemuServer::parse_vm_config(
    $filename, PVE::QemuServer::write_vm_config($filename, $config), 1,
);
is($roundtrip->{vga}, 'mdev,gl=0', 'display mode survives config serialization');
is($roundtrip->{hostpci0}, $mixed->{hostpci0}, 'per-device switches survive serialization');
is($roundtrip->{pending}->{vga}, 'ramfb', 'pending display survives serialization');
is(
    $roundtrip->{snapshots}->{snap}->{hostpci0},
    $mixed->{hostpci0},
    'snapshot configuration preserves display switches',
);

{
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    my @monitor;
    $qemu->mock(load_defaults => sub { return {}; });
    $qemu->mock(mon_cmd => sub { push @monitor, [@_]; });
    my $config_mock = Test::MockModule->new('PVE::QemuConfig');
    $config_mock->mock(write_config => sub { });
    my $cgroup = Test::MockModule->new('PVE::QemuServer::CGroup');
    $cgroup->mock(new => sub { return bless {}, 'PVE::QemuServer::CGroup'; });
    my $pending = {
        vga => 'std',
        hostpci0 => '0000:00:02.0',
        pending => { vga => 'mdev,gl=0', hostpci0 => $mixed->{hostpci0} },
    };
    my $errors = {};
    PVE::QemuServer::vmconfig_hotplug_pending(8006, $pending, {}, undef, $errors);
    is_deeply($errors, {}, 'display updates remain pending without hotplug errors');
    is($pending->{vga}, 'std', 'running display mode is not replaced');
    is($pending->{hostpci0}, '0000:00:02.0', 'running PCI assignment is not replaced');
    is($pending->{pending}->{hostpci0}, $mixed->{hostpci0}, 'RAMFB update waits for shutdown');
    $pending->{pending} = { delete => 'hostpci0,vga' };
    PVE::QemuServer::vmconfig_hotplug_pending(8006, $pending, {}, undef, $errors);
    is($pending->{pending}->{delete}, 'hostpci0,vga', 'display removal waits for shutdown');
    is_deeply(\@monitor, [], 'display updates and removal never send hotplug commands');
}

done_testing();
