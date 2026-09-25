#!/usr/bin/env bash
# ============================================================
# XanMod Kernel Installer
# 1) официальный репозиторий deb.xanmod.org
# 2) если он заблокирован (403 на IP AWS и др.) — зеркало в GitHub Releases
#    (наполняется workflow .github/workflows/xanmod-mirror.yml)
# 3) затем SourceForge
#
# Env:
#   XANMOD_BRANCH=main|lts   ветка (по умолчанию main)
#   XANMOD_SOURCE=auto|repo|github|sourceforge
# https://github.com/awosart/vps-installer
# ============================================================

set -uo pipefail

XANMOD_BRANCH="${XANMOD_BRANCH:-main}"
XANMOD_SOURCE="${XANMOD_SOURCE:-auto}"

KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
LIST="/etc/apt/sources.list.d/xanmod-release.list"
KEY_FPR="D38D7D1DA1349567ADED882D86F7D09EE734E623"
KEY_URL="https://dl.xanmod.org/archive.key"
KEYSERVER_URL="https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${KEY_FPR}"
SF_RSS="https://sourceforge.net/projects/xanmod/rss?path=/releases/${XANMOD_BRANCH}&limit=500"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
BBR_SYSCTL="/etc/sysctl.d/99-bbr.conf"
GH_MIRROR="https://github.com/awosart/vps-installer/releases/latest/download"

WORK="$(mktemp -d /tmp/xanmod.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo "============================================================"
echo " XanMod Kernel Installer"
echo "============================================================"

# ------------------------------------------------------------
# Checks
# ------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run as root."
[[ "$(uname -m)" == "x86_64" ]] || die "XanMod is x86_64 only (this is $(uname -m))."

# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == "ubuntu" || "$ID" == "debian" ]] || die "Ubuntu/Debian only."
CODENAME="${VERSION_CODENAME:-}"
[[ -n "$CODENAME" ]] || die "Cannot detect codename."

info "OS: ${PRETTY_NAME} (${CODENAME}), kernel: $(uname -r)"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get install -y -q ca-certificates curl wget gnupg >/dev/null || die "Failed to install dependencies."

# ------------------------------------------------------------
# CPU level (локально, без dl.xanmod.org)
# ------------------------------------------------------------

FLAGS="$(grep -m1 '^flags' /proc/cpuinfo)"
has() { [[ " $FLAGS " == *" $1 "* ]]; }

if has avx2 && has bmi1 && has bmi2 && has fma && has movbe && has f16c; then
    LEVEL="x64v3"
elif has sse4_2 && has popcnt && has ssse3 && has cx16; then
    LEVEL="x64v2"
else
    LEVEL="x64v1"
fi
ok "CPU level: ${LEVEL}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

fetch() {   # url out
    rm -f "$2"
    wget -q -T 30 -t 2 -O "$2" "$1" 2>/dev/null && [[ -s "$2" ]] && return 0
    curl -fsSL --retry 2 --connect-timeout 20 -A "$UA" -o "$2" "$1" 2>/dev/null && [[ -s "$2" ]] && return 0
    rm -f "$2"
    return 1
}

repo_reachable() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 \
        "http://deb.xanmod.org/dists/${CODENAME}/Release")"
    [[ "$code" == "200" ]]
}

clean_repo() {
    rm -f "$LIST"
    find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.list' \
        -exec sed -i '/deb\.xanmod\.org/d' {} + 2>/dev/null || true
}

# Ubuntu грузит ядро с наибольшей версией. Если XanMod старше по номеру,
# чем штатное (например, 6.x против 7.0-aws), явно делаем его ядром по умолчанию.
set_default_kernel() {
    local kver="$1" newest cfg="/boot/grub/grub.cfg" submenu entry

    newest="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1)"
    if [[ "$newest" == "$kver" ]]; then
        ok "XanMod ${kver} is the newest kernel — it will boot by default."
        return 0
    fi

    warn "Newest kernel is ${newest}, XanMod is ${kver}: setting XanMod as GRUB default."

    submenu="$(grep -m1 -oP "^submenu '\K[^']+" "$cfg")"
    entry="$(grep -oP "^\s*menuentry '\K[^']*${kver//./\\.}[^']*" "$cfg" | grep -v -i recovery | head -n1)"

    if [[ -z "$submenu" || -z "$entry" ]]; then
        warn "Could not find GRUB entry for ${kver}. Default kernel NOT changed."
        return 1
    fi

    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    update-grub >/dev/null 2>&1
    grub-set-default "${submenu}>${entry}"
    ok "GRUB default: $(grub-editenv list | grep saved_entry)"
}

finish() {
    command -v update-grub >/dev/null 2>&1 && update-grub

    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$BBR_SYSCTL"
    sysctl --system >/dev/null 2>&1 || true

    echo
    echo "Installed XanMod packages:"
    dpkg -l | awk '/^ii  linux-(image|headers)-.*xanmod/ { print "  " $2 "  " $3 }'

    local kver
    kver="$(dpkg -l | awk '/^ii  linux-image-.*xanmod/ { sub(/^linux-image-/, "", $2); print $2 }' | sort -V | tail -n1)"
    echo
    if [[ -n "$kver" && -f "/boot/vmlinuz-${kver}" && -f "/boot/initrd.img-${kver}" ]]; then
        ok "Kernel and initrd present: /boot/vmlinuz-${kver}"
    else
        die "Kernel or initrd for '${kver}' not found in /boot — DO NOT reboot, check the output above."
    fi

    set_default_kernel "$kver"

    echo
    echo "============================================================"
    echo " DONE. Before reboot on AWS/Lightsail: take a SNAPSHOT."
    echo " Then: reboot"
    echo " After reboot: uname -r   (contains xanmod)"
    echo "               sysctl net.ipv4.tcp_congestion_control   (bbr)"
    echo "============================================================"
}

# ------------------------------------------------------------
# 1. Official repository
# ------------------------------------------------------------

install_from_repo() {
    local pkg="linux-xanmod-${LEVEL}" raw="${WORK}/xanmod.key" fpr
    [[ "$LEVEL" == "x64v1" ]] && pkg="linux-xanmod-lts-x64v1"

    info "Trying official repository deb.xanmod.org..."

    install -d -m 0755 /etc/apt/keyrings
    if ! fetch "$KEY_URL" "$raw"; then
        warn "dl.xanmod.org blocked, taking key from keyserver.ubuntu.com"
        fetch "$KEYSERVER_URL" "$raw" || return 1
    fi
    gpg --dearmor --yes -o "$KEYRING" "$raw" 2>/dev/null || cp -f "$raw" "$KEYRING"
    chmod 0644 "$KEYRING"

    fpr="$(gpg --show-keys --with-colons "$KEYRING" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')"
    [[ "$fpr" == "$KEY_FPR" ]] || { warn "Key fingerprint mismatch: ${fpr:-none}"; rm -f "$KEYRING"; return 1; }

    clean_repo
    echo "deb [signed-by=${KEYRING}] http://deb.xanmod.org ${CODENAME} main" > "$LIST"

    if ! apt-get update -q; then
        clean_repo; apt-get update -q >/dev/null 2>&1; return 1
    fi
    if ! apt-cache policy "$pkg" | grep -q 'Candidate: [0-9]'; then
        warn "${pkg} not available for ${CODENAME}"
        clean_repo; apt-get update -q >/dev/null 2>&1; return 1
    fi

    apt-get install -y -q "$pkg"
}

# ------------------------------------------------------------
# 2. GitHub Releases mirror
# ------------------------------------------------------------

install_from_github() {
    local name="xanmod-${XANMOD_BRANCH}-${LEVEL}"

    [[ "$LEVEL" == "x64v1" ]] && { warn "x64v1 is not mirrored on GitHub."; return 1; }

    info "Downloading from GitHub mirror (${name})..."

    fetch "${GH_MIRROR}/SHA256SUMS"          "${WORK}/SHA256SUMS"          || { warn "GitHub mirror not available (run the 'XanMod mirror' workflow)."; return 1; }
    fetch "${GH_MIRROR}/VERSIONS.txt"        "${WORK}/VERSIONS.txt"        || true
    fetch "${GH_MIRROR}/${name}-image.deb"   "${WORK}/${name}-image.deb"   || { warn "Mirror has no ${name}-image.deb"; return 1; }
    fetch "${GH_MIRROR}/${name}-headers.deb" "${WORK}/${name}-headers.deb" || { warn "Mirror has no ${name}-headers.deb"; return 1; }

    [[ -s "${WORK}/VERSIONS.txt" ]] && grep "^${name}:" "${WORK}/VERSIONS.txt" | sed 's/^/  /'

    if ! (cd "$WORK" && grep -E " ${name}-(image|headers)\.deb$" SHA256SUMS | sha256sum -c -); then
        warn "Checksum mismatch — packages rejected."
        return 1
    fi

    dpkg -i "${WORK}/${name}-image.deb" "${WORK}/${name}-headers.deb" || apt-get -f install -y -q || return 1

    warn "Installed without a repository: kernel updates will NOT arrive via apt. Re-run this script to update."
    return 0
}

# ------------------------------------------------------------
# 3. SourceForge (.deb)
# ------------------------------------------------------------

install_from_sourceforge() {
    local rss="${WORK}/sf.rss" img_url hdr_url img_name

    info "Downloading from SourceForge (branch: ${XANMOD_BRANCH}, level: ${LEVEL})..."

    fetch "$SF_RSS" "$rss" || { warn "SourceForge is not reachable either."; return 1; }

    # Последний linux-image нужного уровня (без -rt / -edge вариантов)
    img_url="$(grep -oE "https://sourceforge\.net/projects/xanmod/files/releases/${XANMOD_BRANCH}/[^<\"]*/linux-image-[0-9.]+-${LEVEL}-xanmod[0-9]+_[^/<\"]*_amd64\.deb/download" "$rss" \
        | sort -u \
        | awk -F/ '{ print $(NF-1) "\t" $0 }' \
        | sort -V -k1,1 | tail -n1 | cut -f2)"

    [[ -n "$img_url" ]] || { warn "No ${LEVEL} linux-image found in SourceForge feed."; return 1; }

    img_name="$(awk -F/ '{ print $(NF-1) }' <<<"$img_url")"
    hdr_url="${img_url//\/linux-image-/\/linux-headers-}"

    info "Image:   ${img_name}"
    info "Headers: ${img_name/linux-image-/linux-headers-}"

    fetch "$img_url" "${WORK}/image.deb"   || { warn "Failed to download image."; return 1; }
    fetch "$hdr_url" "${WORK}/headers.deb" || { warn "Failed to download headers."; return 1; }

    dpkg-deb -I "${WORK}/image.deb"   >/dev/null 2>&1 || { warn "image.deb is not a valid package."; return 1; }
    dpkg-deb -I "${WORK}/headers.deb" >/dev/null 2>&1 || { warn "headers.deb is not a valid package."; return 1; }

    dpkg -i "${WORK}/image.deb" "${WORK}/headers.deb" || apt-get -f install -y -q || return 1

    warn "Installed without a repository: kernel updates will NOT arrive via apt. Re-run this script to update."
    return 0
}

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------

case "$XANMOD_SOURCE" in
    repo)
        install_from_repo || die "Repository install failed." ;;
    github)
        install_from_github || die "GitHub mirror install failed." ;;
    sourceforge)
        install_from_sourceforge || die "SourceForge install failed." ;;
    *)
        if repo_reachable && install_from_repo; then
            ok "Installed from official repository."
        else
            warn "deb.xanmod.org is blocked for this IP (or install failed). Trying GitHub mirror."
            if install_from_github; then
                ok "Installed from GitHub mirror."
            else
                warn "Trying SourceForge."
                install_from_sourceforge || die "All sources failed. Run the 'XanMod mirror' workflow in GitHub Actions and try again."
                ok "Installed from SourceForge."
            fi
        fi
        ;;
esac

finish
