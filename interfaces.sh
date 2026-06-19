#!/usr/bin/env bash
# auto-network-config.sh – Complete network setup for your topology.
# Run as root on each VM. Hostname must match one of the roles below.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }
warn() { echo "WARNING: $*" >&2; }
check_root() { [[ $EUID -eq 0 ]] || die "Must be run as root."; }

# ----------------------------------------------------------------------
# Install missing packages (iptables, bridge-utils)
# ----------------------------------------------------------------------
install_pkg() {
    local pkg="$1"
    if ! pacman -Q "$pkg" &>/dev/null; then
        info "Installing $pkg..."
        pacman -S --noconfirm "$pkg" || die "Failed to install $pkg"
    else
        info "$pkg is already installed."
    fi
}

# ----------------------------------------------------------------------
# Enable and start systemd-networkd
# ----------------------------------------------------------------------
enable_networkd() {
    systemctl enable systemd-networkd 2>/dev/null || true
    systemctl restart systemd-networkd
}

# ----------------------------------------------------------------------
# Get interface by index (order from 'ip link' – matches VirtualBox)
# ----------------------------------------------------------------------
get_interface_by_index() {
    local index="$1"
    local adapters
    mapfile -t adapters < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$')
    [[ ${#adapters[@]} -ge "$index" ]] || die "Not enough interfaces for index $index"
    echo "${adapters[$((index-1))]}"
}

# ----------------------------------------------------------------------
# COMPLETE CLEANUP – removes ALL previous IPs, routes, and configs
# ----------------------------------------------------------------------
full_cleanup() {
    info "Performing complete network cleanup..."

    # Flush ALL IPs from ALL interfaces (except lo)
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
        ip addr flush dev "$iface" 2>/dev/null || true
        info "Flushed $iface"
    done

    # Remove ALL routes
    ip route flush all 2>/dev/null || true

    # Remove ALL systemd-networkd config files we created
    rm -f /etc/systemd/network/*.network 2>/dev/null || true

    # Remove iptables NAT rules (if any)
    iptables -t nat -F 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true

    info "Cleanup complete."
}

# ----------------------------------------------------------------------
# Assign static IP + optional gateway (using systemd-networkd)
# ----------------------------------------------------------------------
assign_ip() {
    local interface="$1"
    local ip="$2"
    local prefix="$3"
    local gateway="${4:-}"

    info "Assigning $ip/$prefix to $interface"
    ip addr flush dev "$interface" 2>/dev/null || true
    ip addr add "$ip/$prefix" dev "$interface"
    ip link set dev "$interface" up

    local netdir="/etc/systemd/network"
    mkdir -p "$netdir"
    local config_file="$netdir/20-${interface}.network"
    cat > "$config_file" <<EOF
[Match]
Name=$interface

[Network]
Address=$ip/$prefix
EOF

    if [[ -n "$gateway" ]]; then
        echo "Gateway=$gateway" >> "$config_file"
        ip route add default via "$gateway" 2>/dev/null || true
        info "Default gateway set to $gateway"
    fi

    info "Persistent config: $config_file"
}

# ----------------------------------------------------------------------
# Setup DHCP on NAT adapter (systemd-networkd)
# ----------------------------------------------------------------------
setup_nat_dhcp() {
    local interface="$1"
    info "Setting up NAT adapter $interface with DHCP (systemd-networkd)"
    ip link set dev "$interface" up
    local netdir="/etc/systemd/network"
    mkdir -p "$netdir"
    local config_file="$netdir/10-${interface}-dhcp.network"
    cat > "$config_file" <<EOF
[Match]
Name=$interface

[Network]
DHCP=yes
EOF
    info "DHCP config created: $config_file"
}

# ----------------------------------------------------------------------
# Setup NAT (Masquerade) on Orange Router
# ----------------------------------------------------------------------
setup_nat() {
    local nat_interface="$1"
    info "Setting up NAT (masquerade) on $nat_interface"

    install_pkg "iptables"

    # Enable IP forwarding permanently
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf

    # Flush old rules
    iptables -t nat -F
    iptables -F FORWARD
    iptables -P FORWARD ACCEPT

    # MASQUERADE traffic going out the NAT interface
    iptables -t nat -A POSTROUTING -o "$nat_interface" -j MASQUERADE

    # Save rules persistently
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/iptables.rules
    systemctl enable iptables 2>/dev/null || true
    systemctl restart iptables 2>/dev/null || true

    info "NAT configured on $nat_interface"
}

# ----------------------------------------------------------------------
# Setup WAP bridge (systemd-networkd + bridge-utils)
# ----------------------------------------------------------------------
setup_wap_bridge() {
    local wired=$(get_interface_by_index 1)
    local wireless=$(get_interface_by_index 2)

    # Remove any existing bridge (ignore errors)
    ip link set br0 down 2>/dev/null || true
    ip link del br0 2>/dev/null || true

    # Create a new bridge
    ip link add name br0 type bridge
    ip link set dev "$wired" master br0
    ip link set dev "$wireless" master br0
    ip link set br0 up
    ip link set "$wired" up
    ip link set "$wireless" up

    # Assign management IP to the bridge (gateway = YG Router)
    assign_ip "br0" "192.168.34.20" "24" "192.168.34.1"
}

# ----------------------------------------------------------------------
# Add static routes on Orange Router (persistent)
# ----------------------------------------------------------------------
add_static_routes_orange() {
    info "Adding static routes on Orange Router..."

    # Remove old routes first
    ip route del 192.168.37.0/24 2>/dev/null || true
    ip route del 192.168.34.0/24 2>/dev/null || true
    ip route del 192.168.35.0/24 2>/dev/null || true

    # Add new routes
    ip route add 192.168.37.0/24 via 10.0.1.1 || true
    ip route add 192.168.34.0/24 via 10.0.2.2 || true
    ip route add 192.168.35.0/24 via 10.0.2.2 || true

    # Make persistent
    local netdir="/etc/systemd/network"
    mkdir -p "$netdir"
    local route_file="$netdir/10-static-routes.network"
    cat > "$route_file" <<EOF
[Route]
Destination=192.168.37.0/24
Gateway=10.0.1.1

[Route]
Destination=192.168.34.0/24
Gateway=10.0.2.2

[Route]
Destination=192.168.35.0/24
Gateway=10.0.2.2
EOF
    info "Static routes added and made persistent."
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root

    # Full cleanup
    full_cleanup

    # Enable systemd-networkd
    enable_networkd

    local hostname=$(hostname)
    info "Detected hostname: $hostname"

    case "$hostname" in
        blue-router)
            local nic1=$(get_interface_by_index 1)
            local nic2=$(get_interface_by_index 2)
            # NIC1: link to Orange (with default gateway)
            assign_ip "$nic1" "10.0.1.1" "30" "10.0.1.2"
            # NIC2: Blue server network (no gateway needed)
            assign_ip "$nic2" "192.168.37.1" "24"
            ;;

        orange-router)
            local nic1=$(get_interface_by_index 1)
            local nic2=$(get_interface_by_index 2)
            local nic3=$(get_interface_by_index 3)
            local nic4=$(get_interface_by_index 4)

            # NIC1: link to Blue
            assign_ip "$nic1" "10.0.1.2" "30"
            # NIC2: link to YG
            assign_ip "$nic2" "10.0.2.1" "30"
            # NIC3: Orange device network
            assign_ip "$nic3" "172.36.0.1" "16"

            # NIC4: NAT (DHCP)
            setup_nat_dhcp "$nic4"

            # Enable NAT (masquerade) on the NAT interface
            setup_nat "$nic4"

            # Add static routes to internal networks
            add_static_routes_orange
            ;;

        yg-router)
            local nic1=$(get_interface_by_index 1)
            local nic2=$(get_interface_by_index 2)
            local nic3=$(get_interface_by_index 3)
            # NIC1: link to Orange (with default gateway)
            assign_ip "$nic1" "10.0.2.2" "30" "10.0.2.1"
            # NIC2: Yellow network
            assign_ip "$nic2" "192.168.34.1" "24"
            # NIC3: Green network
            assign_ip "$nic3" "192.168.35.1" "24"
            ;;

        yellow-wap)
            setup_wap_bridge
            ;;

        green-phone-1)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "192.168.35.10" "24" "192.168.35.1"
            ;;

        green-phone-2)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "192.168.35.11" "24" "192.168.35.1"
            ;;

        orange-laptop)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "172.36.0.10" "16" "172.36.0.1"
            ;;

        blue-server)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "192.168.37.100" "24" "192.168.37.1"
            ;;

        yellow-laptop-1)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "192.168.34.30" "24" "192.168.34.1"
            ;;

        yellow-laptop-2)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "192.168.34.31" "24" "192.168.34.1"
            ;;

        *)
            die "Unknown hostname: $hostname. Please set one of: blue-router, orange-router, yg-router, yellow-wap, green-phone-1, green-phone-2, orange-laptop, blue-server, yellow-laptop-1, yellow-laptop-2."
            ;;
    esac

    # Final restart to apply all changes
    systemctl restart systemd-networkd

    info "Configuration complete for $hostname"
    echo
    echo "============================================================="
    echo "Final configuration:"
    echo "============================================================="
    echo
    echo "Current IPv4 addresses:"
    ip -4 addr show | grep -E "inet " | grep -v "127.0.0.1" | sort
    echo
    echo "Default gateway:"
    ip route show default 2>/dev/null || echo "No default route set"
    if [[ "$hostname" == "orange-router" ]]; then
        echo
        echo "Static routes on Orange:"
        ip route show | grep "192.168"
        echo
        echo "NAT (MASQUERADE) rules:"
        iptables -t nat -L POSTROUTING -v -n | grep MASQUERADE || echo "No MASQUERADE rule found"
    fi
    echo
    echo "============================================================="
    echo "All configurations are stored in /etc/systemd/network/"
    echo "Run 'ip addr' and 'ip route' to verify."
}

main "$@"
