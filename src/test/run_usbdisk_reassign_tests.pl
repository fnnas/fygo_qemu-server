#!/usr/bin/perl

use strict;
use warnings;

use Storable qw(dclone);
use Test::More;
use Test::MockModule;

use PVE::API2::Qemu;
use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Drive qw(parse_drive);

my $volume = 'local:8006/vm-8006-disk-0.raw';
my $target_volume = 'local:8007/vm-8007-disk-0.raw';
my %configs;
my @events;
my $scheduled;
my $before_worker;
my ($fault, $volume_location, $rollback_failure);
my @locks;
my @rename_args;

{

    package USBReassignRPC;
    sub get_user { 'root@pam' }
    sub check { 1 }
    sub check_vm_perm { 1 }

    sub fork_worker {
        $scheduled++;
        $before_worker->() if $before_worker;
        return $_[-1]->();
    }
}
my $rpc = Test::MockModule->new('PVE::RPCEnvironment');
$rpc->mock(get => sub { bless {}, 'USBReassignRPC' });
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });
$cluster->mock(
    get_vmlist => sub { { ids => { 8006 => { node => 'pve' }, 8007 => { node => 'pve' } } } });
$cluster->mock(log_msg => sub { });
my $storage = Test::MockModule->new('PVE::Storage');
$storage->mock(
    config => sub { {
        ids => {
            local =>
                { type => 'dir', path => '/tmp/usb-reassign-test', content => { images => 1 } },
        },
    } },
);
$storage->mock(check_volume_access => sub { });
$storage->mock(activate_volumes => sub { });
$storage->mock(vdisk_free => sub { push @events, 'free'; });
$storage->mock(
    volume_size_info => sub {
        if ($fault eq 'target-prepare' && $_[1] eq $target_volume) {
            $fault = '';
            die "target preparation failed\n";
        }
        1024**3;
    },
);
$storage->mock(volume_has_feature => sub { $_[1] eq 'rename' ? 1 : 0 });
$storage->mock(
    parse_volname => sub {
        my ($owner) = $_[1] =~ m{^local:(\d+)/};
        ('images', "vm-$owner-disk-0.raw", $owner, undef, undef, undef, 'raw');
    },
);
$storage->mock(
    rename_volume => sub {
        push @events, 'rename';
        push @rename_args, [@_[1 .. $#_]];
        die "storage rollback failed\n" if $_[2] == 8006 && $rollback_failure;
        $volume_location = $_[2] == 8007 ? $target_volume : $volume;
        return $volume_location;
    },
);
my $config = Test::MockModule->new('PVE::QemuConfig');
$config->mock(load_config => sub { dclone($configs{ $_[1] }) });
$config->mock(check_lock => sub { });
$config->mock(lock_config => sub { push @locks, $_[1]; $_[2]->() });
$config->mock(
    write_config => sub {
        my $side = $_[1] == 8006 ? 'source' : 'target';
        if ($fault eq "$side-write") {
            $fault = '';
            die "$side configuration write failed\n";
        }
        $configs{ $_[1] } = dclone($_[2]);
        push @events, "write-$_[1]";
        if ($fault eq "$side-after-write") {
            $fault = '';
            die "$side configuration write failed after persistence\n";
        }
    },
);
my $qemu = Test::MockModule->new('PVE::QemuServer');
$qemu->mock(check_running => sub { 0 });
my $replication = Test::MockModule->new('PVE::ReplicationConfig');
$replication->mock(new => sub { bless {}, 'USBReassignReplication' });
{

    package USBReassignReplication;
    sub check_for_existing_jobs { 0 }
}

my $reset = sub {
    my ($options) = @_;
    %configs = (
        8006 => { usbdisk0 => "$volume,$options", pending => {}, snapshots => {} },
        8007 => { pending => {}, snapshots => {} },
    );
    @events = ();
    $scheduled = 0;
    $before_worker = undef;
    $fault = '';
    $volume_location = $volume;
    @locks = ();
    @rename_args = ();
    $rollback_failure = 0;
};
my $move = sub {
    my ($target) = @_;
    PVE::API2::Qemu->move_vm_disk({
        node => 'pve',
        vmid => 8006,
        'target-vmid' => 8007,
        disk => 'usbdisk0',
        'target-disk' => $target,
    });
};

for my $removable (0, 1) {
    for my $target (qw(usbdisk7 scsi0 virtio0 ide0 sata0 nvme0 unused0)) {
        $reset->("removable=$removable,serial=USB%20Disk,backup=0,cache=writethrough");
        eval { $move->($target); };
        is($@, '', "USB removable=$removable can be reassigned as $target");
        is($scheduled, 1, 'valid reassignment reaches its worker');
        ok(!exists($configs{8006}->{usbdisk0}), 'successful move removes the source attachment');
        my $drive = parse_drive($target, $configs{8007}->{$target});
        is($drive->{file}, $target_volume, 'target owns the renamed volume');
        if ($target =~ /^usbdisk/) {
            is($drive->{removable}, $removable, 'USB targets preserve removable media policy');
        } else {
            ok(!exists($drive->{removable}), 'other targets omit the USB-only media policy');
        }
        if ($target !~ /^unused/) {
            is($drive->{serial}, 'USB%20Disk',
                'cross-bus reassignment retains the serial override');
            is($drive->{backup}, 0, 'cross-bus reassignment retains backup policy');
            is($drive->{cache}, 'writethrough', 'cross-bus reassignment retains cache policy');
        }
    }
}

for my $target (qw(usbdisk7 scsi0 virtio0 nvme0)) {
    $reset->('removable=0,ro=1');
    eval { $move->($target); };
    is($@, '', "read-only USB storage can be reassigned as $target");
    is(
        parse_drive($target, $configs{8007}->{$target})->{ro},
        1,
        'supported targets preserve write protection',
    );
}
for my $target (qw(ide0 sata0)) {
    $reset->('removable=0,ro=1');
    my $before = dclone(\%configs);
    eval { $move->($target); };
    like(
        $@,
        qr/failed to parse source disk for target disk format/,
        'a target without read-only support is still rejected',
    );
    is($scheduled, 0, 'incompatible options are rejected before scheduling');
    is_deeply(\@events, [], 'rejected conversion does not rename volumes or write config');
    is_deeply(\%configs, $before, 'rejected conversion retains both VM configurations');
}

$reset->('removable=0,rerror=stop');
my $before = dclone(\%configs);
eval { $move->('nvme0'); };
like(
    $@,
    qr/failed to parse source disk for target disk format/,
    'USB conversion still rejects unsupported error handling on NVMe',
);
is_deeply(\%configs, $before, 'failed normalization does not modify the source USB options');
is_deeply(\@events, [], 'unsupported target options cause no storage side effects');

for my $concurrent (0, 1) {
    $reset->('removable=0');
    if ($concurrent) {
        $before_worker = sub { $configs{8007}->{scsi0} = 'local:8007/other.raw'; };
    } else {
        $configs{8007}->{scsi0} = 'local:8007/other.raw';
    }
    eval { $move->('scsi0'); };
    like(
        $@,
        qr/Target disk key 'scsi0' is already in use/,
        'slot conflicts are checked before scheduling and under both locks',
    );
    is($scheduled, $concurrent, 'concurrent conflicts are caught in the scheduled worker');
    is_deeply(\@events, [], 'slot conflicts preserve source storage and configuration');
    ok(exists($configs{8006}->{usbdisk0}), 'slot conflicts retain the original USB attachment');
}

for my $target (qw(usbdisk1 scsi0)) {
    $reset->('serial=head%00tail');
    my $before = dclone(\%configs);
    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0]; };
        eval { $move->($target); };
    }
    like(
        $@,
        qr/failed to parse source disk/,
        'reassignment rejects a USB serial that prevents restart',
    );
    is($scheduled, 0, 'invalid serial is rejected before scheduling reassignment');
    is_deeply(
        \@events,
        [],
        'invalid serial does not rename the source volume or write configurations',
    );
    is_deeply(\%configs, $before, 'invalid source keeps both VM configurations intact');
}

for my $stage (qw(source-write source-after-write target-prepare target-write)) {
    $reset->('removable=0,serial=KEEP,backup=0');
    $configs{8006}->{boot} = 'order=usbdisk0';
    $configs{8006}->{pending}->{boot} = 'order=usbdisk0';
    my $before = dclone(\%configs);
    $fault = $stage;
    eval { $move->('usbdisk1'); };
    like($@, qr/failed/, "reassignment reports the original $stage error");
    is($volume_location, $volume, "$stage restores the source volume's ownership and name");
    is_deeply(\%configs, $before, "$stage preserves source options and both boot orders");
    is($rename_args[1]->[2], 'vm-8006-disk-0.raw', 'rollback requests the original image basename');
}

for my $stage (qw(source-write source-after-write target-write)) {
    $reset->('removable=0,serial=KEEP');
    my $before = dclone(\%configs);
    $fault = $stage;
    eval { $move->('unused0'); };
    like($@, qr/failed/, 'unused-target reassignment reports its write failure');
    is($volume_location, $volume, 'failed unused-target transfer restores volume ownership');
    is_deeply(\%configs, $before, 'failed unused-target transfer restores the source attachment');
}

{
    $reset->('removable=0');
    $fault = 'target-after-write';
    eval { $move->('unused0'); };
    like($@, qr/failed after persistence/, 'report a persisted unused-target failure');
    is(
        $volume_location,
        $target_volume,
        'a persisted unused reference also prevents unsafe rollback',
    );
    is(
        $configs{8007}->{unused0},
        $target_volume,
        'persisted unused target still owns the transferred disk',
    );
}

{
    $reset->('removable=0');
    $fault = 'target-write';
    $rollback_failure = 1;
    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0]; };
        eval { $move->('usbdisk1'); };
    }
    like(
        $@,
        qr/target configuration write failed/,
        'storage rollback failure preserves the original error',
    );
    is(
        $volume_location,
        $target_volume,
        'failed storage rollback retains the actual new volume identity',
    );
    is(
        $configs{8007}->{unused0},
        $target_volume,
        'storage rollback failure registers a recoverable unused volume',
    );
    ok(!exists($configs{8006}->{usbdisk0}), 'recovery does not leave a dangling source attachment');
    like(
        $warning,
        qr/volume retained as VM '8007' disk 'unused0'/,
        'report where the volume can be recovered',
    );
    ok(!(grep { $_ eq 'free' } @events), 'recovery never deletes the transferred volume');
}

{
    $reset->('removable=0');
    $fault = 'target-after-write';
    eval { $move->('usbdisk1'); };
    like(
        $@,
        qr/failed after persistence/,
        'report a target failure after its pending config was saved',
    );
    is(
        $volume_location,
        $target_volume,
        'never rename a volume back after target attachment may have started',
    );
    ok(
        !exists($configs{8006}->{usbdisk0}),
        'a partially completed transfer stays removed from the source',
    );
    is(
        parse_drive('usbdisk1', $configs{8007}->{pending}->{usbdisk1})->{file},
        $target_volume,
        'a partial target update retains its recoverable pending disk reference',
    );
}

for my $reverse (0, 1) {
    $reset->('removable=0');
    if ($reverse) {
        %configs = (
            8006 => { pending => {}, snapshots => {} },
            8007 =>
                { usbdisk0 => "$target_volume,removable=0", pending => {}, snapshots => {} },
        );
    }
    eval {
        PVE::API2::Qemu->move_vm_disk({
            node => 'pve',
            vmid => $reverse ? 8007 : 8006,
            'target-vmid' => $reverse ? 8006 : 8007,
            disk => 'usbdisk0',
            'target-disk' => 'usbdisk1',
        });
    };
    is($@, '', 'USB reassignment works in both VMID directions');
    is_deeply([@locks[0, 1]], [8006, 8007],
        'opposite transfers acquire VM locks in the same order');
}

for my $concurrent (0, 1) {
    $reset->('removable=0');
    if ($concurrent) {
        $before_worker = sub { $configs{8006}->{protection} = 1; };
    } else {
        $configs{8006}->{protection} = 1;
    }
    eval { $move->('usbdisk1'); };
    like($@, qr/protection mode enabled/, 'VM protection prevents transferring its USB disk');
    is(
        $scheduled,
        $concurrent,
        'protection is checked before scheduling and again under both locks',
    );
    is_deeply(\@events, [], 'protected sources cause no storage or configuration changes');
    is($volume_location, $volume, 'protected source retains ownership of the original volume');
}

{
    $reset->('removable=0');
    $configs{8007}->{protection} = 1;
    eval { $move->('usbdisk1'); };
    is($@, '', 'target protection still permits adding a USB disk');
    ok(
        exists($configs{8007}->{usbdisk1}),
        'target protection does not remove normal attachment support',
    );
}

for my $concurrent (0, 1) {
    $reset->('removable=0');
    my $foreign = 'local:7999/vm-7999-disk-0.raw';
    if ($concurrent) {
        $before_worker = sub { $configs{8006}->{usbdisk0} = $foreign; };
    } else {
        $configs{8006}->{usbdisk0} = $foreign;
    }
    eval { $move->('usbdisk1'); };
    like($@, qr/not owned by VM/, 'reassignment cannot rename another VM owner\'s attached volume');
    is($scheduled, $concurrent, 'ownership is validated before scheduling and under the locks');
    is_deeply(\@events, [], 'foreign volume ownership is rejected without side effects');
    is($configs{8006}->{usbdisk0}, $foreign, 'foreign source reference remains unchanged');
}

{
    $reset->('removable=0');
    delete $configs{8006}->{usbdisk0};
    $configs{8006}->{unused0} = 'local:7999/vm-7999-disk-0.raw';
    eval {
        PVE::API2::Qemu->move_vm_disk({
            node => 'pve',
            vmid => 8006,
            'target-vmid' => 8007,
            disk => 'unused0',
            'target-disk' => 'usbdisk1',
        });
    };
    like(
        $@,
        qr/not owned by VM/,
        'an unused reference cannot transfer ownership of another VM\'s disk',
    );
    is_deeply(
        \@events,
        [],
        'foreign unused references cause no volume rename or configuration writes',
    );
}

done_testing();
