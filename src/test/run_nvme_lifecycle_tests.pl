#!/usr/bin/perl

use strict;
use warnings;

use Storable qw(dclone);
use Fcntl qw(O_RDWR);
use File::Path qw(make_path);
use Test::More;
use Test::MockModule;

use PVE::API2::Qemu;
use PVE::QemuMigrate;
use PVE::QemuServer;
use PVE::QemuServer::Drive qw(parse_drive);
use PVE::QemuServer::NVMe;

my $volume = 'local:8006/vm-8006-disk-0.raw';
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { return {}; });

my $restore = sub {
    my ($conf, $override, $reverse) = @_;
    my $map = {};
    my $raw = '';
    my $cookie = { netcount => 0 };
    my @ids = sort keys %$conf;
    @ids = reverse @ids if $reverse;
    for my $id (@ids) {
        my $drive = parse_drive($id, $conf->{$id});
        $map->{$id} = "local:8007/vm-8007-disk-$drive->{index}.raw" if $drive->{backup} // 1;
        $raw .= PVE::QemuServer::restore_update_config_line(
            $cookie, $map, "$id: $conf->{$id}\n", 0,
        );
    }
    return PVE::QemuServer::restore_merge_config(
        'nodes/pve/qemu-server/8007.conf',
        $raw,
        $override // {},
    );
};

for my $reverse (0, 1) {
    my $restored = $restore->(
        {
            nvme7 =>
                "$volume,backup=0,mdts=6,cmb_size_mb=16,subnqn=retained,nvme-paths=2,serial=Custom",
            nvme2 => "$volume,nvme-controller=7,nsid=20,ms=8,pi=1",
            nvme3 => "$volume,nvme-controller=7,nsid=30,detached=1",
            nvme4 => "$volume,nvme-controller=7,backup=0",
        },
        undef,
        $reverse,
    );
    ok(!exists($restored->{nvme7}), 'excluded controller-owner volume is not restored');
    ok(!exists($restored->{nvme4}), 'excluded child namespace is not restored');
    my $owner = parse_drive('nvme2', $restored->{nvme2});
    ok(!exists($owner->{'nvme-controller'}),
        'lowest retained namespace becomes its own controller');
    is($owner->{subsystem}, 1, 'promoted controller retains an explicit namespace');
    for my $entry (
        ['mdts', 6],
        ['cmb_size_mb', 16],
        ['subnqn', 'retained'],
        ['nvme-paths', 2],
        ['serial', 'Custom'],
        ['nsid', 20],
        ['ms', 8], ['pi', 1],
    ) {
        is($owner->{ $entry->[0] }, $entry->[1], "restored owner preserves $entry->[0]");
    }
    my $child = parse_drive('nvme3', $restored->{nvme3});
    is($child->{'nvme-controller'}, 2, 'remaining children refer to the promoted owner');
    is($child->{nsid}, 30, 'remaining child retains its namespace ID');
    is($child->{detached}, 1, 'remaining child retains its attachment state');
    my $groups = PVE::QemuServer::NVMe::topology($restored);
    is(scalar(keys %$groups), 1, 'restored namespaces form one valid controller group');
}

my $partial = {
    nvme0 => "$volume,backup=0,mdts=6",
    nvme1 => "$volume,nvme-controller=0",
};
my $single = $restore->($partial);
my $single_owner = parse_drive('nvme1', $single->{nvme1});
is($single_owner->{serial}, 'nvme0', 'promoted controller retains the original default serial');
is($single_owner->{subsystem}, 1, 'a sole survivor keeps explicit namespace numbering');
like(
    PVE::QemuServer::NVMe::namespace_device($single, 8007, $single_owner, 'x86_64'),
    qr/nsid=2,/,
    'a sole survivor retains its original default NSID',
);
my $overridden = $restore->($partial, { nvme0 => "$volume,mdts=5" });
is(
    parse_drive('nvme1', $overridden->{nvme1})->{'nvme-controller'},
    0,
    'an explicitly restored owner takes precedence over promotion',
);
is(parse_drive('nvme0', $overridden->{nvme0})->{mdts}, 5, 'restore overrides are preserved');
my $none = $restore->({ nvme0 => "$volume,backup=0" });
is(scalar(grep { /^nvme\d+$/ } keys %$none), 0, 'fully excluded groups do not create new disks');
my $full = $restore->({ nvme0 => $volume, nvme1 => "$volume,nvme-controller=0" });
ok(!parse_drive('nvme0', $full->{nvme0})->{subsystem},
    'full restores retain the original topology');
is(
    parse_drive('nvme1', $full->{nvme1})->{'nvme-controller'},
    0,
    'full restores retain owner references',
);
my $fdp = $restore->({
    nvme0 => "$volume,backup=0,fdp=1,fdp-nruh=2",
    nvme1 => "$volume,nvme-controller=0,fdp-ruhs=0",
    nvme2 => "$volume,nvme-controller=0",
});
is(
    parse_drive('nvme1', $fdp->{nvme1})->{fdp},
    1,
    'partial restores preserve FDP controller settings',
);
is(
    parse_drive('nvme1', $fdp->{nvme1})->{'fdp-ruhs'},
    0,
    'partial restores preserve the new owner namespace handle list',
);

my %configs;
my $reused_nsid = $restore->(
    {
        nvme0 => "$volume,nsid=1",
        nvme1 => "$volume,nvme-controller=0,nsid=2,backup=0",
    },
    { nvme0 => "$volume,nsid=2" },
);
is(
    parse_drive('nvme0', $reused_nsid->{nvme0})->{nsid},
    2,
    'restore overrides can reuse an excluded namespace ID',
);
my $fdp_override = $restore->(
    {
        nvme0 => "$volume,fdp=1",
        nvme1 => "$volume,nvme-controller=0,fdp-ruhs=0,backup=0",
    },
    { nvme0 => $volume },
);
ok(
    !parse_drive('nvme0', $fdp_override->{nvme0})->{fdp},
    'excluded namespace handle lists do not prevent disabling FDP on restore',
);
my $automatic_restore = $restore->(
    {
        nvme0 => "$volume,fdp=1,fdp-nruh=1,fdp-ruhs=0,backup=0",
        nvme1 => "$volume,nvme-controller=0,fdp-ruhs=0",
    },
    { nvme1 => "$volume,nvme-controller=0" },
);
my $automatic_owner = parse_drive('nvme1', $automatic_restore->{nvme1});
is($automatic_owner->{fdp}, 1, 'promoted owner retains FDP when the namespace mapping changes');
ok(
    !defined($automatic_owner->{'fdp-ruhs'}),
    'the excluded owner namespace does not consume restored FDP handles',
);
is($automatic_owner->{'fdp-nruh'}, 1, 'promoted owner retains the original FDP handle pool');

for my $case (
    [{ nvme1 => "$volume,nvme-controller=0" }, qr/owner 'nvme0' does not exist/],
    [
        {
            nvme0 => "$volume,backup=0,nvme-controller=7",
            nvme1 => "$volume,nvme-controller=0",
        },
        qr/references cannot be chained/,
    ],
    [
        { nvme0 => "$volume,backup=0", nvme1 => "$volume,nvme-controller=0,mdts=5" },
        qr/configure controller options on nvme0/,
    ],
    [
        {
            nvme0 => "$volume,backup=0",
            nvme1 => "$volume,nvme-controller=0,nsid=3",
            nvme2 => "$volume,nvme-controller=0,nsid=03",
        },
        qr/duplicate NVMe namespace identifier/,
    ],
    [
        {
            nvme0 => "$volume,backup=0,fdp=1,fdp-nruh=1,fdp-ruhs=0",
            nvme1 => "$volume,nvme-controller=0,fdp-ruhs=0",
            nvme2 => "$volume,nvme-controller=0",
        },
        qr/automatic placement requires an unused/,
    ],
) {
    eval { $restore->($case->[0]); };
    like($@, $case->[1], 'invalid retained namespace topology is still rejected on restore');
}

my @events;
my $scheduled;
my $execute;
my $before_worker;
my $deny_storage;
my $rpc = bless {}, 'NVMeLifecycleRPC';
{

    package NVMeLifecycleRPC;
    sub get_user { return 'root@pam'; }

    sub check {
        die "storage access denied\n" if $deny_storage && $_[2] eq '/storage/local';
        return 1;
    }
    sub check_vm_perm { return 1; }

    sub fork_worker {
        $scheduled++;
        return 'test-worker' if !$execute;
        $before_worker->() if $before_worker;
        return $_[-1]->();
    }
}
my $rpc_module = Test::MockModule->new('PVE::RPCEnvironment');
$rpc_module->mock(get => sub { $rpc });
$cluster->mock(
    get_vmlist => sub {
        return { ids => { 8006 => { node => 'pve' }, 8007 => { node => 'pve' } } };
    },
);
my $storage = Test::MockModule->new('PVE::Storage');
$storage->mock(config => sub { return {}; });
$storage->mock(activate_volumes => sub { });
$storage->mock(volume_size_info => sub { 1024**3 });
$storage->mock(volume_has_feature => sub { $_[1] eq 'rename' ? 1 : 0 });
$storage->mock(
    parse_volname => sub { return ('images', 'test.raw', 8006, undef, undef, undef, 'raw'); });
$storage->mock(
    rename_volume => sub {
        push @events, 'rename';
        return 'local:8007/vm-8007-disk-0.raw';
    },
);
my $qemu_config = Test::MockModule->new('PVE::QemuConfig');
$qemu_config->mock(load_config => sub { dclone($configs{ $_[1] }) });
$qemu_config->mock(check_lock => sub { });
$qemu_config->mock(lock_config => sub { $_[2]->() });
$qemu_config->mock(
    write_config => sub {
        $configs{ $_[1] } = dclone($_[2]);
        push @events, "write-$_[1]";
    },
);
my $drive_module = Test::MockModule->new('PVE::QemuServer::Drive');
$drive_module->mock(is_volume_in_use => sub { 0 });
my $qemu_server = Test::MockModule->new('PVE::QemuServer');
$qemu_server->mock(check_running => sub { 0 });
my $replication = Test::MockModule->new('PVE::ReplicationConfig');
$replication->mock(new => sub { bless {}, 'NVMeLifecycleReplication' });
{

    package NVMeLifecycleReplication;
    sub check_for_existing_jobs { 0 }
}

my $reset = sub {
    %configs = (
        8006 => { nvme0 => $volume, nvme1 => "$volume,nvme-controller=0", pending => {} },
        8007 => { pending => {} },
    );
    @events = ();
    $scheduled = 0;
    $execute = 1;
    $before_worker = undef;
    $deny_storage = 0;
};
my $move = sub {
    my ($disk, $target_disk) = @_;
    return PVE::API2::Qemu->move_vm_disk({
        node => 'pve',
        vmid => 8006,
        'target-vmid' => 8007,
        disk => $disk,
        'target-disk' => $target_disk,
    });
};
for my $case (
    ['nvme0', 'unused0', 'moving a referenced owner to an unused slot'],
    ['nvme0', 'nvme0', 'moving a referenced owner to an NVMe slot'],
    ['nvme1', 'nvme1', 'moving a child to a VM without its owner'],
) {
    $reset->();
    my $before = dclone(\%configs);
    eval { $move->($case->[0], $case->[1]); };
    like($@, qr/owner 'nvme0' does not exist/, "$case->[2] is rejected");
    is_deeply(\@events, [], 'invalid move has no storage or configuration side effects');
    is_deeply(\%configs, $before, 'invalid move preserves both VM configurations');
    is($scheduled, 0, 'invalid move is rejected before a worker is scheduled');
}

$reset->();
$configs{8007}->{nvme0} = $volume;
$configs{8007}->{nvme2} = "$volume,nvme-controller=0,nsid=2";
eval { $move->('nvme1', 'nvme1'); };
like($@, qr/duplicate NVMe namespace identifier/,
    'target NSID conflicts are checked before moving');
is_deeply(\@events, [], 'NSID conflict does not rename the source volume');

$reset->();
$configs{8007}->{nvme0} = $volume;
$configs{8007}->{pending}->{delete} = '!nvme0';
eval { $move->('nvme1', 'nvme1'); };
like($@, qr/owner 'nvme0' does not exist/, 'target pending owner deletion is respected');
is_deeply(\@events, [], 'pending owner deletion does not rename the source volume');

$reset->();
$configs{8007}->{nvme0} = $volume;
$before_worker = sub { $configs{8007}->{pending}->{delete} = '!nvme0'; };
eval { $move->('nvme1', 'nvme1'); };
like($@, qr/owner 'nvme0' does not exist/, 'topology is rechecked under both VM locks');
is($scheduled, 1, 'concurrent topology change is caught inside the scheduled worker');
is_deeply(\@events, [], 'concurrent topology change is caught before any rename or write');

$reset->();
$execute = 0;
$configs{8007}->{nvme0} = $volume;
eval { $move->('nvme1', 'nvme1'); };
is($@, '', 'a namespace can move to a compatible existing owner');
is($scheduled, 1, 'a compatible target permits scheduling the move');

for my $disk ('nvme0', 'nvme1') {
    $reset->();
    delete $configs{8006}->{nvme1} if $disk eq 'nvme0';
    eval { $move->($disk, 'unused0'); };
    is($@, '', 'an independent disk or child can move to an unused slot');
    is_deeply(
        \@events,
        ['rename', 'write-8006', 'write-8007'],
        'valid move performs its usual writes',
    );
    ok(!exists($configs{8006}->{$disk}), 'valid move removes the original source entry');
    is(
        $configs{8007}->{unused0},
        'local:8007/vm-8007-disk-0.raw',
        'valid move records the target volume',
    );
    eval { PVE::QemuServer::NVMe::topology($configs{8006}); };
    is($@, '', 'source topology remains valid after a successful move');
}

{
    my $image_size;
    my $size_error;
    my %active;
    my @size_queries;
    $storage->mock(
        config => sub {
            return {
                ids => {
                    local => {
                        type => 'dir',
                        path => '/tmp/nvme-lifecycle',
                        content => { images => 1 },
                    },
                },
            };
        },
    );
    $storage->mock(check_volume_access => sub { });
    $storage->mock(activate_volumes => sub { $active{$_}++ for $_[1]->@*; });
    $storage->mock(
        volume_size_info => sub {
            my (undef, $volid) = @_;
            die "size query requires an active volume\n" if !$active{$volid};
            push @size_queries, $volid;
            die "$size_error\n" if $size_error;
            return $image_size;
        },
    );
    $cluster->mock(log_msg => sub { });
    my $setup_layout = sub {
        my ($disk, $options, $size) = @_;
        $reset->();
        $configs{8006} = {
            $disk => $volume . ($disk =~ /^unused/ ? '' : ",size=4G$options"),
            pending => {},
        };
        $image_size = $size;
        $size_error = undef;
        %active = ();
        @size_queries = ();
    };
    my @invalid_layouts = (
        (
            map {
                [$_, '', 'emmc0', 100 * 1024**2, qr/eMMC user area must be a power of two/]
            } qw(unused0 nvme0 usbdisk0 virtio0)
        ),
        [
            'emmc0',
            ',boot-partition-size=4194304',
            'emmc1',
            8 * 1024**2,
            qr/eMMC image must contain a non-empty user area/,
        ],
        ['emmc0', '', 'emmc1', 2 * 1024**4, qr/eMMC user area exceeds/],
        ['emmc0', '', 'emmc1', 3 * 1024**3 + 1, qr/eMMC user area must be a power of two/],
        ['emmc0', '', 'emmc1', 0, qr/volume .* does not exist/],
        ['nvme0', ',zoned=1', 'nvme1', 64 * 1024**2, qr/NVMe ZNS image.*complete zone/],
        [
            'nvme0',
            ',logical_block_size=4096,ms=64',
            'nvme1',
            4096,
            qr/NVMe image must contain at least one complete logical block/,
        ],
        [
            'nvme0',
            ',logical_block_size=4096',
            'nvme1',
            512,
            qr/NVMe image must contain at least one complete logical block/,
        ],
    );
    for my $case (@invalid_layouts) {
        my ($disk, $options, $target_disk, $invalid_size, $error) = @$case;
        for my $concurrent (0, 1) {
            $setup_layout->($disk, $options, $concurrent ? 4 * 1024**3 : $invalid_size);
            $before_worker = sub { $image_size = $invalid_size; }
                if $concurrent;
            my $before = dclone(\%configs);
            eval { $move->($disk, $target_disk); };
            like($@, $error, "$disk to $target_disk rejects incompatible actual image size");
            is($scheduled, $concurrent, 'layout is checked before scheduling and under both locks');
            is_deeply(\@events, [], 'invalid layout prevents volume renames and config writes');
            is_deeply(\%configs, $before, 'invalid layout retains both original VM configurations');
            is_deeply(
                \@size_queries,
                [($volume) x ($concurrent ? 2 : 1)],
                'layout checks use the source volume before renaming, ignoring cached size',
            );
        }
    }

    for my $concurrent (0, 1) {
        $setup_layout->('virtio0', '', 1024**3);
        if ($concurrent) {
            $before_worker = sub { $size_error = 'unable to read source image size'; };
        } else {
            $size_error = 'unable to read source image size';
        }
        my $before = dclone(\%configs);
        eval { $move->('virtio0', 'emmc0'); };
        like($@, qr/unable to read source image size/, 'size probe failures are propagated');
        is($scheduled, $concurrent, 'failed size probes are checked at both validation stages');
        is_deeply(\@events, [], 'failed size probes prevent renames and config writes');
        is_deeply(\%configs, $before, 'failed size probes preserve the source disk attachment');
    }

    for my $concurrent (0, 1) {
        $setup_layout->('virtio0', '', 1024**3);
        if ($concurrent) {
            $before_worker = sub { $deny_storage = 1; };
        } else {
            $deny_storage = 1;
        }
        my $before = dclone(\%configs);
        eval { $move->('virtio0', 'emmc0'); };
        like(
            $@,
            qr/storage access denied/,
            'storage permission is checked at both validation stages',
        );
        is($scheduled, $concurrent, 'storage access is rechecked in the scheduled worker');
        is_deeply(
            \%active,
            $concurrent ? { $volume => 1 } : {},
            'a denied permission check does not activate storage',
        );
        is_deeply(\@events, [], 'denied storage access prevents all renames and config writes');
        is_deeply(\%configs, $before, 'denied storage access preserves both VM configurations');
    }

    for my $case (
        ['unused0', '', 'emmc0', 128 * 1024**2],
        ['virtio0', '', 'emmc0', 3 * 1024**3 + 512],
        ['emmc0', ',boot-partition-size=4194304', 'emmc1', 136 * 1024**2],
        ['nvme0', ',zoned=1', 'nvme1', 128 * 1024**2],
        ['nvme0', ',logical_block_size=4096,ms=64', 'nvme1', 4160],
        ['nvme0', ',logical_block_size=4096', 'nvme1', 4096],
    ) {
        my ($disk, $options, $target_disk, $size) = @$case;
        $setup_layout->($disk, $options, $size);
        eval { $move->($disk, $target_disk); };
        is($@, '', "$disk to $target_disk accepts a compatible image layout");
        is($scheduled, 1, 'compatible layout reaches the reassignment worker');
        ok(!exists($configs{8006}->{$disk}), 'successful move removes the source attachment');
        my $target_drive = parse_drive($target_disk, $configs{8007}->{$target_disk});
        is(
            $target_drive->{file},
            'local:8007/vm-8007-disk-0.raw',
            'successful move attaches the renamed volume to the target VM',
        );
        is($target_drive->{size}, $size, 'target configuration records actual image size');
        is_deeply(
            \@size_queries,
            [$volume, $volume, 'local:8007/vm-8007-disk-0.raw'],
            'valid layouts are checked before scheduling, under locks and on target attachment',
        );
    }

    for my $case (
        ['virtio0', '', 'virtio0'],
        ['nvme0', '', 'nvme0'],
        ['nvme0', ',zoned=1', 'unused0'],
        ['emmc0', ',boot-partition-size=4194304', 'unused0'],
    ) {
        my ($disk, $options, $target_disk) = @$case;
        $setup_layout->($disk, $options, 100 * 1024**2);
        $execute = 0;
        eval { $move->($disk, $target_disk); };
        is($@, '', 'targets without a special layout retain normal reassignment checks');
        is($scheduled, 1, 'normal or unused target can still schedule a move');
        is_deeply(\@size_queries, [], 'targets without layout constraints do not probe image size');
    }
    $storage->mock(config => sub { return {}; });
    $storage->mock(activate_volumes => sub { });
    $storage->mock(volume_size_info => sub { 1024**3 });
    $storage->unmock('check_volume_access');
    $cluster->unmock('log_msg');
}

my $reject_reassign = sub {
    my ($disk, $target_disk, $error, $workers, $expected) = @_;
    $expected //= dclone(\%configs);
    eval { $move->($disk, $target_disk); };
    like($@, $error, 'disk reassignment rejects pending slot changes');
    is($scheduled, $workers, 'slot conflicts are checked before and after scheduling');
    is_deeply(\@events, [], 'slot conflicts prevent all volume renames and config writes');
    is_deeply(\%configs, $expected, 'slot conflicts preserve both VM configurations');
};

for my $bus (qw(nvme usbdisk emmc virtio scsi sata ide)) {
    my $disk = "${bus}0";
    for my $pending ('same-volume', 'replacement', 'delete', 'force-delete') {
        $reset->();
        $configs{8006} = { $disk => $volume, pending => {} };
        if ($pending =~ /delete/) {
            $configs{8006}->{pending}->{delete} = ($pending eq 'force-delete' ? '!' : '') . $disk;
        } else {
            my $file = $pending eq 'same-volume' ? $volume : 'local:8006/vm-8006-disk-3.raw';
            $configs{8006}->{pending}->{$disk} = "$file,cache=writeback";
        }
        $reject_reassign->($disk, 'unused0', qr/disk '$disk'.*pending changes/, 0);
    }

    $reset->();
    $configs{8006} = { nvme0 => $volume, pending => {} };
    $configs{8007}->{pending}->{$disk} = 'local:8007/vm-8007-disk-1.raw';
    $execute = 0;
    $reject_reassign->('nvme0', $disk, qr/Target disk key '$disk'.*already in use/, 0);

    for my $side ('source', 'target') {
        $reset->();
        $configs{8006} = { $disk => $volume, pending => {} };
        my $concurrent;
        $before_worker = sub {
            if ($side eq 'source') {
                $configs{8006}->{pending}->{$disk} = "$volume,cache=writeback";
            } else {
                $configs{8007}->{pending}->{$disk} = 'local:8007/vm-8007-disk-1.raw';
            }
            $concurrent = dclone(\%configs);
        };
        eval { $move->($disk, $side eq 'source' ? 'unused0' : $disk); };
        like(
            $@,
            $side eq 'source'
            ? qr/disk '$disk'.*pending changes/
            : qr/Target disk key '$disk'.*already in use/,
            'concurrent pending slot changes are rejected under both config locks',
        );
        is($scheduled, 1, 'concurrent changes happen after the early slot checks');
        is_deeply(\@events, [], 'concurrent slot conflicts prevent any rename or config write');
        is_deeply(\%configs, $concurrent, 'concurrent pending configuration is retained');
    }
}

for my $pending_boot (
    ['order=nvme2;nvme0;nvme1', 'order=nvme2;nvme1'],
    ['order=nvme0', ''],
    ['', ''], ['ncd', 'ncd'],
) {
    $reset->();
    $configs{8006} = {
        nvme0 => $volume,
        nvme1 => 'local:8006/vm-8006-disk-1.raw',
        nvme2 => 'local:8006/vm-8006-disk-2.raw',
        boot => 'order=nvme0;nvme1;nvme2',
        pending => { boot => $pending_boot->[0], description => 'keep this pending change' },
    };
    eval { $move->('nvme0', 'unused0'); };
    is($@, '', 'a disk can move while an unrelated boot order change is pending');
    is(
        $configs{8006}->{boot},
        'order=nvme1;nvme2',
        'the moved disk is removed from current boot order',
    );
    is(
        $configs{8006}->{pending}->{boot},
        $pending_boot->[1],
        'the moved disk is removed from pending boot order without changing other priorities',
    );
    is(
        $configs{8006}->{pending}->{description},
        'keep this pending change',
        'unrelated pending settings remain intact',
    );
    is(
        $configs{8007}->{unused0},
        'local:8007/vm-8007-disk-0.raw',
        'the moved volume is retained by the target VM',
    );
}

{
    my $moved_volume = 'target:8006/vm-8006-disk-0.raw';
    $storage->mock(storage_check_enabled => sub { return { content => { images => 1 } }; });
    $storage->mock(activate_volumes => sub { });
    $storage->mock(deactivate_volumes => sub { });
    $storage->mock(get_bandwidth_limit => sub { undef });
    $storage->mock(vdisk_free => sub { push @events, 'free'; });
    $cluster->mock(log_msg => sub { });
    $qemu_server->mock(
        clone_disk => sub {
            push @events, 'copy';
            push @{ $_[4] }, $moved_volume;
            return { %{ $_[1]->{drive} }, file => $moved_volume };
        },
    );
    my $move_storage = sub {
        my ($disk, $delete) = @_;
        return PVE::API2::Qemu->move_vm_disk({
            node => 'pve',
            vmid => 8006,
            disk => $disk,
            storage => 'target',
            delete => $delete,
        });
    };

    for my $bus (qw(nvme usbdisk emmc virtio scsi sata ide)) {
        my $disk = "${bus}0";
        for my $pending ('same-volume', 'replacement', 'delete', 'force-delete') {
            $reset->();
            $configs{8006} = { $disk => $volume, pending => {} };
            if ($pending =~ /delete/) {
                $configs{8006}->{pending}->{delete} =
                    ($pending eq 'force-delete' ? '!' : '') . $disk;
            } else {
                my $file = $pending eq 'same-volume' ? $volume : 'local:8006/vm-8006-disk-3.raw';
                $configs{8006}->{pending}->{$disk} = "$file,cache=writeback";
            }
            my $before = dclone(\%configs);
            eval { $move_storage->($disk, 1); };
            like($@, qr/disk '$disk'.*pending changes/,
                'storage move rejects pending slot changes');
            is($scheduled, 0, 'pending storage moves are rejected before scheduling');
            is_deeply(\@events, [], 'pending storage moves do not copy, free or write anything');
            is_deeply(\%configs, $before, 'pending storage moves preserve configuration');
        }

        $reset->();
        $configs{8006} = { $disk => $volume, pending => {} };
        my $concurrent;
        $before_worker = sub {
            $configs{8006}->{pending}->{$disk} = "$volume,cache=writeback";
            $concurrent = dclone(\%configs);
        };
        eval { $move_storage->($disk, 1); };
        like(
            $@,
            qr/disk '$disk'.*pending changes/,
            'storage move rechecks pending changes under lock',
        );
        is($scheduled, 1, 'the concurrent pending change occurs after the early storage check');
        is_deeply(
            \@events,
            [],
            'concurrent storage conflicts prevent any copy, free or config write',
        );
        is_deeply(\%configs, $concurrent, 'concurrent pending settings remain intact');

        for my $delete (0, 1) {
            $reset->();
            $configs{8006} = {
                $disk => $volume,
                pending => { description => 'keep this pending change' },
            };
            eval { $move_storage->($disk, $delete); };
            is($@, '', 'unrelated pending changes do not prevent moving storage');
            is($configs{8006}->{$disk}, $moved_volume, 'a valid move records the target volume');
            is(
                $configs{8006}->{pending}->{description},
                'keep this pending change',
                'a valid storage move preserves unrelated pending settings',
            );
            is_deeply(
                \@events,
                ['copy', 'write-8006', $delete ? ('free') : ()],
                'a valid storage move frees the original only when requested',
            );
            is(
                $configs{8006}->{unused0},
                $delete ? undef : $volume,
                'the original volume remains unused when deletion is not requested',
            );
        }
    }
    $qemu_server->unmock('clone_disk');
    $cluster->unmock('log_msg');
    $storage->unmock($_) for qw(
        storage_check_enabled activate_volumes deactivate_volumes get_bandwidth_limit vdisk_free
    );
}

{
    # Use the real reference checker: mocking it would hide dangling pending
    # references after volume renames and destructive storage operations.
    $drive_module->unmock('is_volume_in_use');
    $storage->mock(
        path => sub {
            my (undef, $volid) = @_;
            (my $path = $volid) =~ s!^(local|alias):!/var/lib/vz/images/!;
            return wantarray ? ($path, 8006) : $path;
        },
    );
    $storage->mock(storage_config => sub { return { type => 'dir', path => '/var/lib/vz' }; });
    $storage->mock(storage_check_enabled => sub { return { content => { images => 1 } }; });
    $storage->mock(vdisk_free => sub { push @events, 'free'; });

    for my $case (
        (
            map {
                my $disk = "${_}1";
                map { [$disk, $_, $volume] } qw(current pending snapshot)
            } qw(nvme emmc usbdisk virtio)
        ),
        ['nvme1', 'pending', '/var/lib/vz/images/8006/vm-8006-disk-0.raw'],
        ['nvme1', 'pending', 'alias:8006/vm-8006-disk-0.raw'],
    ) {
        my ($reference_disk, $section, $reference) = @$case;
        for my $concurrent (0, 1) {
            $reset->();
            $configs{8006} = { nvme0 => $volume, pending => {}, snapshots => {} };
            my $before;
            my $stage = sub {
                my $target = $configs{8007};
                my $config =
                    $section eq 'current' ? $target
                    : $section eq 'pending' ? $target->{pending}
                    : ($target->{snapshots}->{saved} //= {});
                $config->{$reference_disk} = $reference;
                $before = dclone(\%configs);
            };
            if ($concurrent) {
                $before_worker = $stage;
            } else {
                $stage->();
            }
            eval { $move->('nvme0', 'unused0'); };
            like(
                $@,
                qr/disk referenced by.*target VM/,
                "target $section $reference_disk reference prevents reassignment",
            );
            is($scheduled, $concurrent,
                'target references are checked before and after scheduling');
            is_deeply(\@events, [], 'target references prevent volume renames and config writes');
            is_deeply(
                \%configs,
                $before,
                'failed reassignment preserves all target volume references',
            );
        }
    }

    $reset->();
    $configs{8006} = { nvme0 => $volume, pending => {}, snapshots => {} };
    $configs{8007} = {
        nvme1 => 'local:8007/vm-8007-disk-1.raw',
        pending => { emmc1 => 'local:8007/vm-8007-disk-2.raw' },
        snapshots => { saved => { usbdisk1 => 'local:8007/vm-8007-disk-3.raw' } },
    };
    my $target_before = dclone($configs{8007});
    eval { $move->('nvme0', 'unused0'); };
    is($@, '', 'target references to other volumes do not prevent reassignment');
    is_deeply(
        \@events,
        ['rename', 'write-8006', 'write-8007'],
        'unrelated target volumes preserve ordinary reassignment operations',
    );
    is_deeply(
        $configs{8007},
        { %$target_before, unused0 => 'local:8007/vm-8007-disk-0.raw' },
        'successful reassignment retains unrelated target configuration and snapshots',
    );

    for my $bus (qw(nvme usbdisk emmc virtio scsi sata ide)) {
        my $reference_disk = "${bus}1";
        for my $reference (
            $volume,
            '/var/lib/vz/images/8006/vm-8006-disk-0.raw',
            'alias:8006/vm-8006-disk-0.raw',
        ) {
            for my $concurrent (0, 1) {
                $reset->();
                $configs{8006} = { nvme0 => $volume, pending => {}, snapshots => {} };
                my $before;
                my $stage = sub {
                    $configs{8006}->{pending}->{$reference_disk} = $reference;
                    $before = dclone(\%configs);
                };
                if ($concurrent) {
                    $before_worker = $stage;
                } else {
                    $stage->();
                }
                eval { $move->('nvme0', 'unused0'); };
                like(
                    $@,
                    qr/Can't move disk.*another VM/,
                    'a pending volume reference prevents cross-VM reassignment',
                );
                is($scheduled, $concurrent, 'references are checked before and after scheduling');
                is_deeply(\@events, [], 'pending references prevent renames and config writes');
                is_deeply(\%configs, $before, 'rejected reassignment retains pending references');
            }

            for my $delete (0, 1) {
                $reset->();
                $execute = 0;
                $configs{8006} = {
                    nvme0 => $volume,
                    pending => { $reference_disk => $reference },
                    snapshots => {},
                };
                eval {
                    PVE::API2::Qemu->move_vm_disk({
                        node => 'pve',
                        vmid => 8006,
                        disk => 'nvme0',
                        storage => 'target',
                        delete => $delete,
                    });
                };
                if ($delete) {
                    like(
                        $@,
                        qr/volume is still referenced/,
                        'storage migration cannot delete a volume referenced by a pending drive',
                    );
                } else {
                    is($@, '', 'storage migration can retain the volume for a pending drive');
                }
                is(
                    $scheduled,
                    $delete ? 0 : 1,
                    'pending references prevent scheduling only when the source would be freed',
                );
            }

            $reset->();
            my $conf = {
                unused0 => $volume,
                pending => { $reference_disk => $reference },
                snapshots => {},
            };
            eval {
                PVE::QemuServer::try_deallocate_drive(
                    {},
                    8006,
                    $conf,
                    'unused0',
                    parse_drive('unused0', $volume),
                    $rpc,
                    'root@pam',
                );
            };
            like(
                $@,
                qr/volume is still in use/,
                'pending references protect an unused volume from deletion',
            );
            is_deeply(\@events, [], 'a referenced unused volume is not freed');
        }
    }

    for my $conf (
        {
            nvme0 => $volume,
            pending => { nvme0 => "$volume,cache=writeback" },
            snapshots => {},
        },
        { nvme0 => $volume, snapshots => { snap1 => { nvme0 => $volume } } },
        { nvme0 => $volume, usbdisk0 => $volume, pending => {}, snapshots => {} },
    ) {
        ok(
            PVE::QemuServer::Drive::is_volume_in_use({}, $conf, 'nvme0', $volume),
            'the skipped current slot does not hide pending, snapshot or other drive references',
        );
    }

    $reset->();
    $configs{8006} = {
        nvme0 => $volume,
        pending => { usbdisk0 => 'local:8006/vm-8006-disk-3.raw' },
        snapshots => {},
    };
    eval { $move->('nvme0', 'unused0'); };
    is($@, '', 'a pending reference to a different volume allows reassignment');
    is_deeply(
        \@events,
        ['rename', 'write-8006', 'write-8007'],
        'unrelated pending drives do not block ordinary reassignment',
    );

    $storage->mock(activate_volumes => sub { });
    $storage->mock(deactivate_volumes => sub { });
    $storage->mock(get_bandwidth_limit => sub { undef });
    $cluster->mock(log_msg => sub { });
    $qemu_server->mock(
        clone_disk => sub {
            push @events, 'copy';
            return { %{ $_[1]->{drive} }, file => 'target:8006/vm-8006-disk-0.raw' };
        },
    );
    for my $concurrent (0, 1) {
        $reset->();
        $configs{8006} = { nvme0 => $volume, pending => {}, snapshots => {} };
        my $before;
        my $stage = sub {
            $configs{8006}->{pending}->{usbdisk1} = $volume;
            $before = dclone(\%configs);
        };
        if ($concurrent) {
            $before_worker = $stage;
        } else {
            $stage->();
        }
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_; };
        eval {
            PVE::API2::Qemu->move_vm_disk({
                node => 'pve',
                vmid => 8006,
                disk => 'nvme0',
                storage => 'target',
                delete => $concurrent,
            });
        };
        if ($concurrent) {
            like(
                $@,
                qr/volume is still referenced/,
                'storage migration rechecks pending volume references under lock',
            );
            is_deeply(\@events, [], 'a concurrent pending reference prevents copying and freeing');
            is_deeply(\%configs, $before, 'a concurrent pending reference preserves configuration');
        } else {
            is($@, '', 'a referenced volume can be copied when the source is retained');
            is(
                $configs{8006}->{nvme0},
                'target:8006/vm-8006-disk-0.raw',
                'copy-only migration attaches the new volume',
            );
            is($configs{8006}->{unused0}, $volume, 'copy-only migration retains its source volume');
            is(
                $configs{8006}->{pending}->{usbdisk1},
                $volume,
                'copy-only migration keeps the pending reference valid',
            );
            is_deeply(
                \@events,
                ['copy', 'write-8006'],
                'copy-only migration does not free the source',
            );
        }
        is($scheduled, 1, 'the reference check is also exercised inside the storage worker');
    }
    $qemu_server->unmock('clone_disk');
    $cluster->unmock('log_msg');
    $storage->unmock($_) for qw(
        path storage_config storage_check_enabled vdisk_free activate_volumes deactivate_volumes
        get_bandwidth_limit
    );
    $drive_module->mock(is_volume_in_use => sub { 0 });
}

for my $case (
    ['order=nvme2;nvme0;nvme1', 'nvme0', 'order=nvme2;nvme1'],
    ['order=nvme0', 'nvme0', ''],
    ['order=nvme0;nvme1;nvme2', 'nvme1', 'order=nvme1;nvme2'],
    ['order=nvme1;nvme2', 'nvme0', 'order=nvme1;nvme2'],
    ['', 'nvme0', ''],
    ['c', 'nvme1', 'c'],
    ['c', 'nvme1', '', 'nvme0'],
    ['n', 'nvme1', 'n'],
) {
    $reset->();
    $configs{8006} = {
        nvme0 => $volume,
        nvme1 => 'local:8006/vm-8006-disk-1.raw',
        nvme2 => 'local:8006/vm-8006-disk-2.raw',
        boot => $case->[0],
        pending => {},
    };
    $configs{8006}->{ $case->[1] } .= ',detached=1';
    $configs{8006}->{bootdisk} = $case->[3] if defined($case->[3]);
    eval { $move->('nvme0', 'unused0'); };
    is($@, '', 'an initially detached namespace does not prevent reassignment');
    is(
        $configs{8006}->{boot},
        $case->[2],
        'reassignment removes only the moved disk from the stored boot order',
    );
}

{
    my $source_volume = 'local:8006/vm-8006-disk-0.raw';
    my $target_volume = 'target:8007/vm-8007-disk-0.raw';
    my $source_size = 256 * 1024**2 + 65536;
    my $target_size;
    $storage->mock(
        volume_size_info => sub { $_[1] eq $source_volume ? $source_size : $target_size },
    );
    $storage->mock(vdisk_alloc => sub { push @events, 'allocate'; return $target_volume; });
    $storage->mock(activate_volumes => sub { push @events, 'activate'; });
    $storage->mock(volume_has_feature => sub { 0 });
    $storage->mock(storage_config => sub { return { type => 'dir', path => '/tmp' }; });
    $qemu_server->mock(resolve_dst_disk_format => sub { 'raw' });
    my $image = Test::MockModule->new('PVE::QemuServer::QemuImage');
    $image->mock(convert => sub { push @events, 'copy'; });
    my $block_job = Test::MockModule->new('PVE::QemuServer::BlockJob');
    $block_job->mock(mirror => sub { push @events, 'mirror'; });
    my $machine = Test::MockModule->new('PVE::QemuServer::Machine');
    $machine->mock(get_current_qemu_machine => sub { 'pc-q35-11.1' });

    for my $running (0, 1) {
        for my $entry (
            ['ms=8,pi=1', 257 * 1024**2, 0],
            ['ms=16,logical_block_size=4096', 257 * 1024**2, 0],
            ['ms=8,pi=1', $source_size, 1],
            ['ms=8,pi=1', $source_size + 1, 1],
            ['ms=0', 257 * 1024**2, 1],
        ) {
            my ($options, $size, $allowed) = @$entry;
            $target_size = $size;
            @events = ();
            my $new_volumes = [];
            my $cloned;
            eval {
                $cloned = PVE::QemuServer::clone_disk(
                    {},
                    {
                        vmid => 8006,
                        drivename => 'nvme0',
                        running => $running,
                        drive => parse_drive('nvme0', "$source_volume,$options"),
                    },
                    { vmid => 8007, drivename => 'nvme0', storage => 'target' },
                    1,
                    $new_volumes,
                    {},
                    'complete',
                    undef,
                    undef,
                );
            };
            if ($allowed) {
                is($@, '', 'clones with a compatible metadata offset or no metadata succeed');
                is($cloned->{size}, $target_size, 'successful clone records its actual size');
                is_deeply(
                    \@events,
                    ['allocate', 'activate', $running ? 'mirror' : 'copy'],
                    'compatible clones use their normal offline or online copy path',
                );
            } else {
                like(
                    $@,
                    qr/target image size changes the metadata offset/,
                    'storage size rounding cannot invalidate cloned NVMe metadata',
                );
                is_deeply(
                    \@events,
                    ['allocate', 'activate'],
                    'incompatible clones stop before copying data or switching block nodes',
                );
            }
            is_deeply(
                $new_volumes,
                [$target_volume],
                'the allocated destination remains registered for worker cleanup',
            );
        }
    }
}

{
    my $source_volume = 'local:8006/vm-8006-disk-0.qcow2';
    my $target_volume = 'target:8007/vm-8007-disk-0.raw';
    my $snapshot_size = 256 * 1024**2;
    my $current_size = 512 * 1024**2;
    my ($format, $method, $snapshot_json, $target_padding);
    my @snapshot_events;
    $drive_module->mock(checked_volume_format => sub { $format });
    $storage->mock(volume_qemu_snapshot_method => sub { $method });
    $storage->mock(
        volume_size_info => sub {
            return $current_size if $_[1] eq $source_volume;
            return $snapshot_size + $target_padding;
        },
    );
    $storage->mock(
        vdisk_alloc => sub {
            push @snapshot_events, ['allocate', $_[5] * 1024];
            return $target_volume;
        },
    );
    $storage->mock(
        activate_volumes => sub {
            push @snapshot_events, ['activate', $_[1]->[0], $_[2]];
        },
    );
    $storage->mock(
        path => sub {
            push @snapshot_events, ['path', $_[1], $_[2]];
            return '/snapshot/source';
        },
    );
    $storage->mock(volume_has_feature => sub { 0 });
    $qemu_server->mock(resolve_dst_disk_format => sub { 'raw' });
    my $common = Test::MockModule->new('PVE::Storage::Common');
    $common->mock(
        qemu_img_info => sub {
            push @snapshot_events, ['info', @_];
            die "snapshot query failed\n" if $snapshot_json eq 'error';
            return $snapshot_json;
        },
    );
    my $image = Test::MockModule->new('PVE::QemuServer::QemuImage');
    $image->mock(
        convert => sub {
            push @snapshot_events, ['copy', $_[2], $_[3]->{snapname}];
        },
    );
    my $clone = sub {
        my ($options, $saved_size, $running) = @_;
        my $drive = parse_drive('nvme0', "$source_volume,$options");
        $drive->{size} = $saved_size if defined($saved_size);
        my $new_volumes = [];
        @snapshot_events = ();
        my $result = eval {
            PVE::QemuServer::clone_disk(
                {},
                {
                    vmid => 8006,
                    drivename => 'nvme0',
                    drive => $drive,
                    running => $running,
                    snapname => 'before-resize',
                },
                { vmid => 8007, drivename => 'nvme0', storage => 'target' },
                1,
                $new_volumes,
                {},
                'complete',
                undef,
                undef,
            );
        };
        return ($result, $@, $new_volumes);
    };

    ($format, $method, $target_padding) = ('qcow2', 'qemu', 0);
    for my $running (0, 1) {
        for my $options ('ms=8,pi=1', 'ms=16,logical_block_size=4096') {
            my (undef, $err, $new_volumes) = $clone->($options, $snapshot_size, $running);
            like(
                $err,
                qr/current image size changes the metadata offset/,
                'internal metadata snapshots cannot silently inherit a later resize',
            );
            is_deeply(\@snapshot_events, [], 'unsafe internal snapshots stop before allocation');
            is_deeply($new_volumes, [], 'rejecting the source creates no destination volume');
        }
        for my $saved_size (undef, 0) {
            my (undef, $err) = $clone->('ms=8', $saved_size, $running);
            like(
                $err,
                qr/saved disk size is missing/,
                'internal metadata snapshots require their original disk size',
            );
            is_deeply(\@snapshot_events, [], 'missing snapshot sizes have no storage side effects');
        }
        $current_size = $snapshot_size;
        my ($result, $err) = $clone->('ms=8,pi=1', $snapshot_size, $running);
        is($err, '', 'unchanged internal metadata snapshots can still be cloned');
        is($result->{size}, $snapshot_size, 'internal snapshot clone records the correct size');
        is_deeply(
            $snapshot_events[-1],
            ['copy', $snapshot_size, 'before-resize'],
            'running and stopped snapshot clones use offline conversion of the requested snapshot',
        );
        $current_size = 512 * 1024**2;
    }
    for my $size (undef, 0, 'invalid') {
        $current_size = $size;
        my (undef, $err, $new_volumes) = $clone->('ms=8', $snapshot_size, 0);
        like(
            $err,
            qr/unable to determine disk size/,
            'internal metadata snapshots reject unavailable current image sizes',
        );
        is_deeply($new_volumes, [], 'unavailable current sizes create no target volume');
    }
    $current_size = 512 * 1024**2;
    for my $entry (['raw', undef], ['qcow2', 'volume-chain']) {
        ($format, $method) = @$entry;
        for my $running (0, 1) {
            $snapshot_json = '{"virtual-size":' . $snapshot_size . '}';
            my ($result, $err) = $clone->('ms=8,pi=1', undef, $running);
            is($err, '', 'native snapshots and volume chains use their own size after a resize');
            is(
                $result->{size},
                $snapshot_size,
                'native snapshot clones retain their metadata layout',
            );
            is_deeply(
                \@snapshot_events,
                [
                    ['activate', $source_volume, 'before-resize'],
                    ['path', $source_volume, 'before-resize'],
                    ['info', '/snapshot/source', $format, 10],
                    ['allocate', $snapshot_size],
                    ['activate', $target_volume, undef],
                    ['copy', $snapshot_size, 'before-resize'],
                ],
                'snapshot size is queried after activation and before allocation or copying',
            );
        }
        $target_padding = 1024**2;
        my (undef, $err, $new_volumes) = $clone->('ms=8', undef, 0);
        like(
            $err,
            qr/target image size changes the metadata offset/,
            'snapshot-aware sizing still rejects rounded destination allocations',
        );
        is_deeply($new_volumes, [$target_volume], 'rounded targets remain registered for cleanup');
        ok(
            !grep({ $_->[0] eq 'copy' } @snapshot_events),
            'rounded targets receive no snapshot data',
        );
        $target_padding = 0;
        for my $json (
            '',
            '{}',
            '[]',
            'invalid',
            '{"virtual-size":0}',
            '{"virtual-size":"invalid"}',
            'error',
        ) {
            $snapshot_json = $json;
            my (undef, $err, $new_volumes) = $clone->('ms=8', undef, 0);
            like(
                $err,
                qr/unable to determine disk size|snapshot query failed/,
                'missing or failed native snapshot size queries abort the clone',
            );
            is_deeply($new_volumes, [], 'failed native snapshot queries create no target volume');
        }
    }
    # Non-metadata snapshots retain the existing clone behavior.
    ($format, $method, $snapshot_json) = ('qcow2', 'qemu', 'error');
    my (undef, $err) = $clone->('ms=0', undef, 0);
    is($err, '', 'snapshots without metadata do not need a saved size or additional queries');
    is_deeply(
        $snapshot_events[-1],
        ['copy', $current_size, 'before-resize'],
        'non-metadata snapshots keep the existing allocation and conversion size',
    );
    $drive_module->unmock('checked_volume_format');
}

{
    my $source_size = 256 * 1024**2 + 65536;
    my $target_size;
    my $options;
    my $reverse;
    $cluster->mock(cfs_read_file => sub { $_[0] eq 'datacenter.cfg' ? {} : undef });
    $storage->mock(path_to_volume_id => sub { return (undef, undef); });
    $storage->mock(get_bandwidth_limit => sub { undef });
    $storage->mock(storage_config => sub { return { type => 'dir', content => { images => 1 } }; });
    $storage->mock(resolve_format_hint => sub { 'raw' });
    $storage->mock(volume_size_info => sub { $target_size });
    $storage->mock(vdisk_alloc => sub { push @events, 'allocate'; return $volume; });
    $storage->mock(activate_volumes => sub { push @events, 'activate'; });
    $storage->mock(deactivate_volumes => sub { push @events, 'deactivate'; });
    $storage->mock(vdisk_free => sub { push @events, 'free'; });
    $storage->mock(path => sub { '/tmp/nvme-lifecycle-restore.raw' });
    $qemu_config->mock(config_file => sub { 'nodes/pve/qemu-server/8007.conf' });
    $qemu_server->mock(rescan => sub { });
    $qemu_server->mock(
        run_command => sub {
            my ($commands, %opts) = @_;
            my $extract = $commands->[-1];
            my ($fifo, $archive, $tmpdir) = $extract->@[-3 .. -1];
            make_path($tmpdir);
            my @lines = (
                "#qmdump#map:nvme0:drive-nvme0:local:raw:\n", "nvme0: $volume,$options\n",
            );
            @lines = reverse @lines if $reverse;
            PVE::Tools::file_set_contents("$tmpdir/qemu-server.conf", join('', @lines));
            # Keep the FIFO open in both directions to simulate the extractor.
            sysopen(my $reader, $fifo, O_RDWR) or die "open test FIFO: $!";
            $opts{afterfork}->();
            $opts{outfunc}->("DEV: dev_id=1 size: $source_size devname: drive-nvme0");
            $opts{outfunc}->('CTIME: test backup');
            push @events, 'restore';
            close($reader);
        },
    );
    for $reverse (0, 1) {
        for my $entry (
            ['ms=8,pi=1', 257 * 1024**2, 0],
            ['ms=8,pi=1', $source_size, 1],
            ['ms=0', 257 * 1024**2, 1],
        ) {
            ($options, $target_size, my $allowed) = @$entry;
            @events = ();
            eval {
                PVE::QemuServer::restore_vma_archive(
                    '/tmp/nvme-lifecycle.vma',
                    8007,
                    'root@pam',
                    { override_conf => {} },
                    undef,
                );
            };
            if ($allowed) {
                is($@, '', 'restores with a compatible metadata offset or no metadata succeed');
                is_deeply(
                    \@events,
                    ['allocate', 'activate', 'restore', 'deactivate', 'write-8007'],
                    'compatible restores copy their archive and install the VM configuration',
                );
            } else {
                like(
                    $@,
                    qr/target image size changes the metadata offset/,
                    'backup restore rejects storage rounding which moves NVMe metadata',
                );
                is_deeply(
                    \@events,
                    ['allocate', 'activate', 'deactivate', 'free'],
                    'incompatible restores clean up before extracting disk data or saving configuration',
                );
            }
        }
    }
}

{
    my $source_size = 256 * 1024**2 + 65536;
    my $target_size;
    my $source_volume = 'local:8006/vm-8006-disk-0.raw';
    my $target_volume = 'target:8007/vm-8007-disk-0.raw';
    $storage->mock(
        volume_size_info => sub { $_[1] eq $source_volume ? $source_size : $target_size },
    );
    $storage->mock(file_size_info => sub { return ($source_size, 'raw'); });
    $storage->mock(abs_filesystem_path => sub { $_[1] });
    $storage->mock(check_volume_access => sub { });
    $storage->mock(storage_check_enabled => sub { { type => 'dir', content => { images => 1 } } });
    $storage->mock(volume_has_feature => sub { 1 });
    $qemu_config->mock(lock_config_shared => sub { $_[3]->(); });
    $qemu_config->mock(lock_config_full => sub { $_[3]->(); });
    $qemu_config->mock(assert_config_exists_on_node => sub { });
    $qemu_server->mock(
        clone_disk => sub {
            push @{ $_[4] }, $target_volume;
            push @events, 'import';
            return { file => $target_volume, size => $target_size };
        },
    );
    $qemu_server->mock(vmconfig_apply_pending => sub { push @events, 'apply'; });
    my $import = Test::MockModule->new('PVE::QemuServer::ImportDisk');
    $import->mock(
        do_import => sub { push @events, 'import'; return ($source_size, $target_volume); });
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    $helpers->mock(vm_running_locally => sub { 0 });
    $cluster->mock(log_msg => sub { });
    my $image = Test::MockModule->new('PVE::QemuServer::QemuImage');
    $image->mock(initialize_nvme_pi => sub { die "must not initialize imported metadata\n"; });

    for my $source ('/tmp/nvme-lifecycle-import.raw', $source_volume) {
        for my $entry (
            ['ms=8,pi=1', 257 * 1024**2, 0],
            ['ms=8,pi=1', $source_size, 1],
            ['ms=0', 257 * 1024**2, 1],
        ) {
            my ($options, $size, $allowed) = @$entry;
            $target_size = $size;
            %configs = (8006 => {}, 8007 => { pending => {} });
            @events = ();
            eval {
                PVE::API2::Qemu->update_vm({
                    node => 'pve',
                    vmid => 8007,
                    nvme0 => "target:0,import-from=$source,$options",
                });
            };
            if ($allowed) {
                is($@, '', 'raw and managed-volume imports preserve valid metadata layouts');
                ok(
                    grep($_ eq 'apply', @events),
                    'compatible imports apply their new disk configuration',
                );
            } else {
                like(
                    $@,
                    qr/target image size changes the metadata offset/,
                    'raw and managed-volume imports reject incompatible storage rounding',
                );
                is_deeply(
                    \@events,
                    ['import', 'free'],
                    'failed imports free their destination before installing a disk configuration',
                );
                ok(
                    !exists($configs{8007}->{pending}->{nvme0}),
                    'failed import does not leave an invalid pending namespace',
                );
            }
        }
    }
}

{
    my $target_volume = 'target:vm-8006-disk-9';
    my $source_size = 256 * 1024**2 + 65536;
    my $target_size;
    my $missing;
    my $query_error;
    my @migration_events;
    my $migration = Test::MockModule->new('PVE::QemuMigrate');
    $migration->mock(log => sub { });
    my $tools = Test::MockModule->new('PVE::Tools');
    $tools->mock(
        run_command => sub {
            my ($command, %options) = @_;
            if ($command->[2] eq 'free') {
                push @migration_events, 'free-target';
                is($command->[3], $target_volume,
                    'migration cleanup frees the imported target');
                return;
            }
            push @migration_events, 'query';
            is_deeply(
                $command,
                [
                    'pvesh',
                    'get',
                    "/nodes/targetnode/storage/target/content/$target_volume",
                    '--output-format',
                    'json',
                ],
                'in-cluster migration queries attributes of the actual target volume',
            );
            die "target query failed\n" if $query_error;
            my $result = $missing ? {} : { size => $target_size };
            my $output = JSON::encode_json($result);
            my $split = int(length($output) / 2);
            $options{outfunc}->(substr($output, 0, $split));
            $options{outfunc}->(substr($output, $split));
        },
    );
    $storage->mock(
        storage_migrate => sub {
            push @migration_events, 'copy';
            return $target_volume;
        },
    );
    $storage->mock(
        deactivate_volumes => sub {
            push @migration_events, 'deactivate-source';
        },
    );
    my $storage_tunnel = Test::MockModule->new('PVE::StorageTunnel');
    $storage_tunnel->mock(
        storage_migrate => sub {
            push @migration_events, 'copy';
            return $target_volume;
        },
    );
    my $tunnel = Test::MockModule->new('PVE::Tunnel');
    $tunnel->mock(
        write_tunnel => sub {
            my ($connection, $timeout, $command, $params) = @_;
            push @migration_events, 'query';
            is($command, 'query-disk-size', 'remote migration queries the imported disk size');
            is_deeply(
                $params,
                { volid => $target_volume },
                'query uses the actual renamed volume ID',
            );
            die "target query failed\n" if $query_error;
            return $missing ? {} : { size => $target_size };
        },
    );
    $tunnel->mock(
        finish_tunnel => sub {
            push @migration_events, 'abort-target';
            is($_[1], 1, 'remote failure requests cleanup of the target tunnel');
        },
    );

    for my $remote (0, 1) {
        for my $section ('current', 'pending', 'snapshot') {
            for my $entry (
                ['ms=8,pi=1', $source_size, 1],
                ['ms=8', $source_size + 1, 1],
                ['ms=8,pi=1', 257 * 1024**2, 0],
                ['ms=16,logical_block_size=4096', 257 * 1024**2, 0],
                ['ms=0', 257 * 1024**2, 1],
            ) {
                my ($options, $size, $allowed) = @$entry;
                my $drive_conf = { nvme0 => "$volume,$options" };
                my $conf =
                    $section eq 'current' ? $drive_conf
                    : $section eq 'pending' ? { pending => $drive_conf }
                    : { snapshots => { before => $drive_conf } };
                my $self = bless {
                    vmid => 8006,
                    node => 'targetnode',
                    vmconf => $conf,
                    storecfg => {},
                    opts => {
                        migration_type => 'secure',
                        ($remote ? (remote => { vmid => 8007 }) : ()),
                    },
                    rem_ssh => ['ssh-target'],
                    tunnel => {},
                    volume_map => {},
                    local_volumes => {
                        $volume => {
                            migration_mode => 'offline',
                            replicated => 0,
                            targetsid => 'target',
                            size => $source_size,
                        },
                    },
                    },
                    'PVE::QemuMigrate';
                $target_size = $size;
                @migration_events = ();
                eval { $self->sync_offline_local_volumes(); };
                if ($allowed) {
                    is($@, '', "$section metadata layout is preserved during migration ($remote)");
                    is_deeply(
                        \@migration_events,
                        ['copy', ($options eq 'ms=0' ? () : ('query')), 'deactivate-source'],
                        'compatible migrations keep the existing source deactivation order',
                    );
                } else {
                    like(
                        $@,
                        qr/target image size changes the metadata offset/,
                        "$section metadata rejects target allocation rounding ($remote)",
                    );
                    is_deeply(
                        \@migration_events,
                        ['copy', 'query'],
                        'layout failure stops before deactivating or removing the source',
                    );
                    $self->cleanup_remotedisks();
                    is(
                        $migration_events[-1],
                        $remote ? 'abort-target' : 'free-target',
                        'failed migration can clean up its copied target',
                    );
                }
                is(
                    $self->{volume_map}->{$volume},
                    $target_volume,
                    'imported target is registered for normal migration cleanup',
                );
            }
        }

        for my $failure ('missing', 'zero', 'query') {
            my $self = bless {
                vmid => 8006,
                node => 'targetnode',
                vmconf => { nvme0 => "$volume,ms=8" },
                storecfg => {},
                opts =>
                    { migration_type => 'secure', ($remote ? (remote => { vmid => 8007 }) : ()) },
                rem_ssh => ['ssh-target'],
                tunnel => {},
                volume_map => {},
                local_volumes => {
                    $volume => {
                        migration_mode => 'offline',
                        replicated => 0,
                        targetsid => 'target',
                        size => $source_size,
                    },
                },
                },
                'PVE::QemuMigrate';
            $target_size = 0;
            $missing = $failure eq 'missing';
            $query_error = $failure eq 'query';
            @migration_events = ();
            eval { $self->sync_offline_local_volumes(); };
            like(
                $@,
                qr/unable to determine target size|target query failed/,
                'missing size and target query failures abort metadata migration',
            );
            is_deeply(
                \@migration_events,
                ['copy', 'query'],
                'failed size queries leave the source intact',
            );
            is(
                $self->{volume_map}->{$volume},
                $target_volume,
                'failed size queries retain the target for cleanup',
            );
        }
        $missing = $query_error = 0;
    }

    my $state = { storecfg => {}, cleanup => { volumes => { $target_volume => 1 } } };
    $storage->mock(activate_volumes => sub { push @migration_events, 'activate-target'; });
    $storage->mock(volume_size_info =>
        sub { push @migration_events, 'read-target-size'; return $target_size; });
    @migration_events = ();
    eval { PVE::QemuMigrate::Helpers::get_imported_volume_size($state, $volume); };
    like($@, qr/was not imported by this migration tunnel/,
        'tunnel cannot query unrelated volumes');
    is_deeply(\@migration_events, [], 'unrelated volumes are neither activated nor probed');

    for my $size (undef, 0, $source_size) {
        $target_size = $size;
        @migration_events = ();
        my $result =
            eval { PVE::QemuMigrate::Helpers::get_imported_volume_size($state, $target_volume); };
        if ($size) {
            is($@, '', 'tunnel can query its imported volume');
            is($result, $size, 'tunnel reports the actual byte size');
        } else {
            like(
                $@,
                qr/unable to determine size for imported volume/,
                'tunnel rejects absent and zero imported sizes',
            );
        }
        is_deeply(
            \@migration_events,
            ['activate-target', 'read-target-size'],
            'tunnel activates imported storage before querying its size',
        );
    }
}

{
    my $new_volume = 'target:8007/vm-8007-disk-0.raw';
    my $base_volume = 'target:8007/base-8007-disk-0.raw';
    my $failure;
    my $actual_size;
    my @initialized;
    $storage->mock(storage_default_format => sub { 'raw' });
    $storage->mock(storage_check_enabled => sub { { type => 'dir', content => { images => 1 } } });
    $storage->mock(check_volume_access => sub { });
    $storage->mock(volume_size_info => sub { $actual_size });
    $storage->mock(vdisk_alloc => sub { push @events, 'allocate'; return $new_volume; });
    $storage->mock(vdisk_free => sub { push @events, "free-$_[1]"; });
    $storage->mock(
        vdisk_create_base => sub {
            push @events, 'base';
            die "base creation failed\n" if ($failure // '') eq 'base';
            return $base_volume;
        },
    );
    $qemu_config->mock(lock_config_shared => sub { $_[3]->(); });
    $qemu_config->mock(lock_config_full => sub { $_[3]->(); });
    $qemu_config->mock(assert_config_exists_on_node => sub { });
    $qemu_server->mock(vmconfig_apply_pending => sub { push @events, 'apply'; });
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    $helpers->mock(vm_running_locally => sub { 0 });
    $cluster->mock(log_msg => sub { });
    my $image = Test::MockModule->new('PVE::QemuServer::QemuImage');
    $image->mock(
        initialize_nvme_pi => sub {
            push @events, 'initialize';
            push @initialized, dclone($_[1]);
            die "PI initialization failed\n" if ($failure // '') eq 'initialize';
        },
    );

    for my $template (0, 1) {
        for my $options ('ms=8,pi=1', 'ms=8,pi=1,ro=1', 'ms=8,pi=0', 'ms=0') {
            %configs = (8007 => { pending => {}, template => $template });
            @events = @initialized = ();
            $actual_size = 65 * 1024**2; # Storage rounded the request upwards.
            $failure = undef;
            eval {
                PVE::API2::Qemu->update_vm({
                    node => 'pve',
                    vmid => 8007,
                    nvme0 => "target:0.0625,$options",
                });
            };
            is($@, '', 'new PI, read-only and metadata-only disks can be created');
            my $pi = $options =~ /pi=1/ ? 1 : 0;
            is_deeply(
                [grep { /^(?:allocate|initialize|base)$/ } @events],
                ['allocate', $pi ? ('initialize') : (), $template ? ('base') : ()],
                'only new PI disks are initialized, before read-only base conversion',
            );
            is(scalar(@initialized), $pi, 'each new PI image is initialized exactly once');
            is($initialized[0]->{file}, $new_volume, 'initialize the allocated writable volume')
                if $pi;
            my $drive = parse_drive('nvme0', $configs{8007}->{pending}->{nvme0});
            is(
                $drive->{size},
                $drive->{ms} ? $actual_size : 64 * 1024**2,
                'metadata disks save the actual allocated capacity',
            );
            is($drive->{file}, $template ? $base_volume : $new_volume, 'save the final volume ID');
        }

        for my $fail ('initialize', $template ? ('base', 'size') : ()) {
            %configs = (8007 => { pending => {}, template => $template });
            @events = @initialized = ();
            $failure = $fail;
            $actual_size = $fail eq 'size' ? 1 : 64 * 1024**2;
            eval {
                PVE::API2::Qemu->update_vm({
                    node => 'pve',
                    vmid => 8007,
                    nvme0 => 'target:0.0625,ms=8,pi=1',
                });
            };
            like(
                $@,
                qr/PI initialization failed|base creation failed|at least one complete/,
                'allocation and validation failures abort the update',
            );
            is_deeply(
                \@events,
                [
                    'allocate',
                    'initialize',
                    $fail ne 'initialize' ? ('base') : (),
                    'free-' . ($fail eq 'size' ? $base_volume : $new_volume),
                ],
                'free the current volume ID without writing a failed disk configuration',
            );
            ok(!exists($configs{8007}->{pending}->{nvme0}), 'failed PI disk is not attached');
        }
    }

    %configs = (8007 => { pending => {} });
    @events = @initialized = ();
    $actual_size = 64 * 1024**2;
    $failure = undef;
    eval {
        PVE::API2::Qemu->update_vm({
            node => 'pve',
            vmid => 8007,
            nvme0 => "$new_volume,ms=8,pi=1",
        });
    };
    is($@, '', 'existing PI disks can still be attached');
    is_deeply(\@initialized, [], 'attaching an existing image never initializes metadata');
    ok(
        !grep(/^(?:allocate|initialize|base|free-)/, @events),
        'existing images are neither allocated nor rewritten',
    );
}

done_testing();
