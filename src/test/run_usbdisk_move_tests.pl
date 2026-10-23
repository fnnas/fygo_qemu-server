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

my $old = 'local:8006/vm-8006-disk-0.raw';
my $new = 'target:8006/vm-8006-disk-0.raw';
my ($conf, $running, $stage, $node, $node_queries, $scheduled, $before_worker);
my (@freed, @allocated, @writes);
my $copy_attempts;

{

    package USBMoveRPC;
    sub get_user { 'root@pam' }
    sub check { 1 }
    sub check_vm_perm { 1 }

    sub fork_worker {
        $scheduled++;
        $before_worker->() if $before_worker;
        $_[-1]->();
    }
}
my $rpc = Test::MockModule->new('PVE::RPCEnvironment');
$rpc->mock(get => sub { bless {}, 'USBMoveRPC' });
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });
$cluster->mock(log_msg => sub { });
my $storage = Test::MockModule->new('PVE::Storage');
my $storecfg = {
    ids => {
        local => { type => 'dir', path => '/tmp/usb-move-source', content => { images => 1 } },
        target => { type => 'dir', path => '/tmp/usb-move-target', content => { images => 1 } },
    },
};
$storage->mock(config => sub { $storecfg });
$storage->mock(storage_check_enabled => sub { $storecfg->{ids}->{ $_[1] } });
$storage->mock(activate_volumes => sub { });
$storage->mock(deactivate_volumes => sub { });
$storage->mock(get_bandwidth_limit => sub { undef });
$storage->mock(volume_size_info => sub { 8 * 1024 * 1024 });
$storage->mock(vdisk_free => sub { push @freed, $_[1]; });
$storage->mock(
    parse_volname => sub {
        my ($owner) = $_[1] =~ m{:(\d+)/};
        ('images', "vm-$owner-disk-0.raw", $owner, undef, undef, undef, 'raw');
    },
);
my $config = Test::MockModule->new('PVE::QemuConfig');
$config->mock(
    load_config => sub {
        die "configuration query failed\n"
            if $stage =~ /^(?:config-query|unreadable)$/ && $copy_attempts;
        dclone($conf);
    },
);
$config->mock(check_lock => sub { });
$config->mock(lock_config => sub { $_[2]->() });
$config->mock(
    write_config => sub {
        if ($stage eq 'write-before' || $stage eq 'write-persistent') {
            $stage = '' if $stage eq 'write-before';
            die "configuration write failed\n";
        }
        $conf = dclone($_[2]);
        push @writes, dclone($conf);
        if ($stage eq 'write-after-unreadable') {
            $stage = 'unreadable';
            die "configuration write failed after persistence\n";
        }
        if ($stage eq 'write-after') {
            $stage = '';
            die "configuration write failed after persistence\n";
        }
    },
);
my $blockdev = Test::MockModule->new('PVE::QemuServer::Blockdev');
$blockdev->mock(
    get_node_name_below_throttle => sub {
        $node_queries++;
        return undef if $stage eq 'no-source';
        die "runtime query failed\n" if $stage eq 'runtime-query' && $copy_attempts;
        $node;
    },
);
my $qemu = Test::MockModule->new('PVE::QemuServer');
$qemu->mock(check_running => sub { $running });
$qemu->mock(
    clone_disk => sub {
        my ($cfg, $source, $dest, $full, $volumes, $jobs) = @_;
        $copy_attempts++;
        push @$volumes, $new;
        push @allocated, $new;
        die "copy failed\n" if $stage =~ /^(?:copy|runtime-query|config-query|mirror-busy)$/;
        $node = 'new-node' if $running;
        die "mirror completion failed\n" if $stage eq 'after-switch';
        return { %{ $source->{drive} }, file => $new, size => 8 * 1024 * 1024 };
    },
);
my $monitor = Test::MockModule->new('PVE::QemuServer::Monitor');
$monitor->mock(
    qmp_cmd => sub {
        die "unexpected monitor command $_[1]\n" if $_[1] ne 'query-block-jobs';
        $stage eq 'mirror-busy' ? [{ device => 'mirror-usbdisk0' }] : [];
    },
);
my $reset = sub {
    ($running, $stage) = @_;
    $conf = {
        usbdisk0 => "$old,serial=KEEP,removable=0,cache=writeback,aio=threads,ro=1",
        pending => {},
        snapshots => {},
    };
    $node = 'old-node';
    $node_queries = 0;
    $scheduled = 0;
    $copy_attempts = 0;
    $before_worker = undef;
    @allocated = ();
    @freed = ();
    @writes = ();
};
my $move = sub {
    my ($delete) = @_;
    PVE::API2::Qemu->move_vm_disk({
        node => 'pve',
        vmid => 8006,
        disk => 'usbdisk0',
        storage => 'target',
        delete => $delete // 0,
    });
};

for my $live (0, 1) {
    for my $failure (qw(write-before write-after)) {
        $reset->($live, $failure);
        my $warning = '';
        {
            local $SIG{__WARN__} = sub { $warning .= $_[0] };
            eval { $move->(0) };
        }
        like($@, qr/configuration write failed/, "report $failure for running=$live");
        if ($live || $failure eq 'write-after') {
            ok(!(grep { $_ eq $new } @freed), 'never free an active or committed destination');
            is(
                parse_drive('usbdisk0', $conf->{usbdisk0})->{file},
                $new,
                'configuration retains the destination volume',
            );
            my $drive = parse_drive('usbdisk0', $conf->{usbdisk0});
            is($drive->{serial}, 'KEEP', 'recovery preserves the USB serial');
            is($drive->{removable}, 0, 'recovery preserves fixed-media mode');
            is($drive->{ro}, 1, 'recovery preserves write protection');
        } else {
            is_deeply(\@freed, [$new], 'an uncommitted offline copy is cleaned up');
            is(
                parse_drive('usbdisk0', $conf->{usbdisk0})->{file},
                $old,
                'offline failure retains the source attachment',
            );
        }
        ok(!(grep { $_ eq $old } @freed), 'an unsuccessful move never deletes the source');
    }
}

for my $failure (qw(after-switch write-persistent)) {
    $reset->(1, $failure);
    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        eval { $move->(1) };
    }
    like($@, qr/failed/, 'report failure after the runtime switched to the destination');
    is_deeply(\@freed, [], 'a failed runtime switch cannot delete either volume');
    if ($failure eq 'after-switch') {
        is(
            parse_drive('usbdisk0', $conf->{usbdisk0})->{file},
            $new,
            'late mirror errors reconcile the active destination',
        );
    } else {
        like($warning, qr/\Q$new\E/, 'persistent configuration errors report the retained volume');
    }
}

for my $failure (qw(copy runtime-query config-query mirror-busy)) {
    $reset->(1, $failure);
    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0] };
        eval { $move->(0) };
    }
    like($@, qr/copy failed/, 'the original copy error is preserved');
    if ($failure eq 'copy') {
        is_deeply(\@freed, [$new], 'an unattached destination is cleaned up after a failed copy');
    } else {
        ok(!(grep { $_ eq $new } @freed), 'a busy or unverified destination is retained');
    }
    ok(!(grep { $_ eq $old } @freed), 'failed copies never delete the original volume');
}

for my $concurrent (0, 1) {
    $reset->(1, '');
    my $fill = sub { $conf->{"unused$_"} = "local:8006/vm-8006-unused-$_.raw" for 0 .. 255 };
    $concurrent ? ($before_worker = $fill) : $fill->();
    eval { $move->(0) };
    like($@, qr/Too many unused volumes/, 'reject exhausted unused slots before copying');
    is($scheduled, $concurrent, 'unused capacity is checked before scheduling and under the lock');
    is($copy_attempts, 0, 'no live mirror starts without room to retain its source');
    is_deeply(\@freed, [], 'capacity rejection does not free any volume');
}

for my $delete (0, 1) {
    $reset->(0, '');
    $conf->{usbdisk0} = 'local:7999/vm-7999-disk-0.raw';
    eval { $move->($delete) };
    if ($delete) {
        like($@, qr/not owned by VM/, 'storage migration cannot delete another VM owner\'s volume');
        is($scheduled, 0, 'foreign source deletion is rejected before scheduling');
        is_deeply(\@freed, [], 'foreign volume is never deleted');
    } else {
        is($@, '', 'copying a foreign volume without deleting it remains allowed');
    }
}

for my $live (0, 1) {
    for my $delete (0, 1) {
        $reset->($live, '');
        eval { $move->($delete); };
        is($@, '', 'successful storage migration still commits normally');
        is(
            parse_drive('usbdisk0', $conf->{usbdisk0})->{file},
            $new,
            'successful move records its destination',
        );
        is_deeply(
            \@freed,
            $delete ? [$old] : [],
            'source deletion happens only after a successful commit',
        );
    }
}

{
    $reset->(1, '');
    $conf->{"unused$_"} = "local:8006/vm-8006-unused-$_.raw" for 0 .. 255;
    $conf->{unused0} = $old;
    eval { $move->(0); };
    is($@, '', 'an existing unused reference needs no additional slot');
    is($copy_attempts, 1, 'existing source metadata does not block a valid move');
    is($conf->{unused0}, $old, 'the retained source keeps its existing unused slot');
}

{
    $reset->(1, 'no-source');
    eval { $move->(0); };
    like($@, qr/no source block node/, 'reject a missing runtime source before copying');
    is($copy_attempts, 0, 'a missing runtime source cannot allocate a destination');
    is_deeply(\@freed, [], 'missing runtime source does not free any disk');
}

{
    $reset->(0, '');
    $before_worker = sub { $conf->{usbdisk0} = 'local:7999/vm-7999-disk-0.raw'; };
    eval { $move->(1); };
    like($@, qr/not owned by VM/, 'source ownership is checked again under the lock');
    is($scheduled, 1, 'concurrent ownership changes are caught by the worker');
    is($copy_attempts, 0, 'concurrent ownership changes prevent copying');
    is_deeply(\@freed, [], 'concurrent ownership changes cannot delete the foreign source');
}

{
    $reset->(0, 'write-after-unreadable');
    my $warning = '';
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0]; };
        eval { $move->(0); };
    }
    like(
        $@,
        qr/configuration write failed/,
        'keep the original error if the committed config cannot be reloaded',
    );
    is(
        parse_drive('usbdisk0', $conf->{usbdisk0})->{file},
        $new,
        'fallback recovery retains the committed destination',
    );
    my @unused = map { $conf->{$_} } grep { /^unused\d+$/ } keys %$conf;
    ok(
        !(grep { $_ eq $new } @unused),
        'fallback recovery never lists an attached destination as unused',
    );
    ok(
        !(grep { $_ eq $new } @freed),
        'unreadable committed configuration cannot delete the destination',
    );
}

done_testing();
