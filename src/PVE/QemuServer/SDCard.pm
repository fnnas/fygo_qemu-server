package PVE::QemuServer::SDCard;

use strict;
use warnings;

use PVE::Storage;
use PVE::Tools;
use PVE::QemuServer::Helpers;

sub validate_options {
    my ($drive) = @_;

    die "SD card cid must contain exactly 32 hexadecimal characters\n"
        if defined($drive->{cid}) && $drive->{cid} !~ m/\A[0-9a-fA-F]{32}\z/;
    if (defined(my $version = $drive->{'sd-spec-version'})) {
        die "SD card specification version must be 2 or 3\n" if $version !~ m/\A[23]\z/;
        $drive->{'sd-spec-version'} = 0 + $version;
    }
}

sub validate_size {
    my ($drive, $size) = @_;

    validate_options($drive);
    die "cannot determine SD card image size\n" if !defined($size) || $size <= 0;
    # QEMU's SDSC CSD encodes capacity in 256 KiB steps; its SDHC CSD has
    # a 22-bit count of 512 KiB units. Never advertise inaccessible sectors.
    die "SD card image must be between 256 KiB and 2 TiB\n"
        if $size < 256 * 1024 || $size > 2 * 1024**4;
    die "SD card image must be a power of two up to 2 GiB, or a multiple of 512 KiB above 2 GiB\n"
        if $size != int($size)
        || ($size <= 2 * 1024**3 ? ($size & ($size - 1)) : $size % (512 * 1024));
    return $size;
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

sub assert_qemu_support {
    my ($drive, $arch, $bootindex) = @_;

    my $binary = PVE::QemuServer::Helpers::get_command_for_arch($arch);
    for my $probe (
        (defined($drive->{cid}) ? ['sd-card', 'cid'] : ()),
        (defined($bootindex) ? ['sdhci-pci', 'bootindex'] : ()),
    ) {
        my ($device, $property) = @$probe;
        my $supported;
        eval {
            PVE::Tools::run_command(
                [$binary, '-device', "$device,help"],
                timeout => 10,
                outfunc => sub { $supported = 1 if $_[0] =~ m/^\s*\Q$property\E\s*=/; },
                errfunc => sub { },
            );
        };
        die
            "SD card $property requires a QEMU build with the $device.$property property; upgrade QEMU"
            . " or remove the corresponding setting\n"
            if $@ || !$supported;
    }
}

1;
