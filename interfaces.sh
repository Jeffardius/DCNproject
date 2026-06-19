#!/usr/bin/env bash
# auto-network-config.sh – Final version with corrected topology
# Run as root on each VM.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }
check_root() { [[ $EUID -eq 0 ]] || die "Must be run as root."; }

# ----------------------------------------------------------------------
# Install missing package
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
# Enable systemd-networkd
# ----------------------------------------------------------------------
enable_networkd() {
    systemctl enable systemd-networkd 2>/dev/null || true
    systemctl restart systemd-networkd
}

# ----------------------------------------------------------------------
# Get interface by index (sorted alphabetically)
# ----------------------------------------------------------------------
get_interface_by_index() {
    local index="$1"
    local adapters
    mapfile -t adapters < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | sort)
    [[ ${#adapters[@]} -ge "$index" ]] || die "Not enough interfaces for index $index"
    echo "${adapters[$((index-1))]}"
}

# ----------------------------------------------------------------------
# Assign IP + optional gateway
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
}

# ----------------------------------------------------------------------
# Setup WAP bridge
# ----------------------------------------------------------------------
setup_wap_bridge() {
    install_pkg "bridge-utils"
    local wired=$(get_interface_by_index 1)
    local wireless=$(get_interface_by_index 2)

    brctl addbr br0 2>/dev/null || true
    brctl addif br0 "$wired" 2>/dev/null || true
    brctl addif br0 "$wireless" 2>/dev/null || true

    ip link set br0 up
    ip link set "$wired" up
    ip link set "$wireless" up

    assign_ip "br0" "192.168.34.20" "24" "192.168.34.1"
}

# ----------------------------------------------------------------------
# Add static routes on Orange Router
# ----------------------------------------------------------------------
add_static_routes_orange() {
    info "Adding static routes on Orange Router..."
    ip route add 192.168.37.0/24 via 10.0.1.1 2>/dev/null || true
    ip route add 192.168.34.0/24 via 10.0.2.2 2>/dev/null || true
    ip route add 192.168.35.0/24 via 10.0.2.2 2>/dev/null || true

    # Make them persistent by adding to a network config
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
    enable_networkd

    local hostname=$(hostname)
    info "Detected hostname: $hostname"

    case "$hostname" in
        blue-router)
            local nic1=$(get_interface_by_index 1)
            local nic2=$(get_interface_by_index 2)
            assign_ip "$nic1" "10.0.1.1" "30" "10.0.1.2"
            assign_ip "$nic2" "192.168.37.1" "24"
            ;;

        orange-router)
            local nic1=$(get_interface_by_index 1)
            local nic2=$(get_interface_by_index 2)
            local nic3=$(get_interface_by_index 3)
            local nic4=$(get_interface_by_index 4)

            assign_ip "$nic1" "10.0.1.2" "30"
            assign_ip "$nic2" "10.0.2.1" "30"
            assign_ip "$nic3" "172.36.0.1" "16"

            # NAT adapter: DHCP
            ip link set dev "$nic4" up
            dhcpcd "$nic4" 2>/dev/null || true
            info "NAT adapter $nic4 configured via DHCP (internet access)."

            # Add static routes to reach Blue, Yellow, Green
            add_static_routes_orange
            ;;

        yg-router)
            local nic1=$(get_interface_by_index 1)
            local nic2=$(get_interface_by_index 2)
            local nic3=$(get_interface_by_index 3)
            assign_ip "$nic1" "10.0.2.2" "30" "10.0.2.1"
            assign_ip "$nic2" "192.168.34.1" "24"
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
            die "Unknown hostname: $hostname"
            ;;
    esac

    info "Configuration complete for $hostname"
    echo
    echo "Current IPv4 addresses:"
    ip -4 addr show | grep -E "inet " | grep -v "127.0.0.1"
    echo
    echo "Default gateway:"
    ip route show default 2>/dev/null || echo "No default route set"
    echo
    if [[ "$hostname" == "orange-router" ]]; then
        echo "Static routes on Orange:"
        ip route show | grep "192.168"
    fi
}

main "$@"
