package PVE::QemuServer::NVMe;

use strict;
use warnings;

use Digest::SHA qw(sha1_hex);
use JSON qw(decode_json);
use URI::Escape qw(uri_escape uri_unescape);

use PVE::AbstractConfig;
use PVE::JSONSchema;
use PVE::Storage;
use PVE::Storage::Common;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Machine;
use PVE::QemuServer::PCI qw(print_pci_addr);
use PVE::Tools;

# Keep controller settings on the disk which owns the controller. Other disks
# can select that disk with nvme-controller to become additional namespaces.
my @controller_options = qw(
    max_ioqpairs msix_qsize mdts use-intel-id model firmware-version
    cmb_size_mb legacy-cmb ocp zoned-zasl
    sriov_max_vfs sriov_vq_flexible sriov_vi_flexible
    sriov_max_vi_per_vf sriov_max_vq_per_vf
);
my @namespace_options = qw(
    nsid uuid nguid eui64 logical_block_size mssrl mcl msrc
    zoned zoned-zone-size zoned-zone-capacity zoned-descr-ext-size
    zoned-cross-read zoned-max-active zoned-max-open
    ms mset pi pil pif nvme-shared detached fdp-ruhs
);
my @subsystem_options = qw(subsystem subnqn nvme-paths fdp fdp-nrg fdp-nruh fdp-runs);

sub controller_option_names {
    return ('serial', 'nvme-slot', @controller_options, @subsystem_options);
}
sub option_names { return ('nvme-controller', controller_option_names(), @namespace_options); }

my %qemu_names = (
    'zoned-zasl' => 'zoned.zasl',
    'zoned-zone-size' => 'zoned.zone_size',
    'zoned-zone-capacity' => 'zoned.zone_capacity',
    'zoned-descr-ext-size' => 'zoned.descr_ext_size',
    'zoned-cross-read' => 'zoned.cross_read',
    'zoned-max-active' => 'zoned.max_active',
    'zoned-max-open' => 'zoned.max_open',
    'fdp-nrg' => 'fdp.nrg',
    'fdp-nruh' => 'fdp.nruh',
    'fdp-runs' => 'fdp.runs',
    'fdp-ruhs' => 'fdp.ruhs',
    'nvme-shared' => 'shared',
);
my %boolean = map { $_ => 1 } qw(
    use-intel-id legacy-cmb ocp zoned zoned-cross-read nvme-shared detached fdp
);

sub option_schema {
    my $schema = {};
    for my $entry (
        [
            'nvme-controller',
            0,
            15,
            'Disk index of the owning NVMe controller. Omit for a dedicated controller.',
        ],
        [
            'nvme-slot',
            0,
            2,
            'Fixed controller slot on a custom machine. Defaults to the controller disk index; ignored on other machines.',
        ],
        ['nvme-paths', 1, 8, 'Number of controller paths to the same subsystem.'],
        ['max_ioqpairs', 1, 65535, 'Maximum number of I/O queue pairs.'],
        ['msix_qsize', 1, 2048, 'Number of MSI-X vectors.'],
        ['mdts', 1, 9, 'Maximum transfer size exponent, in 4 KiB units.'],
        ['cmb_size_mb', 0, 4096, 'Controller Memory Buffer size in MiB; zero disables it.'],
        ['zoned-zasl', 0, 9, 'Zone Append transfer size exponent; zero inherits MDTS.'],
        ['nsid', 1, 256, 'Namespace identifier; defaults to the disk index plus one.'],
        [
            'mssrl',
            0,
            65535,
            'Maximum single source range length for Simple Copy, in logical blocks.',
        ],
        ['mcl', 0, 4294967295, 'Maximum total Simple Copy length, in logical blocks.'],
        ['msrc', 0, 255, 'Maximum Simple Copy source range count minus one.'],
        [
            'ms',
            0,
            65535,
            'Metadata bytes per logical block. Metadata occupies space in the backing image.',
        ],
        ['mset', 0, 1, 'Transfer metadata separately (0) or as extended LBAs (1).'],
        ['pi', 0, 3, 'Protection information type; zero disables protection.'],
        ['pil', 0, 1, 'Protection information at the end (0) or beginning (1) of metadata.'],
        ['zoned-zone-size', 512, 9007199254740991, 'ZNS zone size in bytes.'],
        [
            'zoned-zone-capacity',
            0,
            9007199254740991,
            'ZNS zone capacity in bytes; zero uses the zone size.',
        ],
        [
            'zoned-descr-ext-size',
            0,
            16320,
            'Zone descriptor extension bytes, a multiple of 64.',
        ],
        ['zoned-max-active', 0, 4294967295, 'Maximum active zones; zero is unlimited.'],
        [
            'zoned-max-open',
            0,
            4294967295,
            'Maximum open zones; zero follows the active limit or is unlimited.',
        ],
        ['fdp-nrg', 1, 65535, 'Number of FDP reclaim groups.'],
        ['fdp-nruh', 1, 127, 'Number of FDP reclaim unit handles.'],
        ['fdp-runs', 512, 9007199254740991, 'FDP reclaim unit nominal size in bytes.'],
        [
            'sriov_max_vfs',
            0,
            127,
            'Maximum virtual functions; nonzero enables experimental SR-IOV. Requires Q35 or aarch64.',
        ],
        [
            'sriov_vq_flexible',
            0,
            65535,
            'Flexible queue resources available to virtual functions.',
        ],
        [
            'sriov_vi_flexible',
            0,
            2047,
            'Flexible interrupt resources available to virtual functions.',
        ],
        [
            'sriov_max_vq_per_vf',
            0,
            65535,
            'Maximum queues per VF; zero divides the flexible pool equally.',
        ],
        [
            'sriov_max_vi_per_vf',
            0,
            2047,
            'Maximum interrupts per VF; zero divides the flexible pool equally.',
        ],
    ) {
        my ($name, $min, $max, $description) = @$entry;
        $schema->{$name} = {
            type => 'integer',
            minimum => $min,
            maximum => $max,
            description => $description,
            optional => 1,
        };
    }
    for my $entry (
        ['use-intel-id', 1, 'Use the legacy Intel PCI vendor and device IDs.'],
        ['legacy-cmb', 0, 'Use NVMe 1.3 Controller Memory Buffer behavior.'],
        ['ocp', 0, 'Expose the OCP extended SMART/Health log.'],
        ['subsystem', 0, 'Create an NVM subsystem for shared or detached namespaces.'],
        [
            'nvme-shared',
            1,
            'Attach this namespace to every controller path in its subsystem. Independent of the shared storage flag.',
        ],
        ['detached', 0, 'Leave the namespace initially detached; attach it from the guest.'],
        ['zoned', 0, 'Expose a Zoned Namespace. Zone state is reset on cold starts.'],
        ['zoned-cross-read', 0, 'Allow reads to cross zone boundaries.'],
        ['fdp', 0, 'Enable Flexible Data Placement on the controller subsystem.'],
    ) {
        my ($name, $default, $description) = @$entry;
        $schema->{$name} = {
            type => 'boolean',
            default => $default,
            description => $description,
            optional => 1,
        };
    }
    $schema->{logical_block_size} = {
        type => 'integer',
        enum => [512, 4096],
        optional => 1,
        description => 'Logical block size in bytes. Changing it reinterprets existing data.',
    };
    $schema->{pif} = {
        type => 'integer',
        enum => [0, 2],
        optional => 1,
        description =>
            'Protection guard format: 0 for 16-bit, 2 for 64-bit; 32-bit guards are unsupported.',
    };
    for my $entry (
        [
            'model',
            'urlencoded',
            'Reported controller model, at most 40 printable ASCII bytes after URL decoding. Requires QEMU support.',
        ],
        [
            'firmware-version',
            'urlencoded',
            'Reported firmware version, at most 8 printable ASCII bytes after URL decoding. Requires QEMU support.',
        ],
        [
            'uuid',
            undef,
            'Namespace UUID, or auto for a new random value each start. Omit for a stable generated UUID.',
        ],
        [
            'nguid',
            undef,
            '32 hexadecimal namespace identifier digits, with optional hyphens between bytes, or auto for a random value each start.',
        ],
        ['eui64', undef, 'Namespace EUI-64, as 16 hexadecimal digits prefixed by 0x.'],
        ['subnqn', undef, 'Subsystem NQN suffix; QEMU prepends nqn.2019-08.org.qemu:.'],
        [
            'fdp-ruhs',
            undef,
            'FDP handle list, using semicolons and inclusive ranges, e.g. 0;8-15.',
        ],
    ) {
        my ($name, $format, $description) = @$entry;
        $schema->{$name} = {
            type => 'string',
            format_description => $name,
            optional => 1,
            description => $description,
        };
        $schema->{$name}->{format} = $format if $format;
    }
    $schema->{uuid}->{pattern} = '^(?:auto|[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12})$';
    $schema->{nguid}->{pattern} = '^(?:auto|[a-fA-F0-9]{2}(?:-?[a-fA-F0-9]{2}){15})$';
    $schema->{eui64}->{pattern} = '^0x[a-fA-F0-9]{16}$';
    $schema->{subnqn}->{pattern} = '^[a-zA-Z0-9_.:-]{1,200}$';
    $schema->{'fdp-ruhs'}->{pattern} = '^\d+(?:-\d+)?(?:;\d+(?:-\d+)?)*$';
    return $schema;
}

my @integer_options = do {
    my $schema = option_schema();
    grep { $schema->{$_}->{type} eq 'integer' } keys %$schema;
};

sub validate_options {
    my ($drive) = @_;

    # Property strings retain leading zeros, while QEMU interprets them as octal.
    # Normalize decimal integers before using them as IDs or device properties.
    $drive->{$_} = 0 + $drive->{$_} for grep { defined($drive->{$_}) } @integer_options;

    my $cmb = $drive->{cmb_size_mb} // 0;
    die "NVMe CMB size must be a power of two in MiB\n" if $cmb && ($cmb & ($cmb - 1));

    for my $entry (['serial', 20], ['model', 40], ['firmware-version', 8]) {
        my ($name, $max) = @$entry;
        next if !defined($drive->{$name});
        my $value = uri_unescape($drive->{$name});
        die "NVMe $name must contain 1 to $max printable ASCII bytes\n"
            if $value !~ m/^[\x20-\x7e]{1,$max}$/;
    }
    my $metadata = $drive->{ms} // 0;
    my $pi = $drive->{pi} // 0;
    my $guard = $drive->{pif} // 0;
    die "NVMe protection information requires at least "
        . ($guard == 2 ? 16 : 8)
        . " metadata bytes\n"
        if $pi && $metadata < ($guard == 2 ? 16 : 8);
    die "NVMe 64-bit guards require at least 16 metadata bytes\n" if $guard == 2 && $metadata < 16;
    die "NVMe extended LBAs require nonzero metadata\n" if $drive->{mset} && !$metadata;
    die "NVMe protection information placement requires pi\n" if $drive->{pil} && !$pi;

    my $block = $drive->{logical_block_size} // 512;
    my $zone_size = $drive->{'zoned-zone-size'} // 128 * 1024**2;
    my $zone_cap = $drive->{'zoned-zone-capacity'} || $zone_size;
    if ($drive->{zoned}) {
        die "NVMe ZNS zone size and capacity must be aligned to the logical block size\n"
            if $zone_size % $block || $zone_cap % $block;
        die "NVMe ZNS zone capacity exceeds zone size\n" if $zone_cap > $zone_size;
        die "NVMe ZNS descriptor extension size must be a multiple of 64 bytes\n"
            if ($drive->{'zoned-descr-ext-size'} // 0) % 64;
        die "NVMe ZNS open zone limit exceeds active zone limit\n"
            if $drive->{'zoned-max-active'}
            && ($drive->{'zoned-max-open'} // 0) > $drive->{'zoned-max-active'};
    } elsif (grep { $drive->{$_} }
        qw(zoned-zone-size zoned-zone-capacity zoned-descr-ext-size zoned-cross-read zoned-max-active zoned-max-open)
    ) {
        die "NVMe zone settings require zoned=1\n";
    }

    if ($drive->{fdp}) {
        my $groups = $drive->{'fdp-nrg'} // 1;
        my $handles = $drive->{'fdp-nruh'} // 16;
        my $rgif = 0;
        # QEMU omits the reclaim-group field only for a single group.
        my $value = $groups == 1 ? 0 : $groups;
        $rgif++, $value >>= 1 while $value;
        die "NVMe FDP reclaim groups and handles exceed the 16-bit placement identifier\n"
            if (65535 >> $rgif) < $handles;
        die "NVMe FDP reclaim unit size must be aligned to the logical block size\n"
            if ($drive->{'fdp-runs'} // 96 * 1024**2) % $block;
    } elsif (grep { defined($drive->{$_}) } qw(fdp-nrg fdp-nruh fdp-runs)) {
        die "NVMe FDP subsystem settings require fdp=1\n";
    }
    if (defined($drive->{'fdp-ruhs'})) {
        my %seen;
        my $count = 0;
        for my $range (split(';', $drive->{'fdp-ruhs'})) {
            my ($first, $last) = split('-', $range);
            $last //= $first;
            die "invalid NVMe FDP handle range\n" if $last < $first || $last > 126;
            for my $handle ($first .. $last) {
                die "duplicate NVMe FDP handle\n" if $seen{$handle}++;
                $count++;
            }
        }
    }

    my $vfs = $drive->{sriov_max_vfs} // 0;
    if ($vfs) {
        die "NVMe SR-IOV cannot use a Controller Memory Buffer\n" if $drive->{cmb_size_mb};
        my $queues = $drive->{sriov_vq_flexible} // (2 * $vfs);
        my $interrupts = $drive->{sriov_vi_flexible} // $vfs;
        die "NVMe SR-IOV requires one controller path\n" if ($drive->{'nvme-paths'} // 1) != 1;
        die "NVMe SR-IOV needs at least two flexible queues and one interrupt per VF\n"
            if $queues < 2 * $vfs || $interrupts < $vfs;
        die "NVMe SR-IOV must leave an I/O queue pair and an interrupt for the primary controller\n"
            if $queues + 2 > ($drive->{max_ioqpairs} // 64)
            || $interrupts >= ($drive->{msix_qsize} // 65);
        die "NVMe SR-IOV per-VF queue limit exceeds the flexible pool\n"
            if ($drive->{sriov_max_vq_per_vf} // 0) > int($queues / $vfs);
        die "NVMe SR-IOV per-VF interrupt limit exceeds the flexible pool\n"
            if ($drive->{sriov_max_vi_per_vf} // 0) > int($interrupts / $vfs);
        die "NVMe SR-IOV per-VF queue limit must be at least two\n"
            if defined($drive->{sriov_max_vq_per_vf}) && $drive->{sriov_max_vq_per_vf} == 1;
    } elsif (
        grep { $drive->{$_} }
        qw(sriov_vq_flexible sriov_vi_flexible sriov_max_vq_per_vf sriov_max_vi_per_vf)
    ) {
        die "NVMe SR-IOV resources require sriov_max_vfs\n";
    }
}

sub topology {
    my ($conf) = @_;

    my $drives = {};
    for my $id (grep { /^nvme\d+$/ && defined($conf->{$_}) } keys %$conf) {
        $drives->{$id} = PVE::QemuServer::Drive::parse_drive($id, $conf->{$id}, 1)
            or die "unable to parse NVMe disk '$id'\n";
    }
    my $groups = {};
    for my $id (sort { $drives->{$a}->{index} <=> $drives->{$b}->{index} } keys %$drives) {
        my $drive = $drives->{$id};
        my $owner_id = 'nvme' . ($drive->{'nvme-controller'} // $drive->{index});
        my $owner = $drives->{$owner_id}
            or die "$id: NVMe controller owner '$owner_id' does not exist\n";
        die "$id: NVMe controller references cannot be chained\n"
            if ($owner->{'nvme-controller'} // $owner->{index}) != $owner->{index};
        if ($id ne $owner_id) {
            my @own_options = grep { defined($drive->{$_}) } controller_option_names();
            die "$id: configure controller options on $owner_id: "
                . join(', ', @own_options) . "\n"
                if @own_options;
        }
        my $group = $groups->{$owner_id} //= { owner => $owner, namespaces => {}, explicit => 0 };
        $group->{namespaces}->{$id} = $drive;
        $group->{explicit} = 1
            if $id ne $owner_id
            || $owner->{sriov_max_vfs}
            || grep { defined($drive->{$_}) }
            (@namespace_options, @subsystem_options, 'nvme-controller');
    }
    for my $group (values %$groups) {
        my $owner = $group->{owner};
        my %ids;
        my %host_handles;
        my $automatic_placement;
        my $check_format = sub {
            my ($previous, $format) = @_;
            die
                "NVMe FDP namespaces sharing a reclaim unit handle must use the same LBA and metadata format\n"
                if defined($previous) && $previous ne $format;
        };
        for my $id (sort keys $group->{namespaces}->%*) {
            my $drive = $group->{namespaces}->{$id};
            my $nsid = $drive->{nsid} // $drive->{index} + 1;
            die "duplicate NVMe namespace identifier $nsid\n" if $ids{$nsid}++;
            die "NVMe Zoned Namespaces cannot use an FDP subsystem\n"
                if $drive->{zoned} && $owner->{fdp};
            die "NVMe FDP handle lists require fdp=1 on the controller owner\n"
                if defined($drive->{'fdp-ruhs'}) && !$owner->{fdp};
            if ($owner->{fdp}) {
                my $block = $drive->{logical_block_size} // 512;
                die
                    "$id: NVMe FDP reclaim unit size must be aligned to the namespace logical block size\n"
                    if ($owner->{'fdp-runs'} // 96 * 1024**2) % $block;
                my $handles = $owner->{'fdp-nruh'} // 16;
                my $format = join(':', $block, $drive->{ms} // 0);
                for my $range (split(';', $drive->{'fdp-ruhs'} // '')) {
                    my @range = split('-', $range);
                    die "NVMe FDP handle exceeds the subsystem handle count\n"
                        if $range[-1] >= $handles;
                    for my $handle ($range[0] .. $range[-1]) {
                        $check_format->($host_handles{$handle}, $format);
                        $host_handles{$handle} = $format;
                    }
                }
                # Automatic namespaces share one controller-assigned handle;
                # manual handles are reserved separately before device creation.
                if (!defined($drive->{'fdp-ruhs'})) {
                    $check_format->($automatic_placement, $format);
                    $automatic_placement = $format;
                }
            }
            die "NVMe Zone Append size cannot exceed the controller MDTS\n"
                if ($owner->{'zoned-zasl'} // 0) > ($owner->{mdts} // 7);
        }
        die "NVMe FDP automatic placement requires an unused reclaim unit handle\n"
            if $automatic_placement && keys(%host_handles) >= ($owner->{'fdp-nruh'} // 16);
    }
    PVE::QemuServer::Machine::assert_valid_custom_machine_config($conf, $groups);
    return $groups;
}

sub has_explicit_namespace {
    my ($conf, $drive) = @_;
    my $owner = 'nvme' . ($drive->{'nvme-controller'} // $drive->{index});
    return topology($conf)->{$owner}->{explicit};
}

sub validate_update {
    my ($conf, $changes, $deletions) = @_;
    my $pending = $conf->{pending} // {};
    my $effective = { %$conf, %$pending, %$changes };
    my $pending_delete = PVE::AbstractConfig->parse_pending_delete($pending->{delete});
    delete $effective->@{ grep { !exists($changes->{$_}) } keys %$pending_delete };
    delete $effective->{$_} for @{ $deletions // [] };
    return topology($effective);
}

sub restore_config {
    my ($conf, $excluded) = @_;
    my $groups = {};
    for my $id (sort grep { /^nvme\d+$/ && defined($conf->{$_}) } keys %$conf) {
        my $drive = PVE::QemuServer::Drive::parse_drive($id, $conf->{$id}, 1)
            or die "unable to parse NVMe disk '$id'\n";
        my $owner_id = 'nvme' . ($drive->{'nvme-controller'} // $drive->{index});
        next if exists($conf->{$owner_id});
        my $group = $groups->{$owner_id};
        if (!$group) {
            my $value = $excluded->{$owner_id}
                or die "$id: NVMe controller owner '$owner_id' does not exist\n";
            my $owner = PVE::QemuServer::Drive::parse_drive($owner_id, $value, 1)
                or die "unable to parse NVMe disk '$owner_id'\n";
            die "$id: NVMe controller references cannot be chained\n"
                if ($owner->{'nvme-controller'} // $owner->{index}) != $owner->{index};
            $group = $groups->{$owner_id} = { owner => $owner, namespaces => {} };
        }
        my @own_options = grep { defined($drive->{$_}) } controller_option_names();
        die "$id: configure controller options on $owner_id: " . join(', ', @own_options) . "\n"
            if @own_options;
        $group->{namespaces}->{$id} = $drive;
    }
    for my $owner_id (sort keys %$groups) {
        my $group = $groups->{$owner_id};
        # Excluded disks contribute controller settings, never namespace IDs,
        # formats or FDP mappings to the topology which is actually restored.
        my @retained = sort {
            $group->{namespaces}->{$a}->{index} <=> $group->{namespaces}->{$b}->{index}
        } keys $group->{namespaces}->%*;
        my $new_owner_id = $retained[0];
        my $new_owner = { $group->{namespaces}->{$new_owner_id}->%* };
        delete $new_owner->{'nvme-controller'};
        for my $option (controller_option_names()) {
            $new_owner->{$option} = $group->{owner}->{$option}
                if defined($group->{owner}->{$option});
        }
        if (PVE::QemuServer::Machine::machine_type_is_custom($conf)) {
            # Keep the controller's physical slot without renaming namespace
            # disk IDs, which also name their backup/live-restore streams.
            $new_owner->{'nvme-slot'} //= $group->{owner}->{index};
            $new_owner->{serial} //= uri_escape(
                PVE::QemuServer::Machine::custom_nvme_serial($conf, $new_owner->{'nvme-slot'}),
            );
        } else {
            $new_owner->{serial} //= $owner_id;
        }
        # Keep explicit namespace IDs and identifiers even with one survivor.
        $new_owner->{subsystem} = 1;
        $conf->{$new_owner_id} = PVE::QemuServer::Drive::print_drive($new_owner);
        for my $id (@retained[1 .. $#retained]) {
            my $drive = { $group->{namespaces}->{$id}->%* };
            $drive->{'nvme-controller'} = $new_owner->{index};
            $conf->{$id} = PVE::QemuServer::Drive::print_drive($drive);
        }
    }
    topology($conf);
}

sub validate_size {
    my ($drive, $size) = @_;
    return if !($drive->{zoned} || $drive->{ms} || $drive->{logical_block_size});
    my $block = $drive->{logical_block_size} // 512;
    my $lbas = int($size / ($block + ($drive->{ms} // 0)));
    die "NVMe image must contain at least one complete logical block and its metadata\n" if !$lbas;
    if ($drive->{zoned}) {
        my $zone_size = $drive->{'zoned-zone-size'} // 128 * 1024**2;
        die "NVMe ZNS image must contain at least one complete zone after accounting for metadata\n"
            if $lbas * $block < $zone_size;
    }
}

sub image_size {
    my ($storecfg, $drive) = @_;
    my ($storeid) = PVE::Storage::parse_volume_id($drive->{file}, 1);
    return PVE::Storage::volume_size_info($storecfg, $drive->{file}) if $storeid;
    return scalar(PVE::Storage::file_size_info($drive->{file}, undef, $drive->{format} // 'raw'));
}

sub assert_resize_allowed {
    my ($drive) = @_;
    # Metadata follows the data area. Growing the image would change its offset
    # without moving existing metadata, invalidating protection information.
    die "cannot resize an NVMe namespace with metadata; convert the complete image layout first\n"
        if $drive->{ms};
}

sub assert_copy_size {
    my ($drive, $source_size, $target_size) = @_;
    return if !$drive->{ms};

    my $lba_size = ($drive->{logical_block_size} // 512) + $drive->{ms};
    # Storage allocation can round up the requested size. A byte-for-byte copy
    # must still place metadata at the same offset in the destination image.
    die
        "cannot copy an NVMe namespace with metadata: target image size changes the metadata offset; use storage that preserves the logical block count\n"
        if int($source_size / $lba_size) != int($target_size / $lba_size);
}

sub snapshot_size {
    my ($storecfg, $drive, $snapname) = @_;

    my $format = PVE::QemuServer::Drive::checked_volume_format($storecfg, $drive->{file});
    my $method = PVE::Storage::volume_qemu_snapshot_method($storecfg, $drive->{file});
    my $size;
    if ($format eq 'qcow2' && ($method // '') eq 'qemu') {
        # qemu-img convert -l loads the snapshot's data, but retains the current
        # image size. The saved configuration is needed to check its layout.
        my $snapshot_size = $drive->{size};
        die "cannot clone NVMe metadata snapshot '$snapname': saved disk size is missing\n"
            if !defined($snapshot_size) || $snapshot_size !~ /^\d+$/ || !$snapshot_size;

        $size = PVE::Storage::volume_size_info($storecfg, $drive->{file}, 10);
        if (defined($size) && $size =~ /^\d+$/ && $size > 0) {
            my $lba_size = ($drive->{logical_block_size} // 512) + $drive->{ms};
            die
                "cannot clone NVMe metadata snapshot '$snapname': current image size changes the metadata offset; roll back the snapshot first\n"
                if int($snapshot_size / $lba_size) != int($size / $lba_size);
        }
    } else {
        # Native snapshots and volume chains have their own path and size,
        # independent of any later resize of the current volume.
        PVE::Storage::activate_volumes($storecfg, [$drive->{file}], $snapname);
        my $path = PVE::Storage::path($storecfg, $drive->{file}, $snapname);
        my $json = PVE::Storage::Common::qemu_img_info($path, $format, 10);
        my $info = eval { decode_json($json // '') };
        $size = $info->{'virtual-size'} if ref($info) eq 'HASH';
    }

    die "unable to determine disk size for NVMe metadata snapshot '$snapname'\n"
        if !defined($size) || $size !~ /^\d+$/ || !$size;

    return $size;
}

sub _qemu_option {
    my ($name, $value) = @_;
    my $qname = $qemu_names{$name} // $name;
    if ($boolean{$name}) {
        $value = $value ? 'on' : 'off';
    } elsif ($name eq 'model' || $name eq 'firmware-version' || $name eq 'serial') {
        $value = uri_unescape($value);
        $value =~ s/,/,,/g;
    } elsif ($name eq 'fdp-ruhs') {
        # QEMU parses handle numbers with base 0. Configuration IDs are decimal.
        $value =~ s/(\d+)/0 + $1/ge;
    }
    return ",$qname=$value";
}

sub controller_options {
    my ($drive) = @_;
    my $options = _qemu_option('use-intel-id', $drive->{'use-intel-id'} // 1);
    for my $option (grep { $_ ne 'use-intel-id' } @controller_options) {
        next if !defined($drive->{$option});
        $options .= _qemu_option($option, $drive->{$option});
    }
    if ($drive->{sriov_max_vfs}) {
        $options .= _qemu_option('sriov_vq_flexible', 2 * $drive->{sriov_max_vfs})
            if !defined($drive->{sriov_vq_flexible});
        $options .= _qemu_option('sriov_vi_flexible', $drive->{sriov_max_vfs})
            if !defined($drive->{sriov_vi_flexible});
    }
    return $options;
}

sub controller_devices {
    my ($conf, $vmid, $arch, $machine_type) = @_;
    my $groups = topology($conf);
    my @devices;
    my %root_ports;
    my $custom = PVE::QemuServer::Machine::machine_type_is_custom($conf);
    return @devices if $conf->{template};
    for my $owner_id (
        sort { $groups->{$a}->{owner}->{index} <=> $groups->{$b}->{owner}->{index} }
        keys %$groups
    ) {
        my $group = $groups->{$owner_id};
        my $owner = $group->{owner};
        assert_model_support($owner, $arch);
        next if !$group->{explicit};
        if ($owner->{sriov_max_vfs}) {
            die "NVMe SR-IOV requires Q35 or aarch64\n"
                if $arch ne 'aarch64' && $machine_type !~ m/q35/ && !$custom;
            # Separate PCIe buses keep VF routing IDs clear of other devices.
            # Q35 needs function zero to anchor sparse multifunction root slots.
            $root_ports{ 8 * int($owner->{index} / 8) } = 1 if $arch ne 'aarch64' && !$custom;
            $root_ports{ $owner->{index} } = 1 if !$custom;
        }
    }
    if ($arch eq 'aarch64' && %root_ports) {
        # ARM's host bridge and legacy map occupy every root slot. Bridge pci.1
        # exposes function zero as multifunction, leaving function one for us.
        my $pciaddr = print_pci_addr('pci.1', $arch) . '.1';
        push @devices, '-device',
            "pcie-root-port,id=nvme-root$pciaddr,multifunction=on,chassis=199";
        push @devices, '-device', 'x3130-upstream,id=nvme-switch,bus=nvme-root,addr=0x0';
    }
    for my $index (sort { $a <=> $b } keys %root_ports) {
        my $port;
        if ($arch eq 'aarch64') {
            my $addr = sprintf('0x%x', $index);
            $port = "xio3130-downstream,id=nvme-port$index,bus=nvme-switch,addr=$addr";
        } else {
            my $addr = sprintf('0x%x.%x', 7 + int($index / 8), $index % 8);
            $port = "pcie-root-port,id=nvme-port$index,bus=pcie.0,addr=$addr,multifunction=on";
        }
        push @devices, '-device', "$port,chassis=" . (200 + $index);
    }
    for my $owner_id (
        sort { $groups->{$a}->{owner}->{index} <=> $groups->{$b}->{owner}->{index} }
        keys %$groups
    ) {
        my $group = $groups->{$owner_id};
        next if !$group->{explicit};
        my $owner = $group->{owner};
        my $subsys = "nvme-subsys-$owner_id";
        my $nqn = $owner->{subnqn} // "vm$vmid-$owner_id";
        my $device = "nvme-subsys,id=$subsys,nqn=$nqn";
        if ($owner->{fdp}) {
            $device .= ',fdp=on';
            for my $entry (['fdp-nrg', 1], ['fdp-nruh', 16], ['fdp-runs', 96 * 1024**2]) {
                $device .= _qemu_option($entry->[0], $owner->{ $entry->[0] } // $entry->[1]);
            }
        }
        push @devices, '-device', $device;
        my $paths = $owner->{'nvme-paths'} // 1;
        my $serial = $owner->{serial} // ($custom ? undef : $owner_id);
        # Controllers in one subsystem must share a serial. The machine's
        # per-function defaults differ, so use the first path's topology serial.
        my $slot = $owner->{'nvme-slot'} // $owner->{index};
        $serial //= PVE::QemuServer::Machine::custom_nvme_serial($conf, $slot)
            if $paths > 1;
        for my $path (0 .. $paths - 1) {
            my $id = "nvme-ctrl-$owner_id" . ($path ? "-path$path" : '');
            my $pciaddr = print_pci_addr($owner_id, $arch);
            $pciaddr = PVE::QemuServer::Machine::custom_nvme_pci_address($conf, $slot) // $pciaddr;
            $pciaddr .= sprintf('.%x', $path) if $path;
            $pciaddr .= ',multifunction=on' if !$path && $paths > 1;
            $pciaddr = ",bus=nvme-port$owner->{index},addr=0x0"
                if $owner->{sriov_max_vfs} && !$custom;
            $device = "nvme,id=$id,subsys=$subsys$pciaddr";
            $device .= _qemu_option('serial', $serial) if defined($serial);
            $device .= controller_options($owner);
            push @devices, '-device', $device;
        }
    }
    return @devices;
}

sub namespace_device {
    my ($conf, $vmid, $drive, $arch) = @_;
    my $id = 'nvme' . $drive->{index};
    if ($conf->{template}) {
        return "virtio-blk-pci,id=$id,drive=drive-$id" . print_pci_addr($id, $arch);
    }
    my $owner = 'nvme' . ($drive->{'nvme-controller'} // $drive->{index});
    my $device = "nvme-ns,id=$id,drive=drive-$id,bus=nvme-ctrl-$owner";
    my $nsid = $drive->{nsid} // $drive->{index} + 1;
    my $hash = sha1_hex("pve-nvme:$vmid:$id");
    # Stable identifiers let Linux recognize all paths to the same namespace.
    my $uuid = sprintf(
        '%s-%s-5%s-a%s-%s',
        substr($hash, 0, 8),
        substr($hash, 8, 4),
        substr($hash, 13, 3),
        substr($hash, 17, 3),
        substr($hash, 20, 12),
    );
    $device .= ",nsid=$nsid,uuid=" . ($drive->{uuid} // $uuid);
    for my $option (grep { $_ ne 'nsid' && $_ ne 'uuid' } @namespace_options) {
        $device .= _qemu_option($option, $drive->{$option}) if defined($drive->{$option});
    }
    # QEMU defaults the physical size to 512 even with a custom logical size.
    $device .= ",physical_block_size=$drive->{logical_block_size}" if $drive->{logical_block_size};
    $device .= ",bootindex=$drive->{bootindex}" if $drive->{bootindex} && !$drive->{detached};
    my $cache = $drive->{cache} // '';
    $device .=
        ',write-cache=' . ($cache eq 'writethrough' || $cache eq 'directsync' ? 'off' : 'on');
    return $device;
}

# model and firmware-version were added after the minimum supported QEMU.
# Probe actual downstream builds rather than guessing from version numbers.
sub assert_model_support {
    my ($drive, $arch) = @_;
    my @needed = grep { defined($drive->{$_}) } qw(model firmware-version);
    return if !@needed;
    my %supported;
    my $binary = PVE::QemuServer::Helpers::get_command_for_arch($arch);
    eval {
        PVE::Tools::run_command(
            [$binary, '-device', 'nvme,help'],
            timeout => 10,
            outfunc => sub { $supported{$1} = 1 if $_[0] =~ m/^\s*([\w-]+)\s*=/; },
            errfunc => sub { },
        );
    };
    for my $name (@needed) {
        die
            "NVMe $name requires a QEMU build with nvme.$name support; upgrade QEMU or remove $name\n"
            if !$supported{$name};
    }
}

1;
