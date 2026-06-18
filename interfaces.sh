#!/usr/bin/env bash
# auto-network-config.sh – Auto‑configure IPs, gateways, and WAP bridging.
# Run as root on each VM. Hostname determines the role.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }
check_root() { [[ $EUID -eq 0 ]] || die "Must be run as root."; }

# ----------------------------------------------------------------------
# Install a package if missing (uses pacman)
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
# Enable and start systemd-networkd (for persistence)
# ----------------------------------------------------------------------
enable_networkd() {
    systemctl enable systemd-networkd 2>/dev/null || true
    systemctl restart systemd-networkd
}

# ----------------------------------------------------------------------
# Get interface by index (1st, 2nd, 3rd NIC) – sorted alphabetically
# ----------------------------------------------------------------------
get_interface_by_index() {
    local index="$1"
    local adapters
    mapfile -t adapters < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | sort)
    [[ ${#adapters[@]} -ge "$index" ]] || die "Not enough interfaces for index $index"
    echo "${adapters[$((index-1))]}"
}

# ----------------------------------------------------------------------
# Assign IP, netmask, and optional default gateway (immediate + persistent)
# ----------------------------------------------------------------------
assign_ip() {
    local interface="$1"
    local ip="$2"
    local prefix="$3"
    local gateway="${4:-}"   # optional

    info "Assigning $ip/$prefix to $interface"
    ip addr flush dev "$interface" 2>/dev/null || true
    ip addr add "$ip/$prefix" dev "$interface"
    ip link set dev "$interface" up

    # Persistent config via systemd-networkd
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
        # Set default route immediately
        ip route add default via "$gateway" 2>/dev/null || true
        info "Default gateway set to $gateway"
    fi

    info "Persistent config: $config_file"
}

# ----------------------------------------------------------------------
# Setup WAP bridging (install bridge-utils, create br0, assign IP with gateway)
# ----------------------------------------------------------------------
setup_wap_bridge() {
    install_pkg "bridge-utils"

    local wired=$(get_interface_by_index 1)
    local wireless=$(get_interface_by_index 2)

    # Create bridge and add interfaces
    brctl addbr br0 2>/dev/null || true
    brctl addif br0 "$wired" 2>/dev/null || true
    brctl addif br0 "$wireless" 2>/dev/null || true

    # Bring up all interfaces
    ip link set br0 up
    ip link set "$wired" up
    ip link set "$wireless" up

    # Assign management IP to the bridge (with gateway = Y/G router)
    assign_ip "br0" "192.168.34.20" "24" "192.168.34.1"

    info "WAP bridge configured: br0 (192.168.34.20/24) with gateway 192.168.34.1"
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
            assign_ip "$nic1" "10.0.1.1" "30" "10.0.1.2"   # gateway = Orange router
            assign_ip "$nic2" "192.168.34.1" "24"          # no gateway (it's the gateway itself)
            ;;

        orange-router)
            local nic1=$(get_interface_by_index 1)
            local nic2=$(get_interface_by_index 2)
            local nic3=$(get_interface_by_index 3)
            assign_ip "$nic1" "10.0.1.2" "30"              # no default gateway unless external internet
            assign_ip "$nic2" "10.0.2.1" "30"
            assign_ip "$nic3" "172.34.0.1" "16"
            ;;

        yg-router)
            local nic1=$(get_interface_by_index 1)
            local nic2=$(get_interface_by_index 2)
            assign_ip "$nic1" "10.0.2.2" "30" "10.0.2.1"   # gateway = Orange router
            assign_ip "$nic2" "192.168.34.1" "24"          # no gateway
            ;;

        yellow-wap)
            setup_wap_bridge   # handles everything (installs bridge-utils, creates bridge, sets IP/gateway)
            ;;

        green-phone-1)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "192.168.34.10" "24" "192.168.34.1"
            ;;

        green-phone-2)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "192.168.34.11" "24" "192.168.34.1"
            ;;

        orange-laptop)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "172.34.0.10" "16" "172.34.0.1"
            ;;

        blue-server)
            local nic1=$(get_interface_by_index 1)
            assign_ip "$nic1" "192.168.34.100" "24" "192.168.34.1"
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

    # Enable IP forwarding on routers? This script doesn't do that; use your separate forwarding script.
    info "Configuration complete for $hostname"
    echo
    echo "Current IPv4 addresses and routes:"
    ip -4 addr show | grep -E "inet " | grep -v "127.0.0.1"
    echo
    echo "Default gateway:"
    ip route show default 2>/dev/null || echo "No default route set"
}

main "$@"
