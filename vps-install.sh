#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# XanMod Kernel Installer for Ubuntu 24.04+
# Repository: https://github.com/awosart/vps-installer
# ============================================================

readonly XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly XANMOD_REPO="http://deb.xanmod.org"
readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"
readonly CPU_CHECK_URL="https://dl.xanmod.org/check_x86-64_psabi.sh"

log() {
    echo
    echo "============================================================"
    echo " $1"
    echo "============================================================"
    echo
}

die() {
    echo
    echo "ERROR: $1"
    echo
    exit 1
}

trap 'echo; echo "ERROR: installer failed at line $LINENO"; exit 1' ERR

# ------------------------------------------------------------
# ROOT
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root."
fi

# ------------------------------------------------------------
# OS DETECTION
# ------------------------------------------------------------

source /etc/os-release

OS_NAME="${PRETTY_NAME:-unknown}"
OS_ID="${ID:-unknown}"
CODENAME="${VERSION_CODENAME:-}"

log "XanMod Kernel Installer"

echo "Detected:"
echo "  OS:       ${OS_NAME}"
echo "  Codename: ${CODENAME}"
echo

if [[ "${OS_ID}" != "ubuntu" ]]; then
    die "This installer supports Ubuntu only."
fi

if [[ "${CODENAME}" != "noble" ]]; then
    die "This installer currently targets Ubuntu 24.04 (noble)."
fi

# ------------------------------------------------------------
# 1. CLEAN OLD XANMOD REPOSITORIES
# ------------------------------------------------------------

echo "[1/6] Cleaning old XanMod repositories..."
echo

# Remove known XanMod list
rm -f "${XANMOD_LIST}"

# Remove any XanMod repository lines from other .list files
if [[ -d /etc/apt/sources.list.d ]]; then
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue

        if grep -q "deb.xanmod.org" "$file" 2>/dev/null; then
            echo "Removing old XanMod entries from: $file"

            sed -i '/deb\.xanmod\.org/d' "$file"

            # Remove empty files
            if [[ ! -s "$file" ]]; then
                rm -f "$file"
            fi
        fi
    done < <(find /etc/apt/sources.list.d -type f \( -name "*.list" -o -name "*.sources" \))
fi

# Also clean old XanMod entries from the main sources.list
if [[ -f /etc/apt/sources.list ]]; then
    if grep -q "deb.xanmod.org" /etc/apt/sources.list 2>/dev/null; then
        echo "Removing old XanMod entries from /etc/apt/sources.list"
        sed -i '/deb\.xanmod\.org/d' /etc/apt/sources.list
    fi
fi

echo
echo "Old XanMod repositories cleaned."

# ------------------------------------------------------------
# 2. DEPENDENCIES
# ------------------------------------------------------------

echo
echo "[2/6] Installing dependencies..."
echo

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https

# ------------------------------------------------------------
# 3. CPU COMPATIBILITY
# ------------------------------------------------------------

echo
echo "[3/6] Checking CPU compatibility..."
echo

CPU_CHECK="$(mktemp)"

cleanup() {
    rm -f "${CPU_CHECK}"
}

trap cleanup EXIT

if ! wget -qO "${CPU_CHECK}" "${CPU_CHECK_URL}"; then
    echo "WARNING: Could not download XanMod CPU checker."
    echo "Falling back to x64v2."
    XANMOD_PACKAGE="linux-xanmod-x64v2"
else
    chmod +x "${CPU_CHECK}"

    CPU_RESULT="$(
        bash "${CPU_CHECK}" 2>&1 || true
    )"

    echo "CPU compatibility result:"
    echo "${CPU_RESULT}"
    echo

    # XanMod supports:
    # v2 -> x64v2
    # v3 -> x64v3
    # v4 -> x64v3 (v4 has no kernel benefit)

    if echo "${CPU_RESULT}" | grep -Eqi 'x86-64-v4|x86_64-v4'; then
        CPU_LEVEL="x86-64-v4"
        XANMOD_PACKAGE="linux-xanmod-x64v3"

    elif echo "${CPU_RESULT}" | grep -Eqi 'x86-64-v3|x86_64-v3'; then
        CPU_LEVEL="x86-64-v3"
        XANMOD_PACKAGE="linux-xanmod-x64v3"

    elif echo "${CPU_RESULT}" | grep -Eqi 'x86-64-v2|x86_64-v2'; then
        CPU_LEVEL="x86-64-v2"
        XANMOD_PACKAGE="linux-xanmod-x64v2"

    else
        CPU_LEVEL="unknown"
        XANMOD_PACKAGE="linux-xanmod-x64v2"

        echo "WARNING: Could not determine CPU level."
        echo "Falling back to x64v2."
    fi
fi

echo
echo "Selected:"
echo "  CPU level: ${CPU_LEVEL:-unknown}"
echo "  Package:   ${XANMOD_PACKAGE}"
echo

# ------------------------------------------------------------
# 4. INSTALL OFFICIAL XANMOD REPOSITORY
# ------------------------------------------------------------

echo "[4/6] Installing official XanMod repository..."
echo

mkdir -p /etc/apt/keyrings

wget -qO- "${XANMOD_KEY_URL}" \
    | gpg --dearmor --yes -o "${XANMOD_KEYRING}"

chmod 0644 "${XANMOD_KEYRING}"

cat > "${XANMOD_LIST}" <<EOF
deb [signed-by=${XANMOD_KEYRING}] ${XANMOD_REPO} ${CODENAME} main
EOF

echo "Repository:"
cat "${XANMOD_LIST}"
echo

# ------------------------------------------------------------
# 5. INSTALL XANMOD
# ------------------------------------------------------------

echo "[5/6] Installing XanMod kernel..."
echo

apt-get update

apt-get install -y "${XANMOD_PACKAGE}"

# Make sure GRUB configuration is current
if command -v update-grub >/dev/null 2>&1; then
    update-grub
fi

# ------------------------------------------------------------
# 6. RESULT
# ------------------------------------------------------------

echo
echo "[6/6] Installation complete."
echo

echo "Installed XanMod packages:"
dpkg -l | grep xanmod || true

echo
echo "Current kernel:"
uname -r

echo
echo "XanMod kernels available:"
dpkg -l | grep -E 'linux-(image|headers).*xanmod' || true

echo
echo "============================================================"
echo " REBOOT REQUIRED"
echo "============================================================"
echo
echo "Run:"
echo
echo "  reboot"
echo
echo "After reboot verify:"
echo
echo "  uname -r"
echo
echo "Expected output contains:"
echo
echo "  xanmod"
echo
echo "============================================================"
