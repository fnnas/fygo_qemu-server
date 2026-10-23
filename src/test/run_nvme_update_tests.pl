#!/usr/bin/perl

use strict;
use warnings;

use Storable qw(dclone);
use Test::More;
use Test::MockModule;

use PVE::API2::Qemu;
use PVE::QemuServer::Drive qw(parse_drive);
use PVE::QemuServer::NVMe;

my $owner_volume = 'local:8006/vm-8006-disk-0.raw';
my $child_volume = 'local:8006/vm-8006-disk-1.raw';
my $size = 1024**3;
my $conf;
my @events;
my @written_configs;
my $write_error;
my $before_worker;
my $scheduled;
my $running;
my $rpc = bless {}, 'NVMeUpdateRPC';
{

    package NVMeUpdateRPC;
    sub get_user { 'root@pam' }
    sub check { 1 }
    sub check_vm_perm { 1 }

    sub fork_worker {
        $scheduled++;
        $before_worker->() if $before_worker;
        $_[-1]->();
        return 'test-worker';
    }
}
my $rpc_module = Test::MockModule->new('PVE::RPCEnvironment');
$rpc_module->mock(get => sub { $rpc });
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });
$cluster->mock(log_msg => sub { });
my $storage = Test::MockModule->new('PVE::Storage');
$storage->mock(
    config => sub {
        return {
            ids => {
                local =>
                    { type => 'dir', path => '/tmp/nvme-update', content => { images => 1 } },
            },
        };
    },
);
$storage->mock(check_volume_access => sub { });
$storage->mock(activate_volumes => sub { });
$storage->mock(volume_size_info => sub { $size });
for my $method (qw(vdisk_alloc vdisk_free rename_volume)) {
    $storage->mock($method => sub { die "unexpected storage operation: $method\n"; });
}
my $config = Test::MockModule->new('PVE::QemuConfig');
$config->mock(load_config => sub { dclone($conf) });
$config->mock(check_lock => sub { });
$config->mock(
    lock_config => sub {
        push @events, 'lock';
        $_[2]->();
    },
);
$config->mock(
    write_config => sub {
        die "$write_error\n" if $write_error;
        push @events, 'write';
        PVE::QemuServer::write_vm_config('nodes/pve/qemu-server/8006.conf', $_[2]);
        $conf = dclone($_[2]);
        push @written_configs, dclone($conf);
    },
);
my $qemu = Test::MockModule->new('PVE::QemuServer');
$qemu->mock(check_running => sub { $running });
my $machine = Test::MockModule->new('PVE::QemuServer::Machine');
$machine->mock(get_current_qemu_machine => sub { 'pc-i440fx-11.1' });
for my $method (qw(vm_deviceplug vm_deviceunplug)) {
    $qemu->mock($method => sub { die "unexpected device operation: $method\n"; });
}
my $replication = Test::MockModule->new('PVE::ReplicationConfig');
$replication->mock(new => sub { bless {}, 'NVMeUpdateReplication' });
{

    package NVMeUpdateReplication;
    sub check_for_existing_jobs { 0 }
}

my @cases = (
    {
        name => 'namespace ID',
        current => "$owner_volume,nsid=1,size=$size",
        pending => "$owner_volume,nsid=2,size=$size",
        child => "$child_volume,nvme-controller=0,nsid=1,size=$size",
        error => qr/duplicate NVMe namespace identifier/,
    },
    {
        name => 'FDP handle pool',
        current => "$owner_volume,fdp=1,fdp-nruh=1,fdp-ruhs=0,size=$size",
        pending => "$owner_volume,fdp=1,fdp-nruh=2,fdp-ruhs=0,size=$size",
        child => "$child_volume,nvme-controller=0,fdp-ruhs=1,size=$size",
        error => qr/FDP handle exceeds the subsystem handle count/,
    },
    {
        name => 'FDP reclaim unit alignment',
        current => "$owner_volume,fdp=1,fdp-nruh=2,fdp-ruhs=0,fdp-runs=512,size=$size",
        pending => "$owner_volume,fdp=1,fdp-nruh=2,fdp-ruhs=0,fdp-runs=4096,size=$size",
        child =>
            "$child_volume,nvme-controller=0,fdp-ruhs=1,logical_block_size=4096,size=$size",
        error => qr/FDP reclaim unit size must be aligned/,
    },
);
my $reset = sub {
    my ($case) = @_;
    $conf = {
        nvme0 => $case->{current},
        pending => { nvme0 => $case->{pending}, nvme1 => $case->{child} },
    };
    @events = ();
    @written_configs = ();
    $write_error = undef;
    $scheduled = 0;
    $before_worker = undef;
};
my $update = sub {
    my ($async, $revert) = @_;
    my $params = { node => 'pve', vmid => 8006, revert => $revert };
    return $async
        ? PVE::API2::Qemu->update_vm_async($params)
        : PVE::API2::Qemu->update_vm($params);
};

for my $async (0, 1) {
    for my $is_running (0, 1) {
        for my $options (
            ['fdp-ruhs=0', 'fdp-ruhs=1,logical_block_size=4096'],
            ['fdp-ruhs=0,ms=8', 'fdp-ruhs=1,ms=16'],
            ['', 'fdp-ruhs=0,logical_block_size=4096'],
        ) {
            $reset->($cases[0]);
            $running = $is_running;
            $conf = { pending => {} };
            my $changes = {
                nvme0 =>
                    join(',', "$owner_volume,fdp=1,fdp-nruh=2", grep { length } $options->[0]),
                nvme1 => "$child_volume,nvme-controller=0,$options->[1]",
            };
            my $params = { node => 'pve', vmid => 8006, %$changes };
            eval {
                $async
                    ? PVE::API2::Qemu->update_vm_async($params)
                    : PVE::API2::Qemu->update_vm($params);
            };
            is($@, '', "create independent FDP formats (async=$async, running=$is_running)");
            my $effective = { %$conf, $conf->{pending}->%* };
            for my $id (qw(nvme0 nvme1)) {
                my $drive =
                    defined($effective->{$id}) ? parse_drive($id, $effective->{$id}) : undef;
                is_deeply(
                    $drive,
                    parse_drive($id, "$changes->{$id},size=$size"),
                    "independent FDP format and handle assignment retained on $id",
                );
                is(
                    exists($conf->{$id}) ? 1 : 0,
                    !$is_running ? 1 : 0,
                    'FDP changes become active only while stopped',
                );
            }
        }
    }
}

for my $case (@cases) {
    for my $async (0, 1) {
        for my $is_running (0, 1) {
            $running = $is_running;
            for my $revert ('nvme0,nvme1', 'nvme1,nvme0') {
                $reset->($case);
                eval { $update->($async, $revert); };
                is(
                    $@,
                    '',
                    "$case->{name} combined revert succeeds (async=$async, running=$running, $revert)",
                );
                is($scheduled, $async, 'asynchronous requests reach exactly one worker');
                is_deeply(
                    parse_drive('nvme0', $conf->{nvme0}),
                    parse_drive('nvme0', $case->{current}),
                    'original controller configuration is preserved',
                );
                ok(!exists($conf->{nvme1}), 'reverted new namespace is not attached');
                is_deeply(
                    $conf->{pending},
                    {},
                    'combined revert clears the selected pending changes',
                );
                my @unused = map { parse_drive($_, $conf->{$_})->{file} }
                    grep { /^unused\d+$/ } keys %$conf;
                is_deeply(
                    \@unused,
                    [$child_volume],
                    'new namespace volume is retained as an unused disk',
                );
                eval { PVE::QemuServer::NVMe::topology($conf); };
                is($@, '', 'the resulting active topology remains valid');
            }
        }
        for my $revert ('nvme0', 'nvme1') {
            $running = 0;
            $reset->($case);
            my $before = dclone($conf);
            eval { $update->($async, $revert); };
            if ($revert eq 'nvme0') {
                like(
                    $@,
                    $case->{error},
                    'reverting only the owner still rejects the conflicting child',
                );
                is($scheduled, 0, 'invalid partial revert is rejected before scheduling a worker');
                is_deeply(
                    \@events,
                    [],
                    'invalid partial revert never locks or writes configuration',
                );
                is_deeply($conf, $before, 'invalid partial revert preserves every pending change');
            } else {
                is($@, '', 'a newly added child can be reverted on its own');
                is(
                    $conf->{nvme0},
                    $case->{pending},
                    'unselected controller changes remain effective',
                );
                ok(!exists($conf->{nvme1}), 'reverting only the child removes its attachment');
            }
        }
    }
}

for my $async (0, 1) {
    for my $is_running (0, 1) {
        $running = $is_running;
        $reset->($cases[0]);
        $conf = {
            pending => {
                nvme0 => "$owner_volume,nsid=1,size=$size",
                nvme1 => "$child_volume,nvme-controller=0,nsid=2,size=$size",
            },
        };
        eval { $update->($async, 'nvme0,nvme1'); };
        is($@, '', 'a newly added controller and all its namespaces can be reverted together');
        ok(
            !exists($conf->{nvme0}) && !exists($conf->{nvme1}),
            'reverted additions are not attached',
        );
        is_deeply($conf->{pending}, {}, 'reverted additions leave no pending changes');
        my @unused = sort map { parse_drive($_, $conf->{$_})->{file} }
            grep { /^unused\d+$/ } keys %$conf;
        is_deeply(
            \@unused,
            [$owner_volume, $child_volume],
            'both new volumes are retained as unused disks',
        );
    }
}

$running = 0;
$reset->($cases[0]);
my $raced_conf;
$before_worker = sub {
    $conf->{pending}->{nvme1} = "$child_volume,nvme-controller=0,nsid=3,size=$size";
    $conf->{pending}->{nvme2} = 'local:8006/vm-8006-disk-2.raw,nvme-controller=0,nsid=1';
    eval { PVE::QemuServer::NVMe::validate_update($conf, {}, []); };
    is($@, '', 'concurrent changes form a valid topology before the revert');
    $raced_conf = dclone($conf);
};
eval { $update->(1, 'nvme0,nvme1'); };
like(
    $@,
    qr/duplicate NVMe namespace identifier/,
    'locked check rejects a conflicting concurrent namespace',
);
is($scheduled, 1, 'race is introduced after the asynchronous precheck');
is_deeply(\@events, ['lock'], 'locked validation fails before any configuration write');
is_deeply($conf, $raced_conf, 'failed locked validation preserves the concurrent configuration');

my $failed_update = sub {
    my ($async, $changes, $error) = @_;
    my $before = dclone($conf);
    my $params = { node => 'pve', vmid => 8006, %$changes };
    eval {
        $async
            ? PVE::API2::Qemu->update_vm_async($params)
            : PVE::API2::Qemu->update_vm($params);
    };
    like($@, $error, 'failed disk preparation reports its original error');
    is_deeply($conf, $before,
        'failed NVMe batch preserves the complete original configuration');
    is(
        scalar(grep { $_ eq 'write' } @events),
        0,
        'failed preparation does not save a partial NVMe batch',
    );
    eval { PVE::QemuServer::NVMe::validate_update($conf, {}, []); };
    is($@, '', 'failed preparation leaves a valid effective NVMe topology');
};

for my $async (0, 1) {
    for my $scenario ('swap', 'reparent') {
        $running = 0;
        $reset->($cases[0]);
        $conf = {
            nvme0 => "$owner_volume,nsid=1,size=$size",
            nvme1 => "$child_volume,nvme-controller=0,nsid=2,size=$size",
            pending => { description => 'preserve this unrelated pending change' },
        };
        my $queries = 0;
        my $fail_at = $scenario eq 'swap' ? 2 : 1;
        $storage->mock(
            volume_size_info => sub {
                die "test volume query failure\n" if ++$queries == $fail_at;
                return $size;
            },
        );
        my $changes;
        if ($scenario eq 'swap') {
            $changes = {
                nvme0 => "$owner_volume,nsid=2",
                nvme1 => "$child_volume,nvme-controller=0,nsid=1",
            };
        } else {
            $conf->{nvme2} = 'local:8006/vm-8006-disk-2.raw';
            $changes = {
                delete => 'nvme0',
                nvme1 => "$child_volume,nvme-controller=2",
            };
        }
        $failed_update->($async, $changes, qr/test volume query failure/);
    }
}
$storage->mock(volume_size_info => sub { $size });

for my $async (0, 1) {
    $running = 0;
    $reset->($cases[0]);
    $conf = { pending => {} };
    my @allocated;
    my @freed;
    my $allocations = 0;
    $storage->mock(
        vdisk_alloc => sub {
            die "test disk allocation failure\n" if ++$allocations == 2;
            push @allocated, 'local:8006/vm-8006-disk-10.raw';
            return $allocated[-1];
        },
    );
    $storage->mock(vdisk_free => sub { push @freed, $_[1]; });
    $failed_update->(
        $async,
        {
            nvme0 => 'local:1,format=raw',
            nvme1 => 'local:1,format=raw,nvme-controller=0',
        },
        qr/test disk allocation failure/,
    );
    is_deeply(\@freed, \@allocated, 'failed batch frees all volumes allocated by that batch');
}

{
    my $import = Test::MockModule->new('PVE::QemuServer::ImportDisk');
    $storage->mock(abs_filesystem_path => sub { $_[1] });
    $storage->mock(file_size_info => sub { return ($size, 'raw'); });
    for my $async (0, 1) {
        $reset->($cases[0]);
        $conf = { pending => {} };
        my @imported;
        my @freed;
        my $imports = 0;
        $import->mock(
            do_import => sub {
                die "test disk import failure\n" if ++$imports == 2;
                push @imported, 'local:8006/vm-8006-disk-10.raw';
                return ($size, $imported[-1]);
            },
        );
        $storage->mock(vdisk_free => sub { push @freed, $_[1]; });
        $failed_update->(
            $async,
            {
                nvme0 => 'local:0,import-from=/tmp/nvme-owner.raw,format=raw',
                nvme1 => 'local:0,import-from=/tmp/nvme-child.raw,format=raw,nvme-controller=0',
            },
            qr/test disk import failure/,
        );
        is_deeply(\@freed, \@imported, 'failed batch frees its completed imports');
    }
}

for my $async (0, 1) {
    $reset->($cases[0]);
    $conf = { pending => {} };
    my @allocated;
    my @freed;
    $storage->mock(
        vdisk_alloc => sub {
            my $index = 10 + @allocated;
            push @allocated, "local:8006/vm-8006-disk-$index.raw";
            return $allocated[-1];
        },
    );
    $storage->mock(vdisk_free => sub { push @freed, $_[1]; });
    $write_error = 'test configuration save failure';
    $failed_update->(
        $async,
        {
            nvme0 => 'local:1,format=raw',
            nvme1 => 'local:1,format=raw,nvme-controller=0',
        },
        qr/test configuration save failure/,
    );
    is_deeply(\@freed, \@allocated, 'failed save frees all newly allocated batch volumes');
}

for my $async (0, 1) {
    $reset->($cases[0]);
    $conf = { nvme0 => "$owner_volume,nsid=1,size=$size", pending => {} };
    my @freed;
    $storage->mock(vdisk_free => sub { push @freed, $_[1]; });
    $write_error = 'test configuration save failure';
    $failed_update->(
        $async,
        { nvme0 => "$owner_volume,nsid=2" },
        qr/test configuration save failure/,
    );
    is_deeply(\@freed, [], 'failed save never frees existing volumes');
}

for my $async (0, 1) {
    $reset->($cases[0]);
    $conf = { pending => {} };
    my @allocated;
    my @freed;
    $storage->mock(
        vdisk_alloc => sub {
            my $index = 10 + @allocated;
            push @allocated, "local:8006/vm-8006-disk-$index.raw";
            return $allocated[-1];
        },
    );
    $storage->mock(vdisk_free => sub { push @freed, $_[1]; });
    my $params = {
        node => 'pve',
        vmid => 8006,
        nvme0 => 'local:1,format=raw',
        nvme1 => 'local:1,format=raw,nvme-controller=0',
    };
    eval {
        $async
            ? PVE::API2::Qemu->update_vm_async($params)
            : PVE::API2::Qemu->update_vm($params);
    };
    is($@, '', 'allocating a controller owner and child together succeeds');
    is(scalar(@allocated), 2, 'both namespace volumes are allocated');
    is_deeply(\@freed, [], 'successful batch retains its allocated volumes');
    my @attached = sort map { parse_drive($_, $conf->{$_})->{file} } qw(nvme0 nvme1);
    is_deeply(\@attached, [sort @allocated], 'each allocated volume is attached to its namespace');
    my @errors;
    for my $written (@written_configs) {
        eval { PVE::QemuServer::NVMe::validate_update($written, {}, []); };
        push @errors, $@ if $@;
    }
    is_deeply(\@errors, [], 'new controller and child are never saved as a partial topology');
}

for my $async (0, 1) {
    for my $is_running (0, 1) {
        $running = $is_running;
        for my $scenario ('swap', 'reparent') {
            $reset->($cases[0]);
            $conf = {
                nvme0 => "$owner_volume,nsid=1,size=$size",
                nvme1 => "$child_volume,nvme-controller=0,nsid=2,size=$size",
                pending => {},
            };
            my $changes;
            if ($scenario eq 'swap') {
                $changes = {
                    nvme0 => "$owner_volume,nsid=2",
                    nvme1 => "$child_volume,nvme-controller=0,nsid=1",
                };
            } else {
                $conf->{nvme2} = 'local:8006/vm-8006-disk-2.raw';
                $conf->{boot} = 'order=nvme0;nvme1;nvme2';
                $changes = {
                    delete => 'nvme0',
                    nvme1 => "$child_volume,nvme-controller=2",
                };
            }
            my $params = { node => 'pve', vmid => 8006, %$changes };
            eval {
                $async
                    ? PVE::API2::Qemu->update_vm_async($params)
                    : PVE::API2::Qemu->update_vm($params);
            };
            is($@, '', "valid NVMe $scenario succeeds (async=$async, running=$running)");
            my @errors;
            for my $written (@written_configs) {
                eval { PVE::QemuServer::NVMe::validate_update($written, {}, []); };
                push @errors, $@ if $@;
            }
            is_deeply(\@errors, [], 'every saved configuration has a valid effective topology');
            my $effective = { %$conf, $conf->{pending}->%* };
            if ($scenario eq 'swap') {
                is(
                    parse_drive('nvme0', $conf->{nvme0})->{nsid},
                    $is_running ? 1 : 2,
                    'namespace ID changes reach the active configuration only while stopped',
                );
                is(
                    exists($conf->{pending}->{nvme0}) ? 1 : 0,
                    $is_running,
                    'running namespace ID changes remain pending',
                );
                is(
                    parse_drive('nvme0', $effective->{nvme0})->{nsid},
                    2,
                    'owner NSID change is retained',
                );
                is(
                    parse_drive('nvme1', $effective->{nvme1})->{nsid},
                    1,
                    'child NSID change is retained',
                );
            } else {
                is(
                    exists($conf->{nvme0}) ? 1 : 0,
                    $is_running,
                    'the removed controller remains active until shutdown',
                );
                is(
                    parse_drive('nvme1', $conf->{nvme1})->{'nvme-controller'},
                    $is_running ? 0 : 2,
                    'namespace controller changes reach the active configuration only while stopped',
                );
                is(
                    parse_drive('nvme1', $effective->{nvme1})->{'nvme-controller'},
                    2,
                    'namespace moves to its new owner',
                );
                is(
                    $effective->{boot},
                    'order=nvme1;nvme2',
                    'removed owner is deleted from boot order',
                );
            }
        }
    }
}

for my $async (0, 1) {
    for my $bus (qw(nvme usbdisk emmc virtio scsi sata ide)) {
        $reset->($cases[0]);
        $running = 0;
        my $disk = "${bus}0";
        $conf = {
            $disk => "$owner_volume,size=$size",
            pending => { $disk => "$child_volume,size=$size" },
        };
        my @freed;
        $storage->mock(vdisk_free => sub { push @freed, $_[1]; });
        my $params = { node => 'pve', vmid => 8006, delete => $disk };
        eval {
            $async
                ? PVE::API2::Qemu->update_vm_async($params)
                : PVE::API2::Qemu->update_vm($params);
        };
        is($@, '', "deleting a $bus slot with a pending replacement succeeds");
        ok(!exists($conf->{$disk}), 'the active disk is detached');
        is_deeply($conf->{pending}, {}, 'pending replacement is removed');
        my @unused = sort map { parse_drive($_, $conf->{$_})->{file} }
            grep { /^unused\d+$/ } keys %$conf;
        is_deeply(
            \@unused,
            [$owner_volume, $child_volume],
            'active and pending volumes both remain as unused disks',
        );
        is_deeply(\@freed, [], 'detaching the slot does not free either volume');
    }
}

my $effective_boot = sub {
    return $conf->{pending}->{boot} if exists($conf->{pending}->{boot});
    my $deleted = PVE::QemuConfig->parse_pending_delete($conf->{pending}->{delete});
    return $deleted->{boot} ? undef : $conf->{boot};
};
my $check_boot_update = sub {
    my ($async, $changes, $expected, $message) = @_;
    my $params = { node => 'pve', vmid => 8006, %$changes };
    eval {
        $async
            ? PVE::API2::Qemu->update_vm_async($params)
            : PVE::API2::Qemu->update_vm($params);
    };
    is($@, '', "$message succeeds (async=$async, running=$running)");
    is($effective_boot->(), $expected, $message);
    if (defined($expected) && $expected eq '') {
        is_deeply(
            PVE::QemuServer::device_bootorder({ %$conf, boot => $effective_boot->() }),
            {},
            'an empty boot order does not enable other boot devices',
        );
    }
};

for my $async (0, 1) {
    for my $is_running (0, 1) {
        $running = $is_running;
        for my $bus (qw(nvme usbdisk virtio scsi sata ide)) {
            my @disks = map { "${bus}$_" } (0, 1, 2);
            my @boot_cases = (
                {
                    pending => "order=$disks[2];$disks[1];$disks[0]",
                    delete => $disks[0],
                    expected => "order=$disks[2];$disks[1]",
                    name => 'preserves the pending device priority',
                },
                {
                    pending => "order=$disks[1]",
                    delete => $disks[1],
                    expected => '',
                    name => 'leaves no boot devices when removing the last enabled one',
                },
                {
                    pending => '',
                    delete => $disks[0],
                    expected => '',
                    name => 'preserves an explicitly empty pending boot order',
                },
                {
                    pending => 'ncd',
                    delete => $disks[0],
                    expected => 'ncd',
                    name => 'preserves a pending switch to legacy boot order',
                },
                {
                    pending_delete => 'boot',
                    delete => $disks[0],
                    expected => undef,
                    name => 'preserves a pending boot configuration deletion',
                },
                {
                    delete => "boot,$disks[0]",
                    expected => undef,
                    name => 'honors boot deletion before disk deletion',
                },
                {
                    delete => "$disks[0],boot",
                    expected => undef,
                    name => 'honors boot deletion after disk deletion',
                },
            );
            for my $case (@boot_cases) {
                $reset->($cases[0]);
                $conf = {
                    $disks[0] => "$owner_volume,size=$size",
                    $disks[1] => "$child_volume,size=$size",
                    $disks[2] => "local:8006/vm-8006-disk-2.raw,size=$size",
                    boot => 'order=' . join(';', @disks),
                    hotplug => '0',
                    pending => {},
                };
                $conf->{pending}->{boot} = $case->{pending} if exists($case->{pending});
                $conf->{pending}->{delete} = $case->{pending_delete}
                    if $case->{pending_delete};
                $check_boot_update->(
                    $async,
                    { delete => $case->{delete} },
                    $case->{expected},
                    "deleting a $bus disk $case->{name}",
                );
            }
        }

        for my $scenario (qw(pending explicit empty deleted delete-request)) {
            $reset->($cases[0]);
            $conf = {
                nvme0 => "$owner_volume,size=$size",
                nvme1 => "$child_volume,size=$size",
                boot => 'order=nvme0;nvme1',
                hotplug => '0',
                pending => {},
            };
            my $changes = { ide2 => 'none,media=cdrom' };
            my $expected;
            if ($scenario eq 'pending') {
                $conf->{pending}->{boot} = 'order=nvme1;nvme0';
                $expected = 'order=nvme1;nvme0;ide2';
            } elsif ($scenario eq 'explicit' || $scenario eq 'empty') {
                $expected = $scenario eq 'empty' ? '' : 'order=nvme1';
                $changes->{boot} = $expected;
            } elsif ($scenario eq 'deleted') {
                $conf->{pending}->{delete} = 'boot';
            } else {
                $changes->{delete} = 'boot';
            }
            $check_boot_update->(
                $async,
                $changes,
                $expected,
                "adding a CD drive respects the $scenario boot configuration",
            );
        }
    }
}

my $reject_boot_update = sub {
    my ($async, $changes, $device) = @_;
    my $before = dclone($conf);
    my $params = { node => 'pve', vmid => 8006, %$changes };
    eval {
        $async
            ? PVE::API2::Qemu->update_vm_async($params)
            : PVE::API2::Qemu->update_vm($params);
    };
    like(
        $@,
        qr/invalid bootorder: device '$device' does not exist/,
        'a device absent from the effective configuration cannot be enabled for boot',
    );
    is_deeply($conf, $before, 'invalid boot order preserves every configuration entry');
    is_deeply(\@events, [], 'invalid boot order is rejected before locking or writing');
    is($scheduled, 0, 'invalid boot order does not schedule an asynchronous worker');
};

for my $async (0, 1) {
    for my $is_running (0, 1) {
        $running = $is_running;
        for my $bus (qw(nvme usbdisk virtio scsi sata ide)) {
            my $disk = "${bus}0";
            $reset->($cases[0]);
            $conf = {
                $disk => "$owner_volume,size=$size",
                hotplug => '0',
                pending => { delete => $disk },
            };
            $reject_boot_update->($async, { boot => "order=$disk" }, $disk);

            $reset->($cases[0]);
            $conf = { $disk => "$owner_volume,size=$size", pending => {} };
            $reject_boot_update->($async, { delete => $disk, boot => "order=$disk" }, $disk);

            $reset->($cases[0]);
            $conf = {
                $disk => "$owner_volume,size=$size",
                hotplug => '0',
                pending => { delete => $disk },
            };
            $check_boot_update->(
                $async,
                { $disk => $conf->{$disk}, boot => "order=$disk" },
                "order=$disk",
                "reattaching a $bus disk makes it available for boot",
            );
            my $deleted = PVE::QemuConfig->parse_pending_delete($conf->{pending}->{delete});
            ok(!$deleted->{$disk}, 'reattaching a disk cancels its pending deletion');
        }

        $reset->($cases[0]);
        $conf = { pending => {} };
        my @allocated;
        $storage->mock(
            vdisk_alloc => sub {
                push @allocated, 'local:8006/vm-8006-disk-10.raw';
                return $allocated[-1];
            },
        );
        $reject_boot_update->(
            $async, { nvme0 => 'local:1,format=raw', boot => 'order=nvme1' }, 'nvme1',
        );
        is_deeply(\@allocated, [], 'invalid boot order is rejected before allocating volumes');

        $reset->($cases[0]);
        $conf = { pending => { nvme0 => "$owner_volume,size=$size" }, hotplug => '0' };
        $check_boot_update->(
            $async,
            { boot => 'order=nvme0' },
            'order=nvme0',
            'an existing pending addition can be enabled for boot',
        );

        $reset->($cases[0]);
        $conf = { pending => {}, hotplug => '0' };
        $check_boot_update->(
            $async,
            { nvme0 => "$owner_volume,size=$size", boot => 'order=nvme0' },
            'order=nvme0',
            'a disk added in the same request can be enabled for boot',
        );

        for my $revert ('boot,nvme0,usbdisk0', 'usbdisk0,nvme0,boot') {
            $reset->($cases[0]);
            $conf = {
                nvme0 => "$owner_volume,size=$size",
                usbdisk0 => "$child_volume,size=$size",
                boot => 'order=nvme0;usbdisk0',
                hotplug => '0',
                pending => { delete => 'nvme0,usbdisk0', boot => '' },
            };
            $check_boot_update->(
                $async,
                { revert => $revert },
                'order=nvme0;usbdisk0',
                'boot order and disk deletions can be reverted together',
            );
            is_deeply($conf->{pending}, {}, 'combined revert clears all selected pending changes');
        }

        $reset->($cases[0]);
        $conf = {
            nvme0 => "$owner_volume,size=$size",
            boot => 'order=nvme0',
            pending => { delete => 'nvme0', boot => '' },
        };
        $reject_boot_update->($async, { revert => 'boot' }, 'nvme0');
    }
}

$reset->($cases[0]);
$running = 0;
$conf = { nvme0 => "$owner_volume,size=$size", pending => {} };
$before_worker = sub {
    $conf->{pending}->{delete} = 'nvme0';
    $raced_conf = dclone($conf);
};
eval { PVE::API2::Qemu->update_vm_async({ node => 'pve', vmid => 8006, boot => 'order=nvme0' }); };
like(
    $@,
    qr/invalid bootorder: device 'nvme0' does not exist/,
    'locked boot validation detects a concurrent disk deletion',
);
is($scheduled, 1, 'the concurrent deletion happens after the successful early check');
is_deeply(\@events, ['lock'], 'locked boot validation fails before saving configuration');
is_deeply($conf, $raced_conf, 'locked boot validation preserves the concurrent deletion');

{
    my $volume_size;
    my $resize = sub {
        my ($disk, $size) = @_;
        return PVE::API2::Qemu->resize_vm({
            node => 'pve',
            vmid => 8006,
            disk => $disk,
            size => $size // '+1G',
        });
    };
    $storage->mock(activate_volumes => sub { push @events, 'activate'; });
    $storage->mock(volume_size_info => sub { $volume_size });
    $storage->mock(
        volume_resize => sub {
            push @events, 'resize';
            $volume_size = $_[2];
        },
    );
    $storage->mock(
        path => sub {
            (my $path = $_[1]) =~ s!^(local|alias):!/tmp/nvme-update/images/!;
            return $path;
        },
    );
    $storage->mock(storage_config => sub { return { type => 'dir', path => '/tmp/nvme-update' }; });
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    $helpers->mock(vm_running_locally => sub { $running });
    my $blockdev = Test::MockModule->new('PVE::QemuServer::Blockdev');
    $blockdev->mock(get_block_info =>
        sub { return { scsi0 => { inserted => { 'node-name' => 'drive-scsi0' } } }; });
    $blockdev->mock(mon_cmd => sub { push @events, 'notify'; });

    for my $bus (qw(nvme usbdisk emmc virtio scsi sata ide)) {
        my $disk = "${bus}0";
        for my $pending ('same-volume', 'replacement', 'delete', 'force-delete') {
            $reset->($cases[0]);
            $running = 0;
            $volume_size = $size;
            $conf = { $disk => "$owner_volume,size=$size", pending => {} };
            if ($pending =~ /delete/) {
                $conf->{pending}->{delete} = ($pending eq 'force-delete' ? '!' : '') . $disk;
            } else {
                my $file = $pending eq 'same-volume' ? $owner_volume : $child_volume;
                $conf->{pending}->{$disk} = "$file,cache=writeback,size=$size";
            }
            my $before = dclone($conf);
            eval { $resize->($disk); };
            like($@, qr/disk '$disk'.*pending changes/, 'resize refuses pending disk changes');
            is($volume_size, $size,
                'pending resize refusal leaves the original volume size intact');
            is_deeply(
                \@events,
                ['lock'],
                'pending resize refusal happens before storage activation',
            );
            is_deeply($conf, $before, 'pending resize refusal preserves all configuration');
        }

        $reset->($cases[0]);
        $running = 0;
        $volume_size = $size;
        $conf = { $disk => "$owner_volume,size=$size", pending => {} };
        my $concurrent;
        $before_worker = sub {
            my $options = $bus eq 'nvme' ? 'ms=8,pi=1' : 'cache=writeback';
            $conf->{pending}->{$disk} = "$owner_volume,$options,size=$size";
            $concurrent = dclone($conf);
        };
        eval { $resize->($disk); };
        like(
            $@,
            qr/disk '$disk'.*pending changes/,
            'resize checks concurrent pending changes under lock',
        );
        is($volume_size, $size, 'a concurrent pending change prevents growing the volume');
        is_deeply(\@events, ['lock'],
            'a concurrent pending change prevents all storage operations');
        is_deeply($conf, $concurrent, 'a concurrent pending change is preserved');

        $reset->($cases[0]);
        $running = 0;
        $volume_size = $size;
        $conf = {
            $disk => "$owner_volume,size=$size",
            pending => { description => 'retain this unrelated pending setting' },
        };
        eval { $resize->($disk); };
        is($@, '', 'unrelated pending changes allow ordinary offline resize');
        is($volume_size, 2 * $size, 'ordinary resize grows the actual volume');
        is(
            parse_drive($disk, $conf->{$disk})->{size},
            2 * $size,
            'ordinary resize saves the new size',
        );
        is(
            $conf->{pending}->{description},
            'retain this unrelated pending setting',
            'ordinary resize retains unrelated pending settings',
        );
    }

    my $small_size = 26 * 1024**2;
    for my $case (
        ['nvme0', 'ms=8,pi=1', 0],
        ['emmc0', 'boot-partition-size=4194304,rpmb-partition-size=2097152', 0],
        ['nvme0', '', 1],
        ['emmc0', '', 1],
        ['sdcard0', 'sd-spec-version=3', 0],
        ['sdcard0', '', 1],
    ) {
        my ($reference_disk, $options, $live) = @$case;
        for my $section ('current', 'pending') {
            next if $live && $section eq 'pending';
            for my $reference (
                $owner_volume,
                '/tmp/nvme-update/images/8006/vm-8006-disk-0.raw',
                'alias:8006/vm-8006-disk-0.raw',
            ) {
                for my $concurrent (0, 1) {
                    $reset->($cases[0]);
                    $running = $live;
                    $volume_size = $small_size;
                    $conf = { scsi0 => "$owner_volume,size=$small_size", pending => {} };
                    my $before;
                    my $stage = sub {
                        my $section_conf = $section eq 'pending' ? $conf->{pending} : $conf;
                        $section_conf->{$reference_disk} =
                            "$reference"
                            . ($options ne '' ? ",$options" : '')
                            . ",size=$small_size";
                        $before = dclone($conf);
                    };
                    if ($concurrent) {
                        $before_worker = $stage;
                    } else {
                        $stage->();
                    }
                    eval { $resize->('scsi0', '+1M'); };
                    like(
                        $@,
                        qr/volume.*referenced by another NVMe, eMMC or SD card disk/,
                        'resizing through another slot cannot bypass layout or running-device restrictions',
                    );
                    is(
                        $volume_size,
                        $small_size,
                        'an aliased layout reference protects the actual volume size',
                    );
                    is_deeply(
                        \@events,
                        ['lock', 'activate'],
                        'aliased layout references are checked before growing storage or saving configuration',
                    );
                    is_deeply(
                        $conf,
                        $before,
                        'refusing an aliased resize preserves current and pending configuration',
                    );
                }
            }
        }
    }

    for my $case (
        ['nvme0', 'ms=8,pi=1', 0],
        ['emmc0', 'boot-partition-size=4194304,rpmb-partition-size=2097152', 0],
        ['nvme0', '', 1],
        ['emmc0', '', 1],
    ) {
        $reset->($cases[0]);
        $running = $case->[2];
        $volume_size = $small_size;
        my $reference = "$owner_volume" . ($case->[1] ne '' ? ",$case->[1]" : '');
        $conf = {
            scsi0 => "$owner_volume,size=$small_size",
            $case->[0] => $reference,
            pending => {},
        };
        my $before = dclone($conf);
        eval { $resize->('scsi0', "$small_size"); };
        is($@, '', 'unchanged size requests remain harmless for protected aliases');
        is($volume_size, $small_size, 'unchanged size requests retain the actual size');
        is_deeply(\@events, ['lock', 'activate'], 'unchanged size requests do not resize or write');
        is_deeply($conf, $before, 'unchanged size requests preserve configuration');
    }

    for my $disk ('nvme0', 'emmc0') {
        $reset->($cases[0]);
        $running = 1;
        $volume_size = $size;
        $conf = { $disk => "$owner_volume,size=$size", pending => {} };
        eval { $resize->($disk); };
        like(
            $@,
            qr/cannot resize.*while the VM is running/,
            'direct live NVMe and eMMC resize stays forbidden',
        );
        is($volume_size, $size, 'direct live resize refusal preserves the actual size');
    }

    for my $case (['nvme0', 'ms=8,pi=1'], ['emmc0', 'boot-partition-size=4194304']) {
        for my $section ('current', 'pending') {
            $reset->($cases[0]);
            $running = 0;
            $volume_size = $size;
            $conf = { scsi0 => "$owner_volume,size=$size", pending => {} };
            my $section_conf = $section eq 'pending' ? $conf->{pending} : $conf;
            $section_conf->{ $case->[0] } = "$child_volume,$case->[1]";
            eval { $resize->('scsi0'); };
            is($@, '', 'layout references to a different volume do not block resizing');
            is($volume_size, 2 * $size, 'an unrelated layout disk leaves ordinary growth enabled');
        }
    }

    $reset->($cases[0]);
    $running = 0;
    $volume_size = $size;
    $conf = { scsi0 => "$owner_volume,size=$size", nvme0 => $owner_volume, pending => {} };
    eval { $resize->('scsi0'); };
    is($@, '', 'ordinary NVMe references without metadata retain offline resize behavior');
    is($volume_size, 2 * $size, 'ordinary offline aliases can still grow');

    $reset->($cases[0]);
    $running = 0;
    $volume_size = $size;
    $conf = { nvme0 => "$owner_volume,ms=8,pi=1,size=$size", pending => {} };
    eval { $resize->('nvme0'); };
    like(
        $@,
        qr/cannot resize an NVMe namespace with metadata/,
        'metadata growth through its own NVMe slot remains forbidden',
    );
    is($volume_size, $size, 'direct metadata refusal preserves the actual volume size');
}

for my $async (0, 1) {
    for my $case (
        [
            { machine => 'q35', nvme3 => $owner_volume },
            { machine => 'azw-me-pro-6' },
            qr/supports NVMe controllers nvme0 through nvme2/,
        ],
        [
            { machine => 'azw-me-pro-6', nvme0 => $owner_volume },
            { nvme1 => "$child_volume,nvme-slot=0" },
            qr/use the same custom machine slot 0/,
        ],
        [
            { machine => 'azw-me-pro-6', map { ("sata$_" => $owner_volume) } 0 .. 5 },
            { ide2 => 'none,media=cdrom' },
            qr/only six shared SATA\/IDE ports/,
        ],
        [{ arch => 'aarch64' }, { machine => 'azw-me-pro-6' }, qr/only supported on x86_64/],
    ) {
        $reset->($cases[0]);
        $running = 0;
        $conf = { $case->[0]->%*, pending => {} };
        my $before = dclone($conf);
        my $params = { node => 'pve', vmid => 8006, $case->[1]->%* };
        eval {
            $async
                ? PVE::API2::Qemu->update_vm_async($params)
                : PVE::API2::Qemu->update_vm($params);
        };
        like($@, $case->[2], 'API rejects an invalid custom machine topology');
        is_deeply($conf, $before, 'invalid custom topology leaves the configuration unchanged');
        is_deeply(\@events, [], 'custom topology is validated before locks, storage or writes');
        is($scheduled, 0, 'invalid custom topology does not schedule a worker');
    }
}

done_testing();
