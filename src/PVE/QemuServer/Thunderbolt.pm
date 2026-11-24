package PVE::QemuServer::Thunderbolt;

use strict;
use warnings;

use URI::Escape qw(uri_unescape);

use PVE::JSONSchema qw(parse_property_string);
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Machine;
use PVE::Tools;

our $MAX_HOSTS = 2;
our $MAX_DOCKS = 4;
our $DOWNSTREAM_PORTS = 3;

my %pcie_switch_model = (
    'tb3-alpine-ridge' => 'usb4-tb3',
    'tb3-titan-ridge' => 'usb4-tr',
);

my $host_format = {
    model => {
        type => 'string',
        enum =>
            [qw(usb4-generic intel-adl asm4242 amd tb3-alpine-ridge tb3-titan-ridge tb3-ice-lake)],
        default_key => 1,
        description => 'Emulated Thunderbolt or USB4 host controller model.',
    },
};
my $dock_format = {
    host => {
        type => 'string',
        pattern => '^thunderbolt[01]$',
        format_description => 'controller',
        description => 'Thunderbolt host controller to connect the dock to.',
        optional => 1,
    },
    parent => {
        type => 'string',
        pattern => '^tbdock[0-3]$',
        format_description => 'dock',
        description => 'Parent dock to connect the dock to.',
        optional => 1,
    },
    port => {
        type => 'integer',
        minimum => 1,
        maximum => $DOWNSTREAM_PORTS,
        description => 'Port on the parent dock or controller.',
    },
    disconnected => {
        type => 'boolean',
        description => 'Disconnect the dock while keeping its configured upstream port.',
        optional => 1,
        default => 0,
    },
};

sub config_descriptions {
    return (
        (
            map { (
                "thunderbolt$_" => {
                    type => 'string',
                    format => $host_format,
                    optional => 1,
                    description => 'Virtual Thunderbolt or USB4 controller.',
                },
            ) } 0 .. $MAX_HOSTS - 1
        ),
        (
            map { (
                "tbdock$_" => {
                    type => 'string',
                    format => $dock_format,
                    optional => 1,
                    description => 'Virtual Thunderbolt dock.',
                },
            ) } 0 .. $MAX_DOCKS - 1
        ),
    );
}

sub topology {
    my ($conf, $drives) = @_;
    my ($hosts, $docks, $ports) = ({}, {}, {});
    for my $id (sort keys %$conf) {
        next if !defined($conf->{$id});
        if ($id =~ /^thunderbolt[01]$/) {
            $hosts->{$id} = parse_property_string($host_format, $conf->{$id});
        } elsif ($id =~ /^tbdock[0-3]$/) {
            $docks->{$id} = parse_property_string($dock_format, $conf->{$id});
        }
    }
    if (keys %$hosts || keys %$docks) {
        die "Thunderbolt requires an x86_64 Q35 or compatible custom machine\n"
            if PVE::QemuServer::Helpers::get_vm_arch($conf) ne 'x86_64'
            || !PVE::QemuServer::Machine::machine_type_is_q35($conf);
    }
    my @ordered;
    my %visiting;
    my %child_docks;
    my $resolve;
    $resolve = sub {
        my ($id) = @_;
        my $dock = $docks->{$id};
        return $dock->{root} if $dock->{root};
        die "$id: Thunderbolt docks cannot form a cycle\n" if $visiting{$id};
        local $visiting{$id} = 1;
        my ($host, $parent, $port) = $dock->@{qw(host parent port)};
        die "$id: specify exactly one Thunderbolt controller or parent dock\n"
            if defined($host) == defined($parent);
        if ($parent) {
            die "$id: Thunderbolt dock '$parent' does not exist\n" if !$docks->{$parent};
            $dock->{root} = $resolve->($parent);
            die "$id: chained docks require a USB4 controller\n"
                if $hosts->{ $dock->{root} }->{model} =~ /^tb3-/;
            # The current QEMU switch model shares its PCI slot numbering
            # across branches of a tunnel. Keep the supported cascade linear
            # and use one downstream switch per root dock.
            die "$id: only one level of Thunderbolt dock cascading is supported\n"
                if $docks->{$parent}->{parent};
            die "$id: Thunderbolt dock '$parent' already has a chained dock\n"
                if $child_docks{$parent}++;
        } else {
            die "$id: Thunderbolt controller '$host' does not exist\n" if !$hosts->{$host};
            die "$id: Alpine Ridge has only port 1\n"
                if $port > 1 && $hosts->{$host}->{model} eq 'tb3-alpine-ridge';
            die "$id: Thunderbolt controller '$host' has only two ports\n" if $port > 2;
            $dock->{root} = $host;
        }
        my $upstream = $parent // $host;
        die "$id: Thunderbolt device '$upstream' port $port already has a dock\n"
            if $ports->{$upstream}->{$port}++;
        push @ordered, $id;
        return $dock->{root};
    };
    eval { $resolve->($_) for sort keys %$docks };
    my $err = $@;
    undef $resolve;
    die $err if $err;

    for my $id (sort keys %$drives) {
        my $drive = $drives->{$id};
        my $dock_id = $drive->{'nvme-dock'} // next;
        my $dock = $docks->{$dock_id}
            or die "$id: Thunderbolt dock '$dock_id' does not exist\n";
        if (my $port = $drive->{'nvme-dock-port'}) {
            die "$id: downstream storage ports require a USB4 controller\n"
                if $hosts->{ $dock->{root} }->{model} =~ /^tb3-/;
            die "$id: Thunderbolt dock '$dock_id' port $port is already in use\n"
                if $ports->{$dock_id}->{$port}++;
            $dock->{disks}->{$port} = { id => $id, serial => $drive->{serial} };
            next;
        }
        die "$id: Thunderbolt dock '$dock_id' already has an NVMe disk\n" if $dock->{drive_id};
        $dock->{drive_id} = $id;
        $dock->{drive_disconnected} = $drive->{disconnected};
        $dock->{serial} = uri_unescape($drive->{serial} // $id);
    }
    for my $dock (values %$docks) {
        $dock->{downstream_ports} =
            $hosts->{ $dock->{root} }->{model} =~ /^tb3-/ ? 0 : $DOWNSTREAM_PORTS;
    }
    return ($hosts, $docks, \@ordered);
}

sub dock_device {
    my ($id, $dock, $nvme_hotplug) = @_;
    my $spec = "usb4-device,id=$id,bus=$dock->{root}.0,port=$dock->{port},dock=on"
        . ",downstream-ports=$dock->{downstream_ports}";
    $spec .= ",parent=$dock->{parent}" if $dock->{parent};
    $spec .= ',x-cable=off' if $dock->{disconnected};
    my $serial = ($dock->{serial} // $id) =~ s/,/,,/gr;
    $spec .= ",serial=$serial";
    if (my $disk = $dock->{drive_id}) {
        if ($nvme_hotplug) {
            $spec .= ",drive=drive-$disk,x-dock-nvme-hotplug=on";
            $spec .= ',x-nvme-disconnected=on' if $dock->{drive_disconnected};
        } elsif (!$dock->{drive_disconnected}) {
            $spec .= ",drive=drive-$disk";
        }
    }
    return $spec;
}

sub disk_device {
    my ($id, $dock_id, $host, $port, $serial) = @_;
    $serial = uri_unescape($serial // $id) =~ s/,/,,/gr;
    return "usb4-device,id=tb-$id,bus=$host.0,parent=$dock_id,port=$port,drive=drive-$id"
        . ",serial=$serial";
}

my sub discrete_controller_switch {
    my ($host, $index, $type, $ports) = @_;
    my $root = "$host-root";
    my $switch = "$host-switch";
    my $addr = sprintf('0x1c.%d', 4 + $index);
    # Keep these chassis IDs outside the range used by the standalone tunnel root ports.
    my $chassis = 235 + 5 * $index;
    my @devices = (
        "usb4-tunnel-port,id=$root,bus=pcie.0,addr=$addr,chassis=$chassis"
            . ',bus-reserve=32,mem-reserve=32M,usb4-dvsec=off',
        "$type-usp,id=$switch,bus=$root,addr=0",
        "$type-dsp,id=$host-nhi,bus=$switch,addr=0,chassis=" . ($chassis + 1) . ',slot=0',
        "$type-dsp,id=$host-xhci-port,bus=$switch,addr=2,chassis=" . ($chassis + 2) . ',slot=2',
        "$type-xhci,id=$host-xhci,bus=$host-xhci-port,addr=0",
    );
    for my $port (1 .. $ports) {
        my $slot = $port == 1 ? 1 : 4;
        push @devices,
            "$type-tunnel-dsp,id=$host-port$port,bus=$switch,addr=$slot,chassis="
            . ($chassis + 2 + $port)
            . ",slot=$slot,usb4-port=$port";
    }
    return map { ('-device', $_) } @devices;
}

sub devices {
    my ($hosts, $docks, $order, $binary, $dry_run) = @_;
    return () if !keys %$hosts;
    my $can_reserve_dock = $dry_run;
    my $nvme_hotplug = $dry_run;
    if (!$dry_run) {
        my %devices;
        eval {
            PVE::Tools::run_command(
                [$binary, '-device', 'help'],
                timeout => 10,
                outfunc => sub {
                    $devices{$1} = 1 if $_[0] =~ /^name "([^"]+)"/;
                },
            );
        };
        die "Could not query the QEMU device list ($binary): $@" if $@;
        my %required = map { $_ => 1 } qw(usb4-host usb4-device usb4-tunnel-port);
        for my $host (values %$hosts) {
            my $type = $pcie_switch_model{ $host->{model} } or next;
            $required{"$type-$_"} = 1 for qw(usp dsp tunnel-dsp xhci);
        }
        my @missing = grep { !$devices{$_} } sort keys %required;
        die "Thunderbolt requires a QEMU build with USB4 emulation ($binary is missing: "
            . join(', ', @missing) . ")\n"
            if @missing;

        eval {
            PVE::Tools::run_command(
                [$binary, '-device', 'usb4-tunnel-dsp,help'],
                timeout => 10,
                outfunc => sub { $can_reserve_dock = 1 if $_[0] =~ /^\s*x-reserve-for-dock=</ },
                errfunc => sub { },
            );
        };
        die "Chained Thunderbolt docks require a QEMU build with downstream resource reservation\n"
            if !$can_reserve_dock && grep { $_->{parent} } values %$docks;
        if (grep { $_->{drive_id} || $_->{disconnected} } values %$docks) {
            my %properties;
            eval {
                PVE::Tools::run_command(
                    [$binary, '-device', 'usb4-device,help'],
                    timeout => 10,
                    outfunc => sub { $properties{$1} = 1 if $_[0] =~ /^\s*(x-[\w-]+)=</ },
                    errfunc => sub { },
                );
            };
            %properties = () if $@;
            $nvme_hotplug = $properties{'x-dock-nvme-hotplug'};
            die "Disconnected Thunderbolt docks require QEMU support for usb4-device.x-cable\n"
                if !$properties{'x-cable'} && grep { $_->{disconnected} } values %$docks;
        }
    }

    my @devices;
    push @devices, '-global', 'usb4-tunnel-dsp.x-reserve-for-dock=on' if $can_reserve_dock;
    for my $host (sort keys %$hosts) {
        my ($index) = $host =~ /(\d+)$/;
        my $model = $hosts->{$host}->{model};
        my $ports = $model eq 'tb3-alpine-ridge' ? 1 : 2;
        my $addr = sprintf('0x1c.%d', 4 + $index);
        my $switch_type = $pcie_switch_model{$model};
        my $placement = $switch_type ? "bus=$host-nhi,addr=0" : "bus=pcie.0,addr=$addr";
        my $spec = "usb4-host,id=$host,$placement,ports=$ports";
        $spec .=
            $model =~ /^tb3-/
            ? ",profile=$model,security=none"
            : ",profile=usb4-generic,preos-cm=on,host-model="
            . ($model eq 'usb4-generic' ? 'minimal' : $model);

        if ($switch_type) {
            $spec .= ',power=always';
            push @devices, discrete_controller_switch($host, $index, $switch_type, $ports);
        }
        for my $port (1 .. $ports) {
            my $target = "$host-port$port";
            $spec .= ($port == 1 ? ',tunnel-port=' : ',tunnel-port2=') . $target;
            next if $switch_type;

            my $function = 4 + 2 * $index + $port - 1;
            my $chassis = 230 + 2 * $index + $port;
            my ($dock) =
                grep { ($_->{host} // '') eq $host && $_->{port} == $port } values %$docks;
            my $tunnel =
                "usb4-tunnel-port,id=$target,bus=pcie.0,addr=0x1f.$function,chassis=$chassis"
                . ",bus-reserve=32,mem-reserve=32M,usb4-port=$port";
            # Preserve the cold-plug behavior of existing integrated disks.
            $tunnel .= ',x-force-tunnel=on'
                if $dock && !$dock->{disconnected} && ($dock->{drive_id} || $model =~ /^tb3-/);
            push @devices, '-device', $tunnel;
        }
        push @devices, '-device', $spec;
    }

    for my $id (@$order) {
        my $dock = $docks->{$id};
        push @devices, '-device', dock_device($id, $dock, $nvme_hotplug);
        for my $port (sort keys %{ $dock->{disks} // {} }) {
            my $disk = $dock->{disks}->{$port};
            push @devices, '-device',
                disk_device($disk->{id}, $id, $dock->{root}, $port, $disk->{serial});
        }
    }
    return @devices;
}

1;
