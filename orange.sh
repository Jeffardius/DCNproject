#!/usr/bin/env bash
# fix-orange-routes.sh – Permanently fixes static routes on Orange Router.
# Run as root ONCE on the Orange Router.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }
check_root() { [[ $EUID -eq 0 ]] || die "Must be run as root."; }

# ----------------------------------------------------------------------
# Find the NAT interface (the one with DHCP default route)
# ----------------------------------------------------------------------
find_nat_interface() {
    local default_iface
    default_iface=$(ip route show default | awk '{print $5}' | head -n1)
    if [[ -z "$default_iface" ]]; then
        die "No default route found – is DHCP working?"
    fi
    echo "$default_iface"
}

# ----------------------------------------------------------------------
# Wipe all routes EXCEPT the default DHCP route
# ----------------------------------------------------------------------
wipe_and_add_routes() {
    info "Wiping all static routes (keeping DHCP default)..."

    # Remove the specific static routes if they exist (to avoid duplicates)
    ip route del 192.168.37.0/24 2>/dev/null || true
    ip route del 192.168.34.0/24 2>/dev/null || true
    ip route del 192.168.35.0/24 2>/dev/null || true

    # Add the correct static routes
    info "Adding static routes..."
    ip route add 192.168.37.0/24 via 10.0.1.1
    ip route add 192.168.34.0/24 via 10.0.2.2
    ip route add 192.168.35.0/24 via 10.0.2.2

    info "Static routes added:"
    ip route show | grep "192.168"
}

# ----------------------------------------------------------------------
# Create a systemd service to reapply routes at boot
# ----------------------------------------------------------------------
install_persistent_service() {
    local nat_iface="$1"
    info "Creating systemd service to reapply routes at boot..."

    cat > /etc/systemd/system/fix-orange-routes.service <<EOF
[Unit]
Description=Reapply static routes for Blue/YG networks
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip route add 192.168.37.0/24 via 10.0.1.1
ExecStart=/usr/sbin/ip route add 192.168.34.0/24 via 10.0.2.2
ExecStart=/usr/sbin/ip route add 192.168.35.0/24 via 10.0.2.2
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable fix-orange-routes.service
    systemctl start fix-orange-routes.service

    info "Service installed and enabled. Routes will be reapplied at every boot."
}

# ----------------------------------------------------------------------
# Also ensure NAT (MASQUERADE) is set up
# ----------------------------------------------------------------------
setup_nat() {
    local nat_iface="$1"
    info "Setting up NAT (MASQUERADE) on $nat_iface..."

    install_pkg() {
        local pkg="$1"
        if ! pacman -Q "$pkg" &>/dev/null; then
            pacman -S --noconfirm "$pkg" || die "Failed to install $pkg"
        fi
    }
    install_pkg iptables

    # Enable forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf

    # Flush and add MASQUERADE
    iptables -t nat -F
    iptables -F FORWARD
    iptables -P FORWARD ACCEPT
    iptables -t nat -A POSTROUTING -o "$nat_iface" -j MASQUERADE

    # Save rules
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/iptables.rules
    systemctl enable iptables 2>/dev/null || true
    systemctl restart iptables 2>/dev/null || true

    info "NAT configured on $nat_iface."
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root

    local nat_iface
    nat_iface=$(find_nat_interface)
    info "NAT interface detected: $nat_iface"

    wipe_and_add_routes
    install_persistent_service "$nat_iface"
    setup_nat "$nat_iface"

    echo
    echo "============================================================="
    echo "Orange Router routes are now fixed and persistent."
    echo "Current routes:"
    ip route show
    echo
    echo "The service will reapply them after every reboot."
    echo "============================================================="
}

main "$@"
