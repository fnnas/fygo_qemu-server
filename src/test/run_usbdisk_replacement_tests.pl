#!/usr/bin/perl

use strict;
use warnings;

use Storable qw(dclone);
use Test::More;
use Test::MockModule;

use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::Drive qw(parse_drive);

my $old_volume = 'local:8006/vm-8006-disk-0.raw';
my $new_volume = 'local:8006/vm-8006-disk-1.raw';
my $old_value = "$old_volume,serial=OLD,removable=0,ro=1,backup=0";
my $new_value = "$new_volume,serial=NEW,removable=1,ro=0";
my ($frontend, $backend, $failure, $rollback_failure, $unplug_attempts, @events);

my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });
my $machine = Test::MockModule->new('PVE::QemuServer::Machine');
$machine->mock(get_current_qemu_machine => sub { 'pc-q35-11.1' });
my $config = Test::MockModule->new('PVE::QemuConfig');
$config->mock(write_config => sub { });
my $cgroup = Test::MockModule->new('PVE::QemuServer::CGroup');
$cgroup->mock(new => sub { bless {}, 'PVE::QemuServer::CGroup' });
my $storage = Test::MockModule->new('PVE::Storage');
$storage->mock(
    activate_volumes => sub {
        push @events, 'activate';
        die "target activation failed\n" if $failure eq 'activation';
    },
);
my $qemu = Test::MockModule->new('PVE::QemuServer');
$qemu->mock(
    vmconfig_register_unused_drive => sub {
        push @events, 'prepare-unused';
        $_[2]->{unused0} = $_[3]->{file};
        die "unused registration failed\n" if $failure eq 'metadata';
    },
);
$qemu->mock(
    vm_deviceunplug => sub {
        push @events, 'unplug';
        $unplug_attempts++;
        die "old device removal failed\n"
            if $failure eq 'unplug-request' && $unplug_attempts == 1;
        $frontend = undef;
        die "old device verification failed\n"
            if $failure eq 'unplug-verify' && $unplug_attempts == 1;
        die "old backend removal failed\n"
            if $failure eq 'unplug-backend' && $unplug_attempts == 1;
        $backend = undef;
    },
);
$qemu->mock(
    mon_cmd => sub {
        my ($vmid, $command, %args) = @_;
        die "unexpected monitor command '$command'\n"
            if $command ne 'qom-list' || $args{path} ne '/machine/peripheral';
        return $frontend ? [{ name => 'usbdisk0' }] : [];
    },
);
$qemu->mock(
    vm_deviceplug => sub {
        my $drive = $_[4];
        my $old = $drive->{file} eq $old_volume;
        push @events, $old ? 'restore-old' : 'plug-new';
        die "rollback failed\n" if $old && $rollback_failure;
        die "previous backend remains\n" if defined($backend);
        $backend = $drive->{file};
        die "new backend failed\n" if !$old && $failure eq 'backend';
        $frontend = dclone($drive);
        die "new frontend failed\n" if !$old && $failure eq 'frontend';
    },
);

my $reset = sub {
    ($failure, $rollback_failure) = @_;
    $failure //= '';
    $unplug_attempts = 0;
    @events = ();
    $frontend = parse_drive('usbdisk0', $old_value);
    $backend = $old_volume;
    return {
        ostype => 'l26',
        hotplug => 'usb',
        usbdisk0 => $old_value,
        pending => { usbdisk0 => $new_value },
    };
};
my $apply = sub {
    my ($conf) = @_;
    my $errors = {};
    PVE::QemuServer::vmconfig_hotplug_pending(8006, $conf, {}, undef, $errors);
    return $errors;
};

for my $stage (
    qw(metadata activation unplug-request unplug-verify unplug-backend backend frontend)
) {
    my $conf = $reset->($stage);
    my $errors = $apply->($conf);
    like($errors->{usbdisk0}, qr/failed/, "replacement reports its $stage error");
    is($conf->{usbdisk0}, $old_value, 'failed replacement retains the active disk configuration');
    is(
        $conf->{pending}->{usbdisk0},
        $new_value,
        'failed replacement retains the requested disk for retry',
    );
    ok(!exists($conf->{unused0}), 'failed replacement does not expose the active disk as unused');
    is($backend, $old_volume, 'failed replacement keeps or restores the old backing volume');
    is_deeply(
        $frontend,
        parse_drive('usbdisk0', $old_value),
        'restored USB disk retains all options',
    );

    if ($stage eq 'metadata' || $stage eq 'activation') {
        ok(!grep($_ eq 'unplug', @events), 'preparation failure never disconnects the old disk');
    } elsif ($stage eq 'unplug-request') {
        is_deeply(
            \@events,
            ['prepare-unused', 'activate', 'unplug'],
            'failed removal of an intact old device does not disconnect it for rollback',
        );
    } elsif ($stage =~ /^unplug-/) {
        is_deeply(
            [@events[-3 .. -1]],
            ['unplug', 'unplug', 'restore-old'],
            'partial removal is cleaned up and the old disk restored without attaching the new disk',
        );
    } else {
        is_deeply(
            [@events[-3 .. -1]],
            ['plug-new', 'unplug', 'restore-old'],
            'failed new device is removed before the old disk is restored',
        );
    }

    $failure = '';
    @events = ();
    $errors = $apply->($conf);
    is_deeply($errors, {}, 'corrected replacement can be retried');
    is($conf->{usbdisk0}, $new_value, 'successful retry commits the new disk configuration');
    ok(!exists($conf->{pending}->{usbdisk0}), 'successful retry clears the pending disk');
    is(
        $conf->{unused0},
        $old_volume,
        'only successful replacement registers the old volume as unused',
    );
    is($backend, $new_volume, 'successful retry uses the new volume');
    is_deeply(
        $frontend,
        parse_drive('usbdisk0', $new_value),
        'successful retry realizes the new options',
    );
}

{
    my $conf = $reset->('frontend', 1);
    my $warning = '';
    my $errors;
    {
        local $SIG{__WARN__} = sub { $warning .= $_[0]; };
        $errors = $apply->($conf);
    }
    like(
        $errors->{usbdisk0},
        qr/new frontend failed/,
        'rollback failure preserves the original operation error',
    );
    like(
        $warning,
        qr/unable to restore USB disk 'usbdisk0'.*rollback failed/,
        'rollback failure is reported separately',
    );
    ok($conf->{pending}->{usbdisk0}, 'failed rollback cannot silently commit a replacement');
    ok(!exists($conf->{unused0}), 'failed rollback does not publish unused-volume metadata');
}

{
    my $conf = $reset->();
    $conf->{hotplug} = 'disk';
    my $errors = $apply->($conf);
    is_deeply($errors, {}, 'disabled USB hotplug leaves replacement pending without errors');
    is_deeply(\@events, [], 'the disk hotplug switch alone cannot replace a USB disk');
    is($backend, $old_volume, 'disabled USB hotplug preserves the running disk');
}

done_testing();
