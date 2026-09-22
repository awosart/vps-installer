#!/usr/bin/env bash

# ============================================================
# VPS INSTALLER
# Ubuntu only
# ============================================================

SCRIPT_VERSION="1.2.0"

LOG_DIR="/var/log/vps-setup"
MASTER_LOG="${LOG_DIR}/install.log"
BACKUP_DIR="${LOG_DIR}/backup"
TMP_DIR="/tmp/vps-installer"

mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$TMP_DIR"

# ============================================================
# COLORS
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# LOGGING
# ============================================================

exec > >(tee -a "$MASTER_LOG") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# ============================================================
# ERROR HANDLING
# ============================================================

set -o pipefail

FAILED_STEPS=()
COMPLETED_STEPS=()
REBOOT_REQUIRED="NO"

cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================
# ROOT CHECK
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    error "This installer must be run as root."
    exit 1
fi

# ============================================================
# OS CHECK
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    error "Cannot determine operating system."
    exit 1
fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    error "This installer supports Ubuntu only."
    error "Detected OS: ${PRETTY_NAME:-unknown}"
    exit 1
fi

# ============================================================
# SYSTEM INFORMATION
# ============================================================

echo
echo "============================================================"
echo " VPS INSTALLER v${SCRIPT_VERSION}"
echo "============================================================"
echo

log "Starting VPS installer."
log "Operating system: ${PRETTY_NAME}"
log "Kernel: $(uname -r)"
log "Architecture: $(uname -m)"
log "Hostname: $(hostname)"

if [[ "$(uname -m)" != "x86_64" ]]; then
    warning "Architecture is not x86_64: $(uname -m)"
fi

echo

# ============================================================
# APT / DPKG LOCK HANDLING
# ============================================================

wait_for_apt() {
    local timeout=600
    local elapsed=0

    info "Checking for running APT/dpkg processes..."

    while true; do
        if ! pgrep -x apt >/dev/null 2>&1 \
            && ! pgrep -x apt-get >/dev/null 2>&1 \
            && ! pgrep -x dpkg >/dev/null 2>&1 \
            && ! pgrep -x unattended-upgrade >/dev/null 2>&1; then
            break
        fi

        if [[ "$elapsed" -ge "$timeout" ]]; then
            error "APT/dpkg is still busy after ${timeout} seconds."
            return 1
        fi

        warning "APT/dpkg is currently busy. Waiting..."

        sleep 5
        elapsed=$((elapsed + 5))
    done

    elapsed=0

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
        || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
        || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
        || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do

        if [[ "$elapsed" -ge "$timeout" ]]; then
            error "APT/dpkg locks are still held after ${timeout} seconds."
            return 1
        fi

        warning "APT lock is still held. Waiting..."

        sleep 5
        elapsed=$((elapsed + 5))
    done

    success "APT/dpkg is available."
    return 0
}

# ============================================================
# APT INITIALIZATION
# ============================================================

echo
echo "============================================================"
echo " INITIAL SYSTEM UPDATE"
echo "============================================================"
echo

wait_for_apt || exit 1

log "Running apt-get update..."

if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
    error "apt-get update failed."
    exit 1
fi

wait_for_apt || exit 1

log "Installing required packages..."

if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    apt-transport-https; then

    error "Failed to install required packages."
    exit 1
fi

wait_for_apt || exit 1

log "Running initial system upgrade..."

if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
    error "apt-get upgrade failed."
    exit 1
fi

success "Initial system update completed."

# ============================================================
# SSH PUBLIC KEY
# ============================================================

echo
echo "============================================================"
echo " SSH PUBLIC KEY"
echo "============================================================"
echo

SSH_DIR="/root/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$AUTHORIZED_KEYS" ]] && grep -Eq \
    '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256) ' \
    "$AUTHORIZED_KEYS"; then

    success "A valid SSH public key already exists."
else
    warning "No SSH public key was found for root."

    echo
    echo "Paste your SSH public key below."
    echo "Example:"
    echo "ssh-ed25519 AAAA... user@computer"
    echo

    while true; do
        read -r -p "SSH public key: " SSH_PUBLIC_KEY

        if [[ -z "$SSH_PUBLIC_KEY" ]]; then
            warning "SSH key cannot be empty."
            continue
        fi

        if [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)[[:space:]]+ ]]; then

            touch "$AUTHORIZED_KEYS"

            if ! grep -Fqx "$SSH_PUBLIC_KEY" "$AUTHORIZED_KEYS"; then
                echo "$SSH_PUBLIC_KEY" >> "$AUTHORIZED_KEYS"
            fi

            chmod 600 "$AUTHORIZED_KEYS"

            success "SSH public key added."
            break
        else
            warning "The key format does not look like a valid SSH public key."
            warning "Please paste the complete public key."
        fi
    done
fi

# ============================================================
# SSH CONFIG BACKUP
# ============================================================

if [[ -f /etc/ssh/sshd_config ]]; then
    SSH_BACKUP="${BACKUP_DIR}/sshd_config.$(date '+%Y%m%d-%H%M%S').bak"

    cp -a /etc/ssh/sshd_config "$SSH_BACKUP"

    success "SSH configuration backed up:"
    echo "  $SSH_BACKUP"
fi

# ============================================================
# EXTERNAL SCRIPT RUNNER
# ============================================================

run_step() {
    local name="$1"
    local url="$2"
    shift 2

    local step_log="${LOG_DIR}/${name}.log"
    local tmp_script="${TMP_DIR}/${name}.sh"

    echo
    echo "============================================================"
    echo " ${name}"
    echo "============================================================"
    echo

    log "Starting step: ${name}"
    log "Source: ${url}"

    : > "$step_log"

    if ! curl -fLsS \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 1800 \
        "$url" \
        -o "$tmp_script"; then

        error "${name}: failed to download script."

        FAILED_STEPS+=("$name")

        rm -f "$tmp_script"

        return 1
    fi

    if [[ ! -s "$tmp_script" ]]; then
        error "${name}: downloaded script is empty."

        FAILED_STEPS+=("$name")

        rm -f "$tmp_script"

        return 1
    fi

    chmod 700 "$tmp_script"

    if ! bash -n "$tmp_script" >> "$step_log" 2>&1; then
        error "${name}: downloaded script has invalid Bash syntax."
        error "See log: ${step_log}"

        cat "$step_log"

        FAILED_STEPS+=("$name")

        rm -f "$tmp_script"

        return 1
    fi

    log "Executing ${name}..."

    bash "$tmp_script" "$@" 2>&1 | tee -a "$step_log"

    local exit_code=${PIPESTATUS[0]}

    rm -f "$tmp_script"

    if [[ "$exit_code" -eq 0 ]]; then
        success "${name}: completed successfully."
        COMPLETED_STEPS+=("$name")
        return 0
    fi

    error "${name}: failed with exit code ${exit_code}."
    error "See log: ${step_log}"

    FAILED_STEPS+=("$name")

    return "$exit_code"
}

# ============================================================
# INSTALLATION STEPS
# ============================================================

echo
echo "============================================================"
echo " INSTALLATION"
echo "============================================================"
echo

INSTALL_FAILED=0

# ------------------------------------------------------------
# 01 - BBRv3
# ------------------------------------------------------------

run_step \
    "01-bbrv3" \
    "https://raw.githubusercontent.com/opiran-club/VPS-Optimizer/main/bbrv3.sh" \
    --ipv4 || INSTALL_FAILED=1

# ------------------------------------------------------------
# 02 - SSH PORT
# ------------------------------------------------------------

run_step \
    "02-ssh-port" \
    "https://dignezzz.github.io/server/ssh-port.sh" || INSTALL_FAILED=1

# ------------------------------------------------------------
# 03 - DASHBOARD
# ------------------------------------------------------------

run_step \
    "03-dashboard" \
    "https://dignezzz.github.io/server/dashboard.sh" || INSTALL_FAILED=1

# ------------------------------------------------------------
# 04 - SWAP
# ------------------------------------------------------------

run_step \
    "04-swap" \
    "https://dignezzz.github.io/server/swap.sh" || INSTALL_FAILED=1

# ------------------------------------------------------------
# 05 - FAIL2BAN
# ------------------------------------------------------------

run_step \
    "05-f2b" \
    "https://dignezzz.github.io/server/f2b.sh" || INSTALL_FAILED=1

# ------------------------------------------------------------
# 06 - SECURITY
# ------------------------------------------------------------

run_step \
    "06-security" \
    "https://dignezzz.github.io/server/security.sh" || INSTALL_FAILED=1

# ------------------------------------------------------------
# 07 - REMNANODE
# ------------------------------------------------------------

run_step \
    "07-remnanode" \
    "https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh" \
    @ install || INSTALL_FAILED=1

# ============================================================
# FINAL APT UPDATE
# ============================================================

echo
echo "============================================================"
echo " FINAL SYSTEM UPDATE"
echo "============================================================"
echo

if wait_for_apt; then

    log "Running final apt-get update..."

    if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
        warning "Final apt-get update failed."
        INSTALL_FAILED=1
    fi

    if wait_for_apt; then
        log "Running final apt-get upgrade..."

        if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
            warning "Final apt-get upgrade failed."
            INSTALL_FAILED=1
        fi
    else
        warning "Could not obtain APT lock for final upgrade."
        INSTALL_FAILED=1
    fi

else
    warning "Could not obtain APT lock for final update."
    INSTALL_FAILED=1
fi

# ============================================================
# REBOOT CHECK
# ============================================================

if [[ -f /var/run/reboot-required ]]; then
    REBOOT_REQUIRED="YES"
fi

# ============================================================
# SERVICE STATUS
# ============================================================

get_service_status() {
    local service="$1"

    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "ACTIVE"
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo "ENABLED / NOT RUNNING"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^${service}"; then
        echo "INSTALLED / INACTIVE"
    else
        echo "NOT FOUND"
    fi
}

# ============================================================
# SYSTEM STATUS
# ============================================================

echo
echo "============================================================"
echo " FINAL SYSTEM STATUS"
echo "============================================================"
echo

echo "Hostname       : $(hostname)"
echo "OS             : ${PRETTY_NAME}"
echo "Kernel         : $(uname -r)"
echo "Architecture   : $(uname -m)"
echo

echo "BBR:"
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null; then
    :
else
    echo "  Unable to determine"
fi

echo
echo "Swap:"
if swapon --show --noheadings 2>/dev/null | grep -q .; then
    swapon --show
else
    echo "  No active swap"
fi

echo
echo "SSH:"
if systemctl is-active --quiet ssh 2>/dev/null \
    || systemctl is-active --quiet sshd 2>/dev/null; then
    echo "  SSH service: ACTIVE"
else
    echo "  SSH service: NOT ACTIVE"
fi

echo
echo "Fail2Ban:"
echo "  $(get_service_status fail2ban)"

echo
echo "Docker:"
echo "  $(get_service_status docker)"

echo
echo "RemnaNode:"
if systemctl list-unit-files 2>/dev/null | grep -qi "remnanode"; then
    echo "  Service detected"
    systemctl list-units --type=service --all 2>/dev/null | grep -i remnanode || true
else
    echo "  Service not detected"
fi

# ============================================================
# STEP SUMMARY
# ============================================================

echo
echo "============================================================"
echo " INSTALLATION SUMMARY"
echo "============================================================"
echo

echo "Completed steps:"
if [[ "${#COMPLETED_STEPS[@]}" -eq 0 ]]; then
    echo "  None"
else
    for step in "${COMPLETED_STEPS[@]}"; do
        echo -e "  ${GREEN}[OK]${NC} $step"
    done
fi

echo

echo "Failed steps:"
if [[ "${#FAILED_STEPS[@]}" -eq 0 ]]; then
    echo -e "  ${GREEN}None${NC}"
else
    for step in "${FAILED_STEPS[@]}"; do
        echo -e "  ${RED}[FAILED]${NC} $step"
    done
fi

echo
echo "Reboot Required: ${REBOOT_REQUIRED}"

echo
echo "Master log:"
echo "  ${MASTER_LOG}"

echo
echo "Individual logs:"
ls -1 "${LOG_DIR}"/*.log 2>/dev/null || true

echo
echo "Backups:"
ls -lah "$BACKUP_DIR" 2>/dev/null || true

echo
echo "============================================================"

if [[ "$INSTALL_FAILED" -eq 0 ]]; then
    echo -e "${GREEN}ALL INSTALLATION STEPS COMPLETED${NC}"
    log "Installation completed successfully."
else
    echo -e "${RED}INSTALLATION COMPLETED WITH ERRORS${NC}"
    log "Installation completed with one or more errors."
fi

echo "============================================================"
echo

if [[ "$REBOOT_REQUIRED" == "YES" ]]; then
    warning "A reboot is required."
    warning "The VPS will NOT be rebooted automatically."
fi

if [[ "$INSTALL_FAILED" -ne 0 ]]; then
    warning "Check individual logs in ${LOG_DIR}."
    exit 1
fi

exit 0
