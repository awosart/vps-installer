#!/usr/bin/env bash
# ============================================================
# VPS INSTALLER
# Ubuntu / Debian
# https://github.com/awosart/vps-installer
#
# Run:
#   bash <(curl -fsSL https://raw.githubusercontent.com/awosart/vps-installer/main/vps-install.sh)
#
# Flags:
#   --lang ru|en   interface language
#   -y, --yes      accept defaults, no questions
#   -h, --help     help
#
# Env (for unattended mode):
#   SSH_PUBLIC_KEY="ssh-ed25519 AAAA..."
# ============================================================

SCRIPT_VERSION="1.7.0"

set -o pipefail

# ============================================================
# SETTINGS
# ============================================================

LOG_DIR="/var/log/vps-setup"
MASTER_LOG="${LOG_DIR}/install.log"
BACKUP_DIR="${LOG_DIR}/backup"

REMNANODE_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"
BBRV3_URL="https://raw.githubusercontent.com/opiran-club/VPS-Optimizer/main/bbrv3.sh"
DIGNEZZZ_BASE="https://dignezzz.github.io/server"

XANMOD_REPO="http://deb.xanmod.org"
XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
XANMOD_KEY_FPR="D38D7D1DA1349567ADED882D86F7D09EE734E623"
XANMOD_LIST="/etc/apt/sources.list.d/xanmod-release.list"
BBR_SYSCTL="/etc/sysctl.d/99-bbr.conf"

SSH_KEY_RE='(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+AAAA'

ASSUME_YES=0
UI_LANG=""

# ============================================================
# ARGUMENTS
# ============================================================

usage() {
    cat <<'EOF_USAGE'
Usage: vps-install.sh [--lang ru|en] [-y|--yes] [-h|--help]

  --lang ru|en   interface language / язык интерфейса
  -y, --yes      accept defaults / ответы по умолчанию

Env: SSH_PUBLIC_KEY
EOF_USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)  ASSUME_YES=1 ;;
        --lang)    UI_LANG="${2:-}"; shift ;;
        --lang=*)  UI_LANG="${1#--lang=}" ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

# ============================================================
# COLORS / OUTPUT
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# L "русский" "english" -> строка на выбранном языке
L() {
    if [[ "$UI_LANG" == "ru" ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

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

# ============================================================
# ROOT / OS CHECK
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run as root (sudo -i) / запустите от root (sudo -i)"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: cannot detect OS / не удалось определить ОС"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID}" != "ubuntu" && "${ID}" != "debian" ]]; then
    echo "ERROR: Ubuntu/Debian only. Detected: ${PRETTY_NAME:-unknown}"
    exit 1
fi

# ============================================================
# TERMINAL / LOGGING
# ============================================================

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
TMP_DIR="$(mktemp -d /tmp/vps-installer.XXXXXX)"

# Ввод всегда с терминала: работает и при `curl | bash`.
if (: </dev/tty) 2>/dev/null; then
    TTY_IN="/dev/tty"
else
    TTY_IN="/dev/null"
    ASSUME_YES=1
fi

# ------------------------------------------------------------
# LANGUAGE (до включения лога, чтобы меню было чистым)
# ------------------------------------------------------------

case "$UI_LANG" in
    ru|RU|rus|russian) UI_LANG="ru" ;;
    en|EN|eng|english) UI_LANG="en" ;;
    *)
        UI_LANG=""
        if [[ "$ASSUME_YES" -eq 1 ]]; then
            [[ "${LANG:-}" == ru* ]] && UI_LANG="ru" || UI_LANG="en"
        else
            echo
            echo "  Select language / Выберите язык:"
            echo
            echo "    1) English"
            echo "    2) Русский"
            echo
            while [[ -z "$UI_LANG" ]]; do
                read -r -p "  [1/2]: " lang_answer <"$TTY_IN"
                case "$lang_answer" in
                    1|en|EN) UI_LANG="en" ;;
                    2|ru|RU) UI_LANG="ru" ;;
                    *) echo "  Enter 1 or 2 / Введите 1 или 2" ;;
                esac
            done
        fi
        ;;
esac

# fd 3/4 = настоящий терминал для интерактивных внешних скриптов.
exec 3>&1 4>&2
exec > >(tee -a "$MASTER_LOG") 2>&1

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

# Сбрасывает лишние строки, оставшиеся в буфере терминала после
# многострочной вставки, чтобы они не стали ответами на следующие вопросы.
flush_tty_input() {

    while IFS= read -r -t 0.3 _ <"$TTY_IN"; do :; done 2>/dev/null
}

ask_yn() {
    local prompt="$1" default="${2:-n}" answer hint
    hint="$(L "да/нет" "yes/no")"
    local def_word
    [[ "$default" == "y" ]] && def_word="$(L "да" "yes")" || def_word="$(L "нет" "no")"

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        echo "  ${prompt} -> ${def_word} (auto)"
        [[ "$default" == "y" ]]
        return
    fi

    while true; do
        read -r -p "$(echo -e "${CYAN}?${NC}") ${prompt} [${hint}, Enter = ${def_word}]: " answer <"$TTY_IN"
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes|д|да)  return 0 ;;
            n|no|н|нет)  return 1 ;;
            *) warning "$(L "Введите y (да) или n (нет)." "Enter y (yes) or n (no).")" ;;
        esac
    done
}

# ask_choice "Вопрос" default "вариант 1" "вариант 2" ... -> печатает номер
ask_choice() {
    local prompt="$1" default="$2"
    shift 2
    local options=("$@") i answer

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        echo "  ${prompt} -> ${default}) ${options[$((default - 1))]} (auto)" >&2
        echo "$default"
        return
    fi

    {
        echo
        echo -e "${CYAN}?${NC} ${BOLD}${prompt}${NC}"
        for i in "${!options[@]}"; do
            echo "    $((i + 1))) ${options[$i]}"
        done
    } >&2

    while true; do
        read -r -p "  $(L "Номер" "Number") [1-${#options[@]}, Enter = ${default}]: " answer <"$TTY_IN"
        answer="${answer:-$default}"
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
            echo "$answer"
            return
        fi
        warning "$(L "Введите номер от 1 до ${#options[@]}." "Enter a number from 1 to ${#options[@]}.")" >&2
    done
}

ask_input() {
    local prompt="$1" default="${2:-}" answer

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        echo "$default"
        return
    fi

    read -r -p "$(echo -e "${CYAN}?${NC}") ${prompt}${default:+ [Enter = ${default}]}: " answer <"$TTY_IN"
    echo "${answer:-$default}"
}

# ============================================================
# APT
# ============================================================

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

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
        info "$(L "Жду завершения cloud-init (на новом сервере он может ещё ставить пакеты)..." \
                 "Waiting for cloud-init (a fresh server may still be installing packages)...")"
        timeout 600 cloud-init status --wait >/dev/null 2>&1 \
            || warning "$(L "cloud-init не завершился за 10 минут, продолжаю." \
                            "cloud-init did not finish within 10 minutes, continuing.")"
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

find_ssh_key_files() {
    local f
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        [[ -f "$f" ]] || continue
        if grep -Eq "(^|[[:space:]])${SSH_KEY_RE}" "$f" 2>/dev/null; then
            echo "$f"
        fi
    done
}

count_keys_in() {
    grep -Ec "(^|[[:space:]])${SSH_KEY_RE}" "$1" 2>/dev/null || echo 0
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

# ============================================================
# STEP RUNNERS
# ============================================================

mark_result() {
    local name="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then
        success "${name}: $(L "готово." "done.")"
        COMPLETED_STEPS+=("$name")
    else
        error "${name}: $(L "ошибка (код ${rc})." "failed (exit code ${rc}).")"
        FAILED_STEPS+=("$name")
        INSTALL_FAILED=1
    fi
}

skip_step() {
    info "$1: $(L "пропущено." "skipped.")"
    SKIPPED_STEPS+=("$1")
}

run_local() {
    local name="$1"
    shift
    section "$name"
    "$@"
    mark_result "$name" $?
}

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
        error "$(L "Не удалось скачать скрипт." "Failed to download script.")"
        mark_result "$name" 1
        return 1
    fi

    if ! bash -n "$tmp_script" 2>"$step_log"; then
        error "$(L "Скачанный скрипт содержит синтаксическую ошибку." "Downloaded script has a syntax error.")"
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

run_optional() {
    local flag="$1" name="$2" url="$3"
    if [[ "$flag" -eq 1 ]]; then
        run_remote "$name" "$url"
    else
        skip_step "$name"
    fi
}

# ============================================================
# STEP: SSH
# ============================================================

ensure_ssh_server() {
    if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
        warning "$(L "OpenSSH-сервер не установлен, устанавливаю..." "OpenSSH server is not installed, installing...")"
        apt_get install openssh-server || return 1
        systemctl enable --now ssh 2>/dev/null || true
    fi
    return 0
}

show_existing_keys() {
    local f n
    for f in "$@"; do
        n="$(count_keys_in "$f")"
        echo -e "  ${GREEN}${f}${NC} — $(L "ключей" "keys"): ${n}"
        ssh-keygen -l -f "$f" 2>/dev/null | sed 's/^/      /'
    done
}

# Читает многострочный блок до строки END (или паузы во вводе).
read_pasted_block() {
    local line block="$1"
    while IFS= read -r -t 3 line <"$TTY_IN"; do
        line="${line%$'\r'}"
        block+=$'\n'"$line"
        [[ "$line" == *"END "*"KEY"* || "$line" == *"END SSH2 PUBLIC KEY"* ]] && break
    done
    printf '%s\n' "$block"
}

# Приводит вставленный текст к одной строке публичного ключа OpenSSH.
# Печатает ключ в stdout, при ошибке возвращает 1 (пояснение в stderr).
normalize_pubkey() {
    local input="$1" tmp out

    # 1. Обычный публичный ключ OpenSSH
    if [[ "$input" =~ ^${SSH_KEY_RE} ]]; then
        printf '%s\n' "$input" | head -n1
        return 0
    fi

    tmp="$(mktemp -p /dev/shm 2>/dev/null || mktemp)"
    chmod 600 "$tmp"
    printf '%s\n' "$input" > "$tmp"

    # 2. Публичный ключ в формате SSH2/RFC4716 (PuTTYgen "Save public key")
    if [[ "$input" == *"BEGIN SSH2 PUBLIC KEY"* ]]; then
        out="$(ssh-keygen -i -m RFC4716 -f "$tmp" 2>/dev/null)"
        rm -f "$tmp"
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
            return 0
        fi
        error "$(L "Не удалось прочитать ключ формата SSH2." "Could not parse the SSH2-format key.")" >&2
        return 1
    fi

    # 3. Вставлен ПРИВАТНЫЙ ключ — извлекаем из него публичную часть,
    #    сам приватный ключ нигде не сохраняется.
    if [[ "$input" == *"PRIVATE KEY"* ]]; then
        warning "$(L "Вы вставили ПРИВАТНЫЙ ключ. Его не нужно передавать на сервер." \
                     "You pasted a PRIVATE key. It should never be sent to a server.")" >&2
        out="$(ssh-keygen -y -P "" -f "$tmp" 2>/dev/null)"
        if command -v shred >/dev/null 2>&1; then shred -u "$tmp" 2>/dev/null; else rm -f "$tmp"; fi
        if [[ -n "$out" ]]; then
            warning "$(L "Из него извлечена публичная часть, приватный ключ удалён из памяти." \
                         "Its public part was extracted, the private key was discarded.")" >&2
            printf '%s vps-installer\n' "$out"
            return 0
        fi
        error "$(L "Ключ защищён паролем или повреждён. На своём компьютере выполните: ssh-keygen -y -f <файл_ключа>  и вставьте результат." \
                   "Key is passphrase-protected or damaged. On your computer run: ssh-keygen -y -f <key_file>  and paste the output.")" >&2
        return 1
    fi

    rm -f "$tmp"

    if [[ "$input" == PuTTY-User-Key-File* ]]; then
        error "$(L "Это файл .ppk (PuTTY). В PuTTYgen скопируйте поле 'Public key for pasting into OpenSSH authorized_keys file'." \
                   "This is a .ppk (PuTTY) file. In PuTTYgen copy the field 'Public key for pasting into OpenSSH authorized_keys file'.")" >&2
        return 1
    fi

    error "$(L "Не похоже на SSH-ключ. Нужна одна строка, которая начинается с ssh-ed25519 или ssh-rsa." \
               "This does not look like an SSH key. Expected one line starting with ssh-ed25519 or ssh-rsa.")" >&2
    return 1
}

add_root_ssh_key() {
    local auth="/root/.ssh/authorized_keys" raw key

    install -d -m 700 /root/.ssh
    touch "$auth"
    chmod 600 "$auth"

    while true; do
        if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
            raw="$SSH_PUBLIC_KEY"
            SSH_PUBLIC_KEY=""
        elif [[ "$ASSUME_YES" -eq 1 ]]; then
            error "$(L "Нет терминала для ввода ключа. Передайте его через SSH_PUBLIC_KEY." \
                       "No terminal to enter the key. Pass it via SSH_PUBLIC_KEY.")"
            return 1
        else
            echo
            echo -e "${BOLD}$(L "Вставьте ваш ПУБЛИЧНЫЙ SSH-ключ и нажмите Enter." \
                                 "Paste your PUBLIC SSH key and press Enter.")${NC}"
            echo
            L "  Это одна строка из файла .pub на вашем компьютере, например:" \
              "  It is one line from the .pub file on your computer, for example:"; echo
            echo "      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@laptop"
            echo
            L "  Как получить (на вашем компьютере, НЕ на сервере):" \
              "  How to get it (on your computer, NOT on the server):"; echo
            echo "      Linux/macOS:  cat ~/.ssh/id_ed25519.pub"
            echo "      Windows:      type %USERPROFILE%\\.ssh\\id_ed25519.pub"
            L "      Нет ключа?    ssh-keygen -t ed25519" \
              "      No key yet?   ssh-keygen -t ed25519"; echo
            echo
            L "  Файл без .pub (-----BEGIN ... PRIVATE KEY-----) — это приватный ключ, его не вставляйте." \
              "  A file without .pub (-----BEGIN ... PRIVATE KEY-----) is the private key, do not paste it."; echo
            echo

            read -r -p "$(L "Публичный ключ" "Public key"): " raw <"$TTY_IN"
            raw="${raw%$'\r'}"

            # Многострочный блок: дочитываем его целиком, чтобы строки
            # не ушли ответами на следующие вопросы.
            if [[ "$raw" == -----BEGIN* || "$raw" == "---- BEGIN"* ]]; then
                raw="$(read_pasted_block "$raw")"
            fi
            flush_tty_input
        fi

        raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

        if [[ -z "$raw" ]]; then
            warning "$(L "Пустой ввод. Вставьте ключ." "Empty input. Please paste the key.")"
            continue
        fi

        if ! key="$(normalize_pubkey "$raw")"; then
            unset raw
            continue
        fi
        unset raw

        if ! ssh-keygen -l -f <(printf '%s\n' "$key") >/dev/null 2>&1; then
            error "$(L "Ключ повреждён (возможно, обрезан при копировании)." \
                       "The key is damaged (possibly cut off while copying).")"
            continue
        fi

        if grep -Fq -- "$(awk '{print $2}' <<<"$key")" "$auth"; then
            success "$(L "Этот ключ уже есть в ${auth}." "This key is already in ${auth}.")"
        else
            printf '%s\n' "$key" >> "$auth"
            success "$(L "Ключ добавлен в ${auth}:" "Key added to ${auth}:")"
        fi
        ssh-keygen -l -f <(printf '%s\n' "$key") 2>/dev/null | sed 's/^/  /'
        return 0
    done
}

backup_ssh_config() {
    local stamp
    stamp="$(date '+%Y%m%d-%H%M%S')"
    if [[ -d /etc/ssh ]]; then
        tar -czf "${BACKUP_DIR}/etc-ssh.${stamp}.tar.gz" -C /etc ssh 2>/dev/null \
            && success "$(L "Резервная копия /etc/ssh" "Backup of /etc/ssh"): ${BACKUP_DIR}/etc-ssh.${stamp}.tar.gz"
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
        info "$(L "Удаляю старый репозиторий XanMod" "Removing old XanMod repository"): $f"
        if [[ "$f" == *.sources ]]; then
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

# dl.xanmod.org иногда отвечает 403 на curl / IP дата-центров.
# Порядок: wget (как в официальной инструкции) -> curl с браузерным User-Agent.
# Ключ: сначала dl.xanmod.org, при 403 (облачные IP) — keyserver.ubuntu.com через gpg.
xanmod_install_key() {
    local gh ok=0

    gh="$(mktemp -d)"
    chmod 700 "$gh"

    if curl -fsSL "$XANMOD_KEY_URL" -o "${gh}/archive.key" 2>/dev/null \
            && gpg --homedir "$gh" --import "${gh}/archive.key" >/dev/null 2>&1; then
        info "$(L "Ключ XanMod скачан с dl.xanmod.org." "XanMod key downloaded from dl.xanmod.org.")"
        ok=1
    else
        warning "$(L "dl.xanmod.org недоступен, беру ключ с keyserver.ubuntu.com." \
                     "dl.xanmod.org is unavailable, taking key from keyserver.ubuntu.com.")"
        gpg --homedir "$gh" --keyserver hkps://keyserver.ubuntu.com \
            --recv-keys "$XANMOD_KEY_FPR" >/dev/null 2>&1 && ok=1
    fi

    if [[ "$ok" -ne 1 ]] || ! gpg --homedir "$gh" --list-keys "$XANMOD_KEY_FPR" >/dev/null 2>&1; then
        error "$(L "Не удалось получить ключ XanMod (отпечаток ${XANMOD_KEY_FPR})." \
                   "Could not get the XanMod key (fingerprint ${XANMOD_KEY_FPR}).")"
        rm -rf "$gh"
        return 1
    fi

    install -d -m 0755 /etc/apt/keyrings
    gpg --homedir "$gh" --export "$XANMOD_KEY_FPR" > "$XANMOD_KEYRING"
    chmod 0644 "$XANMOD_KEYRING"
    rm -rf "$gh"

    [[ -s "$XANMOD_KEYRING" ]] || { error "Empty keyring: ${XANMOD_KEYRING}"; return 1; }
    success "$(L "Ключ XanMod проверен" "XanMod key verified"): ${XANMOD_KEY_FPR}"
}

# Уровень CPU через загрузчик glibc — без обращения к dl.xanmod.org.
xanmod_detect_level() {
    local psabi flags
    psabi="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null || true)"

    if   grep -q "x86-64-v3 (supported" <<<"$psabi"; then echo "x64v3"; return
    elif grep -q "x86-64-v2 (supported" <<<"$psabi"; then echo "x64v2"; return
    elif [[ -n "$psabi" ]] && grep -q "x86-64-v" <<<"$psabi"; then echo "x64v1"; return
    fi

    # Фоллбэк по /proc/cpuinfo, если ld.so не показал уровни
    flags="$(grep -m1 '^flags' /proc/cpuinfo)"
    if [[ "$flags" =~ avx2 && "$flags" =~ bmi2 && "$flags" =~ fma && "$flags" =~ movbe ]]; then
        echo "x64v3"
    elif [[ "$flags" =~ sse4_2 && "$flags" =~ popcnt && "$flags" =~ ssse3 ]]; then
        echo "x64v2"
    else
        echo "x64v1"
    fi
}

# Ubuntu грузит ядро с наибольшей версией. Если XanMod по номеру младше
# штатного (например, 6.x против 7.0-aws), явно делаем его ядром по умолчанию.
xanmod_set_default_kernel() {
    local kver newest cfg="/boot/grub/grub.cfg" submenu entry

    kver="$(ls /boot/vmlinuz-*xanmod* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1)"
    [[ -n "$kver" ]] || { error "$(L "Ядро XanMod не найдено в /boot." "XanMod kernel not found in /boot.")"; return 1; }

    if [[ ! -f "/boot/initrd.img-${kver}" ]]; then
        error "$(L "Нет /boot/initrd.img-${kver} — НЕ перезагружайтесь." "Missing /boot/initrd.img-${kver} — DO NOT reboot.")"
        return 1
    fi

    newest="$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1)"
    if [[ "$newest" == "$kver" ]]; then
        success "$(L "XanMod ${kver} — самое новое ядро, загрузится по умолчанию." \
                     "XanMod ${kver} is the newest kernel and will boot by default.")"
        return 0
    fi

    warning "$(L "Самое новое ядро — ${newest}, XanMod — ${kver}. Делаю XanMod ядром по умолчанию." \
                 "Newest kernel is ${newest}, XanMod is ${kver}. Making XanMod the default.")"

    submenu="$(grep -m1 -oP "^submenu '\K[^']+" "$cfg")"
    entry="$(grep -oP "^\s*menuentry '\K[^']*${kver//./\\.}[^']*" "$cfg" | grep -vi recovery | head -n1)"

    if [[ -z "$submenu" || -z "$entry" ]]; then
        error "$(L "Не найден пункт GRUB для ${kver}, ядро по умолчанию не изменено." \
                   "GRUB entry for ${kver} not found, default kernel not changed.")"
        return 1
    fi

    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    update-grub >/dev/null 2>&1
    grub-set-default "${submenu}>${entry}"
    success "GRUB: $(grub-editenv list | grep saved_entry)"
}

install_xanmod() {
    local codename="${VERSION_CODENAME:-}" level pkg

    if [[ "$(uname -m)" != "x86_64" ]]; then
        warning "$(L "XanMod есть только для x86_64 (здесь $(uname -m)). Пропуск." \
                     "XanMod is x86_64 only (this is $(uname -m)). Skipping.")"
        return 0
    fi
    [[ -n "$codename" ]] || { error "Cannot detect codename."; return 1; }

    xanmod_clean_old_repos
    apt_get install ca-certificates curl gnupg dirmngr || return 1

    xanmod_install_key || return 1

    # Важно: deb.xanmod.org отвечает 403 на curl/wget с облачных IP,
    # но пускает apt. Поэтому доступность проверяем самим apt, а не curl.
    echo "deb [signed-by=${XANMOD_KEYRING}] ${XANMOD_REPO} ${codename} main" > "$XANMOD_LIST"
    info "Repository: $(cat "$XANMOD_LIST")"

    local upd
    upd="$(apt-get "${APT_OPTS[@]}" update 2>&1)"
    echo "$upd"
    if grep -qE "NO_PUBKEY|is not signed|xanmod.*(403|Forbidden)" <<<"$upd"; then
        error "$(L "apt не может работать с репозиторием XanMod (см. вывод выше). Репозиторий удалён." \
                   "apt cannot use the XanMod repository (see output above). Repository removed.")"
        rm -f "$XANMOD_LIST"
        apt_get update >/dev/null 2>&1 || true
        return 1
    fi

    level="$(xanmod_detect_level)"
    pkg="linux-xanmod-${level}"
    [[ "$level" == "x64v1" ]] && pkg="linux-xanmod-lts-x64v1"
    info "$(L "Уровень CPU" "CPU level"): ${level}, $(L "пакет" "package"): ${pkg}"

    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        error "$(L "Пакет ${pkg} не найден. Доступные:" "Package ${pkg} not found. Available:") \
$(apt-cache search --names-only '^linux-xanmod' | cut -d' ' -f1 | xargs)"
        return 1
    fi

    apt_get install "$pkg" || return 1
    update-grub >/dev/null 2>&1 || true

    xanmod_set_default_kernel || return 1

    cat > "$BBR_SYSCTL" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1 || true

    REBOOT_REQUIRED="YES"
    success "XanMod: $(dpkg -l | awk '/^ii  linux-image-.*xanmod/ { print $2 }' | sort -V | tail -n1)"
    return 0
}

# ============================================================
# STEP: UFW (только установка; правила настраивает security.sh)
# ============================================================

ensure_ufw() {
    if command -v ufw >/dev/null 2>&1; then
        success "$(L "UFW уже установлен." "UFW is already installed.")"
        return 0
    fi
    warning "$(L "UFW не установлен, устанавливаю..." "UFW is not installed, installing...")"
    apt_get install ufw
}

# Проверка, что Fail2Ban следит за актуальным SSH-портом.
check_f2b_ssh_port() {
    local ssh_ports jail_ports p ok=1
    command -v fail2ban-client >/dev/null 2>&1 || return 0

    ssh_ports="$(get_ssh_ports)"
    jail_ports="$(cat /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*.conf /etc/fail2ban/jail.d/*.local 2>/dev/null \
        | awk '/^\[/{sec=$0} sec ~ /^\[sshd\]/ && /^[[:space:]]*port[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print }' \
        | tail -n1)"

    if ! fail2ban-client status sshd >/dev/null 2>&1; then
        warning "$(L "Jail sshd в Fail2Ban не активен." "Fail2Ban sshd jail is not active.")"
        return 1
    fi

    info "$(L "SSH-порт(ы)" "SSH port(s)"): ${ssh_ports}  |  Fail2Ban sshd port: ${jail_ports:-ssh (22)}"

    for p in $ssh_ports; do
        if [[ -z "$jail_ports" ]]; then
            [[ "$p" == "22" ]] || ok=0
        elif ! grep -Eq "(^|[^0-9])${p}([^0-9]|$)" <<<"$jail_ports"; then
            ok=0
        fi
    done

    if [[ "$ok" -eq 1 ]]; then
        success "$(L "Fail2Ban следит за актуальным SSH-портом." "Fail2Ban watches the current SSH port.")"
        return 0
    fi

    warning "$(L "Fail2Ban НЕ следит за текущим SSH-портом. Проверьте секцию [sshd] в /etc/fail2ban/jail.local." \
                 "Fail2Ban does NOT watch the current SSH port. Check the [sshd] section in /etc/fail2ban/jail.local.")"
    return 1
}

# ============================================================
# STEP: REMNANODE
# ============================================================

remnanode_running() {
    command -v docker >/dev/null 2>&1 || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null)" == "true" ]]
}

install_remnanode() {
    local rc
    section "08-remnanode"
    log "bash <(curl -fsSL ${REMNANODE_URL}) @ install"
    echo
    warning "$(L "После установки скрипт ноды сам откроет логи контейнера. Когда увидите, что нода запустилась, нажмите Ctrl+C — установка продолжится." \
                 "After installation the node script opens container logs. Once the node is up, press Ctrl+C — the installer will continue.")"
    echo

    # Ctrl+C должен закрыть только логи ноды, а не весь установщик.
    trap ':' INT
    bash <(curl -fsSL "$REMNANODE_URL") @ install <"$TTY_IN" >&3 2>&4
    rc=$?
    trap - INT

    # Код выхода ненадёжен (Ctrl+C на логах даёт 130), поэтому
    # успех определяем по тому, запущен ли контейнер.
    sleep 3
    if remnanode_running; then
        [[ "$rc" -ne 0 ]] && info "$(L "Скрипт ноды завершился с кодом ${rc} (выход из логов), но контейнер работает." \
                                        "Node script exited with code ${rc} (logs closed), but the container is running.")"
        mark_result "08-remnanode" 0
    else
        error "$(L "Контейнер remnanode не запущен." "The remnanode container is not running.")"
        mark_result "08-remnanode" "$(( rc == 0 ? 1 : rc ))"
    fi
}

# ============================================================
# START
# ============================================================

section "VPS INSTALLER v${SCRIPT_VERSION}"

CLOUD="$(detect_cloud)"
CURRENT_SSH_PORTS="$(get_ssh_ports)"

log "OS:           ${PRETTY_NAME}"
log "Kernel:       $(uname -r)"
log "Architecture: $(uname -m)"
log "Hostname:     $(hostname)"
log "Cloud:        ${CLOUD}"
log "SSH ports:    ${CURRENT_SSH_PORTS}"

# ============================================================
# QUESTIONNAIRE
# ============================================================

section "$(L "НАСТРОЙКА — ответьте на вопросы, дальше установка пойдёт сама" \
             "SETUP — answer the questions, installation then runs on its own")"

# ---------------- SSH ----------------

mapfile -t KEY_FILES < <(find_ssh_key_files)

echo -e "${BOLD}$(L "Вход по SSH-ключу" "SSH key login")${NC}"
echo
if [[ "${#KEY_FILES[@]}" -gt 0 ]]; then
    L "  На сервере уже есть SSH-ключи:" "  SSH keys already present on this server:"; echo
    show_existing_keys "${KEY_FILES[@]}"
    DEF_SSH_CHOICE=1
else
    L "  На сервере НЕ найдено ни одного SSH-ключа (вход сейчас, скорее всего, по паролю)." \
      "  NO SSH keys found on this server (login is probably by password right now)."; echo
    DEF_SSH_CHOICE=2
fi

if root_keys_blocked; then
    echo
    warning "$(L "Провайдер запретил вход под root по ключу (AWS: 'Please login as ...'). Вы входите под обычным пользователем — это нормально." \
                 "The provider blocks root key login (AWS: 'Please login as ...'). You log in as a regular user — that is fine.")"
fi

SSH_CHOICE="$(ask_choice \
    "$(L "Что сделать с SSH-ключами?" "What to do with SSH keys?")" \
    "$DEF_SSH_CHOICE" \
    "$(L "Ничего не менять — мой ключ уже работает (например, AWS или ключ добавлен провайдером)" \
         "Change nothing — my key already works (e.g. AWS or key added by the provider)")" \
    "$(L "Добавить мой публичный ключ для пользователя root" \
         "Add my public key for the root user")")"

[[ "$SSH_CHOICE" == "2" ]] && DO_SSH_KEY=1 || DO_SSH_KEY=0

# ---------------- SSH port ----------------

echo
if [[ "$CLOUD" == "aws" ]]; then
    warning "$(L "AWS: новый SSH-порт нужно вручную открыть в Security Group, иначе доступ к серверу пропадёт." \
                 "AWS: a new SSH port must be opened manually in the Security Group, or you will lose access.")"
fi
DEF_SSH_PORT="y"
[[ "$CLOUD" == "aws" || "$DO_SSH_KEY" -eq 0 ]] && DEF_SSH_PORT="n"
ask_yn "$(L "Сменить SSH-порт (сейчас: ${CURRENT_SSH_PORTS:-22})?" \
            "Change SSH port (current: ${CURRENT_SSH_PORTS:-22})?")" "$DEF_SSH_PORT" \
    && DO_SSH_PORT=1 || DO_SSH_PORT=0

# ---------------- Kernel / BBR ----------------

if [[ "$(uname -m)" == "x86_64" ]]; then
    ask_yn "$(L "Установить ядро XanMod с BBRv3 (ускорение сети, нужна перезагрузка)?" \
                "Install XanMod kernel with BBRv3 (faster networking, reboot required)?")" "y" \
        && DO_XANMOD=1 || DO_XANMOD=0
else
    info "$(L "Архитектура $(uname -m): XanMod недоступен, шаг пропущен." \
              "Architecture $(uname -m): XanMod is unavailable, step skipped.")"
    DO_XANMOD=0
fi

if [[ "$DO_XANMOD" -eq 1 ]]; then
    DO_BBR_SCRIPT=0
else
    ask_yn "$(L "Включить BBRv3 сторонним скриптом (opiran bbrv3.sh)?" \
                "Enable BBRv3 with third-party script (opiran bbrv3.sh)?")" "y" \
        && DO_BBR_SCRIPT=1 || DO_BBR_SCRIPT=0
fi

# ---------------- Other steps ----------------

ask_yn "$(L "Усилить защиту SSH и настроить UFW (security.sh: вход только по ключу, файрвол)?" \
            "Harden SSH and configure UFW (security.sh: key-only login, firewall)?")" "y" \
    && DO_SECURITY=1 || DO_SECURITY=0

ask_yn "$(L "Установить Fail2Ban (блокировка перебора паролей)?" \
            "Install Fail2Ban (blocks brute-force attempts)?")" "y" \
    && DO_F2B=1 || DO_F2B=0

ask_yn "$(L "Установить приветственный дашборд (информация о сервере при входе)?" \
            "Install login dashboard (server info shown on login)?")" "y" \
    && DO_DASHBOARD=1 || DO_DASHBOARD=0

if swapon --show --noheadings 2>/dev/null | grep -q .; then
    DEF_SWAP="n"
    SWAP_NOTE="$(L "swap уже есть" "swap already exists")"
else
    DEF_SWAP="y"
    SWAP_NOTE="$(L "swap сейчас нет" "no swap right now")"
fi
ask_yn "$(L "Настроить swap-файл (${SWAP_NOTE})?" "Configure swap file (${SWAP_NOTE})?")" "$DEF_SWAP" \
    && DO_SWAP=1 || DO_SWAP=0

ask_yn "$(L "Установить Remnanode?" "Install Remnanode?")" "y" \
    && DO_REMNANODE=1 || DO_REMNANODE=0

# ---------------- Confirm ----------------

yn_word() { [[ "$1" -eq 1 ]] && L "да" "yes" || L "нет" "no"; }

section "$(L "ПЛАН УСТАНОВКИ" "INSTALLATION PLAN")"
echo "  01 $(L "Добавить SSH-ключ root   " "Add root SSH key         "): $(yn_word "$DO_SSH_KEY")"
echo "  02 XanMod + BBRv3            : $(yn_word "$DO_XANMOD")$([[ "$DO_BBR_SCRIPT" -eq 1 ]] && echo "  (bbrv3.sh opiran)")"
echo "  03 $(L "Сменить SSH-порт         " "Change SSH port          "): $(yn_word "$DO_SSH_PORT")"
echo "  04 $(L "Защита SSH + UFW (security.sh)" "SSH hardening + UFW (security.sh)"): $(yn_word "$DO_SECURITY")"
echo "  05 Fail2Ban                  : $(yn_word "$DO_F2B")"
echo "  06 $(L "Дашборд                  " "Dashboard                "): $(yn_word "$DO_DASHBOARD")"
echo "  07 Swap                      : $(yn_word "$DO_SWAP")"
echo "  08 Remnanode                 : $(yn_word "$DO_REMNANODE")"
echo

if ! ask_yn "$(L "Начать установку?" "Start installation?")" "y"; then
    info "$(L "Отменено пользователем." "Cancelled by user.")"
    exit 0
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
    error "$(L "Не удалось установить базовые пакеты." "Failed to install required packages.")"
    exit 1
fi

apt_get upgrade || { warning "apt-get upgrade failed."; INSTALL_FAILED=1; }

ensure_ssh_server || { error "openssh-server install failed."; INSTALL_FAILED=1; }

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
# 03 - SSH PORT -> 04 - SECURITY (UFW) -> 05 - FAIL2BAN
# Сначала ваш SSH-порт, затем security.sh настраивает UFW,
# затем Fail2Ban ставится на рабочий порт и проверяется.
# ============================================================

if [[ "$DO_SSH_PORT" -eq 1 ]]; then
    run_remote "03-ssh-port" "${DIGNEZZZ_BASE}/ssh-port.sh"
    info "$(L "SSH-порт(ы) после смены" "SSH port(s) after change"): $(get_ssh_ports)"
else
    skip_step "03-ssh-port"
fi

if [[ "$DO_SECURITY" -eq 1 ]]; then
    if [[ -z "$(find_ssh_key_files)" ]]; then
        error "$(L "На сервере нет ни одного SSH-ключа — security.sh пропущен, иначе вы потеряете доступ." \
                   "No SSH keys on this server — security.sh skipped, otherwise you would lose access.")"
        FAILED_STEPS+=("04-security (no ssh key)")
        INSTALL_FAILED=1
    else
        run_remote "04-security" "${DIGNEZZZ_BASE}/security.sh"
    fi
else
    skip_step "04-security"
fi

if [[ "$DO_F2B" -eq 1 ]]; then
    run_remote "05-f2b" "${DIGNEZZZ_BASE}/f2b.sh"
    section "05b-f2b-check"
    check_f2b_ssh_port || INSTALL_FAILED=1
else
    skip_step "05-f2b"
fi

# ============================================================
# 06 - DASHBOARD, 07 - SWAP
# ============================================================

run_optional "$DO_DASHBOARD" "06-dashboard" "${DIGNEZZZ_BASE}/dashboard.sh"
run_optional "$DO_SWAP"      "07-swap"      "${DIGNEZZZ_BASE}/swap.sh"

# ============================================================
# 08 - REMNANODE
# ============================================================

if [[ "$DO_REMNANODE" -eq 1 ]]; then
    install_remnanode
else
    skip_step "08-remnanode"
fi

# ============================================================
# FINAL UPDATE
# ============================================================

section "FINAL SYSTEM UPDATE"

if apt_get update && apt_get upgrade; then
    success "$(L "Система обновлена." "System is up to date.")"
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
if swapon --show --noheadings 2>/dev/null | grep -q .; then
    swapon --show
else
    echo "  No active swap"
fi

echo
echo "Remnanode:"
if command -v docker >/dev/null 2>&1 \
        && docker ps -a --filter name=remnanode --format '  {{.Names}}: {{.Status}}' 2>/dev/null | grep -q .; then
    docker ps -a --filter name=remnanode --format '  {{.Names}}: {{.Status}}'
else
    echo "  Container not found"
fi

section "$(L "ИТОГ" "SUMMARY")"

echo "$(L "Выполнено" "Completed"):"
[[ "${#COMPLETED_STEPS[@]}" -eq 0 ]] && echo "  -"
for s in "${COMPLETED_STEPS[@]}"; do echo -e "  ${GREEN}[OK]${NC} $s"; done

echo
echo "$(L "Пропущено" "Skipped"):"
[[ "${#SKIPPED_STEPS[@]}" -eq 0 ]] && echo "  -"
for s in "${SKIPPED_STEPS[@]}"; do echo -e "  ${YELLOW}[SKIP]${NC} $s"; done

echo
echo "$(L "С ошибками" "Failed"):"
[[ "${#FAILED_STEPS[@]}" -eq 0 ]] && echo -e "  ${GREEN}-${NC}"
for s in "${FAILED_STEPS[@]}"; do echo -e "  ${RED}[FAILED]${NC} $s"; done

echo
echo "$(L "Нужна перезагрузка" "Reboot required") : ${REBOOT_REQUIRED}"
echo "$(L "Общий лог         " "Master log       ") : ${MASTER_LOG}"
echo "$(L "Логи шагов        " "Step logs        ") : ${LOG_DIR}/*.log"
echo "$(L "Резервные копии   " "Backups          ") : ${BACKUP_DIR}"
echo

if [[ "$REBOOT_REQUIRED" == "YES" ]]; then
    warning "$(L "Нужна перезагрузка: выполните reboot (автоматически сервер НЕ перезагружается)." \
                 "Reboot required: run reboot (the server is NOT rebooted automatically).")"
    if dpkg -l 2>/dev/null | grep -q '^ii  linux-image-.*xanmod'; then
        warning "$(L "После перезагрузки проверьте: uname -r (должно содержать xanmod) и sysctl net.ipv4.tcp_congestion_control (bbr)" \
                     "After reboot check: uname -r (should contain xanmod) and sysctl net.ipv4.tcp_congestion_control (bbr)")"
    fi
fi

if [[ "$INSTALL_FAILED" -ne 0 ]]; then
    echo -e "${RED}$(L "УСТАНОВКА ЗАВЕРШЕНА С ОШИБКАМИ" "INSTALLATION COMPLETED WITH ERRORS")${NC} — ${LOG_DIR}"
    exit 1
fi

echo -e "${GREEN}$(L "ВСЕ ШАГИ ВЫПОЛНЕНЫ" "ALL STEPS COMPLETED")${NC}"
exit 0
