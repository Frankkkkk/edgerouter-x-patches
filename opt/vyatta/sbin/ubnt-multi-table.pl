#!/usr/bin/perl
# Module: ubnt-multi-table.pl

use strict;
use warnings;
use Getopt::Long;

$ENV{PATH} = '/usr/sbin:/usr/bin:/sbin:/bin';

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;

use constant {
    # Actions
    ACTION_ADD              => "add",
    ACTION_DEL              => "del",
    ACTION_SHOW             => "show",

    # Route types
    ROUTE_NEXTHOP           => "next-hop",
    ROUTE_BLACKHOLE         => "blackhole",
    ROUTE_IF                => "next-hop-interface",

    # Address families
    AF_IPV4                 => "ipv4",
    AF_IPV6                 => "ipv6",

    # Misc
    DISTANCE_UNDEFINED      => -1,
    INTERFACE_UNDEFINED      => "",
};

my ($action, $table, $route_type, $route, $nexthop);
my $af = AF_IPV4;
my $distance = DISTANCE_UNDEFINED;
my $interface = INTERFACE_UNDEFINED;
my $debug_flag = 0;
GetOptions(
    "action=s"         => \$action,
    "table=s"          => \$table,
    "route-type=s"     => \$route_type,
    "route=s"          => \$route,
    "next-hop=s"       => \$nexthop,
    "distance=s"       => \$distance,
    "interface=s"       => \$interface,
    "address-family=s" => \$af,
    "debug=s"          => \$debug_flag,
);

my $ip_cmd = 'sudo ip';
if ($af eq AF_IPV6) {
    $ip_cmd = 'sudo ip -6';
}

# Force debug
#$debug_flag = 1;

sub log_msg {
  my $message = shift;
  print "DEBUG: $message\n" if $debug_flag;
}

sub run_cmd {
    my ($cmd) = @_;

    if ($cmd =~ /^($ip_cmd route .*)$/) {
        $cmd = $1;
    } else {
        print "Running command [$cmd]";
    }

    # Run shell command and get exit status
    my $output = `$cmd 2>&1`;
    my $exit_status=$?;

    log_msg("shell_command=$cmd");
    log_msg("exit_status=$exit_status");
    log_msg("output=$output");

    # Print error message
#    if ($exit_status != 0) {
#        print("$cmd\n$output\n");
#    }
    return ($exit_status, $output);
}

sub create_ip_cmd {
    my ($action, $table, $route_type, $route, $nexthop, $distance, $interface) = @_;

    # Action/table
    my $cmd = "$ip_cmd route $action table $table";

    # Route-type/route
    if ($route_type eq ROUTE_NEXTHOP) {
        $cmd = "$cmd $route via $nexthop";
    } elsif ($route_type eq ROUTE_BLACKHOLE) { 
        $cmd = "$cmd blackhole $route";
    } elsif ($route_type eq ROUTE_IF) { 
        $cmd = "$cmd $route dev $nexthop";
    } else {
        die("Failed to create ip command, invalid route type [$route_type]\n");
    }

    # Distance
    $cmd = "$cmd metric $distance" if ($distance > DISTANCE_UNDEFINED);
    # Interface
    $cmd = "$cmd dev $interface" if ($interface ne INTERFACE_UNDEFINED);
    return $cmd;
}

sub del_all_routes_by_if {
    my ($if_name) = @_;
    my $route_mask = " dev $if_name ";

    # Walk routing tables
    my $config = new Vyatta::Config;
    my @tables = $config->listOrigNodes("protocols static table");
    foreach my $table (@tables) {
        #
        # Output sample:
        #   root@ubnt-pro:~# /bin/ip route show table 42
        #   1.1.1.1 dev eth0  scope link  metric 2
        #   2.2.2.2 dev eth1  scope link  metric 3
        #   3.3.3.3 via 192.168.1.111 dev eth0  metric 4
        #   4.4.4.4 via 10.1.1.111 dev eth1  metric 5
        #   blackhole 5.5.5.5  metric 6
        # 
        my $output = (run_cmd("$ip_cmd route show table $table"))[1];
        foreach my $line (split(/\n/, $output)) {
            # Ignore route with non-matching next-hop interfaces (wrong dev)
            if ($line !~ $route_mask) {
                log_msg("Ignoring non matching route [$line]");
                next;
            }

            # Extract route definition from string
            my ($match_start, $match_end) = (@-, @+);
            my $route = ($line =~ " via ") ? 
                substr($line, 0, $match_start) :  # Generic nexthop route (i.e. 3.3.3.3) 
                substr($line, 0, $match_end + 1); # Interface route (i.e. 1.1.1.1)

            # Delete matched route 
            run_cmd("$ip_cmd route del table $table $route");
        }
    }
}

sub add_kernel_route_if_not_disabled {
    my $config  = $_[0];
    my $path    = $_[1];
    my $table   = $_[2];
    my $nh_type = $_[3];
    my $route   = $_[4];
    my $nh      = $_[5];

    if ($config->existsOrig("$path disable")) {
        log_msg("Ignoring disabled static route [$path]");
        return;
    }

    my $distance = DISTANCE_UNDEFINED;
    if ($config->existsOrig("$path distance") ) {
        $distance = $config->returnOrigValue("$path distance");
    }

    my $interface = INTERFACE_UNDEFINED;
    if ($config->existsOrig("$path interface") ) {
        $interface = $config->returnOrigValue("$path interface");
    }

    # Update kernel route
    run_cmd(create_ip_cmd(ACTION_ADD, $table, $nh_type, $route, $nh, $distance, $interface));
}

sub update_all_tables {
    my ($action, $nh_if) = @_;

    # Walk routing tables
    my $config = new Vyatta::Config;
    my @tables = $config->listOrigNodes("protocols static table");

    foreach my $table (@tables) {
        my $path = "protocols static table $table interface-route";
        my $nh_type = ROUTE_IF;

        foreach my $route ($config->listOrigNodes($path)) {
            foreach my $nh ($config->listOrigNodes("$path $route $nh_type")) {
                add_kernel_route_if_not_disabled($config, "$path $route $nh_type $nh", $table, $nh_type, $route, $nh);
            }
        }

        $path = "protocols static table $table route";
        foreach my $route ($config->listOrigNodes($path)) {
            $nh_type = ROUTE_NEXTHOP;
            foreach my $nh ($config->listOrigNodes("$path $route $nh_type")) {
                add_kernel_route_if_not_disabled($config, "$path $route $nh_type $nh", $table, $nh_type, $route, $nh);
            }

            $nh_type = ROUTE_BLACKHOLE;
            if ($config->existsOrig("$path $route $nh_type")) {
                add_kernel_route_if_not_disabled($config, "$path $route $nh_type", $table, $nh_type, $route, undef);
            }
        }
    }
}

# If routing table was not explicitly specified then action is performed in all 
# non-default routing tables
if (not defined($table)) {
    # If nexthop interface was specified then we delete all routes with specified
    # nexthop interface from all non-default routing tables
    if ($action eq ACTION_DEL and defined($nexthop)) {
        log_msg("del_all_routes_by_if($nexthop)");
        del_all_routes_by_if($nexthop);

    # Otherwise if nexthop interface was not specified then we perform action 
    # (either add or delete) on all routes in all non-default routing tables
    } else {
        log_msg("update_all_tables($action)");
        update_all_tables($action, $nexthop);
    }

# Add route to specified routing table
} elsif ($action eq ACTION_ADD) {
    $nexthop = "undefined" unless $nexthop;
    log_msg("add_route($table, $route_type, $route, $nexthop, $distance, $interface)");
    run_cmd(create_ip_cmd($action, $table, $route_type, $route, $nexthop, $distance, $interface));

# Delete route from specified routing table
} elsif ($action eq ACTION_DEL) {
    $nexthop = "undefined" unless $nexthop;
    log_msg("del_route($table, $route_type, $route, $nexthop, $distance, $interface)");
    run_cmd(create_ip_cmd($action, $table, $route_type, $route, $nexthop, $distance, $interface));

# Show routes from specified routing table
} elsif ($action eq ACTION_SHOW) {
    log_msg("show_route($table)");
    my $output = (run_cmd("$ip_cmd route show table $table"))[1];
    print $output

# Huh 0_o ?
} else {
    die("Invalid action [$action]\n");
}
exit 0;
