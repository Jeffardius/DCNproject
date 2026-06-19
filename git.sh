#!/usr/bin/env bash
# install-git-grab.sh – Installs the 'git-grab' shortcut.
# Run as root or with sudo.

set -euo pipefail

# ----------------------------------------------------------------------
# Check root
# ----------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Installing to /usr/local/bin requires root. Please run with sudo."
    exit 1
fi

# ----------------------------------------------------------------------
# Create the git-grab script
# ----------------------------------------------------------------------
TARGET="/usr/local/bin/git-grab"

cat > "$TARGET" <<'EOF'
#!/usr/bin/env bash
# git-grab – Force pull origin/main, discard all local changes,
#           then make every file in the repo executable.
#
# Usage: git-grab  (run inside a Git repository)

set -euo pipefail

# Check if we're inside a Git repo
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "ERROR: Not inside a Git repository."
    exit 1
fi

# Fetch the latest from origin
echo "Fetching origin..."
git fetch origin

# Hard reset to origin/main (adjust branch if needed)
echo "Resetting to origin/main..."
git reset --hard origin/main

# Make everything executable
echo "Making all files executable..."
chmod -R +x *

echo "Done. Your repository is now an exact copy of origin/main,"
echo "and all files are executable."
EOF

# Make it executable
chmod +x "$TARGET"

echo "git-grab has been installed to $TARGET"
echo "You can now run 'git-grab' from any Git repository."
