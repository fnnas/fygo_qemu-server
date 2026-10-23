#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;

use PVE::API2::Qemu;
use PVE::QemuServer;
use PVE::QemuServer::Blockdev;
use PVE::QemuServer::Drive qw(parse_drive print_drive);

my $volume = '/tmp/usbdisk-limits-test.raw';
my $cluster = Test::MockModule->new('PVE::Cluster');
$cluster->mock(cfs_read_file => sub { {} });

for my $bus (qw(usbdisk scsi virtio nvme sata ide)) {
    for my $direction (['', '-total'], ['_rd', '-read'], ['_wr', '-write']) {
        my ($suffix, $qmp_suffix) = @$direction;
        for my $bytes (0, 1, 3, 511, 1024, 1_048_575, 1_048_576, 2_097_153, 1_000_000_000_000_000) {
            my $options = "$volume,aio=threads,cache=writeback,bps$suffix=$bytes";
            my $drive = parse_drive("${bus}0", $options);
            ok($drive, "$bus parses legacy bps$suffix=$bytes") or next;
            my $limits = PVE::QemuServer::Blockdev::generate_throttle_group($drive)->{limits};
            is(
                $limits->{"bps$qmp_suffix"} // 0,
                $bytes,
                'modern QEMU receives the original byte rate',
            );
            my $legacy = PVE::QemuServer::print_drive_commandline_full({}, 8006, $drive);
            my ($rate) = $legacy =~ /(?:^|,)throttling\.bps\Q$qmp_suffix\E=(\d+)(?:,|$)/;
            is($rate // 0, $bytes, 'legacy QEMU receives the original byte rate');
            my $roundtrip = parse_drive("${bus}0", print_drive($drive));
            ok($roundtrip, 'normalized configuration can be parsed again') or next;
            is(
                PVE::QemuServer::Blockdev::generate_throttle_group($roundtrip)->{limits}
                    ->{"bps$qmp_suffix"} // 0,
                $bytes,
                'configuration save and reload retain byte precision',
            );
        }
    }
}

my @invalid;
for my $family (qw(mbps iops)) {
    for my $suffix ('', '_rd', '_wr') {
        push @invalid,
            "$family$suffix=-1",
            "${family}${suffix}_max=-1,$family$suffix=1",
            "${family}${suffix}_max=100",
            "${family}${suffix}_max=100,$family$suffix=0",
            "$family$suffix=100,${family}${suffix}_max=10";
        my $length =
            $family eq 'mbps' ? "bps${suffix}_max_length" : "${family}${suffix}_max_length";
        my $minimum = $family eq 'mbps' ? '0.00000095367431640625' : 1;
        push @invalid, "$family$suffix=$minimum,${family}${suffix}_max=$minimum,$length=4294967296";
    }
}
push @invalid,
    'bps=-1', 'bps_rd=-1', 'bps_wr=-1',
    'mbps=1000000000', 'iops=1000000000000001',
    'mbps=0.0000001', 'mbps_rd=0.0000001', 'mbps_wr=0.0000001',
    'iops=100,iops_max=200,iops_max_length=10000000000000',
    'mbps=1,mbps_max=2,bps_max_length=1000000000';

for my $bus (qw(usbdisk scsi virtio nvme sata ide)) {
    for my $options (@invalid) {
        local $SIG{__WARN__} = sub { };
        ok(!parse_drive("${bus}0", "$volume,$options"), "$bus rejects invalid limits: $options");
    }
    for my $options (
        'mbps=0,iops=0',
        'mbps_rd=1,mbps_rd_max=1',
        'iops_wr=10,iops_wr_max=20,iops_wr_max_length=3',
        'mbps_rd=1,mbps_rd_max=2,bps_rd_max_length=3',
        'mbps_wr=1,mbps_wr_max=2,bps_wr_max_length=3',
        'iops=1000000000000000,iops_max=1000000000000000',
        'iops=1,iops_max=1,iops_max_length=4294967295',
        'mbps=0.00000095367431640625,mbps_max=0.00000095367431640625,bps_max_length=4294967295',
    ) {
        ok(parse_drive("${bus}0", "$volume,$options"), "$bus retains valid limits: $options");
    }
}

{

    package USBLimitsRPC;
    sub get_user { 'root@pam' }
}
{

    package USBLimitsReplication;
    sub check_for_existing_jobs { 0 }
}
{
    my $rpc = Test::MockModule->new('PVE::RPCEnvironment');
    $rpc->mock(get => sub { bless {}, 'USBLimitsRPC' });
    my $replication = Test::MockModule->new('PVE::ReplicationConfig');
    $replication->mock(new => sub { bless {}, 'USBLimitsReplication' });
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(config => sub { {} });
    my $effects = 0;
    for my $operation (qw(activate_volumes vdisk_alloc)) {
        $storage->mock($operation => sub { $effects++; die "unexpected storage mutation\n"; });
    }
    my $config = Test::MockModule->new('PVE::QemuConfig');
    $config->mock(write_config => sub { $effects++; die "unexpected config mutation\n"; });
    for my $options (@invalid) {
        local $SIG{__WARN__} = sub { };
        eval {
            PVE::API2::Qemu->map_method_by_name('update_vm_async')->{code}->({
                node => 'pve',
                vmid => 8006,
                usbdisk0 => "local:1,$options",
            });
        };
        like(
            $@,
            qr/unable to parse drive options/,
            "USB API rejects limits before allocation: $options",
        );
    }
    is($effects, 0, 'invalid USB requests never allocate storage or write VM configuration');
}

done_testing();
