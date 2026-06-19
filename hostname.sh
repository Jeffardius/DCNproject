#!/usr/bin/env bash
# set-hostname.sh – Interactive hostname setter for the project.
# Run as root.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
check_root() { [[ $EUID -eq 0 ]] || die "Must be run as root."; }

# ----------------------------------------------------------------------
# Define the 10 hostnames and their display names
# ----------------------------------------------------------------------
declare -A HOSTNAMES=(
    [1]="blue-router|Blue Router"
    [2]="orange-router|Orange Router"
    [3]="yg-router|YG Router"
    [4]="yellow-wap|Yellow WAP"
    [5]="green-phone-1|Green Phone 1"
    [6]="green-phone-2|Green Phone 2"
    [7]="orange-laptop|Orange Laptop"
    [8]="blue-server|Blue Server"
    [9]="yellow-laptop-1|Yellow Laptop 1"
    [10]="yellow-laptop-2|Yellow Laptop 2"
)

# ----------------------------------------------------------------------
# Show menu
# ----------------------------------------------------------------------
show_menu() {
    echo "======================================================"
    echo "  Set Hostname for Network Project"
    echo "======================================================"
    echo "Select a hostname from the list below:"
    for key in $(echo "${!HOSTNAMES[@]}" | tr ' ' '\n' | sort -n); do
        IFS='|' read -r host display <<< "${HOSTNAMES[$key]}"
        echo "  $key) $display ($host)"
    done
    echo "  c) Enter a custom hostname"
    echo "  q) Quit"
    echo
    read -rp "Enter your choice: " choice
}

# ----------------------------------------------------------------------
# Set hostname and update /etc/hosts
# ----------------------------------------------------------------------
set_hostname() {
    local host="$1"
    echo "Setting hostname to: $host"
    hostnamectl set-hostname "$host"

    # Update /etc/hosts: remove old entries for this host, add new ones.
    if grep -q "^127.0.0.1.*$host" /etc/hosts; then
        sed -i "/^127.0.0.1.*$host/d" /etc/hosts
    fi
    if grep -q "^::1.*$host" /etc/hosts; then
        sed -i "/^::1.*$host/d" /etc/hosts
    fi
    echo "127.0.0.1   $host" >> /etc/hosts
    echo "::1         $host" >> /etc/hosts

    echo "Done. Hostname is now: $(hostname)"
    echo "You may need to log out and back in for the prompt to update."
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
main() {
    check_root

    while true; do
        show_menu
        case "$choice" in
            [1-9]|10)
                IFS='|' read -r host display <<< "${HOSTNAMES[$choice]}"
                set_hostname "$host"
                break
                ;;
            c|C)
                read -rp "Enter custom hostname: " custom_host
                if [[ -n "$custom_host" ]]; then
                    set_hostname "$custom_host"
                else
                    echo "No hostname entered. Try again."
                    continue
                fi
                break
                ;;
            q|Q)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo "Invalid choice. Please try again."
                ;;
        esac
    done
}

main "$@"
