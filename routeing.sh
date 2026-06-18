#!/usr/bin/env bash
# arch-ipv4-forward.sh – Enable full IPv4 forwarding using iptables on Arch Linux
# Run as root. Edits existing sysctl files; creates one only if none exist.

set -euo pipefail

# ----------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------
die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

info() {
    echo "INFO: $*"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

# ----------------------------------------------------------------------
# 1. Install iptables if not present
# ----------------------------------------------------------------------
install_iptables() {
    if pacman -Q iptables &>/dev/null; then
        info "iptables is already installed."
    else
        info "iptables not found. Installing via pacman..."
        pacman -S --noconfirm iptables || die "Failed to install iptables."
    fi
}

# ----------------------------------------------------------------------
# 2. Enable IPv4 forwarding persistently by editing an existing sysctl file,
#    or creating a new one if none exists.
# ----------------------------------------------------------------------
enable_ip_forward() {
    local param="net.ipv4.ip_forward"
    local value="1"
    local sysctl_file=""

    # Try to find an existing sysctl configuration file
    if [[ -f /etc/sysctl.conf ]]; then
        sysctl_file="/etc/sysctl.conf"
    else
        # Look for any .conf in /etc/sysctl.d/
        shopt -s nullglob
        local candidates=(/etc/sysctl.d/*.conf)
        if [[ ${#candidates[@]} -gt 0 ]]; then
            # Sort and pick the first one
            IFS=$'\n' sorted=($(sort <<<"${candidates[*]}"))
            sysctl_file="${sorted[0]}"
        fi
    fi

    if [[ -n "$sysctl_file" ]]; then
        info "Found existing sysctl file: $sysctl_file"
        # Check if the parameter is already set (maybe commented out)
        if grep -qE "^\s*#?\s*${param}\s*=" "$sysctl_file"; then
            # Uncomment and set to 1, or change value to 1
            sed -i -E "s/^\s*#?\s*(${param})\s*=\s*.*/\1 = ${value}/" "$sysctl_file"
            info "Updated ${param} = ${value} in $sysctl_file"
        else
            # Append the setting at the end
            echo "${param} = ${value}" >> "$sysctl_file"
            info "Appended ${param} = ${value} to $sysctl_file"
        fi
    else
        # No existing file found – create one
        sysctl_file="/etc/sysctl.d/99-ipv4-forward.conf"
        info "No existing sysctl file found. Creating $sysctl_file"
        echo "${param} = ${value}" > "$sysctl_file"
        info "Created $sysctl_file with ${param} = ${value}"
    fi

    # Apply settings from all sysctl files
    sysctl --system >/dev/null || warn "sysctl --system returned non-zero."

    # Also apply immediately to the running kernel (in case --system didn't catch it)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || warn "Failed to set net.ipv4.ip_forward temporarily."
    info "IPv4 forwarding enabled for the current session and will persist across reboots."
}

# ----------------------------------------------------------------------
# 3. Set iptables FORWARD policy to ACCEPT and flush any restrictive rules
#    (IPv4 only)
# ----------------------------------------------------------------------
configure_iptables() {
    info "Configuring iptables to allow IPv4 forwarding..."
    iptables -P FORWARD ACCEPT || warn "iptables -P FORWARD ACCEPT failed."
    iptables -F FORWARD || warn "iptables -F FORWARD failed."
    info "iptables FORWARD policy set to ACCEPT and existing rules flushed."
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root
    install_iptables
    enable_ip_forward
    configure_iptables

    echo
    echo "============================================================="
    echo "IPv4 forwarding is now enabled (persistently)."
    echo "The iptables FORWARD chain accepts all IPv4 traffic."
    echo "============================================================="
    echo
    echo "Current IPv4 forwarding status:"
    sysctl net.ipv4.ip_forward
    echo
    echo "Check iptables FORWARD policy:"
    iptables -L FORWARD -n -v | head -n 2
}

main "$@"
