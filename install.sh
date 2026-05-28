#!/usr/bin/env bash

set -Eeuo pipefail

# ==========================================
# NaiveProxy + Caddy Installer
# Production-ready edition
# ==========================================

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="/var/log/naive-installer.log"
GO_VERSION="1.22.0"
GO_ARCHIVE="go${GO_VERSION}.linux-amd64.tar.gz"
GO_URL="https://go.dev/dl/${GO_ARCHIVE}"

exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "[ERROR] Ошибка на строке $LINENO"' ERR

# ==========================================
# Colors
# ==========================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ==========================================
# Helpers
# ==========================================

info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# ==========================================
# Root check
# ==========================================

require_root() {
  if [[ $EUID -ne 0 ]]; then
    error "Запустите скрипт от root"
    exit 1
  fi
}

# ==========================================
# OS check
# ==========================================

check_os() {
  if ! command -v apt >/dev/null 2>&1; then
    error "Поддерживаются только Debian/Ubuntu"
    exit 1
  fi
}

# ==========================================
# Internet check
# ==========================================

check_internet() {
  if ! ping -c 1 1.1.1.1 >/dev/null 2>&1; then
    error "Нет интернет соединения"
    exit 1
  fi
}

# ==========================================
# Package installer
# ==========================================

install_package() {
  local pkg="$1"

  if dpkg -s "$pkg" >/dev/null 2>&1; then
    info "$pkg уже установлен"
  else
    info "Установка $pkg..."
    apt install -y "$pkg"
  fi
}

# ==========================================
# Directory creator
# ==========================================

create_dir() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    info "Создан каталог: $dir"
  fi
}

# ==========================================
# Backup config
# ==========================================

backup_file() {
  local file="$1"

  if [[ -f "$file" ]]; then
    cp "$file" "${file}.bak.$(date +%F-%H%M%S)"
    info "Backup создан: ${file}.bak"
  fi
}

# ==========================================
# Cleanup
# ==========================================

cleanup() {
  rm -f "/tmp/${GO_ARCHIVE}"
}

trap cleanup EXIT

# ==========================================
# Checks
# ==========================================

require_root
check_os
check_internet

# ==========================================
# Banner
# ==========================================

echo "========================================"
echo "NAIVEPROXY INSTALLER"
echo "Production Edition"
echo "========================================"

# ==========================================
# User input
# ==========================================

read -rp "🌐 Домен (example.com): " DOMAIN
DOMAIN=${DOMAIN:-example.com}

read -rp "📧 Email для SSL: " EMAIL
EMAIL=${EMAIL:-admin@example.com}

read -rp "🎭 Фейковый сайт: " FAKE_SITE
FAKE_SITE=${FAKE_SITE:-https://demo.cloudreve.org}

read -rp "👤 Логин (пусто = авто): " USER_NAME
read -rp "🔑 Пароль (пусто = авто): " USER_PASS

read -rp "⚡ Установить WARP? (y/n): " WARP_INPUT

INSTALL_WARP=false

if [[ "$WARP_INPUT" =~ ^[Yy]$ ]]; then
  INSTALL_WARP=true
fi

# ==========================================
# Domain check
# ==========================================

if getent hosts "$DOMAIN" >/dev/null 2>&1; then
  info "Домен резолвится"
else
  warn "Домен пока не резолвится"
fi

# ==========================================
# Port check
# ==========================================

if ss -tulpn | grep -q ":443 "; then
  error "Порт 443 уже занят"
  exit 1
fi

# ==========================================
# System update
# ==========================================

info "Обновление системы..."

apt update -y
apt upgrade -y

# ==========================================
# Base packages
# ==========================================

info "Установка базовых пакетов..."

PACKAGES=(
  wget
  curl
  tar
  openssl
  gnupg
  lsb-release
  ca-certificates
)

for pkg in "${PACKAGES[@]}"; do
  install_package "$pkg"
done

# ==========================================
# Enable BBR
# ==========================================

info "Включение BBR..."

if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi

if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi

sysctl -p

# ==========================================
# Install Go
# ==========================================

if command -v go >/dev/null 2>&1; then
  info "Go уже установлен: $(go version)"
else
  info "Установка Go ${GO_VERSION}..."

  cd /tmp

  wget -q "$GO_URL"

  rm -rf /usr/local/go

  tar -C /usr/local -xzf "$GO_ARCHIVE"

  export PATH="$PATH:/usr/local/go/bin"

  if ! grep -q "/usr/local/go/bin" /root/.profile; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.profile
  fi
fi

export PATH="$PATH:/usr/local/go/bin:/root/go/bin"

# ==========================================
# Install xcaddy
# ==========================================

if command -v xcaddy >/dev/null 2>&1; then
  info "xcaddy уже установлен"
else
  info "Установка xcaddy..."
  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
fi

if ! command -v xcaddy >/dev/null 2>&1; then
  error "xcaddy не установлен"
  exit 1
fi

# ==========================================
# TMP dir
# ==========================================

create_dir /root/tmp

export TMPDIR=/root/tmp

# ==========================================
# Build Caddy
# ==========================================

info "Сборка Caddy..."

cd /tmp

xcaddy build \
  --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive

if [[ ! -f "/tmp/caddy" ]]; then
  error "Caddy не собрался"
  exit 1
fi

# ==========================================
# Generate credentials
# ==========================================

info "Генерация логина и пароля..."

if [[ -z "${USER_NAME}" ]]; then
  USER_NAME=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 12)
fi

if [[ -z "${USER_PASS}" ]]; then
  USER_PASS=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 16)
fi

info "Логин: $USER_NAME"
info "Пароль: $USER_PASS"

# ==========================================
# Create config
# ==========================================

create_dir /etc/caddy

backup_file /etc/caddy/Caddyfile

info "Создание Caddyfile..."

cat <<EOF > /etc/caddy/Caddyfile
:443, $DOMAIN

tls $EMAIL

route {
  forward_proxy {
    basic_auth $USER_NAME $USER_PASS
    hide_ip
    hide_via
    probe_resistance
  }

  reverse_proxy $FAKE_SITE {
    header_up Host {upstream_hostport}
    header_up X-Forwarded-Host {host}
  }
}
EOF

# ==========================================
# Install binary
# ==========================================

info "Установка Caddy..."

mv /tmp/caddy /usr/bin/caddy

chmod +x /usr/bin/caddy

# ==========================================
# Validate config
# ==========================================

info "Проверка конфигурации..."

/usr/bin/caddy validate --config /etc/caddy/Caddyfile

# ==========================================
# Systemd service
# ==========================================

backup_file /etc/systemd/system/caddy.service

info "Создание systemd сервиса..."

cat <<EOF > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy with NaiveProxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify

ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force

Restart=always
RestartSec=5s

LimitNOFILE=1048576

AmbientCapabilities=CAP_NET_BIND_SERVICE

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# ==========================================
# Enable service
# ==========================================

info "Запуск сервиса..."

systemctl daemon-reload
systemctl enable --now caddy

# ==========================================
# Check service
# ==========================================

sleep 2

if systemctl is-active --quiet caddy; then
  info "Caddy успешно запущен"
else
  error "Caddy не запустился"
  journalctl -u caddy --no-pager -n 50
  exit 1
fi

# ==========================================
# Install WARP
# ==========================================

if [[ "$INSTALL_WARP" == true ]]; then

  info "Установка Cloudflare WARP..."

  if command -v warp-cli >/dev/null 2>&1; then
    info "WARP уже установлен"
  else

    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
      | gpg --yes --dearmor \
      --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/cloudflare-client.list

    apt update

    apt install -y cloudflare-warp
  fi

  warp-cli registration new || true
  warp-cli mode proxy || true
  warp-cli connect || true

  warn "При использовании WARP настройте outbound proxy вручную"
fi

# ==========================================
# Done
# ==========================================

echo ""
echo "========================================"
echo "ГОТОВО 🚀"
echo "========================================"

echo ""
echo "Домен:"
echo "https://$DOMAIN"

echo ""
echo "Логин:"
echo "$USER_NAME"

echo ""
echo "Пароль:"
echo "$USER_PASS"

echo ""
echo "Конфиг клиента:"
echo ""

cat <<EOF
{
  "listen": "socks://127.0.0.1:20808",
  "proxy": "https://$USER_NAME:$USER_PASS@$DOMAIN"
}
EOF

echo ""
echo "========================================"
echo "Лог файл:"
echo "$LOG_FILE"
echo "========================================"
