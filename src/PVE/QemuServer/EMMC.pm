package PVE::QemuServer::EMMC;

use strict;
use warnings;

use File::Temp;
use JSON qw(decode_json encode_json);

use PVE::GuestHelpers qw(safe_boolean_ne);
use PVE::Storage;
use PVE::Storage::Common;
use PVE::Tools;

use PVE::QemuServer::Helpers;

# QEMU interprets one image as BOOT1 | BOOT2 | RPMB | USER. These options
# describe offsets in that image; changing them never moves existing data.
sub validate_options {
    my ($drive) = @_;

    die "eMMC cid must contain exactly 32 hexadecimal characters\n"
        if defined($drive->{cid}) && $drive->{cid} !~ m/\A[0-9a-fA-F]{32}\z/;

    # Property strings use decimal integers; QEMU treats a leading zero as octal.
    for my $option (qw(boot-partition-size rpmb-partition-size boot-config)) {
        $drive->{$option} = 0 + $drive->{$option} if defined($drive->{$option});
    }

    my $boot = $drive->{'boot-partition-size'} // 0;
    my $rpmb = $drive->{'rpmb-partition-size'} // 0;
    die "eMMC boot-partition-size must be a multiple of 128 KiB, at most 32640 KiB\n"
        if $boot < 0 || $boot > 32640 * 1024 || $boot % (128 * 1024);
    die "eMMC rpmb-partition-size must be a multiple of 128 KiB, at most 16384 KiB\n"
        if $rpmb < 0 || $rpmb > 16384 * 1024 || $rpmb % (128 * 1024);

    my $config = $drive->{'boot-config'} // 0;
    my $access = $config & 7;
    my $enable = ($config >> 3) & 7;
    die "invalid eMMC boot-config: reserved partition or boot selection\n"
        if $config < 0 || $config > 127 || $access > 3 || ($enable > 2 && $enable != 7);
    die "eMMC boot-config requires boot partitions\n"
        if !$boot && ($access == 1 || $access == 2 || $enable == 1 || $enable == 2);
    die "eMMC boot-config requires an RPMB partition\n" if $access == 3 && !$rpmb;

    if (defined(my $key = $drive->{'auth-key'})) {
        die "eMMC auth-key must contain exactly 64 hexadecimal characters\n"
            if $key !~ m/\A[0-9a-fA-F]{64}\z/;
        die "eMMC auth-key requires an RPMB partition\n" if !$rpmb;
    }
}

sub validate_size {
    my ($drive, $size) = @_;

    validate_options($drive);
    die "cannot determine eMMC image size\n" if !defined($size) || $size <= 0;
    my $user =
        $size - 2 * ($drive->{'boot-partition-size'} // 0) - ($drive->{'rpmb-partition-size'} // 0);
    die "eMMC image must contain a non-empty user area after BOOT1, BOOT2 and RPMB\n"
        if $user <= 0;
    # QEMU's CSD encodes small eMMC capacities in 2 MiB steps. Smaller user
    # areas are reported larger than their backing, causing out-of-range I/O.
    die "eMMC user area must be at least 2 MiB"
        . " (image size: $size bytes, user area: $user bytes)\n"
        if $user < 2 * 1024**2;
    # QEMU also checks BOOT1/BOOT2 command addresses against the user size.
    # Keep every advertised boot partition sector accessible.
    my $boot = $drive->{'boot-partition-size'} // 0;
    die "eMMC user area must be at least as large as each boot partition"
        . " (user area: $user bytes, boot partition: $boot bytes)\n"
        if $user < $boot;
    # EXT_CSD SEC_COUNT is a 32-bit count of 512-byte sectors.
    die "eMMC user area exceeds the 32-bit sector count (maximum 2 TiB minus 512 bytes)\n"
        if $user > 0xffffffff * 512;
    die "eMMC user area must be a power of two up to 2 GiB, or a multiple of 512 bytes above 2 GiB"
        . " (image size: $size bytes, user area: $user bytes); use an image/storage preserving this layout\n"
        if $user != int($user)
        || $user % 512
        || ($user <= 2 * 1024**3 && ($user & ($user - 1)));
    return $user;
}

sub image_size {
    my ($storecfg, $drive) = @_;

    my ($storeid) = PVE::Storage::parse_volume_id($drive->{file}, 1);
    return PVE::Storage::volume_size_info($storecfg, $drive->{file}) if $storeid;
    return scalar(PVE::Storage::file_size_info(
        $drive->{file}, undef, $drive->{format} // 'raw',
    ));
}

sub validate_image {
    my ($storecfg, $drive) = @_;

    return validate_size($drive, image_size($storecfg, $drive));
}

# Only metadata and throttling can be applied to an existing eMMC backend.
# Compare defaults and hexadecimal bytes rather than their spelling, so an
# ordinary edit does not queue a device replacement for an unchanged value.
sub needs_cold_restart {
    my ($old, $new) = @_;

    for my $option (qw(boot-partition-size rpmb-partition-size boot-config)) {
        return 1 if ($old->{$option} // 0) != ($new->{$option} // 0);
    }
    for my $option (qw(auth-key cid)) {
        return 1 if lc($old->{$option} // '') ne lc($new->{$option} // '');
    }
    return 1
        if safe_boolean_ne($old->{snapshot} // 0, $new->{snapshot} // 0)
        || safe_boolean_ne($old->{detect_zeroes} // 1, $new->{detect_zeroes} // 1)
        || ($old->{format} // '') ne ($new->{format} // '');

    return 0;
}

# Read only the immutable snapshot table, using the qcow2 v2/v3 layout from
# docs/interop/qcow2.rst. Guest writes can change current refcounts and L1/L2
# tables while a snapshot is cloned, so do not run snapshot-goto on that state.
sub qcow2_snapshot_header {
    my ($path, $snapname) = @_;

    open(my $file, '<:raw', $path) or die "cannot read eMMC snapshot metadata: $!\n";
    my $length = -s $file;
    my $read = sub {
        my ($offset, $size) = @_;
        die "invalid eMMC qcow2 snapshot metadata range\n"
            if $offset < 0 || $size < 0 || $offset > $length || $size > $length - $offset;
        defined(sysseek($file, $offset, 0)) or die "cannot seek eMMC snapshot metadata: $!\n";
        my $data = '';
        while (length($data) < $size) {
            my $got = sysread($file, my $part, $size - length($data));
            die "cannot read eMMC snapshot metadata\n" if !$got;
            $data .= $part;
        }
        return $data;
    };
    my $header = $read->(0, 72);
    my ($magic, $version) = unpack('N N', $header);
    die "unsupported eMMC qcow2 snapshot header\n"
        if $magic != 0x514649fb || ($version != 2 && $version != 3);
    my $count = unpack('N', substr($header, 60, 4));
    my $offset = unpack('Q>', substr($header, 64, 8));
    my $table_start = $offset;
    die "invalid eMMC qcow2 snapshot table\n" if $count > 65536;

    for (1 .. $count) {
        $offset = int(($offset + 7) / 8) * 8;
        die "eMMC qcow2 snapshot table is too large\n" if $offset - $table_start > 64 * 1024**2;
        my $entry = $read->($offset, 40);
        my ($l1_offset, $l1_size, $id_size, $name_size) = unpack('Q> N n n', $entry);
        my $extra_size = unpack('N', substr($entry, 36, 4));
        my $name_offset = $offset + 40 + $extra_size + $id_size;
        my $name = $read->($name_offset, $name_size);
        if ($name eq $snapname) {
            my $size =
                $extra_size >= 16
                ? unpack('Q>', $read->($offset + 48, 8))
                : unpack('Q>', substr($header, 24, 8));
            die "invalid eMMC snapshot L1 table\n"
                if $l1_size && ($l1_offset > $length || $l1_size > ($length - $l1_offset) / 8);
            # Replace only virtual size and the L1 mapping; the read-only view
            # does not need to alter refcounts or apply any snapshot metadata.
            return pack('Q>', $size) . substr($header, 32, 4) . pack('N Q>', $l1_size, $l1_offset);
        }
        $offset = $name_offset + $name_size;
    }
    die "eMMC snapshot '$snapname' does not exist\n";
}

# A qcow2 internal snapshot retains its own virtual size. Temporarily loading
# just its L1 table (qemu-img convert -l) instead exposes the current size.
sub snapshot_view {
    my ($storecfg, $drive, $snapname) = @_;

    require PVE::QemuServer::Drive;
    PVE::Storage::activate_volumes($storecfg, [$drive->{file}], $snapname);
    my $path = PVE::Storage::path($storecfg, $drive->{file}, $snapname);
    my $format = PVE::QemuServer::Drive::checked_volume_format($storecfg, $drive->{file});
    my $internal = $format eq 'qcow2'
        && (PVE::Storage::volume_qemu_snapshot_method($storecfg, $drive->{file}) // '') eq 'qemu';
    my $view = {};
    if ($internal) {
        my $tmp = File::Temp->newdir('pve-emmc-XXXXXX', DIR => '/tmp');
        my $container = "$tmp/container.qcow2";
        my $header = "$tmp/header.bin";
        my $snapshot_header = qcow2_snapshot_header($path, $snapname);
        validate_size($drive, unpack('Q>', $snapshot_header));
        # Overlay the container's raw bytes, then select the snapshot L1 table
        # and capacity in the private header. Never touch the source's metadata.
        my $backing = {
            driver => 'raw',
            'force-share' => JSON::true,
            file => { driver => 'file', filename => $path },
        };
        PVE::Tools::run_command([
            '/usr/bin/qemu-img',
            'create',
            '-q',
            '-f',
            'qcow2',
            '-F',
            'raw',
            '-b',
            'json:' . encode_json($backing),
            $container,
        ]);
        PVE::Tools::file_set_contents($header, $snapshot_header);
        PVE::Tools::run_command(
            [
                '/usr/bin/qemu-io', '-f', 'qcow2', '-c', "write -s $header 24 24", $container,
            ],
            outfunc => sub { },
        );
        my $node = {
            driver => 'qcow2',
            file => { driver => 'qcow2', file => { driver => 'file', filename => $container } },
        };
        # Resolve the original image's backing path before moving its header
        # into /tmp; a relative backing filename must keep its original meaning.
        my $source_info = decode_json(PVE::Storage::Common::qemu_img_info($path, $format, 10));
        if (my $backing_path = $source_info->{'full-backing-filename'}) {
            if ($backing_path =~ /^json:(.*)$/s) {
                $node->{backing} = decode_json($1);
            } else {
                my $backing_format = $source_info->{'backing-filename-format'};
                if (!$backing_format) {
                    my $info = decode_json(
                        PVE::Storage::Common::qemu_img_info($backing_path, undef, 10),
                    );
                    $backing_format = $info->{format};
                }
                $node->{backing} = {
                    driver => $backing_format,
                    file => { filename => $backing_path },
                };
            }
        }
        $view->{guard} = $tmp;
        $view->{node} = $node;
        # Image-info deliberately opens without backing devices and rejects
        # explicit backing options. It only needs the private snapshot header.
        my $probe = {%$node};
        delete $probe->{backing};
        $path = 'json:' . encode_json($probe);
    }
    my $info = decode_json(PVE::Storage::Common::qemu_img_info($path, $format, 10));
    validate_size($drive, $info->{'virtual-size'});
    $view->{size} = $info->{'virtual-size'};
    return $view;
}

# Probe the actual emulator, since downstream builds can backport this property.
# Never include configured values in commands used for probing or errors.
sub assert_qemu_support {
    my ($drive, $arch) = @_;

    my @properties = grep { defined($drive->{$_}) } qw(auth-key cid);
    return if !@properties;
    my $binary = PVE::QemuServer::Helpers::get_command_for_arch($arch);
    my %supported;
    eval {
        PVE::Tools::run_command(
            [$binary, '-device', 'emmc,help'],
            timeout => 10,
            outfunc => sub {
                $supported{$1} = 1 if $_[0] =~ m/^\s*(auth-key|cid)\s*=/;
            },
            errfunc => sub { },
        );
    };
    %supported = () if $@;
    for my $property (@properties) {
        next if $supported{$property};
        my $hint =
            $property eq 'auth-key' ? ' (guest-programmed keys do not survive a cold restart)' : '';
        die "eMMC $property requires a QEMU build with the emmc.$property property; upgrade QEMU"
            . " or remove $property$hint\n";
    }
}

1;
