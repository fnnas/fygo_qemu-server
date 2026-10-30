#!/usr/bin/perl

use strict;
use warnings;

use Fcntl qw(O_RDWR);
use File::Path qw(make_path);
use Test::More;
use Test::MockModule;

use PVE::QemuMigrate;
use PVE::QemuServer;
use PVE::QemuServer::Drive qw(parse_drive);

my $volume = 'local:8006/vm-8006-disk-0.raw';
my $target_volume = 'target:8007/vm-8007-disk-0.raw';
my $options = 'cid=03534453443332478535bca2a70195df,sd-spec-version=3';
my $source_size = 64 * 1024**2;
my @events;
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { $_[0] eq 'datacenter.cfg' ? {} : undef });

{
    my $target_size;
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(
        volume_size_info => sub {
            return $_[1] eq $volume ? $source_size : $target_size;
        },
    );
    $storage->mock(vdisk_alloc => sub { push @events, 'allocate'; return $target_volume; });
    $storage->mock(activate_volumes => sub { push @events, 'activate'; });
    $storage->mock(volume_has_feature => sub { 0 });
    $storage->mock(storage_config => sub { return { type => 'dir', path => '/tmp' }; });
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    $qemu->mock(resolve_dst_disk_format => sub { 'raw' });
    my $image = Test::MockModule->new('PVE::QemuServer::QemuImage');
    $image->mock(convert => sub { push @events, 'copy'; });
    my $job = Test::MockModule->new('PVE::QemuServer::BlockJob');
    $job->mock(mirror => sub { push @events, 'mirror'; });
    my $machine = Test::MockModule->new('PVE::QemuServer::Machine');
    $machine->mock(get_current_qemu_machine => sub { 'pc-q35-11.1' });

    my $normal_source_size = $source_size;
    for my $running (0, 1) {
        for my $entry (
            [$source_size, 1],
            [96 * 1024**2, 0],
            [128 * 1024**2, 1],
            [undef, 0],
            (map { [$_, 0, $_] } (512, 131072, 3 * 1024**2)),
            [128 * 1024, 0, 128 * 1024],
            [4 * 1024**2, 1, 4 * 1024**2],
        ) {
            ($target_size, my $allowed, my $actual_source_size) = @$entry;
            $source_size = $actual_source_size // $normal_source_size;
            @events = ();
            my $new_volumes = [];
            my $result = eval {
                PVE::QemuServer::clone_disk(
                    {},
                    {
                        vmid => 8006,
                        drivename => 'sdcard0',
                        running => $running,
                        drive => parse_drive('sdcard0', "$volume,$options"),
                    },
                    { vmid => 8007, drivename => 'sdcard0', storage => 'target' },
                    1,
                    $new_volumes,
                    {},
                    'complete',
                    undef,
                    undef,
                );
            };
            if ($allowed) {
                is($@, '', 'SD card cloning permits valid exact or enlarged target layouts');
                is($result->{size}, $target_size, 'cloned configuration records actual capacity');
                is_deeply(
                    \@events,
                    ['allocate', 'activate', $running ? 'mirror' : 'copy'],
                    'valid layouts use the normal copy or live mirror path',
                );
            } else {
                like(
                    $@,
                    qr/SD card image must be|cannot determine SD card image size/,
                    'invalid or unknown SD card target capacity aborts cloning',
                );
                is_deeply(
                    \@events,
                    ['allocate', 'activate'],
                    'rejected target receives no copied data or block node switch',
                );
            }
            is_deeply(
                $new_volumes,
                [$target_volume],
                'cloned destination remains registered for worker cleanup',
            );
        }
        $source_size = $normal_source_size;
    }
}

{
    my $target_size;
    my $reverse;
    my $rpc = Test::MockModule->new('PVE::RPCEnvironment');
    $rpc->mock(get => sub { bless {}, 'SDCardLifecycleRPC'; });
    {

        package SDCardLifecycleRPC;
        sub get_user { 'root@pam' }
        sub check { 1 }
        sub check_vm_perm { 1 }
    }
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(config => sub { {} });
    $storage->mock(path_to_volume_id => sub { return (undef, undef); });
    $storage->mock(get_bandwidth_limit => sub { undef });
    $storage->mock(storage_config => sub { return { type => 'dir', content => { images => 1 } }; });
    $storage->mock(resolve_format_hint => sub { 'raw' });
    $storage->mock(volume_size_info => sub { $target_size });
    $storage->mock(vdisk_alloc => sub { push @events, 'allocate'; return $target_volume; });
    $storage->mock(activate_volumes => sub { push @events, 'activate'; });
    $storage->mock(deactivate_volumes => sub { push @events, 'deactivate'; });
    $storage->mock(vdisk_free => sub { push @events, 'free'; });
    $storage->mock(volume_has_feature => sub { 0 });
    $storage->mock(path => sub { '/tmp/sdcard-lifecycle-restore.raw' });
    my $config = Test::MockModule->new('PVE::QemuConfig');
    $config->mock(config_file => sub { 'nodes/pve/qemu-server/8007.conf' });
    $config->mock(write_config => sub { push @events, 'write-config'; });
    my $qemu = Test::MockModule->new('PVE::QemuServer');
    $qemu->mock(rescan => sub { });
    $qemu->mock(
        run_command => sub {
            my ($commands, %opts) = @_;
            my ($fifo, $archive, $tmpdir) = $commands->[-1]->@[-3 .. -1];
            make_path($tmpdir);
            my @lines = (
                "#qmdump#map:sdcard0:drive-sdcard0:local:raw:\n", "sdcard0: $volume,$options\n",
            );
            @lines = reverse @lines if $reverse;
            PVE::Tools::file_set_contents("$tmpdir/qemu-server.conf", join('', @lines));
            sysopen(my $reader, $fifo, O_RDWR) or die "open test FIFO: $!";
            $opts{afterfork}->();
            $opts{outfunc}->("DEV: dev_id=1 size: $source_size devname: drive-sdcard0");
            $opts{outfunc}->('CTIME: test backup');
            push @events, 'extract';
            close($reader);
        },
    );
    for $reverse (0, 1) {
        my $normal_source_size = $source_size;
        for my $entry (
            [$source_size, 1],
            [96 * 1024**2, 0],
            [128 * 1024**2, 1],
            [undef, 0],
            (map { [$_, 0, $_] } (512, 131072, 3 * 1024**2)),
            [128 * 1024, 0, 128 * 1024],
            [4 * 1024**2, 1, 4 * 1024**2],
        ) {
            ($target_size, my $allowed, my $actual_source_size) = @$entry;
            $source_size = $actual_source_size // $normal_source_size;
            @events = ();
            eval {
                PVE::QemuServer::restore_vma_archive(
                    '/tmp/sdcard-lifecycle.vma',
                    8007,
                    'root@pam',
                    { override_conf => {} },
                    undef,
                );
            };
            if ($allowed) {
                is($@, '', 'valid SD card restore layouts are independent of backup hint ordering');
                is_deeply(
                    \@events,
                    ['allocate', 'activate', 'extract', 'deactivate', 'write-config'],
                    'valid restore extracts the archive and saves the VM configuration',
                );
            } else {
                like(
                    $@,
                    qr/SD card image must be|cannot determine SD card image size/,
                    'restore refuses invalid or unknown allocated capacity',
                );
                is_deeply(
                    \@events,
                    ['allocate', 'activate', 'deactivate', 'free'],
                    'failed restore frees its target before extraction or saving configuration',
                );
            }
        }
        $source_size = $normal_source_size;
    }
}

{
    my $target_size;
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(storage_migrate => sub { push @events, 'copy'; return $target_volume; });
    $storage->mock(deactivate_volumes => sub { push @events, 'deactivate-source'; });
    my $storage_tunnel = Test::MockModule->new('PVE::StorageTunnel');
    $storage_tunnel->mock(storage_migrate => sub { push @events, 'copy'; return $target_volume; });
    my $migration = Test::MockModule->new('PVE::QemuMigrate');
    $migration->mock(log => sub { });
    my $tools = Test::MockModule->new('PVE::Tools');
    $tools->mock(
        run_command => sub {
            my ($command, %opts) = @_;
            if ($command->[2] eq 'free') {
                push @events, 'free-target';
                is($command->[3], $target_volume, 'cleanup frees the imported target');
                return;
            }
            push @events, 'query';
            is_deeply(
                $command,
                [
                    'pvesh',
                    'get',
                    "/nodes/targetnode/storage/target/content/$target_volume",
                    '--output-format',
                    'json',
                ],
                'cluster migration queries the actual imported target volume',
            );
            $opts{outfunc}->(JSON::encode_json({ size => $target_size }));
        },
    );
    my $tunnel = Test::MockModule->new('PVE::Tunnel');
    $tunnel->mock(
        write_tunnel => sub {
            my ($connection, $timeout, $command, $params) = @_;
            push @events, 'query';
            is(
                $command,
                'query-disk-size',
                'remote migration requests the imported target size',
            );
            is_deeply($params, { volid => $target_volume },
                'query uses the imported volume ID');
            return { size => $target_size };
        },
    );
    $tunnel->mock(finish_tunnel => sub { push @events, 'abort-target'; });

    for my $remote (0, 1) {
        for my $section ('current', 'pending', 'snapshot') {
            for my $entry (
                [$source_size, 1], [96 * 1024**2, 0], [128 * 1024**2, 1],
                [undef, 0], [0, 0],
                # A preserved native snapshot can be smaller than the current image.
                ($section eq 'snapshot' ? ([96 * 1024**2, 1, 96 * 1024**2]) : ()),
            ) {
                ($target_size, my $allowed, my $current_size) = @$entry;
                $current_size //= $source_size;
                my $drive_conf = { sdcard0 => "$volume,$options" };
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
                            size => $current_size,
                        },
                    },
                    },
                    'PVE::QemuMigrate';
                @events = ();
                eval { $self->sync_offline_local_volumes(); };

                if ($allowed) {
                    is($@, '', "$section SD card layout survives migration ($remote)");
                    is_deeply(
                        \@events,
                        ['copy', 'query', 'deactivate-source'],
                        'successful migration validates capacity before deactivating source',
                    );
                } else {
                    like(
                        $@,
                        qr/SD card image must be|unable to determine target size/,
                        "$section SD card rejects invalid or missing target capacity ($remote)",
                    );
                    is_deeply(
                        \@events,
                        ['copy', 'query'],
                        'failed migration retains the active source',
                    );
                    $self->cleanup_remotedisks();
                    is(
                        $events[-1],
                        $remote ? 'abort-target' : 'free-target',
                        'normal migration cleanup discards the imported target',
                    );
                }
                is(
                    $self->{volume_map}->{$volume},
                    $target_volume,
                    'imported target is registered for cleanup',
                );
            }
        }
    }
}

done_testing();
