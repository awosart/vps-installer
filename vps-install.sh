#!/usr/bin/env bash
# ============================================================
# VPS INSTALLER
# Ubuntu / Debian
# https://github.com/awosart/vps-installer
#
# Запуск:
#   bash <(curl -fsSL https://raw.githubusercontent.com/awosart/vps-installer/main/vps-install.sh)
#
# Флаги:
#   -y, --yes   принять ответы по умолчанию (без вопросов)
#   -h, --help  справка
#
# Переменные окружения (для автоматического режима):
#   SSH_PUBLIC_KEY="ssh-ed25519 AAAA..."   ключ для root
#   PANEL_IP="1.2.3.4"                     открыть порт ноды только для панели
#   NODE_PORT="2222"                       порт ноды (если .env ещё нет)
#   UFW_EXTRA_PORTS="443,8443/tcp"         дополнительные порты
# ============================================================

SCRIPT_VERSION="1.3.0"

set -o pipefail

# ============================================================
# SETTINGS
# ============================================================

LOG_DIR="/var/log/vps-setup"
MASTER_LOG="${LOG_DIR}/install.log"
BACKUP_DIR="${LOG_DIR}/backup"

REMNANODE_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"
REMNANODE_ENV="/opt/remnanode/.env"
BBRV3_URL="https://raw.githubusercontent.com/opiran-club/VPS-Optimizer/main/bbrv3.sh"
DIGNEZZZ_BASE="https://dignezzz.github.io/server"

XANMOD_REPO="http://deb.xanmod.org"
XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_CPU_CHECK_URL="https://dl.xanmod.org/check_x86-64_psabi.sh"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"
BBR_SYSCTL="/etc/sysctl.d/99-bbr.conf"

SSH_KEY_RE='(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+AAAA'

ASSUME_YES=0

# ============================================================
# COLORS / OUTPUT
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

section() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
    echo
}

usage() {
    cat <<'EOF_USAGE'
Usage: vps-install.sh [-y|--yes] [-h|--help]

  -y, --yes   принять ответы по умолчанию (без вопросов)

Env: SSH_PUBLIC_KEY, PANEL_IP, NODE_PORT, UFW_EXTRA_PORTS
EOF_USAGE
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        -y|--yes)  ASSUME_YES=1 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ============================================================
# ROOT / OS CHECK
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    error "This installer must be run as root."
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    error "Cannot determine operating system."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID}" != "ubuntu" && "${ID}" != "debian" ]]; then
    error "Supported: Ubuntu / Debian. Detected: ${PRETTY_NAME:-unknown}"
    exit 1
fi

# ============================================================
# LOGGING
# ============================================================

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
TMP_DIR="$(mktemp -d /tmp/vps-installer.XXXXXX)"

# fd 3/4 = настоящий терминал. Интерактивные скрипты (ssh-port, remnanode)
# запускаются с ними, иначе они видят pipe вместо TTY и падают
# (clear / меню / read при set -e).
exec 3>&1 4>&2
exec > >(tee -a "$MASTER_LOG") 2>&1

# Ввод всегда читаем с терминала: так скрипт работает и при `curl | bash`.
if (: </dev/tty) 2>/dev/null; then
    TTY_IN="/dev/tty"
else
    TTY_IN="/dev/null"
    ASSUME_YES=1
fi

cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

FAILED_STEPS=()
COMPLETED_STEPS=()
SKIPPED_STEPS=()
REBOOT_REQUIRED="NO"
INSTALL_FAILED=0

# ============================================================
# PROMPTS
# ============================================================

ask_yn() {
    local prompt="$1" default="${2:-n}" answer hint

    [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        echo "  ${prompt} [${hint}]: ${default} (auto)"
        [[ "$default" == "y" ]]
        return
    fi

    while true; do
        read -r -p "$(echo -e "${CYAN}?${NC}") ${prompt} [${hint}]: " answer <"$TTY_IN"
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes|д|да)  return 0 ;;
            n|no|н|нет)  return 1 ;;
            *) warning "Ответьте y или n." ;;
        esac
    done
}

# Результат печатается в stdout, подсказка — в stderr (read -p).
ask_input() {
    local prompt="$1" default="${2:-}" answer

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        echo "$default"
        return
    fi

    read -r -p "$(echo -e "${CYAN}?${NC}") ${prompt}${default:+ [${default}]}: " answer <"$TTY_IN"
    echo "${answer:-$default}"
}

# ============================================================
# APT
# ============================================================

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Lock::Timeout вместо ручного pgrep (pgrep -x unattended-upgrade никогда не
# совпадал: имя процесса обрезается до 15 символов).
# force-confold — не зависать на вопросе про изменённый sshd_config.
APT_OPTS=(
    -y -q
    -o DPkg::Lock::Timeout=600
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)

apt_get() {
    apt-get "${APT_OPTS[@]}" "$@"
}

wait_for_cloud_init() {
    if command -v cloud-init >/dev/null 2>&1 && [[ -d /run/cloud-init ]]; then
        info "Ожидание завершения cloud-init (свежий инстанс может ещё ставить пакеты)..."
        timeout 600 cloud-init status --wait >/dev/null 2>&1 \
            || warning "cloud-init не завершился за 10 минут, продолжаем."
    fi
}

# ============================================================
# DETECTION HELPERS
# ============================================================

detect_cloud() {
    local vendor
    vendor="$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/bios_vendor 2>/dev/null | tr '\n' ' ')"

    if [[ "$vendor" == *Amazon* ]] || [[ "$(head -c 3 /sys/hypervisor/uuid 2>/dev/null)" == "ec2" ]]; then
        echo "aws"
    elif [[ "$vendor" == *Google* ]]; then
        echo "gcp"
    else
        echo "generic"
    fi
}

# Ищет authorized_keys с реальными ключами у root и у всех пользователей.
# Учитывает строки с опциями в начале (как у root на AWS:
# no-port-forwarding,...,command="..." ssh-rsa AAAA...).
find_ssh_key_files() {
    local f
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [[ -f "$f" ]] || continue
        if grep -Eq "(^|[[:space:]])${SSH_KEY_RE}" "$f" 2>/dev/null; then
            echo "$f"
        fi
    done
}

root_keys_blocked() {
    [[ -f /root/.ssh/authorized_keys ]] \
        && grep -Eq '^[^#]*command="[^"]*(Please login as|login as the user)' /root/.ssh/authorized_keys
}

get_ssh_ports() {
    local sshd_bin
    sshd_bin="$(command -v sshd || echo /usr/sbin/sshd)"
    install -d -m 0755 /run/sshd 2>/dev/null || true

    {
        "$sshd_bin" -T 2>/dev/null | awk '$1 == "port" { print $2 }'
        ss -Htlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
    } | grep -E '^[0-9]+$' | sort -un | tr '\n' ' '
}

get_node_port() {
    local value=""
    if [[ -f "$REMNANODE_ENV" ]]; then
        value="$(grep -E '^(NODE_PORT|APP_PORT)=' "$REMNANODE_ENV" | head -n1 | cut -d= -f2 | tr -d "\"' ")"
    fi
    echo "${value:-$NODE_PORT}"
}

# ============================================================
# STEP RUNNERS
# ============================================================

mark_result() {
    local name="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then
        success "${name}: completed."
        COMPLETED_STEPS+=("$name")
    else
        error "${name}: failed (exit code ${rc})."
        FAILED_STEPS+=("$name")
        INSTALL_FAILED=1
    fi
}

skip_step() {
    info "$1: пропущено."
    SKIPPED_STEPS+=("$1")
}

# Локальная функция скрипта.
run_local() {
    local name="$1"
    shift
    section "$name"
    "$@"
    mark_result "$name" $?
}

# Внешний скрипт: скачать -> проверить синтаксис -> запустить с настоящим TTY.
# Лог пишется через `script`, который даёт дочернему процессу псевдотерминал.
run_remote() {
    local name="$1" url="$2"
    shift 2

    local step_log="${LOG_DIR}/${name}.log"
    local tmp_script="${TMP_DIR}/${name}.sh"
    local rc

    section "$name"
    log "Source: ${url}"

    if ! curl -fLsS --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
            "$url" -o "$tmp_script" || [[ ! -s "$tmp_script" ]]; then
        mark_result "$name" 1
        return 1
    fi

    if ! bash -n "$tmp_script" 2>"$step_log"; then
        error "${name}: invalid Bash syntax."
        cat "$step_log"
        mark_result "$name" 1
        return 1
    fi

    chmod 700 "$tmp_script"
    log "Executing ${name} (log: ${step_log})"

    if command -v script >/dev/null 2>&1 && [[ "$TTY_IN" == "/dev/tty" ]]; then
        SHELL=/bin/bash script -qefc "$(printf '%q ' bash "$tmp_script" "$@")" "$step_log" \
            <"$TTY_IN" >&3 2>&4
        rc=$?
    else
        bash "$tmp_script" "$@" <"$TTY_IN" 2>&1 | tee -a "$step_log" >&3
        rc=$?
    fi

    mark_result "$name" "$rc"
    return "$rc"
}

# ============================================================
# STEP: SSH KEY
# ============================================================

ensure_ssh_server() {
    if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
        warning "OpenSSH server не установлен. Устанавливаю..."
        apt_get install openssh-server || return 1
        systemctl enable --now ssh 2>/dev/null || true
    fi
    return 0
}

add_root_ssh_key() {
    local auth="/root/.ssh/authorized_keys" key

    install -d -m 700 /root/.ssh
    touch "$auth"
    chmod 600 "$auth"

    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
        key="$SSH_PUBLIC_KEY"
    elif [[ "$ASSUME_YES" -eq 1 ]]; then
        error "Нет SSH-ключа и нет терминала/SSH_PUBLIC_KEY для ввода."
        return 1
    fi

    while true; do
        if [[ -z "${key:-}" ]]; then
            echo
            echo "Вставьте публичный ключ, пример: ssh-ed25519 AAAA... user@pc"
            read -r -p "SSH public key: " key <"$TTY_IN"
        fi

        key="$(printf '%s' "$key" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

        if [[ -z "$key" ]]; then
            warning "Ключ не может быть пустым."
        elif ! [[ "$key" =~ ^${SSH_KEY_RE} ]]; then
            warning "Это не похоже на публичный SSH-ключ (нужна полная строка)."
        elif command -v ssh-keygen >/dev/null 2>&1 \
                && ! ssh-keygen -l -f <(printf '%s\n' "$key") >/dev/null 2>&1; then
            warning "ssh-keygen не принимает этот ключ (обрезан/повреждён?)."
        else
            grep -Fqx -- "$key" "$auth" || printf '%s\n' "$key" >> "$auth"
            success "Ключ добавлен в ${auth}:"
            ssh-keygen -l -f <(printf '%s\n' "$key") 2>/dev/null || true
            return 0
        fi

        [[ "$ASSUME_YES" -eq 1 ]] && return 1
        key=""
    done
}

backup_ssh_config() {
    local stamp
    stamp="$(date '+%Y%m%d-%H%M%S')"
    if [[ -d /etc/ssh ]]; then
        tar -czf "${BACKUP_DIR}/etc-ssh.${stamp}.tar.gz" -C /etc ssh 2>/dev/null \
            && success "Бэкап /etc/ssh: ${BACKUP_DIR}/etc-ssh.${stamp}.tar.gz"
    fi
}

# ============================================================
# STEP: XANMOD + BBRv3
# ============================================================

xanmod_clean_old_repos() {
    local f
    [[ -f "$XANMOD_LIST" ]] && rm -f "$XANMOD_LIST"

    while IFS= read -r -d '' f; do
        grep -q 'deb\.xanmod\.org' "$f" 2>/dev/null || continue
        info "Удаляю старый XanMod-репозиторий: $f"
        if [[ "$f" == *.sources ]]; then
            # deb822: построчное удаление ломает блок, удаляем файл целиком
            rm -f "$f"
        else
            sed -i '/deb\.xanmod\.org/d' "$f"
            [[ -s "$f" ]] || rm -f "$f"
        fi
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \
                \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null)

    [[ -f /etc/apt/sources.list ]] && sed -i '/deb\.xanmod\.org/d' /etc/apt/sources.list
    return 0
}

xanmod_detect_package() {
    local out level=0

    # check_x86-64_psabi.sh — это awk-скрипт, а не bash.
    out="$(curl -fsSL --retry 3 "$XANMOD_CPU_CHECK_URL" 2>/dev/null | awk -f - 2>&1 || true)"

    if [[ -n "$out" ]]; then
        echo "CPU check: ${out}" >&2
        if   grep -Eq 'x86-64-v4' <<<"$out"; then level=4
        elif grep -Eq 'x86-64-v3' <<<"$out"; then level=3
        elif grep -Eq 'x86-64-v2' <<<"$out"; then level=2
        elif grep -Eq 'x86-64-v1' <<<"$out"; then level=1
        fi
    fi

    # Фоллбэк по флагам CPU, если проверка не скачалась.
    if [[ "$level" -eq 0 ]]; then
        local flags
        flags="$(grep -m1 '^flags' /proc/cpuinfo)"
        if [[ "$flags" =~ avx2 && "$flags" =~ bmi2 && "$flags" =~ fma && "$flags" =~ movbe ]]; then
            level=3
        elif [[ "$flags" =~ sse4_2 && "$flags" =~ popcnt && "$flags" =~ ssse3 ]]; then
            level=2
        else
            level=1
        fi
        echo "CPU check (fallback /proc/cpuinfo): x86-64-v${level}" >&2
    fi

    case "$level" in
        3|4) echo "linux-xanmod-x64v3" ;;   # отдельного x64v4 у XanMod нет
        2)   echo "linux-xanmod-x64v2" ;;
        *)   echo "linux-xanmod-lts-x64v1" ;;
    esac
}

install_xanmod() {
    local codename="${VERSION_CODENAME:-}" pkg

    if [[ "$(uname -m)" != "x86_64" ]]; then
        warning "XanMod собирается только под x86_64 (тут $(uname -m)). Пропуск."
        return 0
    fi

    if [[ -z "$codename" ]]; then
        error "Не удалось определить codename дистрибутива."
        return 1
    fi

    xanmod_clean_old_repos

    apt_get install ca-certificates curl gnupg || return 1

    pkg="$(xanmod_detect_package)"
    info "Выбран пакет: ${pkg}"

    install -d -m 0755 /etc/apt/keyrings
    if ! curl -fsSL --retry 3 "$XANMOD_KEY_URL" | gpg --dearmor --yes -o "$XANMOD_KEYRING"; then
        error "Не удалось скачать ключ XanMod."
        return 1
    fi
    chmod 0644 "$XANMOD_KEYRING"

    echo "deb [signed-by=${XANMOD_KEYRING}] ${XANMOD_REPO} ${codename} main" > "$XANMOD_LIST"
    info "Репозиторий: $(cat "$XANMOD_LIST")"

    if ! apt_get update; then
        error "apt-get update с репозиторием XanMod не прошёл."
        return 1
    fi

    if ! apt-cache policy "$pkg" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
        error "Пакет ${pkg} недоступен для ${codename}. Убираю репозиторий."
        rm -f "$XANMOD_LIST"
        apt_get update >/dev/null 2>&1 || true
        return 1
    fi

    apt_get install "$pkg" || return 1

    if command -v update-grub >/dev/null 2>&1; then
        update-grub || warning "update-grub завершился с ошибкой."
    fi

    # В ядре XanMod "bbr" = BBRv3. Включится после перезагрузки в новое ядро.
    cat > "$BBR_SYSCTL" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true

    REBOOT_REQUIRED="YES"
    success "XanMod установлен: $(dpkg -l | awk '/^ii  linux-image-.*xanmod/ { print $2 }' | tail -n1)"
    return 0
}

# ============================================================
# STEP: UFW
# ============================================================

ensure_ufw() {
    local p

    if ! command -v ufw >/dev/null 2>&1; then
        warning "UFW не установлен. Устанавливаю..."
        apt_get install ufw || return 1
    else
        success "UFW уже установлен."
    fi

    # Разрешаем текущий SSH-порт заранее: если какой-то внешний скрипт
    # включит UFW, доступ не потеряется.
    for p in $(get_ssh_ports); do
        ufw allow "${p}/tcp" comment 'SSH' >/dev/null
    done
    return 0
}

configure_ufw() {
    local p node_port

    ensure_ufw || return 1

    for p in $(get_ssh_ports); do
        info "SSH порт ${p}/tcp -> allow"
        ufw allow "${p}/tcp" comment 'SSH'
    done

    node_port="$(get_node_port)"
    if [[ -n "$node_port" ]]; then
        if [[ -n "$PANEL_IP" ]]; then
            info "Порт ноды ${node_port}/tcp -> только с ${PANEL_IP}"
            ufw allow from "$PANEL_IP" to any port "$node_port" proto tcp comment 'Remnawave panel'
        else
            info "Порт ноды ${node_port}/tcp -> allow (для всех)"
            ufw allow "${node_port}/tcp" comment 'Remnanode'
        fi
    fi

    for p in ${UFW_EXTRA_PORTS//,/ }; do
        if [[ "$p" =~ ^[0-9]{1,5}(:[0-9]{1,5})?(/(tcp|udp))?$ ]]; then
            info "Доп. порт ${p} -> allow"
            ufw allow "$p" comment 'extra'
        else
            warning "Некорректный порт '${p}', пропуск."
        fi
    done

    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable || return 1
    ufw status verbose
    return 0
}

# ============================================================
# STEP: REMNANODE (ровно тот вызов, что работает вручную)
# ============================================================

install_remnanode() {
    section "08-remnanode"
    log "bash <(curl -fsSL ${REMNANODE_URL}) @ install"

    # Прямо в терминал, без tee/pipe — скрипт интерактивный и использует clear/меню.
    bash <(curl -fsSL "$REMNANODE_URL") @ install <"$TTY_IN" >&3 2>&4
    mark_result "08-remnanode" $?
}

# ============================================================
# START
# ============================================================

section "VPS INSTALLER v${SCRIPT_VERSION}"

CLOUD="$(detect_cloud)"

log "OS:           ${PRETTY_NAME}"
log "Kernel:       $(uname -r)"
log "Architecture: $(uname -m)"
log "Hostname:     $(hostname)"
log "Cloud:        ${CLOUD}"
log "SSH ports:    $(get_ssh_ports)"

# ============================================================
# QUESTIONNAIRE (все вопросы сразу, дальше установка идёт сама)
# ============================================================

section "НАСТРОЙКА"

mapfile -t KEY_FILES < <(find_ssh_key_files)

if [[ "${#KEY_FILES[@]}" -gt 0 ]]; then
    info "Найдены SSH-ключи:"
    printf '  %s\n' "${KEY_FILES[@]}"
    DEF_KEY_EXISTS="y"
elif [[ "$CLOUD" == "aws" ]]; then
    DEF_KEY_EXISTS="y"
else
    info "SSH-ключи не найдены."
    DEF_KEY_EXISTS="n"
fi

if root_keys_blocked; then
    warning "Вход root по ключу заблокирован провайдером (AWS: 'Please login as ...')."
    warning "Вы заходите под обычным пользователем — это нормально."
fi

if ask_yn "SSH-доступ по ключу уже настроен (AWS / ключ провайдера)? Ничего не трогать?" "$DEF_KEY_EXISTS"; then
    DO_SSH_KEY=0
else
    DO_SSH_KEY=1
fi

DEF_SSH_PORT="y"
[[ "$CLOUD" == "aws" || "$DO_SSH_KEY" -eq 0 ]] && DEF_SSH_PORT="n"
if [[ "$CLOUD" == "aws" ]]; then
    warning "AWS: при смене SSH-порта нужно открыть его в Security Group, иначе потеряете доступ."
fi
ask_yn "Сменить SSH-порт (ssh-port.sh)?" "$DEF_SSH_PORT" && DO_SSH_PORT=1 || DO_SSH_PORT=0

if [[ "$(uname -m)" == "x86_64" ]]; then
    ask_yn "Установить ядро XanMod + BBRv3?" "y" && DO_XANMOD=1 || DO_XANMOD=0
else
    info "Архитектура $(uname -m): XanMod недоступен."
    DO_XANMOD=0
fi

DEF_BBR_SCRIPT="y"
[[ "$DO_XANMOD" -eq 1 ]] && DEF_BBR_SCRIPT="n"
ask_yn "Запустить сторонний bbrv3.sh (opiran)? Не нужен, если ставим XanMod" "$DEF_BBR_SCRIPT" \
    && DO_BBR_SCRIPT=1 || DO_BBR_SCRIPT=0

ask_yn "Установить dashboard?" "y" && DO_DASHBOARD=1 || DO_DASHBOARD=0

DEF_SWAP="y"
swapon --show --noheadings 2>/dev/null | grep -q . && DEF_SWAP="n"
ask_yn "Настроить swap?" "$DEF_SWAP" && DO_SWAP=1 || DO_SWAP=0

ask_yn "Установить Fail2Ban?" "y" && DO_F2B=1 || DO_F2B=0
ask_yn "Запустить security.sh (hardening SSH)?" "y" && DO_SECURITY=1 || DO_SECURITY=0
ask_yn "Установить Remnanode?" "y" && DO_REMNANODE=1 || DO_REMNANODE=0

if ask_yn "Настроить и включить UFW?" "y"; then
    DO_UFW=1
    NODE_PORT="$(ask_input "Порт ноды (NODE_PORT; из ${REMNANODE_ENV}, если есть)" "${NODE_PORT:-2222}")"
    PANEL_IP="$(ask_input "IP панели — открыть порт ноды только для неё (пусто = для всех)" "${PANEL_IP:-}")"
    UFW_EXTRA_PORTS="$(ask_input "Доп. порты через запятую" "${UFW_EXTRA_PORTS:-443}")"
else
    DO_UFW=0
fi

# ============================================================
# 00 - BASE SYSTEM
# ============================================================

section "00-base-system"

wait_for_cloud_init

if ! apt_get update; then
    error "apt-get update failed."
    exit 1
fi

if ! apt_get install curl wget ca-certificates gnupg lsb-release \
        apt-transport-https util-linux psmisc; then
    error "Failed to install required packages."
    exit 1
fi

apt_get upgrade || { warning "apt-get upgrade failed."; INSTALL_FAILED=1; }

ensure_ssh_server || { error "Не удалось установить openssh-server."; INSTALL_FAILED=1; }

# UFW ставим всегда: на части нод его нет, а внешние скрипты (security/f2b)
# могут на него рассчитывать.
run_local "00-ufw-install" ensure_ufw

# ============================================================
# 01 - SSH KEY
# ============================================================

backup_ssh_config

if [[ "$DO_SSH_KEY" -eq 1 ]]; then
    run_local "01-ssh-key" add_root_ssh_key
else
    skip_step "01-ssh-key"
fi

# ============================================================
# 02 - KERNEL / BBR
# ============================================================

if [[ "$DO_XANMOD" -eq 1 ]]; then
    run_local "02-xanmod-bbrv3" install_xanmod
else
    skip_step "02-xanmod-bbrv3"
fi

if [[ "$DO_BBR_SCRIPT" -eq 1 ]]; then
    run_remote "02b-bbrv3-opiran" "$BBRV3_URL" --ipv4
fi

# ============================================================
# 03..07 - DIGNEZZZ SCRIPTS
# ============================================================

if [[ "$DO_SSH_PORT" -eq 1 ]]; then
    run_remote "03-ssh-port" "${DIGNEZZZ_BASE}/ssh-port.sh"
    ensure_ufw >/dev/null 2>&1 || true   # сразу разрешить новый порт в UFW
else
    skip_step "03-ssh-port"
fi

run_optional() {
    local flag="$1" name="$2" url="$3"
    if [[ "$flag" -eq 1 ]]; then
        run_remote "$name" "$url"
    else
        skip_step "$name"
    fi
}

run_optional "$DO_DASHBOARD" "04-dashboard" "${DIGNEZZZ_BASE}/dashboard.sh"
run_optional "$DO_SWAP"      "05-swap"      "${DIGNEZZZ_BASE}/swap.sh"
run_optional "$DO_F2B"       "06-f2b"       "${DIGNEZZZ_BASE}/f2b.sh"

if [[ "$DO_SECURITY" -eq 1 ]]; then
    # Защита от блокировки: hardening обычно отключает вход по паролю.
    if [[ -z "$(find_ssh_key_files)" ]]; then
        error "На сервере нет ни одного SSH-ключа — security.sh пропущен, чтобы не потерять доступ."
        FAILED_STEPS+=("07-security (no ssh key)")
        INSTALL_FAILED=1
    else
        run_remote "07-security" "${DIGNEZZZ_BASE}/security.sh"
    fi
else
    skip_step "07-security"
fi

# ============================================================
# 08 - REMNANODE
# ============================================================

if [[ "$DO_REMNANODE" -eq 1 ]]; then
    install_remnanode
else
    skip_step "08-remnanode"
fi

# ============================================================
# 09 - UFW
# ============================================================

if [[ "$DO_UFW" -eq 1 ]]; then
    run_local "09-ufw" configure_ufw
else
    skip_step "09-ufw"
fi

# ============================================================
# FINAL UPDATE
# ============================================================

section "FINAL SYSTEM UPDATE"

if apt_get update && apt_get upgrade; then
    success "System is up to date."
else
    warning "Final update/upgrade failed."
    INSTALL_FAILED=1
fi

[[ -f /var/run/reboot-required ]] && REBOOT_REQUIRED="YES"

# ============================================================
# STATUS
# ============================================================

get_service_status() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "ACTIVE"
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo "ENABLED / NOT RUNNING"
    elif systemctl list-unit-files "${service}.service" 2>/dev/null | grep -q "^${service}\.service"; then
        echo "INSTALLED / INACTIVE"
    else
        echo "NOT FOUND"
    fi
}

section "FINAL SYSTEM STATUS"

echo "Hostname     : $(hostname)"
echo "OS           : ${PRETTY_NAME}"
echo "Cloud        : ${CLOUD}"
echo "Kernel (now) : $(uname -r)"
echo "XanMod pkgs  : $(dpkg -l 2>/dev/null | awk '/^ii  linux-image-.*xanmod/ { print $2 }' | tr '\n' ' ')"
echo "TCP CC       : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) (qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null))"
echo "SSH ports    : $(get_ssh_ports)"
echo "SSH keys in  : $(find_ssh_key_files | tr '\n' ' ')"
echo "Fail2Ban     : $(get_service_status fail2ban)"
echo "Docker       : $(get_service_status docker)"
echo "UFW          : $(ufw status 2>/dev/null | head -n1)"

echo
echo "Swap:"
swapon --show 2>/dev/null | grep -q . && swapon --show || echo "  No active swap"

echo
echo "Remnanode:"
if command -v docker >/dev/null 2>&1 \
        && docker ps -a --filter name=remnanode --format '  {{.Names}}: {{.Status}}' 2>/dev/null | grep -q .; then
    docker ps -a --filter name=remnanode --format '  {{.Names}}: {{.Status}}'
else
    echo "  Container not found"
fi

section "INSTALLATION SUMMARY"

echo "Completed:"
if [[ "${#COMPLETED_STEPS[@]}" -eq 0 ]]; then echo "  None"; fi
for s in "${COMPLETED_STEPS[@]}"; do echo -e "  ${GREEN}[OK]${NC} $s"; done

echo
echo "Skipped:"
if [[ "${#SKIPPED_STEPS[@]}" -eq 0 ]]; then echo "  None"; fi
for s in "${SKIPPED_STEPS[@]}"; do echo -e "  ${YELLOW}[SKIP]${NC} $s"; done

echo
echo "Failed:"
if [[ "${#FAILED_STEPS[@]}" -eq 0 ]]; then echo -e "  ${GREEN}None${NC}"; fi
for s in "${FAILED_STEPS[@]}"; do echo -e "  ${RED}[FAILED]${NC} $s"; done

echo
echo "Reboot required : ${REBOOT_REQUIRED}"
echo "Master log      : ${MASTER_LOG}"
echo "Step logs       : ${LOG_DIR}/*.log"
echo "Backups         : ${BACKUP_DIR}"
echo

if [[ "$REBOOT_REQUIRED" == "YES" ]]; then
    warning "Нужна перезагрузка (reboot). Автоматически сервер НЕ перезагружается."
    [[ "$DO_XANMOD" -eq 1 ]] && warning "После reboot проверьте: uname -r (должно содержать xanmod) и sysctl net.ipv4.tcp_congestion_control"
fi

if [[ "$INSTALL_FAILED" -ne 0 ]]; then
    echo -e "${RED}INSTALLATION COMPLETED WITH ERRORS${NC} — см. логи в ${LOG_DIR}"
    exit 1
fi

echo -e "${GREEN}ALL INSTALLATION STEPS COMPLETED${NC}"
exit 0
