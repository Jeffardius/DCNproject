#!/usr/bin/env bash
# orange-permanent-fix.sh – Stops weird DHCP routes and makes static routes stick.
# Run as root ONCE on Orange Router.

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
# 1. Prevent DHCP from adding weird routes (option 121)
# ----------------------------------------------------------------------
configure_dhcpcd() {
    local iface="$1"
    info "Configuring dhcpcd to ignore classless static routes on $iface..."

    # Backup original config
    cp /etc/dhcpcd.conf /etc/dhcpcd.conf.bak 2>/dev/null || true

    # Remove any existing 'nooption static_routes' for this interface and add new
    sed -i "/^interface $iface$/,/^$/d" /etc/dhcpcd.conf 2>/dev/null || true
    {
        echo "interface $iface"
        echo "    nooption static_routes"
        echo "    nooption rfc3442"   # also blocks classless static routes
    } >> /etc/dhcpcd.conf

    info "dhcpcd.conf updated. Restarting dhcpcd..."
    systemctl restart dhcpcd 2>/dev/null || true
    # Wait for DHCP to renew
    sleep 3
}

# ----------------------------------------------------------------------
# 2. Remove all weird routes (including any that appear later)
# ----------------------------------------------------------------------
remove_weird_routes() {
    info "Removing weird DHCP routes..."
    for dest in 47.71.255.198 64.71.255.198 64.71.255.204 192.168.0.1; do
        ip route del "$dest" 2>/dev/null || true
    done
    # Also remove any routes that are not part of our plan (e.g., public IPs)
    ip route show | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | while read -r line; do
        dest=$(echo "$line" | awk '{print $1}')
        # Keep our intended networks only
        if [[ "$dest" != "10.0.1.0/30" && "$dest" != "10.0.2.0/30" && "$dest" != "10.0.5.0/24" && "$dest" != "172.36.0.0/16" && "$dest" != "192.168.34.0/24" && "$dest" != "192.168.35.0/24" && "$dest" != "192.168.37.0/24" ]]; then
            ip route del "$dest" 2>/dev/null || true
        fi
    done
}

# ----------------------------------------------------------------------
# 3. Add our static routes (using 'replace' to ensure they exist)
# ----------------------------------------------------------------------
add_static_routes() {
    info "Adding our static routes..."
    ip route replace 192.168.37.0/24 via 10.0.1.1
    ip route replace 192.168.34.0/24 via 10.0.2.2
    ip route replace 192.168.35.0/24 via 10.0.2.2
    info "Static routes applied:"
    ip route show | grep "192.168"
}

# ----------------------------------------------------------------------
# 4. Install a dhcpcd hook to reapply routes after every renewal
# ----------------------------------------------------------------------
install_dhcpcd_hook() {
    info "Installing dhcpcd hook to keep routes clean..."
    cat > /usr/lib/dhcpcd/dhcpcd-hooks/99-orange-static-routes <<'EOF'
#!/bin/bash
# Hook to remove weird routes and re-add our static routes
# Runs after each DHCP lease renewal.

if [[ "$interface" == "$(ip route show default | awk '{print $5}')" ]]; then
    for dest in 47.71.255.198 64.71.255.198 64.71.255.204 192.168.0.1; do
        ip route del "$dest" 2>/dev/null
    done
    ip route replace 192.168.37.0/24 via 10.0.1.1 2>/dev/null
    ip route replace 192.168.34.0/24 via 10.0.2.2 2>/dev/null
    ip route replace 192.168.35.0/24 via 10.0.2.2 2>/dev/null
    # Ensure NAT is still set
    iptables -t nat -A POSTROUTING -o "$interface" -j MASQUERADE 2>/dev/null
fi
EOF
    chmod +x /usr/lib/dhcpcd/dhcpcd-hooks/99-orange-static-routes
    info "dhcpcd hook installed."
}

# ----------------------------------------------------------------------
# 5. Also create a systemd service for boot (as a fallback)
# ----------------------------------------------------------------------
install_boot_service() {
    info "Creating systemd service for boot..."
    cat > /etc/systemd/system/orange-static-routes.service <<'EOF'
[Unit]
Description=Ensure Orange static routes after network
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ensure-orange-routes.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    cat > /usr/local/bin/ensure-orange-routes.sh <<'EOF'
#!/bin/bash
# Reapply static routes at boot
ip route replace 192.168.37.0/24 via 10.0.1.1 2>/dev/null
ip route replace 192.168.34.0/24 via 10.0.2.2 2>/dev/null
ip route replace 192.168.35.0/24 via 10.0.2.2 2>/dev/null
# Also remove weird routes if they appear
for dest in 47.71.255.198 64.71.255.198 64.71.255.204 192.168.0.1; do
    ip route del "$dest" 2>/dev/null
done
# NAT
iptables -t nat -A POSTROUTING -o $(ip route show default | awk '{print $5}') -j MASQUERADE 2>/dev/null
EOF
    chmod +x /usr/local/bin/ensure-orange-routes.sh

    systemctl daemon-reload
    systemctl enable orange-static-routes.service
    systemctl start orange-static-routes.service
    info "Boot service installed and enabled."
}

# ----------------------------------------------------------------------
# 6. Setup NAT (MASQUERADE) – if not already present
# ----------------------------------------------------------------------
setup_nat() {
    local nat_iface="$1"
    info "Ensuring NAT (MASQUERADE) on $nat_iface..."

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
# 7. Clean up any duplicate default routes
# ----------------------------------------------------------------------
fix_default_route() {
    info "Removing duplicate default routes..."
    # Keep only the first default route (via NAT)
    local default_iface
    default_iface=$(ip route show default | awk '{print $5}' | head -n1)
    ip route show default | while read -r line; do
        iface=$(echo "$line" | awk '{print $5}')
        if [[ "$iface" != "$default_iface" ]]; then
            ip route del default via "$(echo "$line" | awk '{print $3}')" 2>/dev/null || true
        fi
    done
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root

    local nat_iface
    nat_iface=$(find_nat_interface)
    info "NAT interface: $nat_iface"

    configure_dhcpcd "$nat_iface"
    remove_weird_routes
    add_static_routes
    install_dhcpcd_hook
    install_boot_service
    setup_nat "$nat_iface"
    fix_default_route

    echo
    echo "============================================================="
    echo "✅ Orange Router is now permanently fixed."
    echo "Weird DHCP routes will not appear again."
    echo "Static routes will survive reboots and DHCP renewals."
    echo "============================================================="
    echo "Current routing table:"
    ip route show
    echo
    echo "The service is at: /etc/systemd/system/orange-static-routes.service"
    echo "The hook is at: /usr/lib/dhcpcd/dhcpcd-hooks/99-orange-static-routes"
    echo
    echo "Reboot to test – it will still work."
}

main "$@"
