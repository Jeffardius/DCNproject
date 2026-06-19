#!/usr/bin/env bash
# install-orange-route-fixer.sh – Permanently fixes routes on Orange Router.
# Run as root ONCE.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }
check_root() { [[ $EUID -eq 0 ]] || die "Must be run as root."; }

# ----------------------------------------------------------------------
# Install the fixer script
# ----------------------------------------------------------------------
install_fixer_script() {
    info "Installing /usr/local/bin/fix-orange-routes.sh..."
    cat > /usr/local/bin/fix-orange-routes.sh <<'EOF'
#!/bin/bash
# Wait for DHCP to get a default route (max 30 seconds)
for i in {1..30}; do
    if ip route show default | grep -q "via"; then
        break
    fi
    sleep 1
done

# Now clean up weird DHCP routes
for dest in 47.71.255.198 64.71.255.198 64.71.255.204 192.168.0.1; do
    ip route del "$dest" 2>/dev/null
done

# Add/replace our static routes
ip route replace 192.168.37.0/24 via 10.0.1.1
ip route replace 192.168.34.0/24 via 10.0.2.2
ip route replace 192.168.35.0/24 via 10.0.2.2

# Ensure NAT is set (idempotent)
nat_iface=$(ip route show default | awk '{print $5}')
if [[ -n "$nat_iface" ]]; then
    iptables -t nat -C POSTROUTING -o "$nat_iface" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$nat_iface" -j MASQUERADE
fi

# Also ensure forwarding is on
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
EOF
    chmod +x /usr/local/bin/fix-orange-routes.sh
    info "Fixer script installed."
}

# ----------------------------------------------------------------------
# Install systemd service (runs after network-online)
# ----------------------------------------------------------------------
install_service() {
    info "Installing systemd service..."
    cat > /etc/systemd/system/fix-orange-routes.service <<'EOF'
[Unit]
Description=Fix Orange Router routes after DHCP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-orange-routes.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable fix-orange-routes.service
    systemctl start fix-orange-routes.service
    info "Service enabled and started."
}

# ----------------------------------------------------------------------
# Also set up NAT and forwarding now (if not already)
# ----------------------------------------------------------------------
setup_nat_now() {
    info "Setting up NAT and forwarding now..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf

    if ! pacman -Q iptables &>/dev/null; then
        pacman -S --noconfirm iptables
    fi

    nat_iface=$(ip route show default | awk '{print $5}')
    if [[ -n "$nat_iface" ]]; then
        iptables -t nat -C POSTROUTING -o "$nat_iface" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -o "$nat_iface" -j MASQUERADE
        iptables -F FORWARD
        iptables -P FORWARD ACCEPT
        iptables-save > /etc/iptables/iptables.rules
        systemctl enable iptables 2>/dev/null || true
        systemctl restart iptables 2>/dev/null || true
        info "NAT configured on $nat_iface."
    else
        warn "No default route found – NAT skipped."
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root

    install_fixer_script
    install_service
    setup_nat_now

    echo
    echo "============================================================="
    echo "✅ Orange Router route fixer installed."
    echo "It will run at boot and reapply routes after DHCP."
    echo "You can test by rebooting."
    echo "============================================================="
    echo "Current routes (after fix):"
    /usr/local/bin/fix-orange-routes.sh
    ip route show
}

main "$@"
