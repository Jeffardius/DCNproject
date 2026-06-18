#!/usr/bin/env bash
# set-ip-interfaces.sh – Set static IP using /etc/network/interfaces on Arch
# Run as root.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }
check_root() { [[ $EUID -eq 0 ]] || die "Must be run as root."; }

# ----------------------------------------------------------------------
# Get the last network adapter (excluding lo)
# ----------------------------------------------------------------------
get_last_adapter() {
    local adapters
    mapfile -t adapters < <(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | sort)
    [[ ${#adapters[@]} -gt 0 ]] || die "No network adapters found."
    echo "${adapters[-1]}"
}

# ----------------------------------------------------------------------
# Install ifupdown if not present (needed for /etc/network/interfaces)
# ----------------------------------------------------------------------
install_ifupdown() {
    if pacman -Q ifupdown &>/dev/null; then
        info "ifupdown is already installed."
    else
        info "ifupdown not found. Installing from AUR..."
        # For Arch, ifupdown is in the AUR – we'll use yay or paru if available
        if command -v yay &>/dev/null; then
            yay -S --noconfirm ifupdown
        elif command -v paru &>/dev/null; then
            paru -S --noconfirm ifupdown
        else
            die "No AUR helper found. Please install 'ifupdown' from AUR manually."
        fi
    fi
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root
    install_ifupdown

    INTERFACE=$(get_last_adapter)
    info "Last network adapter: $INTERFACE"

    echo "Choose the network colour:"
    echo "  B) Blue   (192.168.34.1/24)"
    echo "  O) Orange (172.34.0.1/16)"
    echo "  Y) YG     (192.168.34.1/24)"
    read -rp "Enter choice (B/O/Y): " choice
    choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

    case "$choice" in
        b|blue)
            IP="192.168.34.1"
            NETMASK="255.255.255.0"
            PREFIX="24"
            ;;
        o|orange)
            IP="172.34.0.1"
            NETMASK="255.255.0.0"
            PREFIX="16"
            ;;
        y|yg)
            IP="192.168.34.1"
            NETMASK="255.255.255.0"
            PREFIX="24"
            ;;
        *) die "Invalid choice." ;;
    esac

    # ------------------------------------------------------------------
    # Write configuration to /etc/network/interfaces
    # ------------------------------------------------------------------
    INTERFACES_FILE="/etc/network/interfaces"
    # Remove any existing configuration for this interface (if any)
    # We'll simply append a new block; but to avoid duplicates, we can comment out old lines.
    # For simplicity, we'll add a new block at the end.
    cat >> "$INTERFACES_FILE" <<EOF

# Configuration for $INTERFACE (set by script)
auto $INTERFACE
iface $INTERFACE inet static
    address $IP
    netmask $NETMASK
EOF

    info "Added configuration to $INTERFACES_FILE"

    # Apply immediately using ifup (if the interface is down) or ip addr
    if ifquery "$INTERFACE" &>/dev/null; then
        # Interface is defined in /etc/network/interfaces, we can ifdown/ifup
        ifdown "$INTERFACE" 2>/dev/null || true
        ifup "$INTERFACE"
    else
        # Fallback: just set with ip
        ip addr flush dev "$INTERFACE" 2>/dev/null || true
        ip addr add "$IP/$PREFIX" dev "$INTERFACE"
        ip link set dev "$INTERFACE" up
    fi

    info "Done. IP $IP/$NETMASK assigned to $INTERFACE persistently (via /etc/network/interfaces)."
    echo
    ip addr show dev "$INTERFACE"
}

main "$@"
