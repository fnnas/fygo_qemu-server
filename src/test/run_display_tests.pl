#!/usr/bin/perl

use v5.36;
use lib qw(..);
use Test::More;
use Test::MockModule;
use PVE::QemuServer;
use PVE::QemuServer::Memory;
use PVE::QemuMigrate::Helpers;

my @types = qw(bochs-display ati-vga isa-vga isa-cirrus-vga secondary-vga qxl-pci
    virtio-gpu-pci virtio-gpu-gl-pci virtio-gpu-device virtio-gpu-gl-device
    vhost-user-vga vhost-user-gpu-pci);
my $schema = {
    type => 'object',
    additionalProperties => 0,
    properties => PVE::QemuServer::json_config_properties({}, 0),
};

for my $type (@types) {
    eval { PVE::JSONSchema::validate({ vga => $type }, $schema); };
    is($@, '', "API accepts $type");
    for my $arch (qw(x86_64 aarch64)) {
        my $vga = { type => $type };
        my $qxlnum = PVE::QemuServer::vga_conf_has_spice($type);
        my $device =
            eval { PVE::QemuServer::print_vga_device({}, $vga, $arch, '11.0', undef, $qxlnum); };
        my $bad_arch = $arch eq 'aarch64' && $type =~ /^(isa-|qxl|vhost-user-vga)/
            || $arch ne 'aarch64' && $type =~ /-device$/;
        if ($bad_arch) {
            like($@, qr/only supported on x86_64|MMIO graphics require/, "$type rejects $arch");
        } else {
            is($@, '', "$type supports $arch");
            my $expected = $type eq 'qxl-pci' ? 'qxl' : $type;
            like($device, qr/^\Q$expected\E,id=vga(?:,|$)/, 'selects the actual QEMU device');
            if ($type =~ /^(isa-)|-device$/) {
                unlike($device, qr/\b(?:bus|addr)=/, 'non-PCI display has no PCI properties');
            } else {
                like($device, qr/,bus=/, 'PCI display uses the assigned bus');
            }
        }
    }
    my $filename = '/etc/pve/qemu-server/8006.conf';
    my $config = PVE::QemuServer::parse_vm_config($filename, "vga: $type\n", 1);
    my $restored = PVE::QemuServer::parse_vm_config(
        $filename, PVE::QemuServer::write_vm_config($filename, $config), 1,
    );
    is($restored->{vga}, $type, "$type survives config serialization");
}

sub device($type, $memory, $extra = {}) {
    return PVE::QemuServer::print_vga_device(
        {},
        { type => $type, memory => $memory, %$extra },
        'x86_64',
        '11.0',
        undef,
        PVE::QemuServer::vga_conf_has_spice($type),
    );
}
like(device('bochs-display', 64), qr/,vgamem=67108864,/, 'Bochs memory uses bytes');
like(device('ati-vga', 32, { 'ati-model' => 'rv100' }), qr/,model=rv100$/, 'ATI model is passed');
like(device('virtio-gpu-pci', 128), qr/,max_hostmem=134217728,/, 'VirtIO memory uses max_hostmem');
like(
    device('qxl-pci', 32),
    qr/^qxl,.*vgamem_mb=32,ram_size_mb=128,vram_size_mb=64/,
    'non-VGA QXL memory uses QXL properties',
);
for my $case (
    ['bochs-display', 257, {}, qr/not exceed 256/],
    ['cirrus', 12, {}, qr/4, 8 or 16/],
    ['isa-cirrus-vga', 32, {}, qr/4, 8 or 16/],
    ['ati-vga', 8, { 'ati-model' => 'rv100' }, qr/at least 16/],
    ['vhost-user-gpu-pci', 16, {}, qr/do not support the VGA memory/],
) {
    eval { device(@$case[0 .. 2]); };
    like($@, $case->[3], 'reject unsupported display memory');
}
for my $type (qw(virtio-gl virtio-gpu-gl-pci virtio-gpu-gl-device vhost-user-vga vhost-user-gpu-pci)
) {
    ok(PVE::QemuServer::vga_needs_gl({ type => $type }), "$type uses EGL");
}
for my $type (qw(virtio-gpu-pci virtio-gpu-device)) {
    ok(!PVE::QemuServer::vga_needs_gl({ type => $type }), "$type defaults to 2D");
    ok(PVE::QemuServer::vga_uses_spice({ type => $type }), "$type exposes SPICE");
}
ok(
    PVE::QemuServer::vga_needs_gl({ type => 'vhost-user-gpu-pci' }),
    'vhost-user always uses EGL for DMA-BUF consoles',
);
{
    my $tools = Test::MockModule->new('PVE::Tools');
    $tools->mock(dir_glob_regex => sub { return 0; });
    eval { PVE::QemuServer::print_egl_headless({ type => 'vhost-user-gpu-pci' }); };
    like($@, qr/no DRM render node/, 'vhost-user VNC fails early without a render node');
    is(
        PVE::QemuServer::print_egl_headless({
            type => 'vhost-user-vga',
            rendernode => '/dev/dri/renderD129',
        }),
        'egl-headless,gl=core,rendernode=/dev/dri/renderD129',
        'vhost-user connects EGL to its configured render node',
    );
}
{
    my $cmd = [];
    my $flags = [];
    PVE::QemuServer::Memory::config({ memory => 'current=512' }, 8006, 1, 1, 0, 0, $cmd, $flags, 1);
    like(
        join(' ', @$cmd),
        qr/memory-backend-memfd,id=vgpu-mem,size=512M,share=on/,
        'all main RAM is shared using the parsed memory value',
    );
    is_deeply($flags, ['memory-backend=vgpu-mem'], 'machine selects the shared backend');
    for my $conf (
        { numa => 1, memory => 512 },
        { numa => 1, memory => 512, numa0 => 'cpus=0,memory=512' },
    ) {
        $cmd = [];
        $flags = [];
        PVE::QemuServer::Memory::config($conf, 8006, 1, 1, 0, 0, $cmd, $flags, 1);
        like(
            join(' ', @$cmd),
            qr/memory-backend-memfd,id=vgpu-mem0,size=512M,share=on/,
            'default and custom NUMA use shared RAM',
        );
        unlike(
            join(' ', @$cmd),
            qr/memory-backend-ram,/,
            'no private NUMA backend leaks into vhost-user RAM',
        );
    }
    eval { PVE::QemuServer::Memory::config({ memory => 2048 }, 8006, 1, 1, 1, 0, [], [], 1); };
    like($@, qr/Memory hotplug.*vhost-user/, 'unsupported memory hotplug is rejected');
    $cmd = [];
    $flags = [];
    PVE::QemuServer::Memory::config({ memory => 512 }, 8006, 1, 1, 0, 1, $cmd, $flags, 1);
    is_deeply($flags, ['memory-backend=virtiofs-mem'],
        'virtio-fs and GPU share one memory backend');
}
for my $type (
    qw(ati-vga virtio-gl virtio-gpu-gl-pci virtio-gpu-gl-device vhost-user-vga vhost-user-gpu-pci)
) {
    my @blockers =
        PVE::QemuMigrate::Helpers::check_non_migratable_resources({ vga => $type }, 1, 1);
    is_deeply(\@blockers, ['vga'], "$type blocks migration and RAM snapshots");
    eval { PVE::QemuMigrate::Helpers::check_non_migratable_resources({ vga => $type }, 1, 0); };
    like($@, qr/Cannot live-migrate/, 'state operations fail before allocating state storage');
    @blockers = PVE::QemuMigrate::Helpers::check_non_migratable_resources({ vga => $type }, 0, 1);
    is_deeply(\@blockers, [], 'disk-only operations remain available');
}
for my $type (
    qw(std bochs-display isa-vga secondary-vga qxl-pci virtio-gpu-pci virtio-gpu-device)
) {
    my @blockers =
        PVE::QemuMigrate::Helpers::check_non_migratable_resources({ vga => $type }, 1, 1);
    is_deeply(\@blockers, [], "$type keeps RAM state operations available");
}
{
    my $cluster = Test::MockModule->new('PVE::Cluster');
    $cluster->mock(get_nodelist => sub { return ['alpha']; });
    my @maps = map { Test::MockModule->new("PVE::Mapping::$_") } qw(PCI USB Dir);
    $_->mock(config => sub { return { ids => {} }; }) for @maps;
    for my $running (0, 1) {
        my $resources = PVE::QemuMigrate::Helpers::check_local_resources(
            { vga => 'vhost-user-gpu-pci' },
            $running,
            1,
        );
        is_deeply($resources, ['vga'], 'vhost-user socket remains a local resource');
    }
}
done_testing();
