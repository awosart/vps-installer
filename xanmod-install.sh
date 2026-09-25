#!/usr/bin/env bash
# Установка ядра XanMod на Ubuntu/Debian.
# Использование: sudo bash xanmod-install.sh [main|lts] [--with-dkms]
#   main        — основная ветка (по умолчанию)
#   lts         — LTS-ветка
#   --with-dkms — зависимости для сборки внешних модулей (NVIDIA, VirtualBox и т.п.)
#
# Важно: deb.xanmod.org / dl.xanmod.org отвечают 403 на curl/wget с облачных IP
# (AWS/Lightsail), но пускают apt. Поэтому ключ при необходимости берётся
# с keyserver.ubuntu.com, а репозиторий проверяется самим apt.

set -euo pipefail

KEY_FPR="D38D7D1DA1349567ADED882D86F7D09EE734E623"
KEY_URL="https://dl.xanmod.org/archive.key"
KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
SOURCES="/etc/apt/sources.list.d/xanmod-release.list"
BBR_SYSCTL="/etc/sysctl.d/99-bbr.conf"

BRANCH="main"
WITH_DKMS=0
for arg in "$@"; do
  case "$arg" in
    main|lts) BRANCH="$arg" ;;
    --with-dkms) WITH_DKMS=1 ;;
    *) echo "Неизвестный аргумент: $arg"; exit 1 ;;
  esac
done

log()  { echo -e "\e[1;32m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

# --- Проверки ---
[[ $EUID -eq 0 ]] || die "Запустите через sudo."
[[ "$(uname -m)" == "x86_64" ]] || die "XanMod поддерживает только x86_64."

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

log "Устанавливаю необходимые пакеты..."
apt-get update -qq
apt-get install -y -qq curl gnupg dirmngr lsb-release ca-certificates >/dev/null

CODENAME="$(lsb_release -sc)"
log "Дистрибутив: $CODENAME, текущее ядро: $(uname -r)"

# --- Очистка старых записей XanMod ---
rm -f "$SOURCES"
find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.list' \
  -exec sed -i '/deb\.xanmod\.org/d' {} + 2>/dev/null || true

# --- Ключ репозитория ---
log "Получаю ключ XanMod..."
install -d -m 755 /etc/apt/keyrings
TMP_GNUPG="$(mktemp -d)"
trap 'rm -rf "$TMP_GNUPG"' EXIT
chmod 700 "$TMP_GNUPG"

KEY_OK=0
# Способ 1: с сайта XanMod (может отдавать 403 для облачных IP)
if curl -fsSL "$KEY_URL" -o "$TMP_GNUPG/archive.key" 2>/dev/null \
   && gpg --homedir "$TMP_GNUPG" --import "$TMP_GNUPG/archive.key" 2>/dev/null; then
  KEY_OK=1
  log "Ключ скачан с dl.xanmod.org"
else
  warn "dl.xanmod.org недоступен, беру ключ с keyserver.ubuntu.com"
  if gpg --homedir "$TMP_GNUPG" --keyserver hkps://keyserver.ubuntu.com \
         --recv-keys "$KEY_FPR" 2>/dev/null; then
    KEY_OK=1
  fi
fi
[[ $KEY_OK -eq 1 ]] || die "Не удалось получить ключ XanMod."

# Проверяем полный отпечаток и экспортируем в формат, понятный apt
gpg --homedir "$TMP_GNUPG" --list-keys "$KEY_FPR" >/dev/null 2>&1 \
  || die "Полученный ключ не совпадает с ожидаемым отпечатком $KEY_FPR."
gpg --homedir "$TMP_GNUPG" --export "$KEY_FPR" > "$KEYRING"
chmod 644 "$KEYRING"
[[ -s "$KEYRING" ]] || die "Файл ключа пустой: $KEYRING"

# --- Репозиторий ---
log "Добавляю репозиторий..."
echo "deb [signed-by=$KEYRING] http://deb.xanmod.org $CODENAME main" > "$SOURCES"

UPDATE_OUT="$(apt-get update 2>&1)" || true
echo "$UPDATE_OUT"
if grep -qE "NO_PUBKEY|is not signed" <<<"$UPDATE_OUT"; then
  die "apt не принимает подпись репозитория XanMod."
fi
if grep -qE "xanmod.*(403|Forbidden)" <<<"$UPDATE_OUT"; then
  rm -f "$SOURCES"
  die "deb.xanmod.org отказал apt (403). Репозиторий удалён."
fi

# --- Выбор уровня процессора ---
PSABI="$(/lib64/ld-linux-x86-64.so.2 --help 2>/dev/null || true)"
if   grep -q "x86-64-v3 (supported" <<<"$PSABI"; then LEVEL="x64v3"   # v4 тоже ставим как v3
elif grep -q "x86-64-v2 (supported" <<<"$PSABI"; then LEVEL="x64v2"
else LEVEL="x64v1"
fi
log "Уровень процессора: $LEVEL"

if [[ "$BRANCH" == "lts" || "$LEVEL" == "x64v1" ]]; then
  PKG="linux-xanmod-lts-$LEVEL"
else
  PKG="linux-xanmod-$LEVEL"
fi

apt-cache show "$PKG" >/dev/null 2>&1 \
  || die "Пакет $PKG не найден. Доступные: $(apt-cache search --names-only '^linux-xanmod' | cut -d' ' -f1 | xargs)"

# --- Установка ---
log "Устанавливаю $PKG..."
apt-get install -y "$PKG"

if [[ $WITH_DKMS -eq 1 ]]; then
  log "Устанавливаю зависимости для DKMS..."
  apt-get install -y --no-install-recommends dkms libdw-dev clang lld llvm
fi

update-grub >/dev/null 2>&1 || true

# --- Проверка ядра и выбор его по умолчанию ---
KVER="$(ls /boot/vmlinuz-*xanmod* 2>/dev/null | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1)"
[[ -n "$KVER" ]] || die "Ядро XanMod не найдено в /boot."
[[ -f "/boot/initrd.img-$KVER" ]] || die "Нет /boot/initrd.img-$KVER — НЕ перезагружайтесь."

NEWEST="$(ls /boot/vmlinuz-* | sed 's|/boot/vmlinuz-||' | sort -V | tail -n1)"
if [[ "$NEWEST" == "$KVER" ]]; then
  log "XanMod $KVER — самое новое ядро, загрузится по умолчанию."
else
  # Ubuntu грузит ядро с наибольшей версией; XanMod младше по номеру
  # (например, 6.x против 7.0-aws), поэтому выбираем его явно.
  warn "Самое новое ядро — $NEWEST. Делаю ядром по умолчанию XanMod $KVER."
  CFG="/boot/grub/grub.cfg"
  SUBMENU="$(grep -m1 -oP "^submenu '\K[^']+" "$CFG")"
  ENTRY="$(grep -oP "^\s*menuentry '\K[^']*${KVER//./\\.}[^']*" "$CFG" | grep -vi recovery | head -n1)"
  [[ -n "$SUBMENU" && -n "$ENTRY" ]] || die "Не найден пункт GRUB для $KVER."
  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
  update-grub >/dev/null 2>&1
  grub-set-default "$SUBMENU>$ENTRY"
  log "GRUB: $(grub-editenv list | grep saved_entry)"
fi

# --- BBR (в ядре XanMod это BBRv3) ---
printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$BBR_SYSCTL"
sysctl --system >/dev/null 2>&1 || true

echo
log "Готово. Установленные ядра XanMod:"
dpkg -l | awk '/^ii/ && /xanmod/ {print "    " $2 "  " $3}'
echo
warn "На облачном сервере (Lightsail/EC2) сделайте снапшот ПЕРЕД перезагрузкой."
echo "    Затем: sudo reboot"
echo "    После: uname -r                               (должно содержать 'xanmod')"
echo "           sysctl net.ipv4.tcp_congestion_control (должно быть bbr)"
