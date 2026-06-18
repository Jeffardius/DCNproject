#!/usr/bin/env bash
# set-ip-systemd-networkd.sh – Persistent IP using systemd-networkd on Arch
# Run as root.

set -euo pipefail

die() {
    echo "ERROR: $*" >&2
    exit 1
}
info() {
    echo "INFO: $*"
}
check_root() {
    [[ $EUID -eq 0 ]] || die "Must be run as root."
}

# ----------------------------------------------------------------------
# Find the last network adapter (excluding loopback)
# ----------------------------------------------------------------------
get_last_adapter() {
    local adapters
    mapfile -t adapters < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | sort)
    [[ ${#adapters[@]} -gt 0 ]] || die "No network adapters found (excluding lo)."
    echo "${adapters[-1]}"
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root

    INTERFACE=$(get_last_adapter)
    info "Last network adapter: $INTERFACE"

    # Colour selection
    echo "Choose the network colour:"
    echo "  B) Blue   – 192.168.34.1/24"
    echo "  O) Orange – 172.34.0.1/16"
    echo "  Y) YG     – 192.168.34.1/24"
    read -rp "Enter choice (B/O/Y): " choice
    choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

    case "$choice" in
        b|blue)
            IP="192.168.34.1"
            PREFIX="24"
            ;;
        o|orange)
            IP="172.34.0.1"
            PREFIX="16"
            ;;
        y|yg)
            IP="192.168.34.1"
            PREFIX="24"
            ;;
        *) die "Invalid choice. Use B, O, or Y." ;;
    esac

    # ------------------------------------------------------------------
    # Create systemd-networkd configuration file
    # ------------------------------------------------------------------
    NETDIR="/etc/systemd/network"
    mkdir -p "$NETDIR"
    CONFIG_FILE="$NETDIR/20-${INTERFACE}.network"

    info "Creating persistent config: $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<EOF
[Match]
Name=$INTERFACE

[Network]
Address=$IP/$PREFIX
# DNS=8.8.8.8          # Uncomment if you need DNS
# Gateway=...          # Uncomment if you need a default gateway
EOF

    # ------------------------------------------------------------------
    # Enable and restart systemd-networkd
    # ------------------------------------------------------------------
    systemctl enable systemd-networkd 2>/dev/null || true
    systemctl restart systemd-networkd

    # Also apply the IP immediately (so you don't need to reboot)
    ip addr flush dev "$INTERFACE" 2>/dev/null || true
    ip addr add "$IP/$PREFIX" dev "$INTERFACE"
    ip link set dev "$INTERFACE" up

    info "Done. IP $IP/$PREFIX assigned to $INTERFACE persistently."
    echo
    echo "Current status:"
    ip addr show dev "$INTERFACE"
}

main "$@"
