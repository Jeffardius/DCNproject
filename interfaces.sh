#!/usr/bin/env bash
# auto-network-config.sh – Perfect version with full cleanup.
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
# Get interface by index (in the order they appear from ip link)
# NO SORTING – preserves VirtualBox adapter order.
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

    # 1. Kill any DHCP clients
    pkill dhcpcd 2>/dev/null || true

    # 2. Flush ALL IPs from ALL interfaces (except lo)
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
        ip addr flush dev "$iface" 2>/dev/null || true
        info "Flushed $iface"
    done

    # 3. Remove ALL routes
    ip route flush all 2>/dev/null || true

    # 4. Remove ALL systemd-networkd config files we created
    rm -f /etc/systemd/network/*.network 2>/dev/null || true

    # 5. Remove DHCP leases
    rm -f /var/lib/dhcpcd/*.lease 2>/dev/null || true

    info "Cleanup complete. All previous network configs removed."
}

# ----------------------------------------------------------------------
# Assign IP + optional gateway (with double-check to prevent duplicates)
# ----------------------------------------------------------------------
assign_ip() {
    local interface="$1"
    local ip="$2"
    local prefix="$3"
    local gateway="${4:-}"

    info "Assigning $ip/$prefix to $interface"

    # Remove any existing IP on this interface
    ip addr flush dev "$interface" 2>/dev/null || true

    # Add the new IP
    ip addr add "$ip/$prefix" dev "$interface"
    ip link set dev "$interface" up

    # Create persistent config
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

    # Verify the IP was assigned correctly
    if ! ip addr show "$interface" | grep -q "$ip/$prefix"; then
        die "Failed to assign $ip/$prefix to $interface"
    fi
}

# ----------------------------------------------------------------------
# Setup WAP bridge
# ----------------------------------------------------------------------
setup_wap_bridge() {
    install_pkg "bridge-utils"

    local wired=$(get_interface_by_index 1)
    local wireless=$(get_interface_by_index 2)

    # Remove any existing bridge
    ip link set br0 down 2>/dev/null || true
    brctl delbr br0 2>/dev/null || true

    # Create bridge
    brctl addbr br0
    brctl addif br0 "$wired"
    brctl addif br0 "$wireless"

    ip link set br0 up
    ip link set "$wired" up
    ip link set "$wireless" up

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
    info "Static routes added."
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root

    # COMPLETE CLEANUP FIRST
    full_cleanup

    # Now configure
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

            # NAT adapter (NIC 4): DHCP
            ip link set dev "$nic4" up
            dhcpcd "$nic4" 2>/dev/null || true
            info "NAT adapter $nic4 configured via DHCP."

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
    echo "============================================================="
    echo "Final configuration:"
    echo "============================================================="
    echo
    echo "Current IPv4 addresses:"
    ip -4 addr show | grep -E "inet " | grep -v "127.0.0.1" | sort
    echo
    echo "Default gateway:"
    ip route show default 2>/dev/null || echo "No default route set"
    echo
    if [[ "$hostname" == "orange-router" ]]; then
        echo "Static routes on Orange:"
        ip route show | grep "192.168" || echo "No static routes found"
    fi
    echo
    echo "============================================================="
    echo "All interfaces should now have unique, correct IPs."
    echo "Run 'ip addr' to verify."
}

main "$@"
