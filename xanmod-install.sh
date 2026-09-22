#!/usr/bin/env bash

set -euo pipefail

echo "============================================================"
echo " XanMod Kernel Installer"
echo "============================================================"
echo

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

# ------------------------------------------------------------
# OS check
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: Cannot detect operating system."
    exit 1
fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    echo "ERROR: This installer currently supports Ubuntu only."
    exit 1
fi

if [[ "${VERSION_ID}" != "24.04" ]]; then
    echo "ERROR: This installer is intended for Ubuntu 24.04."
    echo "Detected: Ubuntu ${VERSION_ID}"
    exit 1
fi

CODENAME="${VERSION_CODENAME:-noble}"

echo "Detected:"
echo "  OS:       ${PRETTY_NAME}"
echo "  Codename: ${CODENAME}"
echo

# ------------------------------------------------------------
# CPU compatibility
# ------------------------------------------------------------

echo "[1/6] Checking CPU compatibility..."

CHECK_SCRIPT="/tmp/check_x86-64_psabi.sh"

curl -fsSL \
    https://dl.xanmod.org/check_x86-64_psabi.sh \
    -o "${CHECK_SCRIPT}"

chmod +x "${CHECK_SCRIPT}"

CPU_LEVEL="$("${CHECK_SCRIPT}" 2>/dev/null || true)"

echo
echo "CPU compatibility result:"
echo "${CPU_LEVEL}"
echo

# ------------------------------------------------------------
# Determine x64 level
# ------------------------------------------------------------

if echo "${CPU_LEVEL}" | grep -qi "x86-64-v3"; then
    XANMOD_PACKAGE="linux-xanmod-x64v3"
    echo "Detected x86-64-v3 CPU."
    echo "Installing: ${XANMOD_PACKAGE}"

elif echo "${CPU_LEVEL}" | grep -qi "x86-64-v2"; then
    XANMOD_PACKAGE="linux-xanmod-x64v2"
    echo "Detected x86-64-v2 CPU."
    echo "Installing: ${XANMOD_PACKAGE}"

else
    echo "WARNING: Could not determine CPU level automatically."
    echo
    echo "Falling back to x64v2."
    XANMOD_PACKAGE="linux-xanmod-x64v2"
fi

echo

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

echo "[2/6] Installing dependencies..."

apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release

# ------------------------------------------------------------
# Repository
# ------------------------------------------------------------

echo "[3/6] Configuring XanMod repository..."

mkdir -p /etc/apt/keyrings

wget -qO- https://dl.xanmod.org/archive.key \
    | gpg --dearmor \
    > /etc/apt/keyrings/xanmod-archive-keyring.gpg

chmod 644 /etc/apt/keyrings/xanmod-archive-keyring.gpg

cat > /etc/apt/sources.list.d/xanmod-release.list << EOF
deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${CODENAME} main
EOF

# Remove old/broken XanMod repositories if present
find /etc/apt/sources.list.d -type f \
    ! -name "xanmod-release.list" \
    -exec grep -Il "deb.xanmod.org" {} \; 2>/dev/null \
    | while read -r file; do
        echo "Removing old XanMod repository: ${file}"
        rm -f "${file}"
      done

# ------------------------------------------------------------
# Install
# ------------------------------------------------------------

echo "[4/6] Updating package lists..."

apt-get update

echo
echo "[5/6] Installing ${XANMOD_PACKAGE}..."

apt-get install -y "${XANMOD_PACKAGE}"

# ------------------------------------------------------------
# GRUB
# ------------------------------------------------------------

echo
echo "[6/6] Updating GRUB..."

update-grub

# ------------------------------------------------------------
# Result
# ------------------------------------------------------------

echo
echo "============================================================"
echo " XanMod installation completed"
echo "============================================================"
echo
echo "Installed package:"
dpkg -l | grep "${XANMOD_PACKAGE}" || true

echo
echo "Current kernel:"
uname -r

echo
echo "Installed XanMod kernels:"
dpkg -l | grep xanmod || true

echo
echo "IMPORTANT:"
echo "Reboot the server to start using XanMod:"
echo
echo "    reboot"
echo
echo "After reboot verify with:"
echo
echo "    uname -r"
echo
echo "============================================================"
