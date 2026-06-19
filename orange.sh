#!/usr/bin/env bash
# fix-orange-routes.sh – Permanently fixes static routes on Orange Router.
# Run as root ONCE.

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
# Wipe old static routes and add correct ones
# ----------------------------------------------------------------------
add_routes_now() {
    info "Wiping old static routes..."
    ip route del 192.168.37.0/24 2>/dev/null || true
    ip route del 192.168.34.0/24 2>/dev/null || true
    ip route del 192.168.35.0/24 2>/dev/null || true

    info "Adding static routes..."
    ip route add 192.168.37.0/24 via 10.0.1.1
    ip route add 192.168.34.0/24 via 10.0.2.2
    ip route add 192.168.35.0/24 via 10.0.2.2

    info "Routes added:"
    ip route show | grep "192.168"
}

# ----------------------------------------------------------------------
# Create a script to reapply routes at boot
# ----------------------------------------------------------------------
create_persistent_script() {
    info "Creating /usr/local/bin/add-orange-routes.sh..."
    cat > /usr/local/bin/add-orange-routes.sh <<'EOF'
#!/bin/bash
# Reapply static routes for Orange Router
ip route add 192.168.37.0/24 via 10.0.1.1 2>/dev/null || true
ip route add 192.168.34.0/24 via 10.0.2.2 2>/dev/null || true
ip route add 192.168.35.0/24 via 10.0.2.2 2>/dev/null || true
EOF
    chmod +x /usr/local/bin/add-orange-routes.sh
}

# ----------------------------------------------------------------------
# Create systemd service that runs the script at boot
# ----------------------------------------------------------------------
install_systemd_service() {
    info "Creating systemd service..."
    cat > /etc/systemd/system/add-orange-routes.service <<'EOF'
[Unit]
Description=Add static routes for Orange Router
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/add-orange-routes.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable add-orange-routes.service
    systemctl start add-orange-routes.service
    info "Service enabled and started."
}

# ----------------------------------------------------------------------
# Setup NAT (MASQUERADE) on Orange
# ----------------------------------------------------------------------
setup_nat() {
    local nat_iface="$1"
    info "Setting up NAT (MASQUERADE) on $nat_iface..."

    # Install iptables if missing
    if ! pacman -Q iptables &>/dev/null; then
        pacman -S --noconfirm iptables || die "Failed to install iptables"
    fi

    # Enable forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf

    # Flush and set rules
    iptables -t nat -F
    iptables -F FORWARD
    iptables -P FORWARD ACCEPT
    iptables -t nat -A POSTROUTING -o "$nat_iface" -j MASQUERADE

    # Save rules persistently
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

    add_routes_now
    create_persistent_script
    install_systemd_service
    setup_nat "$nat_iface"

    echo
    echo "============================================================="
    echo "Orange Router is now fixed and persistent."
    echo "Routes and NAT will survive reboots."
    echo "============================================================="
    echo "Current routes:"
    ip route show
}

main "$@"
