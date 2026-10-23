package PVE::QemuServer::QMPHelpers;

use v5.36;

use Encode qw(decode FB_CROAK);

use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor qw(mon_cmd);

use base 'Exporter';

our @EXPORT_OK = qw(
    get_running_qemu_version
    qemu_deviceadd
    qemu_devicedel
    qemu_objectadd
    qemu_objectdel
);

sub nbd_stop($vmid) {
    mon_cmd($vmid, 'nbd-server-stop', timeout => 25);
}

# The QEMU package string is of the form pve-qemu-kvm_X.Y.Z-R.
sub get_qemu_package_string($vmid) {
    my $res = mon_cmd($vmid, 'query-version');
    return $res->{package};
}

sub get_running_qemu_version($vmid) {
    my $res = mon_cmd($vmid, 'query-version');
    return "$res->{qemu}->{major}.$res->{qemu}->{minor}";
}

sub qemu_deviceadd($vmid, $devicefull) {
    # Command-line device options contain bytes (including URL-decoded disk
    # identifiers), while QMP JSON strings contain characters.
    $devicefull = decode('UTF-8', $devicefull, FB_CROAK) if !utf8::is_utf8($devicefull);
    $devicefull = "driver=" . $devicefull;
    # HMP expects the complete property list as a single argument. Serial
    # numbers may contain URL-decoded whitespace, quotes or backslashes.
    $devicefull =~ s/([\\"])/\\$1/g;
    $devicefull =~ s/\n/\\n/g;
    $devicefull =~ s/\r/\\r/g;

    my $result = PVE::QemuServer::Monitor::hmp_cmd($vmid, "device_add \"$devicefull\"", 25);
    # HMP returns device realization errors as text inside a successful QMP
    # response. Do not mistake that response for a successful device_add.
    die "adding device failed: $result\n" if $result ne '';

    return $result;
}

sub qemu_devicedel($vmid, $deviceid) {
    PVE::QemuServer::Monitor::hmp_cmd($vmid, "device_del $deviceid", 25);
}

sub qemu_objectadd($vmid, $objectid, $qomtype, %args) {
    mon_cmd($vmid, "object-add", id => $objectid, "qom-type" => $qomtype, %args);

    return 1;
}

sub qemu_objectdel($vmid, $objectid) {
    mon_cmd($vmid, "object-del", id => $objectid);

    return 1;
}

# dies if a) VM not running or not existing b) Version query failed
# So, any defined return value is valid, any invalid state can be caught by eval
sub runs_at_least_qemu_version($vmid, $major, $minor, $extra = undef) {
    my $v = PVE::QemuServer::Monitor::mon_cmd($vmid, 'query-version');
    die "could not query currently running version for VM $vmid\n" if !defined($v);
    $v = $v->{qemu};

    return PVE::QemuServer::Helpers::version_cmp(
        $v->{major}, $major, $v->{minor}, $minor, $v->{micro}, $extra,
    ) >= 0;
}

1;
