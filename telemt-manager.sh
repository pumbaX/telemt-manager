#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

TLS_DOMAIN="${TLS_DOMAIN:-www.gosuslugi.ru}"
PROXY_PORT="${PROXY_PORT:-443}"
API_PORT="${API_PORT:-9091}"
USERNAME="${PROXY_USER:-tguser}"

[[ $EUID -ne 0 ]] && { error "Запусти от root"; exit 1; }

# ==============================
# УСТАНОВКА
# ==============================
do_install() {
    if systemctl is-active --quiet telemt 2>/dev/null; then
        warn "Telemt уже запущен. Сначала удали (пункт 3)."
        return
    fi

    local TLS_DOMAIN="$TLS_DOMAIN"
    local PROXY_PORT="$PROXY_PORT"
    local SECRET
    SECRET=$(openssl rand -hex 16)

    # --- Выбор домена маскировки ---
    echo ""
    echo -e "${CYAN}Домены маскировки (TLS):${NC}"
    echo "  --- Госсервисы ---"
    echo "  1.  www.gosuslugi.ru     (по умолчанию)"
    echo "  --- Банки ---"
    echo "  2.  www.sberbank.ru"
    echo "  3.  www.tinkoff.ru"
    echo "  4.  www.vtb.ru"
    echo "  --- Магазины ---"
    echo "  5.  www.ozon.ru"
    echo "  6.  www.wildberries.ru"
    echo "  --- Видео ---"
    echo "  7.  www.ivi.ru"
    echo "  8.  okko.tv"
    echo "  9.  www.kion.ru"
    echo "  10. wink.ru"
    echo "  11. www.kinopoisk.ru"
    echo "  --- Своё ---"
    echo "  12. Свой домен"
    echo -ne " Выбор [1-12]: "
    read -r domain_choice
    case $domain_choice in
        2)  TLS_DOMAIN="www.sberbank.ru" ;;
        3)  TLS_DOMAIN="www.tinkoff.ru" ;;
        4)  TLS_DOMAIN="www.vtb.ru" ;;
        5)  TLS_DOMAIN="www.ozon.ru" ;;
        6)  TLS_DOMAIN="www.wildberries.ru" ;;
        7)  TLS_DOMAIN="www.ivi.ru" ;;
        8)  TLS_DOMAIN="okko.tv" ;;
        9)  TLS_DOMAIN="www.kion.ru" ;;
        10) TLS_DOMAIN="wink.ru" ;;
        11) TLS_DOMAIN="www.kinopoisk.ru" ;;
        12)
            echo -ne " Введи домен (например: example.ru): "
            read -r custom_domain
            [[ -z "$custom_domain" ]] && { error "Домен не может быть пустым"; return; }
            TLS_DOMAIN="$custom_domain"
            ;;
        *)  TLS_DOMAIN="www.gosuslugi.ru" ;;
    esac
    info "Домен маскировки: ${TLS_DOMAIN}"

    # --- Автовыбор порта ---
    echo ""
    local PORT_CANDIDATES=(443 8443 2053 2083 2087 8080)
    local SUGGESTED_PORT=""
    for p in "${PORT_CANDIDATES[@]}"; do
        if ! ss -tlnp 2>/dev/null | grep -q ":${p} "; then
            SUGGESTED_PORT="$p"
            break
        fi
    done

    if [[ -n "$SUGGESTED_PORT" ]]; then
        echo -e "${CYAN}Занятые порты:${NC}"
        for p in "${PORT_CANDIDATES[@]}"; do
            if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
                echo "  ✗ $p — занят"
            else
                echo "  ✓ $p — свободен"
            fi
        done
        echo ""
        echo -ne " Использовать порт ${SUGGESTED_PORT}? [Enter = да / введи другой]: "
        read -r port_input
        if [[ -z "$port_input" ]]; then
            PROXY_PORT="$SUGGESTED_PORT"
        elif [[ "$port_input" =~ ^[0-9]+$ ]] && (( port_input >= 1 && port_input <= 65535 )); then
            PROXY_PORT="$port_input"
        else
            error "Некорректный порт: $port_input"
            return
        fi
    else
        echo -ne " Все стандартные порты заняты. Введи порт вручную: "
        read -r port_input
        if [[ "$port_input" =~ ^[0-9]+$ ]] && (( port_input >= 1 && port_input <= 65535 )); then
            PROXY_PORT="$port_input"
        else
            error "Некорректный порт: $port_input"
            return
        fi
    fi
    info "Порт прокси: ${PROXY_PORT}"

    info "Устанавливаю зависимости..."
    apt-get update -qq
    apt-get install -y -qq curl jq openssl

    info "Определяю архитектуру и libc..."
    local ARCH LIBC BINARY_URL
    ARCH=$(uname -m)
    # Определяем libc как в официальном install.sh
    LIBC="gnu"
    for f in /lib/ld-musl-*.so.* /lib64/ld-musl-*.so.*; do
        [ -e "$f" ] && { LIBC="musl"; break; }
    done
    grep -qE '^ID="?alpine"?' /etc/os-release 2>/dev/null && LIBC="musl"
    ldd --version 2>&1 | grep -qi musl && LIBC="musl"
    BINARY_URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz"

    info "Скачиваю бинарь..."
    if ! curl -fsSL "$BINARY_URL" -o /tmp/telemt.tar.gz; then
        error "Не удалось скачать бинарь: $BINARY_URL"
        return
    fi
    tar -xz -C /tmp -f /tmp/telemt.tar.gz
    rm -f /tmp/telemt.tar.gz
    local EXTRACTED_TELEMT
    EXTRACTED_TELEMT=$(find /tmp -maxdepth 1 -name "telemt*" -type f ! -name "*.tar.gz" | head -1)
    [[ -z "$EXTRACTED_TELEMT" ]] && { error "Бинарь не найден после распаковки"; return; }
    install -m 755 "$EXTRACTED_TELEMT" /usr/local/bin/telemt
    rm -f "$EXTRACTED_TELEMT"
    # setcap для работы на порту <1024 без root (предпочтительно над AmbientCapabilities)
    if command -v setcap &>/dev/null; then
        setcap cap_net_bind_service=+ep /usr/local/bin/telemt 2>/dev/null || true
    fi

    info "Получаю публичный IP..."
    local PUBLIC_IP
    PUBLIC_IP=$(curl -s -4 --max-time 10 ifconfig.me)
    [[ -z "$PUBLIC_IP" ]] && { error "Не удалось определить публичный IP"; return; }

    info "Создаю конфиг..."
    mkdir -p /etc/telemt
    cat > /etc/telemt/telemt.toml <<EOF
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[general.links]
public_host = "${PUBLIC_IP}"

[server]
port = ${PROXY_PORT}

[server.api]
enabled = true
listen = "127.0.0.1:${API_PORT}"
whitelist = ["127.0.0.1/32"]

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
tls_emulation = true

[access.users]
${USERNAME} = "${SECRET}"
EOF

    info "Создаю пользователя telemt..."
    if ! getent group telemt &>/dev/null; then
        groupadd -r telemt
    fi
    if ! id telemt &>/dev/null; then
        useradd -r -g telemt -d /opt/telemt -s /bin/false -c "Telemt Proxy" telemt
        mkdir -p /opt/telemt
        chown telemt:telemt /opt/telemt
        chmod 750 /opt/telemt
    fi
    chown root:telemt /etc/telemt
    chmod 770 /etc/telemt
    chown root:telemt /etc/telemt/telemt.toml
    chmod 660 /etc/telemt/telemt.toml

    info "Создаю systemd unit..."
    cat > /etc/systemd/system/telemt.service <<EOF
[Unit]
Description=Telemt MTProto Proxy
After=multi-user.target network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now telemt

    # --- UFW ---
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        info "Открываю порт ${PROXY_PORT}/tcp в UFW..."
        ufw allow "${PROXY_PORT}/tcp" comment "Telemt MTProto" >/dev/null
    else
        warn "UFW не активен — порт ${PROXY_PORT} открой вручную"
    fi

    info "Жду запуск..."
    sleep 5

    if ! systemctl is-active --quiet telemt; then
        error "Сервис не запустился. Проверь: journalctl -u telemt -n 30"
        return
    fi

    LINK=$(curl -s "http://127.0.0.1:${API_PORT}/v1/users" \
        | jq -r '.data[0].links.tls[] | select(test("server=[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))' \
        2>/dev/null | head -1 || true)

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Telemt установлен и запущен!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e " Порт:      ${PROXY_PORT}"
    echo -e " TLS домен: ${TLS_DOMAIN}"
    echo -e " Пользов.:  ${USERNAME}"
    echo -e " Секрет:    ${SECRET}"
    echo ""
    if [[ -n "$LINK" ]]; then
        echo -e " Ссылка TG: ${GREEN}${LINK}${NC}"
    else
        warn "Получи ссылку вручную (пункт 2)"
    fi
    echo ""
}

# ==============================
# ССЫЛКИ КЛИЕНТОВ
# ==============================
do_links() {
    if ! systemctl is-active --quiet telemt 2>/dev/null; then
        error "Telemt не запущен."
        return
    fi

    RAW=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/users" 2>/dev/null)
    if [[ -z "$RAW" ]] || ! echo "$RAW" | jq -e '.ok' &>/dev/null; then
        error "API не ответил. Проверь: systemctl status telemt"
        return
    fi

    echo ""
    echo -e "${CYAN}======= Ссылки клиентов (IPv4) =======${NC}"
    echo "$RAW" | jq -r '.data[] |
        "  [" + .username + "]",
        (.links.tls[] | select(test("server=[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))),
        ""' 2>/dev/null

    # --- Общая статистика сервера ---
    local SUMMARY
    SUMMARY=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/stats/summary" 2>/dev/null)
    if echo "$SUMMARY" | jq -e '.ok' &>/dev/null; then
        local UPTIME TOTAL BAD
        UPTIME=$(echo "$SUMMARY" | jq -r '.data.uptime_seconds | floor | tostring + " сек"')
        TOTAL=$(echo "$SUMMARY" | jq -r '.data.connections_total | tostring')
        BAD=$(echo "$SUMMARY" | jq -r '.data.connections_bad_total | tostring')
        echo -e "${CYAN}======= Сервер =======${NC}"
        echo "  uptime: ${UPTIME} | всего подключений: ${TOTAL} | плохих: ${BAD}"
        echo ""
    fi

    echo -e "${CYAN}======= Статистика =======${NC}"
    echo "$RAW" | jq -r '.data[] |
        "  " + .username +
        " | онлайн: " + (.current_connections|tostring) +
        " | за 24ч IP: " + (.recent_unique_ips|tostring) +
        " | трафик: " + ((.total_octets / 1048576 * 100 | round) / 100 | tostring) + " MB"' \
        2>/dev/null
    echo ""
}

# ==============================
# ПОЛНОЕ УДАЛЕНИЕ
# ==============================
do_remove() {
    echo -ne "${RED}Удалить telemt полностью? [y/N]: ${NC}"
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }

    # Читаем порт ДО удаления конфига
    local OLD_PORT
    OLD_PORT=$(grep -E "^port\s*=" /etc/telemt/telemt.toml 2>/dev/null | head -1 | awk -F= '{print $2}' | tr -d ' ')

    info "Останавливаю сервис..."
    systemctl stop telemt 2>/dev/null || true
    systemctl disable telemt 2>/dev/null || true

    info "Удаляю файлы..."
    rm -f /etc/systemd/system/telemt.service
    rm -rf /etc/telemt
    rm -f /usr/local/bin/telemt

    info "Удаляю пользователя..."
    userdel -r telemt 2>/dev/null || true
    groupdel telemt 2>/dev/null || true

    # --- Отключаем автообновление если активно ---
    if crontab -l 2>/dev/null | grep -q "telemt-autoupdate"; then
        info "Отключаю автообновление..."
        crontab -l 2>/dev/null | grep -v "telemt-autoupdate" | crontab -
        rm -f /usr/local/bin/telemt-autoupdate.sh
    fi

    systemctl daemon-reload

    # --- UFW: закрываем порт ---
    if [[ -n "$OLD_PORT" ]] && command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        info "Закрываю порт ${OLD_PORT}/tcp в UFW..."
        ufw delete allow "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}[+] Telemt полностью удалён.${NC}"
}


# ==============================
# ПОЛНОЕ УДАЛЕНИЕ ПАНЕЛИ
# ==============================
do_remove_panel() {
    echo -ne "${RED}Удалить панель полностью? [y/N]: ${NC}"
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }

    # Читаем порт ДО удаления конфига
    local OLD_PORT
    OLD_PORT=$(grep -E '^listen[[:space:]]*=' /etc/telemt-panel/config.toml 2>/dev/null | head -1 | grep -oE '[0-9]+$')

    info "Останавливаю панель..."
    systemctl stop telemt-panel 2>/dev/null || true
    systemctl disable telemt-panel 2>/dev/null || true

    info "Удаляю файлы..."
    rm -f /etc/systemd/system/telemt-panel.service
    rm -rf /etc/telemt-panel
    rm -f /usr/local/bin/telemt-panel

    systemctl daemon-reload

    # --- UFW: закрываем порт ---
    if [[ -n "$OLD_PORT" ]] && command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        info "Закрываю порт ${OLD_PORT}/tcp в UFW..."
        ufw delete allow "${OLD_PORT}/tcp" >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}[+] Панель полностью удалена.${NC}"
}

# ==============================
# ДОБАВИТЬ КЛИЕНТА
# ==============================
do_add_client() {
    if ! systemctl is-active --quiet telemt 2>/dev/null; then
        error "Telemt не запущен."
        return
    fi

    echo -ne " Имя клиента [A-Za-z0-9_.-]: "
    read -r new_user
    [[ -z "$new_user" ]] && { error "Имя не может быть пустым"; return; }
    if [[ ! "$new_user" =~ ^[A-Za-z0-9_.-]+$ ]] || (( ${#new_user} > 64 )); then
        error "Допустимы только A-Za-z0-9_.- длиной до 64 символов"
        return
    fi

    # Создаём через API — секрет генерируется сервером автоматически
    local RESP
    RESP=$(curl -s --max-time 5 -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${new_user}\"}" \
        "http://127.0.0.1:${API_PORT}/v1/users")

    # Проверяем ответ
    if ! echo "$RESP" | jq -e '.ok' &>/dev/null; then
        local ERR
        ERR=$(echo "$RESP" | jq -r '.error.message // "неизвестная ошибка"' 2>/dev/null)
        error "Ошибка API: ${ERR}"
        return
    fi

    local NEW_SECRET LINK
    NEW_SECRET=$(echo "$RESP" | jq -r '.data.secret // empty')
    LINK=$(echo "$RESP" | jq -r '.data.user.links.tls[] | select(test("server=[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))' \
        2>/dev/null | head -1)

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Клиент добавлен!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e " Имя:    ${new_user}"
    [[ -n "$NEW_SECRET" ]] && echo -e " Секрет: ${NEW_SECRET}"
    echo ""
    if [[ -n "$LINK" ]]; then
        echo -e " Ссылка TG:"
        echo -e " ${GREEN}${LINK}${NC}"
    else
        warn "Ссылка не получена — проверь пункт 2"
    fi
    echo ""
}

# ==============================
# УДАЛИТЬ КЛИЕНТА
# ==============================
do_del_client() {
    if ! systemctl is-active --quiet telemt 2>/dev/null; then
        error "Telemt не запущен."
        return
    fi

    # Показываем список
    echo ""
    echo -e "${CYAN}Текущие клиенты:${NC}"
    local USERS_RAW
    USERS_RAW=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/users" 2>/dev/null)
    if ! echo "$USERS_RAW" | jq -e '.ok' &>/dev/null; then
        error "API не ответил"
        return
    fi
    echo "$USERS_RAW" | jq -r '.data[].username' 2>/dev/null | sed 's/^/  /'
    echo ""

    echo -ne " Имя клиента для удаления: "
    read -r del_user
    [[ -z "$del_user" ]] && { error "Имя не может быть пустым"; return; }

    echo -ne "${RED}Удалить '${del_user}'? [y/N]: ${NC}"
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }

    local RESP
    RESP=$(curl -s --max-time 5 -X DELETE \
        "http://127.0.0.1:${API_PORT}/v1/users/${del_user}")

    if echo "$RESP" | jq -e '.ok' &>/dev/null; then
        info "Клиент '${del_user}' удалён."
    else
        local ERR
        ERR=$(echo "$RESP" | jq -r '.error.message // "неизвестная ошибка"' 2>/dev/null)
        error "Ошибка API: ${ERR}"
    fi
}


# ==============================
# УСТАНОВКА ПАНЕЛИ
# ==============================
do_install_panel() {
    if systemctl is-active --quiet telemt-panel 2>/dev/null; then
        warn "Панель уже запущена."
        return
    fi

    echo ""
    echo -ne " Порт панели [по умолчанию 8080]: "
    read -r panel_port_input
    local PANEL_PORT="${panel_port_input:-8080}"
    if ! [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || (( PANEL_PORT < 1 || PANEL_PORT > 65535 )); then
        error "Некорректный порт: $PANEL_PORT"
        return
    fi

    echo -ne " Логин администратора [по умолчанию admin]: "
    read -r panel_user_input
    local PANEL_USER="${panel_user_input:-admin}"

    echo -ne " Пароль администратора: "
    read -rs panel_pass
    echo ""
    [[ -z "$panel_pass" ]] && { error "Пароль не может быть пустым"; return; }

    info "Генерирую bcrypt хеш пароля..."
    pip install bcrypt --break-system-packages -q 2>/dev/null || true
    local PASS_HASH
    PASS_HASH=$(printf '%s' "${panel_pass}" | python3 -c "
import bcrypt, sys
pw = sys.stdin.read().encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt(10)).decode())
")
    [[ -z "$PASS_HASH" ]] && { error "Не удалось сгенерировать хеш пароля"; return; }

    local JWT_SECRET
    JWT_SECRET=$(openssl rand -hex 32)

    info "Устанавливаю зависимости..."
    apt-get update -qq
    apt-get install -y -qq curl jq

    info "Определяю архитектуру..."
    local ARCH
    ARCH=$(uname -m)
    local ARCH_SUFFIX
    case "$ARCH" in
        x86_64)  ARCH_SUFFIX="x86_64" ;;
        aarch64) ARCH_SUFFIX="aarch64" ;;
        *) error "Неподдерживаемая архитектура: $ARCH"; return ;;
    esac
    local BINARY_NAME="telemt-panel-${ARCH_SUFFIX}-linux-gnu.tar.gz"

    info "Получаю последний релиз панели..."
    local DOWNLOAD_URL
    DOWNLOAD_URL=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest"         | jq -r ".assets[] | select(.name == \"${BINARY_NAME}\") | .browser_download_url")
    [[ -z "$DOWNLOAD_URL" ]] && { error "Не удалось найти бинарь в релизе"; return; }

    info "Скачиваю: $DOWNLOAD_URL"
    if ! curl -fsSL "$DOWNLOAD_URL" -o /tmp/telemt-panel.tar.gz; then
        error "Не удалось скачать архив"
        return
    fi
    tar -xz -C /tmp -f /tmp/telemt-panel.tar.gz
    rm -f /tmp/telemt-panel.tar.gz
    local EXTRACTED_BIN
    EXTRACTED_BIN=$(find /tmp -maxdepth 1 -name "telemt-panel-*-linux" -type f | head -1)
    [[ -z "$EXTRACTED_BIN" ]] && { error "Бинарь не найден после распаковки"; return; }
    install -m 755 "$EXTRACTED_BIN" /usr/local/bin/telemt-panel
    rm -f "$EXTRACTED_BIN"

    info "Генерирую самоподписанный TLS сертификат..."
    mkdir -p /etc/telemt-panel/tls
    local PUBLIC_IP
    PUBLIC_IP=$(curl -s -4 --max-time 10 ifconfig.me)
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /etc/telemt-panel/tls/key.pem \
        -out    /etc/telemt-panel/tls/cert.pem \
        -subj   "/CN=${PUBLIC_IP}" \
        -addext "subjectAltName=IP:${PUBLIC_IP}" \
        2>/dev/null
    chmod 600 /etc/telemt-panel/tls/key.pem
    chmod 644 /etc/telemt-panel/tls/cert.pem

    info "Создаю конфиг панели..."
    mkdir -p /etc/telemt-panel
    cat > /etc/telemt-panel/config.toml <<EOF
listen = "0.0.0.0:${PANEL_PORT}"

[telemt]
url = "http://127.0.0.1:${API_PORT}"
auth_header = ""
binary_path = "/usr/local/bin/telemt"
service_name = "telemt"
github_repo = "telemt/telemt"

[panel]
binary_path = "/usr/local/bin/telemt-panel"
service_name = "telemt-panel"
github_repo = "amirotin/telemt_panel"

[auth]
username = "${PANEL_USER}"
password_hash = "${PASS_HASH}"
jwt_secret = "${JWT_SECRET}"
session_ttl = "24h"

[tls]
cert_file = "/etc/telemt-panel/tls/cert.pem"
key_file  = "/etc/telemt-panel/tls/key.pem"
EOF
    chmod 600 /etc/telemt-panel/config.toml

    info "Создаю systemd unit..."
    cat > /etc/systemd/system/telemt-panel.service <<EOF
[Unit]
Description=Telemt Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/telemt-panel --config /etc/telemt-panel/config.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now telemt-panel

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        info "Открываю порт ${PANEL_PORT}/tcp в UFW..."
        ufw allow "${PANEL_PORT}/tcp" comment "Telemt Panel" >/dev/null
    else
        warn "UFW не активен — порт ${PANEL_PORT} открой вручную"
    fi

    info "Жду запуск..."
    sleep 3

    if ! systemctl is-active --quiet telemt-panel; then
        error "Панель не запустилась. Проверь: journalctl -u telemt-panel -n 30"
        return
    fi

    PUBLIC_IP=$(curl -s -4 --max-time 10 ifconfig.me)

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Telemt Panel установлена!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e " URL:    ${GREEN}https://${PUBLIC_IP}:${PANEL_PORT}${NC}"
    echo -e " Логин:  ${PANEL_USER}"
    echo ""
}

# ==============================
# ВСПОМОГАТЕЛЬНАЯ: установка бинаря telemt
# $1 = версия (например "3.3.29") или "latest"
# ==============================
_install_telemt_binary() {
    local VERSION="$1"
    local ARCH LIBC
    ARCH=$(uname -m)
    LIBC="gnu"
    for f in /lib/ld-musl-*.so.* /lib64/ld-musl-*.so.*; do
        [ -e "$f" ] && { LIBC="musl"; break; }
    done
    grep -qE '^ID="?alpine"?' /etc/os-release 2>/dev/null && LIBC="musl"
    ldd --version 2>&1 | grep -qi musl && LIBC="musl"

    local BINARY_URL
    if [[ "$VERSION" == "latest" ]]; then
        BINARY_URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz"
    else
        BINARY_URL="https://github.com/telemt/telemt/releases/download/${VERSION}/telemt-${ARCH}-linux-${LIBC}.tar.gz"
    fi

    info "Скачиваю: $BINARY_URL"
    if ! curl -fsSL "$BINARY_URL" -o /tmp/telemt.tar.gz; then
        error "Не удалось скачать бинарь"
        return 1
    fi
    tar -xz -C /tmp -f /tmp/telemt.tar.gz
    rm -f /tmp/telemt.tar.gz

    # Ищем бинарь — имя может отличаться (telemt или telemt-x86_64-unknown-linux-gnu)
    local EXTRACTED
    EXTRACTED=$(find /tmp -maxdepth 1 -name "telemt*" -type f ! -name "*.tar.gz" | head -1)
    [[ -z "$EXTRACTED" ]] && { error "Бинарь не найден после распаковки"; return 1; }

    info "Останавливаю сервис..."
    systemctl stop telemt 2>/dev/null || true
    install -m 755 "$EXTRACTED" /usr/local/bin/telemt
    rm -f "$EXTRACTED"
    if command -v setcap &>/dev/null; then
        setcap cap_net_bind_service=+ep /usr/local/bin/telemt 2>/dev/null || true
    fi

    info "Запускаю сервис..."
    systemctl start telemt
    sleep 3

    if systemctl is-active --quiet telemt; then
        return 0
    else
        error "Сервис не запустился. Проверь: journalctl -u telemt -n 30"
        return 1
    fi
}

# ==============================
# ОБНОВЛЕНИЕ TELEMT
# ==============================
do_update_telemt() {
    local CURRENT
    CURRENT=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/system/info"         | jq -r '.data.version // "unknown"' 2>/dev/null)
    local LATEST
    LATEST=$(curl -s --max-time 10 "https://api.github.com/repos/telemt/telemt/releases/latest"         | jq -r '.tag_name // "unknown"' | tr -d 'v')

    echo ""
    echo -e " Установлена: ${CYAN}${CURRENT}${NC}"
    echo -e " Последняя стабильная: ${CYAN}${LATEST}${NC}"
    echo ""
    echo "  1. Обновить до последней стабильной (${LATEST})"
    echo "  2. Установить конкретную версию (pre-release)"
    echo "  0. Назад"
    echo -ne " Выбор: "
    read -r upd_choice

    case $upd_choice in
        1)
            if [[ "$CURRENT" == "$LATEST" ]]; then
                info "Уже установлена последняя стабильная версия."
                return
            fi
            echo -ne " Обновить до ${LATEST}? [y/N]: "
            read -r confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
            if _install_telemt_binary "latest"; then
                info "Telemt обновлён до ${LATEST} ✓"
            fi
            ;;
        2)
            echo ""
            info "Ищу последний pre-release..."
            local PRERELEASE
            PRERELEASE=$(curl -s --max-time 10                 "https://api.github.com/repos/telemt/telemt/releases?per_page=10"                 | jq -r '[.[] | select(.prerelease == true)] | first | .tag_name // ""'                 | tr -d 'v')

            if [[ -n "$PRERELEASE" ]]; then
                echo -e " Последний pre-release: ${YELLOW}${PRERELEASE}${NC}"
            else
                warn "Pre-release не найден"
            fi
            echo ""
            echo -e " Доступные релизы: ${CYAN}https://github.com/telemt/telemt/releases${NC}"
            echo -ne " Введи версию [Enter = ${PRERELEASE:-вручную}]: "
            read -r custom_ver
            # Если Enter — берём последний pre-release
            [[ -z "$custom_ver" && -n "$PRERELEASE" ]] && custom_ver="$PRERELEASE"
            [[ -z "$custom_ver" ]] && { error "Версия не может быть пустой"; return; }
            # Убираем префикс v если есть
            custom_ver="${custom_ver#v}"
            echo -ne " Установить версию ${custom_ver}? [y/N]: "
            read -r confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
            if _install_telemt_binary "${custom_ver}"; then
                info "Telemt ${custom_ver} установлен ✓"
            fi
            ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
}

# ==============================
# ОБНОВЛЕНИЕ ПАНЕЛИ
# ==============================
do_update_panel() {
    if ! command -v telemt-panel &>/dev/null && [[ ! -f /usr/local/bin/telemt-panel ]]; then
        error "Панель не установлена."
        return
    fi

    info "Проверяю последний релиз панели..."
    local ARCH ARCH_SUFFIX
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH_SUFFIX="x86_64" ;;
        aarch64) ARCH_SUFFIX="aarch64" ;;
        *) error "Неподдерживаемая архитектура: $ARCH"; return ;;
    esac
    local BINARY_NAME="telemt-panel-${ARCH_SUFFIX}-linux-gnu.tar.gz"

    local LATEST
    LATEST=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest"         | jq -r '.tag_name // "unknown"')
    echo -e " Последняя версия панели: ${CYAN}${LATEST}${NC}"
    echo ""

    echo -ne " Обновить панель до ${LATEST}? [y/N]: "
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }

    local DOWNLOAD_URL
    DOWNLOAD_URL=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest"         | jq -r ".assets[] | select(.name == \"${BINARY_NAME}\") | .browser_download_url")
    [[ -z "$DOWNLOAD_URL" ]] && { error "Не удалось найти бинарь в релизе"; return; }

    info "Скачиваю: $DOWNLOAD_URL"
    if ! curl -fsSL "$DOWNLOAD_URL" -o /tmp/telemt-panel.tar.gz; then
        error "Не удалось скачать архив"
        return
    fi
    tar -xz -C /tmp -f /tmp/telemt-panel.tar.gz
    rm -f /tmp/telemt-panel.tar.gz
    local EXTRACTED_BIN
    EXTRACTED_BIN=$(find /tmp -maxdepth 1 -name "telemt-panel-*-linux" -type f | head -1)
    [[ -z "$EXTRACTED_BIN" ]] && { error "Бинарь не найден после распаковки"; return; }

    info "Останавливаю панель..."
    systemctl stop telemt-panel 2>/dev/null || true
    install -m 755 "$EXTRACTED_BIN" /usr/local/bin/telemt-panel
    rm -f "$EXTRACTED_BIN"

    info "Запускаю обновлённую панель..."
    systemctl start telemt-panel
    sleep 3

    if systemctl is-active --quiet telemt-panel; then
        info "Панель обновлена до ${LATEST} ✓"
    else
        error "Панель не запустилась. Проверь: journalctl -u telemt-panel -n 30"
    fi
}


# ==============================
# АВТООБНОВЛЕНИЕ
# ==============================
do_autoupdate() {
    local CRON_JOB="0 */3 * * * /usr/local/bin/telemt-autoupdate.sh"
    local SCRIPT="/usr/local/bin/telemt-autoupdate.sh"
    local IS_ENABLED=false

    crontab -l 2>/dev/null | grep -q "telemt-autoupdate" && IS_ENABLED=true

    echo ""
    if $IS_ENABLED; then
        echo -e " Автообновление: ${GREEN}ВКЛЮЧЕНО${NC} (каждые 3 часа)"
    else
        echo -e " Автообновление: ${RED}ВЫКЛЮЧЕНО${NC}"
    fi
    echo ""
    echo "  1. Включить автообновление"
    echo "  2. Выключить автообновление"
    echo "  3. Показать лог обновлений"
    echo "  0. Назад"
    echo -ne " Выбор: "
    read -r au_choice

    case $au_choice in
        1)
            # Создаём скрипт автообновления
            cat > "$SCRIPT" << 'AUTOUPDATE'
#!/bin/bash
API_PORT="9091"
LOG="/var/log/telemt-autoupdate.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

# === Обновление Telemt ===
if systemctl is-active --quiet telemt 2>/dev/null; then
    CURRENT=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/system/info" | jq -r '.data.version // ""')
    LATEST=$(curl -s --max-time 10 "https://api.github.com/repos/telemt/telemt/releases/latest" | jq -r '.tag_name // ""' | tr -d 'v')
    if [[ -n "$CURRENT" && -n "$LATEST" && "$CURRENT" != "$LATEST" ]]; then
        log "Telemt: обновление $CURRENT -> $LATEST"
        ARCH=$(uname -m); LIBC="gnu"
        for f in /lib/ld-musl-*.so.* /lib64/ld-musl-*.so.*; do [ -e "$f" ] && { LIBC="musl"; break; }; done
        curl -fsSL "https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz" -o /tmp/telemt.tar.gz
        tar -xz -C /tmp -f /tmp/telemt.tar.gz && rm -f /tmp/telemt.tar.gz
        EXT=$(find /tmp -maxdepth 1 -name "telemt*" -type f ! -name "*.tar.gz" | head -1)
        if [[ -n "$EXT" ]]; then
            systemctl stop telemt
            install -m 755 "$EXT" /usr/local/bin/telemt && rm -f "$EXT"
            command -v setcap &>/dev/null && setcap cap_net_bind_service=+ep /usr/local/bin/telemt 2>/dev/null
            systemctl start telemt
            log "Telemt: обновлён до $LATEST"
        fi
    else
        log "Telemt: актуальная версия $CURRENT"
    fi
fi

# === Обновление панели ===
if [[ -f /usr/local/bin/telemt-panel ]]; then
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) AS="x86_64" ;; aarch64) AS="aarch64" ;; *) exit 1 ;; esac
    BN="telemt-panel-${AS}-linux-gnu.tar.gz"
    LATEST_P=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest" | jq -r '.tag_name // ""')
    CURRENT_P=$(/usr/local/bin/telemt-panel version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$LATEST_P" && "v${CURRENT_P}" != "$LATEST_P" ]]; then
        log "Panel: updating -> $LATEST_P"
        DL=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest" \
            | jq -r --arg bn "$BN" '.assets[] | select(.name == $bn) | .browser_download_url')
        if [[ -n "$DL" ]]; then
            curl -fsSL "$DL" -o /tmp/telemt-panel.tar.gz
            tar -xz -C /tmp -f /tmp/telemt-panel.tar.gz && rm -f /tmp/telemt-panel.tar.gz
            EX=$(find /tmp -maxdepth 1 -name "telemt-panel-*-linux" -type f | head -1)
            if [[ -n "$EX" ]]; then
                systemctl stop telemt-panel
                install -m 755 "$EX" /usr/local/bin/telemt-panel && rm -f "$EX"
                systemctl start telemt-panel
                log "Panel: updated to $LATEST_P"
            fi
        fi
    else
        log "Panel: up to date"
    fi
fi
AUTOUPDATE
            chmod +x "$SCRIPT"
            # Добавляем в cron если ещё нет
            ( crontab -l 2>/dev/null | grep -v "telemt-autoupdate"; echo "$CRON_JOB" ) | crontab -
            info "Автообновление включено — каждые 3 часа"
            info "Логи: /var/log/telemt-autoupdate.log"
            ;;
        2)
            crontab -l 2>/dev/null | grep -v "telemt-autoupdate" | crontab -
            rm -f "$SCRIPT"
            info "Автообновление отключено"
            ;;
        3)
            if [[ -f /var/log/telemt-autoupdate.log ]]; then
                echo ""
                tail -30 /var/log/telemt-autoupdate.log
            else
                warn "Лог пустой — обновлений ещё не было"
            fi
            ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
}

# ==============================
# МЕНЮ
# ==============================
while true; do
    echo ""
    echo -e "${CYAN}╔══════════════════════════════╗${NC}"
    echo -e "${CYAN}║      TELEMT MANAGER          ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  --- Telemt ---               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  1. Установка                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  2. Ссылки / статистика      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  3. Добавить клиента         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  4. Удалить клиента          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  5. Обновить Telemt          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  6. Полное удаление          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  --- Панель ---               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  7. Установить панель        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  8. Обновить панель          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  9. Удалить панель           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  --- Система ---              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  10. Автообновление          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  0. Выход                    ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════╝${NC}"
    echo -ne " Выбор: "
    read -r choice

    case $choice in
        1) do_install ;;
        2) do_links ;;
        3) do_add_client ;;
        4) do_del_client ;;
        5) do_update_telemt ;;
        6) do_remove ;;
        7) do_install_panel ;;
        8) do_update_panel ;;
        9) do_remove_panel ;;
        10) do_autoupdate ;;
        0) exit 0 ;;
        *) warn "Неверный выбор" ;;
    esac
done
