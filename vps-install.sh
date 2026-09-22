#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# XanMod Kernel Installer
# Ubuntu 24.04 LTS / noble
# Repository:
# https://github.com/awosart/vps-installer
# ============================================================

XANMOD_REPO="http://deb.xanmod.org"
XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_CPU_CHECK="https://dl.xanmod.org/check_x86-64_psabi.sh"

XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"

echo
echo "============================================================"
echo " XanMod Kernel Installer"
echo "============================================================"
echo

# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script as root."
    exit 1
fi

# ------------------------------------------------------------
# OS
# ------------------------------------------------------------

source /etc/os-release

echo "Detected:"
echo "  OS:       ${PRETTY_NAME}"
echo "  Codename: ${VERSION_CODENAME:-unknown}"
echo

if [[ "${ID}" != "ubuntu" ]]; then
    echo "ERROR: Ubuntu is required."
    exit 1
fi

if [[ "${VERSION_CODENAME:-}" != "noble" ]]; then
    echo "ERROR: This installer currently supports Ubuntu 24.04 (noble)."
    exit 1
fi

# ------------------------------------------------------------
# 1. CLEAN OLD XANMOD REPOSITORIES
# ------------------------------------------------------------

echo "[1/6] Cleaning old XanMod repositories..."
echo

# Remove known XanMod repository file
rm -f "${XANMOD_LIST}"

# Clean XanMod entries from all .list/.sources files
if [[ -d /etc/apt/sources.list.d ]]; then
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue

        if grep -q "deb.xanmod.org" "$file" 2>/dev/null; then
            echo "Cleaning: ${file}"
            sed -i '/deb\.xanmod\.org/d' "$file"

            if [[ ! -s "$file" ]]; then
                rm -f "$file"
            fi
        fi
    done < <(
        find /etc/apt/sources.list.d \
            -type f \
            \( -name "*.list" -o -name "*.sources" \)
    )
fi

# Clean main sources.list if necessary
if [[ -f /etc/apt/sources.list ]]; then
    sed -i '/deb\.xanmod\.org/d' /etc/apt/sources.list
fi

echo "Old XanMod repositories removed."

# ------------------------------------------------------------
# 2. INSTALL DEPENDENCIES
# ------------------------------------------------------------

echo
echo "[2/6] Installing dependencies..."
echo

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    wget \
    curl \
    gnupg \
    lsb-release

# ------------------------------------------------------------
# 3. CPU DETECTION
# ------------------------------------------------------------

echo
echo "[3/6] Checking CPU compatibility..."
echo

CPU_CHECK_FILE="$(mktemp)"

cleanup() {
    rm -f "${CPU_CHECK_FILE}"
}

trap cleanup EXIT

CPU_LEVEL="unknown"
XANMOD_PACKAGE="linux-xanmod-x64v2"

if wget -qO "${CPU_CHECK_FILE}" "${XANMOD_CPU_CHECK}"; then

    chmod +x "${CPU_CHECK_FILE}"

    CPU_RESULT="$(bash "${CPU_CHECK_FILE}" 2>&1 || true)"

    echo "CPU compatibility result:"
    echo "${CPU_RESULT}"
    echo

    # XanMod:
    #
    # x86-64-v4 -> x64v3
    # x86-64-v3 -> x64v3
    # x86-64-v2 -> x64v2

    if echo "${CPU_RESULT}" | grep -Eqi \
        'x86-64-v4|x86_64-v4'; then

        CPU_LEVEL="x86-64-v4"
        XANMOD_PACKAGE="linux-xanmod-x64v3"

    elif echo "${CPU_RESULT}" | grep -Eqi \
        'x86-64-v3|x86_64-v3'; then

        CPU_LEVEL="x86-64-v3"
        XANMOD_PACKAGE="linux-xanmod-x64v3"

    elif echo "${CPU_RESULT}" | grep -Eqi \
        'x86-64-v2|x86_64-v2'; then

        CPU_LEVEL="x86-64-v2"
        XANMOD_PACKAGE="linux-xanmod-x64v2"

    else
        echo "WARNING: Could not determine CPU level."
        echo "Falling back to x64v2."
    fi

else
    echo "WARNING: Could not download CPU compatibility checker."
    echo "Falling back to x64v2."
fi

echo "Selected:"
echo "  CPU level: ${CPU_LEVEL}"
echo "  Package:   ${XANMOD_PACKAGE}"

# ------------------------------------------------------------
# 4. ADD OFFICIAL XANMOD REPOSITORY
# ------------------------------------------------------------

echo
echo "[4/6] Installing official XanMod repository..."
echo

mkdir -p /etc/apt/keyrings

wget -qO- "${XANMOD_KEY_URL}" \
    | gpg --dearmor --yes \
    -o "${XANMOD_KEYRING}"

chmod 0644 "${XANMOD_KEYRING}"

cat > "${XANMOD_LIST}" <<EOF
deb [signed-by=${XANMOD_KEYRING}] ${XANMOD_REPO} noble main
EOF

echo "Repository:"
cat "${XANMOD_LIST}"

# ------------------------------------------------------------
# 5. INSTALL KERNEL
# ------------------------------------------------------------

echo
echo "[5/6] Installing XanMod kernel..."
echo

apt-get update

apt-get install -y "${XANMOD_PACKAGE}"

# Update GRUB if available
if command -v update-grub >/dev/null 2>&1; then
    update-grub
fi

# ------------------------------------------------------------
# 6. FINISH
# ------------------------------------------------------------

echo
echo "[6/6] Installation complete."
echo

echo "Installed XanMod packages:"
dpkg -l | grep -E 'linux-(image|headers).*xanmod' || true

echo
echo "Current kernel:"
uname -r

echo
echo "============================================================"
echo " REBOOT REQUIRED"
echo "============================================================"
echo
echo "Run:"
echo
echo "    reboot"
echo
echo "Then verify:"
echo
echo "    uname -r"
echo
echo "Expected:"
echo
echo "    kernel version containing xanmod"
echo
echo "============================================================"
