```bash
#!/usr/bin/env bash

set -o pipefail

# ============================================================
# VPS INSTALLER
# ============================================================

SCRIPT_VERSION="1.0.0"

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

if [[ "$(id -u)" != "0" ]]; then
    error "This script must be run as root."
    exit 1
fi

# ============================================================
# UBUNTU CHECK
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    error "/etc/os-release not found."
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

section "VPS INSTALLER ${SCRIPT_VERSION}"

echo "Hostname : $(hostname)"
echo "OS       : ${PRETTY_NAME}"
echo "Kernel   : $(uname -r)"
echo "Arch     : $(uname -m)"
echo "IPv4     : $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "Date     : $(date)"

# ============================================================
# INITIAL APT UPDATE / UPGRADE
# ============================================================

section "INITIAL SYSTEM UPDATE"

log "Updating APT package lists..."

if apt-get update; then
    success "APT package lists updated."
else
    error "APT update failed."
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
# SSH KEY CHECK
# ============================================================

section "SSH KEY CHECK"

mkdir -p /root/.ssh
chmod 700 /root/.ssh

AUTHORIZED_KEYS="/root/.ssh/authorized_keys"

touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

if grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-sha2-)' "$AUTHORIZED_KEYS"; then

    success "SSH public key already exists in ${AUTHORIZED_KEYS}"

else

    warning "No SSH public key was found in ${AUTHORIZED_KEYS}."
    echo
    echo "Paste your PUBLIC SSH key below."
    echo
    echo "Example:"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@computer"
    echo
    echo "IMPORTANT:"
    echo "Paste the PUBLIC key only."
    echo "Do NOT paste your private key."
    echo

    while true; do

        read -r -p "SSH public key: " SSH_PUBLIC_KEY

        if [[ -z "$SSH_PUBLIC_KEY" ]]; then
            warning "Nothing entered. Please paste your public key."
            continue
        fi

        if [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)[[:space:]] ]]; then

            echo "$SSH_PUBLIC_KEY" >> "$AUTHORIZED_KEYS"

            chmod 600 "$AUTHORIZED_KEYS"

            success "SSH public key added."

            break

        else

            error "This does not look like a valid SSH public key."
            echo
            echo "Expected something beginning with:"
            echo "  ssh-ed25519"
            echo "  ssh-rsa"
            echo "  ecdsa-sha2-nistp256"
            echo

        fi

    done

fi

# ============================================================
# SSH CONFIG BACKUP
# ============================================================

section "SSH CONFIG BACKUP"

if [[ -f /etc/ssh/sshd_config ]]; then

    SSH_BACKUP="${BACKUP_DIR}/sshd_config.$(date '+%Y%m%d-%H%M%S').bak"

    cp -a /etc/ssh/sshd_config "$SSH_BACKUP"

    success "SSH configuration backed up:"
    echo "$SSH_BACKUP"

fi

# ============================================================
# GENERIC SCRIPT RUNNER
# ============================================================

run_step() {

    local NAME="$1"
    local URL="$2"

    shift 2

    local STEP_LOG="${LOG_DIR}/${NAME}.log"
    local START_TIME
    local END_TIME
    local EXIT_CODE
    local TMP_SCRIPT

    START_TIME=$(date +%s)

    section "STEP: ${NAME}"

    echo "URL: ${URL}"
    echo "Started: $(date)"
    echo

    log "Downloading ${NAME}..."

    TMP_SCRIPT=$(mktemp "/tmp/${NAME}.XXXXXX.sh")

    if ! curl -fLsS "$URL" -o "$TMP_SCRIPT"; then

        error "Failed to download ${NAME}"

        rm -f "$TMP_SCRIPT"

        return 1

    fi

    chmod 700 "$TMP_SCRIPT"

    success "Downloaded ${NAME}"

    echo
    echo "Executing ${NAME}..."
    echo

    bash "$TMP_SCRIPT" "$@" 2>&1 | tee "$STEP_LOG"

    EXIT_CODE=${PIPESTATUS[0]}

    rm -f "$TMP_SCRIPT"

    END_TIME=$(date +%s)

    local DURATION=$((END_TIME - START_TIME))

    echo
    echo "Finished: $(date)"
    echo "Duration: ${DURATION}s"
    echo "Exit code: ${EXIT_CODE}"

    if [[ "$EXIT_CODE" -eq 0 ]]; then

        success "${NAME} completed successfully."

    else

        error "${NAME} failed with exit code ${EXIT_CODE}."

        return "$EXIT_CODE"

    fi

    return 0
}

# ============================================================
# BBRV3
# ============================================================

run_step \
    "01-bbrv3" \
    "https://raw.githubusercontent.com/opiran-club/VPS-Optimizer/main/bbrv3.sh" \
    --ipv4

if [[ $? -ne 0 ]]; then
    error "Installation stopped at BBRv3."
    exit 1
fi

# ============================================================
# SSH PORT
# ============================================================

run_step \
    "02-ssh-port" \
    "https://dignezzz.github.io/server/ssh-port.sh"

if [[ $? -ne 0 ]]; then
    error "Installation stopped at SSH port configuration."
    exit 1
fi

# ============================================================
# DASHBOARD
# ============================================================

run_step \
    "03-dashboard" \
    "https://dignezzz.github.io/server/dashboard.sh"

if [[ $? -ne 0 ]]; then
    error "Installation stopped at Dashboard."
    exit 1
fi

# ============================================================
# SWAP
# ============================================================

run_step \
    "04-swap" \
    "https://dignezzz.github.io/server/swap.sh"

if [[ $? -ne 0 ]]; then
    error "Installation stopped at Swap."
    exit 1
fi

# ============================================================
# FAIL2BAN
# ============================================================

run_step \
    "05-f2b" \
    "https://dignezzz.github.io/server/f2b.sh"

if [[ $? -ne 0 ]]; then
    error "Installation stopped at Fail2Ban."
    exit 1
fi

# ============================================================
# SECURITY
# ============================================================

run_step \
    "06-security" \
    "https://dignezzz.github.io/server/security.sh"

if [[ $? -ne 0 ]]; then
    error "Installation stopped at Security."
    exit 1
fi

# ============================================================
# REMNANODE
# ============================================================

run_step \
    "07-remnanode" \
    "https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh" \
    @ install

if [[ $? -ne 0 ]]; then
    error "Installation stopped at RemnaNode."
    exit 1
fi

# ============================================================
# FINAL APT UPDATE / UPGRADE
# ============================================================

section "FINAL SYSTEM UPDATE"

log "Updating APT package lists again..."

if apt-get update; then

    success "Final APT update completed."

else

    error "Final APT update failed."
    exit 1

fi

log "Upgrading installed packages again..."

if DEBIAN_FRONTEND=noninteractive \
    apt-get upgrade -y; then

    success "Final system upgrade completed."

else

    error "Final APT upgrade failed."
    exit 1

fi

# ============================================================
# FINAL REPORT
# ============================================================

section "FINAL REPORT"

echo "VPS INSTALLER"
echo "Version : ${SCRIPT_VERSION}"
echo

echo "STATUS"
echo "------------------------------------------------------------"
echo "Installation : SUCCESS"
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

    SSH_KEY_COUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-|sk-ssh)' \
        "$AUTHORIZED_KEYS" 2>/dev/null || true)

    echo "Authorized keys : ${SSH_KEY_COUNT}"

else

    echo "Authorized keys : 0"

fi

if systemctl is-active --quiet ssh 2>/dev/null; then

    echo "SSH service     : active"

elif systemctl is-active --quiet sshd 2>/dev/null; then

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

sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true

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

echo "LOG FILES"
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
echo -e "${GREEN}ALL SETUP STEPS COMPLETED SUCCESSFULLY${NC}"
echo "============================================================"
echo

log "Installation completed."
```

### Важное исправление к предыдущей версии

Я здесь специально сделал проверку **Ubuntu до любых установочных действий**. Поэтому если случайно запустить на Debian/CentOS/AlmaLinux и т. п., скрипт остановится сразу.

После загрузки в GitHub твоя команда будет:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/awosart/vps-installer/main/vps-install.sh)
```

Только замени `awosart/vps-installer` на фактический репозиторий, если название будет другим.

**И ещё:** я оставил `remnanode.sh` и остальные внешние скрипты как загрузку с их текущих URL — то есть твой GitHub хранит только **master installer**, а не копии этих скриптов.
