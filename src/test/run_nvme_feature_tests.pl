#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;

use PVE::JSONSchema;
use PVE::QemuServer;
use PVE::QemuServer::Blockdev;
use PVE::QemuServer::Drive qw(parse_drive print_drive);
use PVE::QemuServer::DriveDevice qw(print_drivedevice_full);
use PVE::QemuServer::NVMe;

my $volume = 'local:8006/vm-8006-disk-0.raw';
my $schema = {
    type => 'object',
    additionalProperties => 0,
    properties => PVE::QemuServer::json_config_properties({}, 1),
};
my $parse = sub {
    my ($options, $id) = @_;
    return parse_drive($id // 'nvme0', "$volume,$options", 1);
};
my $reject = sub {
    my ($options) = @_;
    local $SIG{__WARN__} = sub { };
    ok(!$parse->($options), "reject invalid NVMe options: $options");
};

eval { PVE::JSONSchema::generate_typetext(PVE::QemuServer::NVMe::option_schema()); };
is($@, '', 'NVMe schema can generate CLI usage and packaged documentation');

for my $options (
    'cmb_size_mb=16,legacy-cmb=1,ocp=1',
    'nvme-paths=2,subsystem=1,subnqn=test',
    'nsid=256,uuid=12345678-1234-5678-9234-123456789abc,nguid=0123456789abcdef0123456789abcdef,eui64=0xffffffffffffffff',
    'nguid=01234567-89ab-cdef-0123-456789abcdef',
    'logical_block_size=4096,mssrl=256,mcl=512,msrc=0',
    'zoned=1,zoned-zone-size=134217728,zoned-zone-capacity=67108864,zoned-descr-ext-size=64,zoned-cross-read=1,zoned-max-active=8,zoned-max-open=4,zoned-zasl=7',
    'ms=8,mset=1,pi=1,pil=1,pif=0',
    'ms=16,pi=3,pif=2',
    'fdp=1,fdp-nrg=1,fdp-nruh=16,fdp-runs=100663296,fdp-ruhs=0;8-15',
    'fdp=1,fdp-nrg=2047',
    'fdp=1,fdp-nrg=2048,fdp-nruh=15',
    'fdp=1,fdp-nrg=32767,fdp-nruh=1',
    'sriov_max_vfs=2,sriov_vq_flexible=4,sriov_vi_flexible=2,sriov_max_vq_per_vf=2,sriov_max_vi_per_vf=1',
    'serial=' . ('x' x 20),
    'subsystem=1,serial=' . ('%41' x 20),
    'serial=Custom%20NVMe%2C%20disk%21',
    'model=Test%2CNVMe,firmware-version=V1%2C2',
) {
    my $drive = $parse->($options);
    ok($drive, "parse NVMe features: $options");
    my $printed = print_drive($drive, 1);
    is_deeply(parse_drive('nvme0', $printed, 1), $drive, 'feature configuration round trip');
    eval { PVE::JSONSchema::validate({ nvme0 => "$volume,$options" }, $schema); };
    is($@, '', 'feature parameters pass API schema validation');
}

for my $options (
    'nvme-controller=16',
    'cmb_size_mb=3',
    'cmb_size_mb=4095',
    'nvme-paths=0',
    'nvme-paths=9',
    'nsid=0',
    'nsid=257',
    'logical_block_size=1024',
    'uuid=not-a-uuid',
    'nguid=1234',
    'eui64=18446744073709551615',
    'subnqn=bad%2Cname',
    'serial=' . ('x' x 21),
    'subsystem=1,serial=' . ('x' x 21),
    'serial=test%00tail',
    'serial=test%0Atail',
    'serial=%e4%b8%ad',
    'model=%00',
    'model=' . ('x' x 41),
    'firmware-version=123456789',
    'ms=7,pi=1',
    'ms=15,pi=3,pif=2',
    'ms=16,pif=1',
    'mset=1',
    'pil=1',
    'zoned-zone-size=1048576',
    'zoned=1,zoned-zone-capacity=268435456',
    'zoned=1,zoned-zone-size=1048577',
    'zoned=1,zoned-descr-ext-size=63',
    'zoned=1,zoned-descr-ext-size=16384',
    'zoned=1,zoned-max-active=1,zoned-max-open=2',
    'fdp-nruh=16',
    'fdp=1,fdp-nruh=0',
    'fdp=1,fdp-nrg=65535',
    'fdp=1,fdp-nrg=2048',
    'fdp=1,fdp-nrg=512,fdp-nruh=64',
    'fdp=1,fdp-nrg=32768,fdp-nruh=1',
    'fdp=1,fdp-runs=513',
    'fdp-ruhs=1;1',
    'fdp-ruhs=8-1',
    'fdp-ruhs=0;127',
    'sriov_max_vfs=1,cmb_size_mb=1',
    'sriov_max_vfs=1,nvme-paths=2',
    'sriov_max_vfs=2,sriov_vq_flexible=3',
    'sriov_max_vfs=2,sriov_vi_flexible=1',
    'sriov_max_vfs=1,sriov_vq_flexible=63',
    'sriov_max_vfs=1,sriov_vi_flexible=65',
    'sriov_max_vfs=1,sriov_max_vq_per_vf=1',
    'sriov_max_vfs=1,sriov_max_vq_per_vf=3',
    'sriov_max_vfs=1,sriov_max_vi_per_vf=2',
    'sriov_vq_flexible=2',
) {
    $reject->($options);
}

my $legacy = { nvme0 => "$volume,cmb_size_mb=16,legacy-cmb=1,ocp=1" };
my $decimal = $parse->('mdts=08,max_ioqpairs=010,msix_qsize=011,nsid=010,ms=08');
for my $entry (
    ['mdts', 8], ['max_ioqpairs', 10], ['msix_qsize', 11], ['nsid', 10], ['ms', 8],
) {
    is($decimal->{ $entry->[0] }, $entry->[1], "normalize decimal NVMe $entry->[0]");
}
like(
    PVE::QemuServer::NVMe::controller_options($decimal),
    qr/max_ioqpairs=10,msix_qsize=11,mdts=8(?:,|$)/,
    'QEMU controller integers remain decimal',
);
like(
    PVE::QemuServer::NVMe::namespace_device({}, 8006, $decimal, 'x86_64'),
    qr/nsid=10,.*ms=8,/,
    'QEMU namespace integers remain decimal',
);
eval { PVE::QemuServer::NVMe::topology({ nvme0 => "$volume,nvme-controller=00" }); };
is($@, '', 'zero-prefixed owner indices refer to the configured controller');
eval {
    PVE::QemuServer::NVMe::topology({
        nvme0 => "$volume,nsid=01",
        nvme1 => "$volume,nvme-controller=00,nsid=1",
    });
};
like($@, qr/duplicate NVMe namespace identifier/, 'decimal NSID aliases cannot bypass uniqueness');
my $decimal_fdp = $parse->('fdp=1,fdp-nrg=08,fdp-nruh=010,fdp-runs=0100663296');
is($decimal_fdp->{'fdp-nrg'}, 8, 'FDP reclaim group count remains decimal');
is($decimal_fdp->{'fdp-nruh'}, 10, 'FDP reclaim handle count remains decimal');
is($decimal_fdp->{'fdp-runs'}, 100663296, 'FDP reclaim unit size remains decimal');
is(
    $parse->('eui64=0x0011223344556677')->{eui64},
    '0x0011223344556677',
    'namespace hexadecimal identity retains its leading zeros',
);
is($parse->('mcl=04294967295')->{mcl}, 4294967295, 'large decimal limits retain their full value');
is(
    $parse->('zoned=1,zoned-zone-size=09007199254740480')->{'zoned-zone-size'},
    9007199254740480,
    'large decimal zone sizes retain integer precision',
);
is_deeply(
    [PVE::QemuServer::NVMe::controller_devices($legacy, 8006, 'x86_64', 'pc')],
    [],
    'ordinary controller features retain the legacy topology',
);
my $device = print_drivedevice_full(
    {},
    $legacy,
    8006,
    parse_drive('nvme0', $legacy->{nvme0}),
    'x86_64',
    'pc-i440fx-11.1',
);
like($device, qr/^nvme,id=nvme0,drive=drive-nvme0/,
    'legacy disk still uses the original device ID');
like($device, qr/cmb_size_mb=16,legacy-cmb=on,ocp=on/, 'CMB and OCP are controller properties');
my $shared_storage = parse_drive('nvme0', "$volume,shared=1");
is($shared_storage->{shared}, 1, 'legacy shared storage flag retains its meaning');
ok(
    !PVE::QemuServer::NVMe::has_explicit_namespace(
        { nvme0 => "$volume,shared=1" },
        $shared_storage,
    ),
    'shared storage flag does not enable NVMe namespace sharing',
);
my $private_shared_storage = $parse->('shared=1,nvme-shared=0');
like(
    PVE::QemuServer::NVMe::namespace_device({}, 8006, $private_shared_storage, 'x86_64'),
    qr/shared=off/,
    'namespace sharing is independent of shared storage',
);
like(
    PVE::QemuServer::NVMe::controller_options(
        $parse->('model=Test%2CNVMe,firmware-version=V1%2C2')
    ),
    qr/model=Test,,NVMe,firmware-version=V1,,2/,
    'URL-encoded identity values cannot inject QEMU options',
);

my $multi = {
    nvme7 => "$volume,nvme-paths=2",
    nvme0 => "$volume,nvme-controller=7,nsid=10,nvme-shared=0",
    nvme1 => "$volume,nvme-controller=7,detached=1",
};
my $groups = PVE::QemuServer::NVMe::topology($multi);
is(scalar(keys %$groups), 1, 'three namespace volumes share one controller group');
my @devices = PVE::QemuServer::NVMe::controller_devices($multi, 8006, 'x86_64', 'pc');
is(scalar(@devices), 6, 'two paths create one subsystem and two controllers');
like(
    $devices[3],
    qr/id=nvme-ctrl-nvme7,.*addr=0xb,multifunction=on/,
    'primary path keeps its stable PCI slot',
);
like(
    $devices[5],
    qr/id=nvme-ctrl-nvme7-path1,.*addr=0xb\.1/,
    'secondary path uses a free function in the same slot',
);
my $namespace = parse_drive('nvme0', $multi->{nvme0});
$namespace->{bootindex} = 100;
my $ns_device = print_drivedevice_full({}, $multi, 8006, $namespace, 'x86_64', 'pc-i440fx-11.1');
like(
    $ns_device,
    qr/^nvme-ns,id=nvme0,drive=drive-nvme0,bus=nvme-ctrl-nvme7,nsid=10,uuid=/,
    'namespace selects the correct controller explicitly',
);
like($ns_device, qr/shared=off,bootindex=100/, 'private namespace can remain bootable');
unlike(
    $ns_device,
    qr/serial=|use-intel-id=/,
    'controller-only properties do not leak to namespaces',
);
like(
    PVE::QemuServer::NVMe::namespace_device(
        { nvme0 => "$volume,logical_block_size=4096" },
        8006,
        $parse->('logical_block_size=4096'),
        'x86_64',
    ),
    qr/logical_block_size=4096,physical_block_size=4096/,
    '4 KiB logical blocks have a compatible physical block size',
);
is(
    print_drivedevice_full({}, $multi, 8006, $namespace, 'x86_64', 'pc-i440fx-11.1'),
    $ns_device,
    'generated namespace UUID is stable',
);
my $detached = parse_drive('nvme1', $multi->{nvme1});
$detached->{bootindex} = 101;
unlike(
    print_drivedevice_full({}, $multi, 8006, $detached, 'x86_64', 'pc-i440fx-11.1'),
    qr/bootindex=/,
    'detached namespaces have no firmware boot index',
);
my $bootconf = { %$multi, boot => 'order=nvme1;nvme0' };
is_deeply(
    PVE::QemuServer::device_bootorder($bootconf),
    { nvme0 => 100 },
    'explicit boot order skips detached namespaces',
);
is_deeply(
    PVE::QemuServer::get_default_bootdevices($bootconf),
    ['nvme0'],
    'default boot order skips detached namespaces',
);
is_deeply(
    PVE::QemuServer::bootorder_from_legacy({ %$multi, bootdisk => 'nvme1' }, { legacy => 'c' }),
    {},
    'legacy boot order skips detached namespaces',
);

my $template = { %$multi, template => 1 };
is_deeply(
    [PVE::QemuServer::NVMe::controller_devices($template, 8006, 'x86_64', 'pc')],
    [],
    'template backups do not create shared controller state',
);
like(
    print_drivedevice_full({}, $template, 8006, $namespace, 'x86_64', 'pc-i440fx-11.1'),
    qr/^virtio-blk-pci,id=nvme0,drive=drive-nvme0/,
    'template backup exposes the complete read-only backing image',
);

for my $path ('/machine/peripheral/nvme0', '/machine/peripheral/nvme0/virtio-backend', 'nvme0') {
    is(
        PVE::QemuServer::Blockdev::qdev_id_to_drive_id($path),
        'nvme0',
        'backup maps native and template QOM paths to their volume',
    );
}

for my $case (
    [{ nvme1 => "$volume,nvme-controller=0" }, qr/does not exist/, 'missing owner'],
    [
        { nvme0 => "$volume,nvme-controller=1", nvme1 => "$volume,nvme-controller=0" },
        qr/cannot be chained/,
        'controller reference cycle',
    ],
    [
        { nvme0 => $volume, nvme1 => "$volume,nvme-controller=0,mdts=8" },
        qr/configure controller options on nvme0/,
        'controller parameters on child',
    ],
    [
        { nvme0 => "$volume,nsid=1", nvme1 => "$volume,nvme-controller=0,nsid=1" },
        qr/duplicate NVMe namespace/,
        'duplicate namespace ID',
    ],
    [{ nvme0 => "$volume,zoned-zasl=8,mdts=7" }, qr/Append size/, 'append limit exceeds MDTS'],
    [{ nvme0 => "$volume,fdp=1,zoned=1" }, qr/cannot use an FDP/, 'ZNS combined with FDP'],
    [{ nvme0 => "$volume,fdp-ruhs=0" }, qr/require fdp=1/, 'handles without FDP'],
    [
        { nvme0 => "$volume,fdp=1,fdp-nruh=8,fdp-ruhs=8" },
        qr/exceeds the subsystem/,
        'handle outside pool',
    ],
    [
        { nvme0 => "$volume,fdp=1", nvme1 => "$volume,nvme-controller=0,ms=8" },
        qr/same LBA and metadata/,
        'incompatible FDP namespace formats',
    ],
) {
    my ($conf, $error, $description) = @$case;
    eval { PVE::QemuServer::NVMe::topology($conf); };
    like($@, $error, "reject $description");
}

for my $runs (512, 4096, 4608, 8192) {
    for my $automatic (0, 1) {
        my $conf = {
            nvme0 => "$volume,fdp=1,fdp-nruh=2,fdp-ruhs=0,fdp-runs=$runs",
            nvme1 => "$volume,nvme-controller=0,logical_block_size=4096"
                . ($automatic ? '' : ',fdp-ruhs=1'),
        };
        eval { PVE::QemuServer::NVMe::topology($conf); };
        if ($runs % 4096) {
            like(
                $@,
                qr/FDP reclaim unit size must be aligned/,
                "reject FDP unit misaligned to child LBA (runs=$runs, automatic=$automatic)",
            );
        } else {
            is(
                $@,
                '',
                "accept FDP unit aligned to both LBA sizes (runs=$runs, automatic=$automatic)",
            );
        }
    }
}

for my $case (
    ['disjoint LBA formats', 2, ['fdp-ruhs=0', 'fdp-ruhs=1,logical_block_size=4096'], 1],
    ['disjoint metadata formats', 2, ['fdp-ruhs=0,ms=8', 'fdp-ruhs=1,ms=16'], 1],
    [
        'disjoint handle ranges',
        4,
        ['fdp-ruhs=0-1,ms=8', 'fdp-ruhs=2-3,logical_block_size=4096,ms=16'],
        1,
    ],
    ['automatic owner and private child', 2, ['', 'fdp-ruhs=0,logical_block_size=4096'], 1],
    [
        'private owner and automatic child',
        2,
        ['fdp-ruhs=0,ms=8', 'logical_block_size=4096,ms=16'],
        1,
    ],
    [
        'automatic namespaces and private other format',
        2,
        ['', 'fdp-ruhs=0,logical_block_size=4096', ''],
        1,
    ],
    [
        'private owner and shared child format',
        2,
        ['fdp-ruhs=0', 'fdp-ruhs=1,ms=16', 'fdp-ruhs=1,ms=16'],
        1,
    ],
    ['matching manual formats', 1, ['fdp-ruhs=0,ms=16', 'fdp-ruhs=0,ms=16'], 1],
    [
        'equivalent implicit and explicit formats',
        2,
        ['fdp-ruhs=0', 'fdp-ruhs=0,logical_block_size=512,ms=0', ''],
        1,
    ],
    [
        'overlapping manual LBA formats',
        1,
        ['fdp-ruhs=0', 'fdp-ruhs=0,logical_block_size=4096'],
        0,
    ],
    ['overlapping manual metadata formats', 1, ['fdp-ruhs=0,ms=8', 'fdp-ruhs=0,ms=16'], 0],
    [
        'overlapping handle ranges',
        3,
        ['fdp-ruhs=0-1', 'fdp-ruhs=1-2,logical_block_size=4096'],
        0,
    ],
    [
        'incompatible children on a shared handle',
        2,
        ['fdp-ruhs=0', 'fdp-ruhs=1,ms=8', 'fdp-ruhs=1,ms=16'],
        0,
    ],
    ['incompatible automatic LBA formats', 2, ['', 'logical_block_size=4096'], 0],
    ['incompatible automatic metadata formats', 2, ['ms=8', 'ms=16'], 0],
    ['incompatible automatic children', 2, ['fdp-ruhs=0', 'ms=8', 'ms=16'], 0],
) {
    my ($name, $handles, $options, $valid) = @$case;
    my $conf = {};
    for my $index (0 .. $#$options) {
        my $controller = $index ? 'nvme-controller=0' : "fdp=1,fdp-nruh=$handles";
        $conf->{"nvme$index"} = join(',', $volume, $controller, grep { length } $options->[$index]);
    }
    eval { PVE::QemuServer::NVMe::topology($conf); };
    if ($valid) {
        is($@, '', "accept FDP $name");
    } else {
        like($@, qr/same LBA and metadata/, "reject FDP $name");
    }
}

eval {
    PVE::QemuServer::NVMe::validate_update(
        { nvme0 => $volume, nvme1 => "$volume,nvme-controller=0" },
        {},
        ['nvme0'],
    );
};
like($@, qr/does not exist/, 'reject deleting an owner while a namespace depends on it');
eval {
    PVE::QemuServer::NVMe::validate_update(
        { nvme0 => $volume, nvme1 => "$volume,nvme-controller=0" },
        {},
        ['nvme0', 'nvme1'],
    );
};
is($@, '', 'owner and namespaces can be removed in one request');
eval {
    PVE::QemuServer::NVMe::validate_update(
        {}, { nvme1 => "$volume,nvme-controller=0", nvme0 => $volume }, [],
    );
};
is($@, '', 'owner and namespaces can be created in one request regardless of parameter order');
eval {
    PVE::QemuServer::NVMe::validate_update(
        { pending => { nvme0 => $volume } },
        { nvme1 => "$volume,nvme-controller=0" },
        [],
    );
};
is($@, '', 'namespace can use an owner pending creation');

for my $pending_delete ('nvme0', '!nvme0') {
    eval {
        PVE::QemuServer::NVMe::validate_update(
            { nvme0 => $volume, pending => { delete => $pending_delete } },
            { nvme1 => "$volume,nvme-controller=0" },
            [],
        );
    };
    like($@, qr/does not exist/, "reject referencing an owner pending deletion: $pending_delete");
    eval {
        PVE::QemuServer::NVMe::validate_update(
            { nvme0 => $volume, pending => { delete => $pending_delete } },
            { nvme0 => $volume, nvme1 => "$volume,nvme-controller=0" },
            [],
        );
    };
    is($@, '', "explicitly restoring a pending owner permits its namespace: $pending_delete");
}
for my $pending_delete ('nvme1', '!nvme1') {
    eval {
        PVE::QemuServer::NVMe::validate_update(
            {
                nvme0 => $volume,
                nvme1 => "$volume,nvme-controller=0,nsid=2",
                pending => { delete => $pending_delete },
            },
            { nvme2 => "$volume,nvme-controller=0,nsid=2" },
            [],
        );
    };
    is($@, '', "a namespace ID pending deletion can be reused: $pending_delete");
}

my $sriov = { nvme9 => "$volume,sriov_max_vfs=1" };
for my $conf (
    { nvme0 => "$volume,fdp=1", nvme1 => "$volume,nvme-controller=0,fdp-ruhs=0" },
    { nvme0 => "$volume,fdp=1,fdp-nruh=1,fdp-ruhs=0" },
    {
        nvme0 => "$volume,fdp=1,fdp-nruh=2,fdp-ruhs=0",
        nvme1 => "$volume,nvme-controller=0",
        nvme2 => "$volume,nvme-controller=0",
    },
) {
    eval { PVE::QemuServer::NVMe::topology($conf); };
    is($@, '', 'FDP reserves explicit handles and shares a remaining automatic handle');
}
for my $conf (
    {
        nvme0 => "$volume,fdp=1,fdp-nruh=1,fdp-ruhs=0",
        nvme1 => "$volume,nvme-controller=0",
    },
    {
        nvme0 => "$volume,fdp=1,fdp-nruh=2",
        nvme1 => "$volume,nvme-controller=0,fdp-ruhs=0;1",
    },
) {
    eval { PVE::QemuServer::NVMe::topology($conf); };
    like($@, qr/automatic placement requires an unused/, 'FDP rejects exhausted automatic handles');
}
like(
    PVE::QemuServer::NVMe::namespace_device(
        {}, 8006, $parse->('fdp=1,fdp-ruhs=00;08-010'), 'x86_64',
    ),
    qr/fdp\.ruhs=0;8-10,/,
    'FDP handle numbers remain decimal when passed to QEMU',
);

@devices = PVE::QemuServer::NVMe::controller_devices($sriov, 8006, 'x86_64', 'pc-q35-11.1');
like($devices[1], qr/nvme-port8,.*addr=0x8\.0,/, 'sparse SR-IOV ports include function zero');
like($devices[3], qr/nvme-port9,.*addr=0x8\.1,/, 'SR-IOV port has a dedicated root function');
like($devices[-1], qr/bus=nvme-port9,addr=0x0,/, 'VF routing is isolated from other NVMe devices');
like(
    $devices[-1],
    qr/sriov_vq_flexible=2,sriov_vi_flexible=1/,
    'SR-IOV receives usable automatic resources',
);
eval { PVE::QemuServer::NVMe::controller_devices($sriov, 8006, 'x86_64', 'pc-i440fx-11.1'); };
like($@, qr/requires Q35 or aarch64/, 'SR-IOV rejects a machine without PCIe');

my $arm_sriov = { map { ("nvme$_" => "$volume,sriov_max_vfs=1") } 0 .. 15 };
@devices = PVE::QemuServer::NVMe::controller_devices($arm_sriov, 8006, 'aarch64', 'virt');
like(
    $devices[1],
    qr/^pcie-root-port,id=nvme-root,bus=pcie\.0,addr=0x1e\.1,multifunction=on,/,
    'ARM uses a free function on the first bridge root slot for the SR-IOV switch',
);
like(
    $devices[3],
    qr/^x3130-upstream,id=nvme-switch,bus=nvme-root,/,
    'ARM downstream ports use a dedicated PCIe switch',
);

for my $index (0 .. 15) {
    my @ports = grep { /^xio3130-downstream,id=nvme-port$index,/ } @devices;
    my $addr = sprintf('0x%x', $index);
    is(scalar(@ports), 1, "ARM controller $index has exactly one downstream port");
    like(
        $ports[0],
        qr/bus=nvme-switch,addr=$addr,/,
        "ARM controller $index has a unique switch slot",
    );
}
is(scalar(grep { /,bus=pcie\.0,/ } @devices), 1, 'ARM SR-IOV occupies only its reserved root slot');
my $bridges = PVE::QemuServer::PCI::get_pci_bridges(
    $arm_sriov, 'aarch64', 0, 0, sub { 1 }, { 1 => 1 },
);
like(
    $bridges->[1],
    qr/^pci-bridge,id=pci\.1,.*addr=0x1e,multifunction=on$/,
    'ARM bridge function zero advertises its additional SR-IOV root port function',
);
unlike(
    join(' ', $bridges->@[2 .. $#$bridges]),
    qr/multifunction=on/,
    'other bridge functions are unchanged',
);
unlike(
    join(' ', @devices),
    qr/bus=pcie\.0,addr=0x[78](?:[.,])/,
    'ARM SR-IOV leaves the SATA and Guest Agent root slots untouched',
);
@devices = PVE::QemuServer::NVMe::controller_devices($sriov, 8006, 'aarch64', 'virt');
unlike(
    join(' ', @devices),
    qr/id=nvme-port8,/,
    'sparse ARM controllers do not require a function-zero anchor',
);

for my $entry (
    ['ms=8', 519, qr/at least one complete logical block/],
    ['zoned=1', 128 * 1024**2 - 1, qr/complete zone/],
    ['zoned=1,ms=8', 128 * 1024**2, qr/complete zone/],
) {
    eval { PVE::QemuServer::NVMe::validate_size($parse->($entry->[0]), $entry->[1]); };
    like($@, $entry->[2], 'validate actual capacity including metadata');
}
eval { PVE::QemuServer::NVMe::validate_size($parse->('zoned=1,ms=8'), 136314880); };
is($@, '', 'valid image contains complete zones and metadata');
eval { PVE::QemuServer::NVMe::assert_resize_allowed($parse->('ms=8,pi=1')); };
like(
    $@,
    qr/cannot resize an NVMe namespace with metadata/,
    'resize cannot move the metadata offset without converting the image',
);
eval { PVE::QemuServer::NVMe::assert_resize_allowed($parse->('logical_block_size=4096')); };
is($@, '', 'ordinary namespaces retain offline resize support');

my $tools = Test::MockModule->new('PVE::Tools');
my $probe = 0;
$tools->mock(
    run_command => sub {
        my ($command, %options) = @_;
        is_deeply(
            [@$command[1 .. $#$command]],
            ['-device', 'nvme,help'],
            'capability probe contains no identity values',
        );
        $probe++;
        $options{outfunc}->('  model=<str>');
        $options{outfunc}->('  firmware-version=<str>');
    },
);
PVE::QemuServer::NVMe::assert_model_support($parse->('model=Test,firmware-version=V1'), 'x86_64');
is($probe, 1, 'model and firmware use one capability probe');
$tools->mock(run_command => sub { });
eval { PVE::QemuServer::NVMe::assert_model_support($parse->('model=Test'), 'x86_64'); };
like(
    $@,
    qr/requires a QEMU build with nvme.model support/,
    'unsupported emulator reports an actionable error',
);

my $qemu = Test::MockModule->new('PVE::QemuServer');
$qemu->mock(vm_deviceplug => sub { die "unexpected device plug\n"; });
for my $options (
    'ocp=1',
    'cmb_size_mb=16',
    'nsid=2',
    'nvme-paths=2',
    'zoned=1',
    'ms=8,pi=1',
    'fdp=1',
    'sriov_max_vfs=1',
    'model=Test',
) {
    eval {
        PVE::QemuServer::vmconfig_update_disk(
            {},
            { nvme0 => $volume },
            1,
            8006,
            'nvme0',
            "$volume,$options",
            'x86_64',
            'pc',
        );
    };
    is($@, "skip\n", "NVMe feature changes wait for shutdown: $options");
}

done_testing();
