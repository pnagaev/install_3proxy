#!/usr/bin/env bash

# Скрипт install_3proxy.sh для установки PROXY и SOCKS5 сервера в Docker
set -euo pipefail

#############################
# НАСТРОЙКИ (МЕНЯТЬ ЗДЕСЬ)
#############################
HTTP_PORT=58172
SOCKS_PORT=3129
PROXY_USER="myuser"

# Если пусто — пароль будет сгенерирован автоматически
PROXY_PASS=""
#############################

echo "⚠️  ВНИМАНИЕ!"
echo "- После установки УДАЛИТЕ строку PROXY_PASS из скрипта"
echo "- Пароль будет сохранён в 3proxy.cfg в зашифрованном виде"
echo "- Не храните пароль в скрипте!"
echo

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_DIR="/opt/3proxy"
CONF_DIR="${BASE_DIR}/conf"
LOG_DIR="${BASE_DIR}/logs"
CFG_FILE="${CONF_DIR}/3proxy.cfg"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
CONTAINER_NAME="3proxy"
IMAGE_NAME="3proxy/3proxy:latest"

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}Запусти через sudo${NC}"
        exit 1
    fi
    return 0
}

msg()  { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }

check_os() {
    msg "Проверка ОС..."
    command -v apt-get >/dev/null 2>&1 || { err "Скрипт рассчитан на Debian/Ubuntu"; exit 1; }
    ok "apt найден"
}

install_base() {
    msg "Установка базовых пакетов..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl openssl ufw iproute2
    ok "Базовые пакеты установлены"
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        ok "Docker уже установлен"
        systemctl enable --now docker >/dev/null 2>&1 || true
        return
    fi

    msg "Установка Docker..."

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "${VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    ok "Docker установлен"
}

check_docker_compose() {
    msg "Проверка docker compose..."
    docker compose version >/dev/null 2>&1 || { err "docker compose недоступен"; exit 1; }
    ok "docker compose доступен"
}

generate_password_if_needed() {
    if [[ -z "${PROXY_PASS}" ]]; then
        msg "Генерация безопасного пароля..."
        PROXY_PASS="$(openssl rand -base64 24 | tr -d '\n' | tr '/+=' 'ABC' | cut -c1-20)"
        ok "Пароль сгенерирован"
    else
        ok "Используется пароль из PROXY_PASS"
    fi
}

prepare_password_hash() {
    msg "Хэширование пароля..."
    HASHED_PASS="$(openssl passwd -1 "${PROXY_PASS}")"
    ok "Хэш пароля создан"
}

port_in_use() {
    local port="$1"
    ss -lnt "( sport = :${port} )" 2>/dev/null | grep -q LISTEN
}

check_ports() {
    msg "Проверка занятости портов..."

    if port_in_use "${HTTP_PORT}"; then
        err "Порт ${HTTP_PORT} занят"
        ss -lntp "( sport = :${HTTP_PORT} )" || true
        exit 1
    fi

    if port_in_use "${SOCKS_PORT}"; then
        err "Порт ${SOCKS_PORT} занят"
        ss -lntp "( sport = :${SOCKS_PORT} )" || true
        exit 1
    fi

    ok "Порты свободны"
}

prepare_dirs() {
    msg "Подготовка каталогов..."
    mkdir -p "${CONF_DIR}" "${LOG_DIR}"
    chmod 775 "${LOG_DIR}"
    ok "Каталоги готовы"
}

create_config() {
    msg "Создание ${CFG_FILE}..."
    cat > "${CFG_FILE}" <<EOF
log /logs/3proxy.log D
logformat "%d-%m-%Y %H:%M:%S %U %C:%c %R:%r %O %I %T"
rotate 30

timeouts 1 5 30 60 180 1800 15 60

nserver 1.0.0.1
nserver 1.1.1.1
nserver 8.8.8.8
nserver 8.8.4.4

nscache 65536

auth strong
users "${PROXY_USER}:CR:${HASHED_PASS}"

allow ${PROXY_USER}

proxy -p${HTTP_PORT}
socks -p${SOCKS_PORT}
flush
EOF
    chmod 640 "${CFG_FILE}"
    ok "Конфиг создан"
}

create_compose() {
    msg "Создание ${COMPOSE_FILE}..."
    cat > "${COMPOSE_FILE}" <<EOF
services:
  3proxy:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    volumes:
      - ${CONF_DIR}:/usr/local/3proxy/conf:ro
      - ${LOG_DIR}:/usr/local/3proxy/logs
    ports:
      - "${HTTP_PORT}:${HTTP_PORT}"
      - "${SOCKS_PORT}:${SOCKS_PORT}"
    restart: unless-stopped
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "HEX_PORT=\$(printf '%04X' ${HTTP_PORT}); grep -qi \":\$HEX_PORT\" /proc/net/tcp /proc/net/tcp6"
        ]
      interval: 15s
      timeout: 3s
      retries: 5
      start_period: 10s
EOF
    ok "docker-compose.yml создан"
}

pull_image() {
    msg "Загрузка образа ${IMAGE_NAME}..."
    docker pull "${IMAGE_NAME}"
    ok "Образ загружен"
}

run_container() {
    msg "Запуск контейнера..."
    docker compose -f "${COMPOSE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
    docker compose -f "${COMPOSE_FILE}" up -d
    ok "Контейнер запущен"
}

setup_ufw() {
    msg "Настройка UFW..."
    ufw allow "${HTTP_PORT}/tcp" >/dev/null
    ufw allow "${SOCKS_PORT}/tcp" >/dev/null
    ufw reload >/dev/null || true
    ok "UFW настроен"
}

wait_container() {
    msg "Проверка запуска контейнера..."
    sleep 3
    docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}" || {
        err "Контейнер не запустился"
        docker logs "${CONTAINER_NAME}" || true
        exit 1
    }
    ok "Контейнер работает"
}

show_info() {
    local ip
    ip="$(curl -4 -s ifconfig.me 2>/dev/null || echo "SERVER_IP")"

    echo
    echo -e "${GREEN}Готово${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "IP: ${ip}"
    echo "HTTP proxy port: ${HTTP_PORT}"
    echo "SOCKS proxy port: ${SOCKS_PORT}"
    echo "User: ${PROXY_USER}"
    echo "Pass: ${PROXY_PASS}"
    echo "3proxy config: ${CFG_FILE}"
    echo "Compose file: ${COMPOSE_FILE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Важно:"
    echo "- Удали строку PROXY_PASS из скрипта после установки"
    echo "- В конфиге 3proxy пароль уже сохранён в виде хэша"
    echo
    echo "Тест HTTP proxy:"
    echo "curl -x http://${PROXY_USER}:${PROXY_PASS}@${ip}:${HTTP_PORT} https://ifconfig.me"
    echo
    echo "Тест SOCKS5 proxy:"
    echo "curl --proxy socks5h://${PROXY_USER}:${PROXY_PASS}@${ip}:${SOCKS_PORT} https://ifconfig.me"
    echo -e "\n Ответ должен быть IP вашего сервера с 3proxy."
    
}

main() {
    need_root
    check_os
    install_base
    install_docker
    check_docker_compose
    generate_password_if_needed
    prepare_password_hash
    check_ports
    prepare_dirs
    create_config
    create_compose
    pull_image
    run_container
    setup_ufw
    wait_container
    show_info
}

main "$@"
