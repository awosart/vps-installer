#!/usr/bin/env bash

# ============================================================
# VPS INSTALLER
# Ubuntu only
# ============================================================

SCRIPT_VERSION="1.1.0"

LOG_DIR="/var/log/vps-setup"
MASTER_LOG="${LOG_DIR}/install.log"
BACKUP_DIR="${LOG_DIR}/backup"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

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
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
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

section() {
    echo
    echo "============================================================"
    echo -e "${BLUE}$*${NC}"
    echo "============================================================"
    echo
}

# ============================================================
# ROOT CHECK
# ============================================================

if [[ "$(id -u)" -ne 0 ]]; then
    error "This installer must be run as root."
    exit 1
fi

# ============================================================
# OS CHECK
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    error "/etc/os-release not found."
    exit 1
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    error "This installer supports Ubuntu only."
    error "Detected: ${PRETTY_NAME:-unknown}"
    exit 1
fi

# ============================================================
# ARCHITECTURE CHECK
# ============================================================

ARCH="$(uname -m)"

if [[ "$ARCH" != "x86_64" ]]; then
    warning "Detected architecture: $ARCH"
    warning "Some external scripts, especially BBR/XanMod, may not support this architecture."
fi

# ============================================================
# SYSTEM INFORMATION
# ============================================================

section "VPS INSTALLER ${SCRIPT_VERSION}"

echo "Hostname     : $(hostname)"
echo "OS           : ${PRETTY_NAME}"
echo "Kernel       : $(uname -r)"
echo "Architecture : ${ARCH}"
echo "IPv4         : $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "Started      : $(date)"

# ============================================================
# APT LOCK WAIT
# ============================================================

wait_for_apt() {

    local TIMEOUT=600
    local ELAPSED=0

    log "Checking for running APT/dpkg processes..."

    while true; do

        if ! pgrep -x apt >/dev/null 2>&1 &&
           ! pgrep -x apt-get >/dev/null 2>&1 &&
           ! pgrep -x dpkg >/dev/null 2>&1 &&
           ! pgrep -x unattended-upgrade >/dev/null 2>&1; then

            break
        fi

        if [[ "$ELAPSED" -eq 0 ]]; then
            warning "APT/dpkg is currently busy."
            warning "Waiting for the existing process to finish..."
        fi

        if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
            error "APT/dpkg remained busy for more than ${TIMEOUT} seconds."
            error "The installer will stop without killing the existing process."
            return 1
        fi

        sleep 5
        ELAPSED=$((ELAPSED + 5))

        if (( ELAPSED % 30 == 0 )); then
            log "Still waiting for APT/dpkg... ${ELAPSED}s"
        fi

    done

    # Extra safety check for locks.
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 ||
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do

        if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
            error "APT lock remained busy for more than ${TIMEOUT} seconds."
            return 1
        fi

        sleep 5
        ELAPSED=$((ELAPSED + 5))

    done

    success "APT/dpkg is available."

    return 0
}

# ============================================================
# INITIAL APT UPDATE
# ============================================================

section "INITIAL SYSTEM UPDATE"

if ! wait_for_apt; then
    exit 1
fi

log "Running apt-get update..."

if apt-get update; then
    success "APT package lists updated."
else
    error "apt-get update failed."
    exit 1
fi

# ============================================================
# INSTALL BASIC DEPENDENCIES
# ============================================================

section "INSTALLING BASIC DEPENDENCIES"

if ! wait_for_apt; then
    exit 1
fi

log "Installing curl, wget and ca-certificates..."

if DEBIAN_FRONTEND=noninteractive \
    apt-get install -y curl wget ca-certificates; then

    success "Basic dependencies installed."

else

    error "Failed to install basic dependencies."
    exit 1

fi

# ============================================================
# SYSTEM UPGRADE
# ============================================================

section "INITIAL SYSTEM UPGRADE"

if ! wait_for_apt; then
    exit 1
fi

log "Upgrading installed packages..."

if DEBIAN_FRONTEND=noninteractive \
    apt-get upgrade -y; then

    success "System packages upgraded."

else

    error "APT upgrade failed."
    exit 1

fi

# ============================================================
# SSH KEY
# ============================================================

section "SSH KEY CHECK"

mkdir -p /root/.ssh
chmod 700 /root/.ssh

AUTHORIZED_KEYS="/root/.ssh/authorized_keys"

touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

if grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)' "$AUTHORIZED_KEYS"; then

    success "An SSH public key already exists."

else

    warning "No SSH public key was found."
    echo
    echo "Paste your PUBLIC SSH key."
    echo
    echo "Example:"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@computer"
    echo
    echo "Do NOT paste your private key."
    echo

    while true; do

        read -r -p "SSH public key: " SSH_PUBLIC_KEY

        if [[ -z "$SSH_PUBLIC_KEY" ]]; then
            warning "No key entered."
            continue
        fi

        if [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)[[:space:]] ]]; then

            echo "$SSH_PUBLIC_KEY" >> "$AUTHORIZED_KEYS"

            chmod 600 "$AUTHORIZED_KEYS"

            success "SSH public key added."

            break

        else

            error "Invalid SSH public key format."
            echo "Expected ssh-ed25519, ssh-rsa or ecdsa-sha2-*."

        fi

    done

fi

# ============================================================
# SSH BACKUP
# ============================================================

section "SSH CONFIG BACKUP"

if [[ -f /etc/ssh/sshd_config ]]; then

    SSH_BACKUP="${BACKUP_DIR}/sshd_config.$(date '+%Y%m%d-%H%M%S').bak"

    cp -a /etc/ssh/sshd_config "$SSH_BACKUP"

    success "SSH configuration backed up."

fi

# ============================================================
# RUN EXTERNAL SCRIPT
# ============================================================

run_step() {

    local NAME="$1"
    local URL="$2"

    shift 2

    local STEP_LOG="${LOG_DIR}/${NAME}.log"
    local TMP_SCRIPT
    local START_TIME
    local END_TIME
    local DURATION
    local EXIT_CODE

    START_TIME=$(date +%s)

    section "STEP: ${NAME}"

    echo "URL     : ${URL}"
    echo "Started : $(date)"
    echo

    TMP_SCRIPT="$(mktemp "/tmp/${NAME}.XXXXXX.sh")"

    log "Downloading script..."

    if ! curl -fLsS --retry 3 --connect-timeout 15 \
        "$URL" -o "$TMP_SCRIPT"; then

        error "Failed to download ${NAME}."
        rm -f "$TMP_SCRIPT"

        return 1
    fi

    if [[ ! -s "$TMP_SCRIPT" ]]; then

        error "Downloaded file is empty."
        rm -f "$TMP_SCRIPT"

        return 1
    fi

    chmod 700 "$TMP_SCRIPT"

    success "Script downloaded."

    echo
    echo "------------------------------------------------------------"
    echo "Running ${NAME}"
    echo "------------------------------------------------------------"
    echo

    # Run interactively.
    # Output is simultaneously written to the individual log.
    bash "$TMP_SCRIPT" "$@" 2>&1 | tee "$STEP_LOG"

    EXIT_CODE=${PIPESTATUS[0]}

    rm -f "$TMP_SCRIPT"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo
    echo "Finished : $(date)"
    echo "Duration : ${DURATION}s"
    echo "Exit code: ${EXIT_CODE}"

    if [[ "$EXIT_CODE" -eq 0 ]]; then

        success "${NAME} completed."

        return 0

    else

        error "${NAME} exited with code ${EXIT_CODE}."

        return "$EXIT_CODE"

    fi
}

# ============================================================
# STEP 01 — BBRv3
# ============================================================

if ! run_step \
    "01-bbrv3" \
    "https://raw.githubusercontent.com/opiran-club/VPS-Optimizer/main/bbrv3.sh" \
    --ipv4; then

    error "Installation stopped at BBRv3."
    exit 1
fi

# ============================================================
# STEP 02 — SSH PORT
# ============================================================

if ! run_step \
    "02-ssh-port" \
    "https://dignezzz.github.io/server/ssh-port.sh"; then

    error "Installation stopped at SSH port configuration."
    exit 1
fi

# ============================================================
# STEP 03 — DASHBOARD
# ============================================================

if ! run_step \
    "03-dashboard" \
    "https://dignezzz.github.io/server/dashboard.sh"; then

    error "Installation stopped at Dashboard."
    exit 1
fi

# ============================================================
# STEP 04 — SWAP
# ============================================================

if ! run_step \
    "04-swap" \
    "https://dignezzz.github.io/server/swap.sh"; then

    error "Installation stopped at Swap."
    exit 1
fi

# ============================================================
# STEP 05 — FAIL2BAN
# ============================================================

if ! run_step \
    "05-f2b" \
    "https://dignezzz.github.io/server/f2b.sh"; then

    error "Installation stopped at Fail2Ban."
    exit 1
fi

# ============================================================
# STEP 06 — SECURITY
# ============================================================

if ! run_step \
    "06-security" \
    "https://dignezzz.github.io/server/security.sh"; then

    error "Installation stopped at Security."
    exit 1
fi

# ============================================================
# STEP 07 — REMNANODE
# ============================================================

if ! run_step \
    "07-remnanode" \
    "https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh" \
    @ install; then

    error "Installation stopped at RemnaNode."
    exit 1
fi

# ============================================================
# FINAL APT UPDATE
# ============================================================

section "FINAL SYSTEM UPDATE"

if ! wait_for_apt; then
    warning "Could not obtain APT lock for final update."
else

    log "Running final apt-get update..."

    if apt-get update; then
        success "Final APT update completed."
    else
        warning "Final apt-get update failed."
    fi

    if ! wait_for_apt; then

        warning "Could not obtain APT lock for final upgrade."

    else

        log "Running final apt-get upgrade..."

        if DEBIAN_FRONTEND=noninteractive \
            apt-get upgrade -y; then

            success "Final system upgrade completed."

        else

            warning "Final apt-get upgrade failed."

        fi

    fi

fi

# ============================================================
# REBOOT REQUIRED CHECK
# ============================================================

section "REBOOT CHECK"

REBOOT_REQUIRED="NO"

if [[ -f /var/run/reboot-required ]]; then
    REBOOT_REQUIRED="YES"
fi

if [[ -f /var/run/reboot-required.pkgs ]]; then
    REBOOT_REQUIRED="YES"
fi

if [[ "$REBOOT_REQUIRED" == "YES" ]]; then

    warning "A reboot is required."
    warning "The installer will NOT reboot the server automatically."

else

    success "No reboot is currently required."

fi

# ============================================================
# FINAL REPORT
# ============================================================

section "FINAL REPORT"

echo "============================================================"
echo "VPS INSTALLER"
echo "============================================================"
echo
echo "Version      : ${SCRIPT_VERSION}"
echo "Status       : SUCCESS"
echo "Finished     : $(date)"
echo

echo "SYSTEM"
echo "------------------------------------------------------------"
echo "Hostname     : $(hostname)"
echo "OS           : ${PRETTY_NAME}"
echo "Kernel       : $(uname -r)"
echo "Architecture : $(uname -m)"
echo "IPv4         : $(hostname -I 2>/dev/null | awk '{print $1}')"
echo

echo "SSH"
echo "------------------------------------------------------------"

if [[ -s "$AUTHORIZED_KEYS" ]]; then

    SSH_KEY_COUNT=$(grep -cE \
        '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-|sk-ssh)' \
        "$AUTHORIZED_KEYS" 2>/dev/null || true)

    echo "Authorized keys : ${SSH_KEY_COUNT}"

else

    echo "Authorized keys : 0"

fi

if systemctl is-active --quiet ssh 2>/dev/null ||
   systemctl is-active --quiet sshd 2>/dev/null; then

    echo "SSH service     : active"

else

    echo "SSH service     : not detected"

fi

echo

echo "FAIL2BAN"
echo "------------------------------------------------------------"

if command -v fail2ban-client >/dev/null 2>&1; then

    fail2ban-client ping 2>/dev/null || true

else

    echo "fail2ban-client : not found"

fi

echo

echo "SWAP"
echo "------------------------------------------------------------"

free -h | grep -i swap || true

echo

echo "NETWORK"
echo "------------------------------------------------------------"

if sysctl net.ipv4.tcp_congestion_control 2>/dev/null; then
    true
else
    echo "TCP congestion control information unavailable."
fi

echo

echo "DOCKER"
echo "------------------------------------------------------------"

if command -v docker >/dev/null 2>&1; then

    docker --version

    echo "Docker service:"
    systemctl is-active docker 2>/dev/null || true

else

    echo "Docker : not installed"

fi

echo

echo "REMNANODE"
echo "------------------------------------------------------------"

if command -v remnanode >/dev/null 2>&1; then

    echo "remnanode command : installed"

    remnanode status 2>/dev/null || true

else

    echo "remnanode command : not found"

fi

echo

echo "REBOOT"
echo "------------------------------------------------------------"
echo "Required : ${REBOOT_REQUIRED}"

echo

echo "LOGS"
echo "------------------------------------------------------------"

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
echo -e "${GREEN}ALL INSTALLATION STEPS COMPLETED${NC}"
echo "============================================================"
echo

log "Installation completed."
```

**После замены файла в GitHub** запускай на новом VPS:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/awosart/vps-installer/main/vps-install.sh)
```

И теперь при занятом `apt` он не будет ломиться в `dpkg`: будет ждать освобождения блокировки до **10 минут**, после чего корректно остановится. Кроме того, если BBR потребует reboot, установщик **не будет сам перезагружать VPS** — в конце просто покажет `Reboot Required: YES`.
