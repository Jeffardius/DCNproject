#!/usr/bin/env bash
# orange-router-final.sh – The final, clean solution.
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
# Clean up weird routes (from DHCP classless static routes)
# ----------------------------------------------------------------------
clean_weird_routes() {
    info "Removing weird DHCP routes..."
    for dest in 47.71.255.198 64.71.255.198 64.71.255.204 192.168.0.1; do
        if ip route del "$dest" 2>/dev/null; then
            info "Removed $dest"
        fi
    done
}

# ----------------------------------------------------------------------
# Add/Replace static routes
# ----------------------------------------------------------------------
add_routes() {
    info "Adding/replacing static routes..."
    # Use 'replace' to ensure only one entry
    ip route replace 192.168.37.0/24 via 10.0.1.1
    ip route replace 192.168.34.0/24 via 10.0.2.2
    ip route replace 192.168.35.0/24 via 10.0.2.2

    info "Routes added:"
    ip route show | grep "192.168"
}

# ----------------------------------------------------------------------
# Create boot script and systemd service (fast start)
# ----------------------------------------------------------------------
install_service() {
    info "Creating /usr/local/bin/clean-orange-routes.sh..."
    cat > /usr/local/bin/clean-orange-routes.sh <<'EOF'
#!/bin/bash
# Cleanup weird routes and add static ones
for dest in 47.71.255.198 64.71.255.198 64.71.255.204 192.168.0.1; do
    ip route del "$dest" 2>/dev/null
done
ip route replace 192.168.37.0/24 via 10.0.1.1
ip route replace 192.168.34.0/24 via 10.0.2.2
ip route replace 192.168.35.0/24 via 10.0.2.2
# Also ensure NAT is set
iptables -t nat -A POSTROUTING -o $(ip route show default | awk '{print $5}') -j MASQUERADE 2>/dev/null || true
EOF
    chmod +x /usr/local/bin/clean-orange-routes.sh

    info "Creating systemd service (fast network start)..."
    cat > /etc/systemd/system/clean-orange-routes.service <<'EOF'
[Unit]
Description=Clean and add static routes for Orange Router
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/clean-orange-routes.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable clean-orange-routes.service
    systemctl start clean-orange-routes.service
    info "Service installed and started."
}

# ----------------------------------------------------------------------
# Setup NAT (MASQUERADE)
# ----------------------------------------------------------------------
setup_nat() {
    local nat_iface="$1"
    info "Setting up NAT on $nat_iface..."

    pacman -Q iptables &>/dev/null || pacman -S --noconfirm iptables

    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf

    iptables -t nat -F
    iptables -F FORWARD
    iptables -P FORWARD ACCEPT
    iptables -t nat -A POSTROUTING -o "$nat_iface" -j MASQUERADE

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/iptables.rules
    systemctl enable iptables 2>/dev/null || true
    systemctl restart iptables 2>/dev/null || true

    info "NAT configured."
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root

    local nat_iface
    nat_iface=$(find_nat_interface)
    info "NAT interface: $nat_iface"

    clean_weird_routes
    add_routes
    install_service
    setup_nat "$nat_iface"

    echo
    echo "============================================================="
    echo "✅ Orange Router is now fully clean and persistent."
    echo "Weird routes removed, static routes added, NAT set."
    echo "Service will reapply at boot (fast start)."
    echo "============================================================="
    echo "Final routing table:"
    ip route show
}

main "$@"
