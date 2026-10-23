package PVE::QemuServer::EMMC;

use strict;
use warnings;

use PVE::Storage;
use PVE::Tools;

use PVE::QemuServer::Helpers;

# QEMU interprets one image as BOOT1 | BOOT2 | RPMB | USER. These options
# describe offsets in that image; changing them never moves existing data.
sub validate_options {
    my ($drive) = @_;

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

# Probe the actual emulator, since downstream builds can backport this property.
# Never include the authentication key in commands used for probing or errors.
sub assert_auth_key_support {
    my ($drive, $arch) = @_;

    return if !defined($drive->{'auth-key'});
    my $binary = PVE::QemuServer::Helpers::get_command_for_arch($arch);
    my $supported = 0;
    eval {
        PVE::Tools::run_command(
            [$binary, '-device', 'emmc,help'],
            timeout => 10,
            outfunc => sub { $supported = 1 if $_[0] =~ m/^\s*auth-key\s*=/; },
            errfunc => sub { },
        );
    };
    die "eMMC auth-key requires a QEMU build with the emmc.auth-key property; upgrade QEMU"
        . " or remove auth-key (guest-programmed keys do not survive a cold restart)\n"
        if !$supported;
}

1;
