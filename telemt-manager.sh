#!/bin/bash
# telemt-manager.sh — менеджер установки и управления Telemt + Telemt Panel
# Совместимо с официальным install.sh из репозитория telemt/telemt

set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }

TLS_DOMAIN="${TLS_DOMAIN:-www.gosuslugi.ru}"
PROXY_PORT="${PROXY_PORT:-443}"
API_PORT="${API_PORT:-9091}"
USERNAME="${PROXY_USER:-tguser}"

# === Маркеры UFW (чтобы удалять только свои правила) ===
UFW_TAG_PROXY="TELEMT_MGR_PROXY"
UFW_TAG_PANEL="TELEMT_MGR_PANEL"

[[ $EUID -ne 0 ]] && { error "Запусти от root"; exit 1; }

# === Проверка ОС: пока поддерживаем только Debian/Ubuntu ===
if [[ ! -f /etc/debian_version ]]; then
    error "Этот менеджер рассчитан на Debian/Ubuntu. Для других ОС используйте оригинальный install.sh"
    exit 1
fi

# ==============================
# ВСПОМОГАТЕЛЬНЫЕ
# ==============================

# Определение архитектуры в формате, который использует telemt-репо
_detect_arch() {
    local a
    a=$(uname -m)
    case "$a" in
        x86_64|amd64)
            # Проверяем поддержку x86_64-v3 (AVX2 + BMI2), как в офф install.sh
            if [[ -r /proc/cpuinfo ]] && grep -q "avx2" /proc/cpuinfo 2>/dev/null \
                    && grep -q "bmi2" /proc/cpuinfo 2>/dev/null; then
                echo "x86_64-v3"
            else
                echo "x86_64"
            fi
            ;;
        aarch64|arm64) echo "aarch64" ;;
        *) echo ""; return 1 ;;
    esac
}

_detect_libc() {
    local f
    for f in /lib/ld-musl-*.so.* /lib64/ld-musl-*.so.*; do
        [[ -e "$f" ]] && { echo "musl"; return 0; }
    done
    if grep -qE '^ID="?alpine"?' /etc/os-release 2>/dev/null; then
        echo "musl"; return 0
    fi
    if command -v ldd &>/dev/null && ldd --version 2>&1 | grep -qi musl; then
        echo "musl"; return 0
    fi
    echo "gnu"
}

# Нормализация версии: удаляет ведущий 'v' (но не v внутри строки)
_normalize_version() {
    echo "${1#v}"
}

# Проверка занятости порта
_port_busy() {
    local p="$1"
    ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
}

# Загрузка релиза telemt с fallback x86_64-v3 -> x86_64
# $1 = версия ("latest" или "3.3.29"), $2 = временная директория для распаковки
# Возвращает в stdout путь к извлечённому бинарю telemt
_download_telemt() {
    local VERSION="$1"
    local TMP="$2"
    local ARCH LIBC URL ARCHIVE

    ARCH=$(_detect_arch) || { error "Неподдерживаемая архитектура: $(uname -m)"; return 1; }
    LIBC=$(_detect_libc)

    _build_url() {
        local arch="$1"
        if [[ "$VERSION" == "latest" ]]; then
            echo "https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${LIBC}.tar.gz"
        else
            echo "https://github.com/telemt/telemt/releases/download/${VERSION}/telemt-${arch}-linux-${LIBC}.tar.gz"
        fi
    }

    ARCHIVE="${TMP}/telemt.tar.gz"
    URL=$(_build_url "$ARCH")

    info "Скачиваю: $URL" >&2
    if ! curl -fsSL "$URL" -o "$ARCHIVE"; then
        if [[ "$ARCH" == "x86_64-v3" ]]; then
            warn "Сборка x86_64-v3 не найдена, откат на x86_64..." >&2
            ARCH="x86_64"
            URL=$(_build_url "$ARCH")
            info "Скачиваю: $URL" >&2
            if ! curl -fsSL "$URL" -o "$ARCHIVE"; then
                error "Не удалось скачать бинарь telemt" >&2
                return 1
            fi
        else
            error "Не удалось скачать бинарь telemt" >&2
            return 1
        fi
    fi

    if ! tar -xzf "$ARCHIVE" -C "$TMP"; then
        error "Не удалось распаковать архив telemt" >&2
        return 1
    fi
    rm -f "$ARCHIVE"

    local FOUND
    FOUND=$(find "$TMP" -type f -name "telemt" -print 2>/dev/null | head -1)
    if [[ -z "$FOUND" ]]; then
        # Иногда бинарь распакован в подпапку с именем релиза
        FOUND=$(find "$TMP" -type f -executable ! -name "*.tar.gz" -print 2>/dev/null | head -1)
    fi
    if [[ -z "$FOUND" ]]; then
        error "Бинарь telemt не найден после распаковки" >&2
        return 1
    fi

    echo "$FOUND"
}

# Установка бинаря telemt с правильными capabilities (как в офф install.sh)
_install_telemt_bin() {
    local SRC="$1"
    install -m 0755 "$SRC" /usr/local/bin/telemt || return 1
    if command -v setcap &>/dev/null; then
        # Офф ставит обе capability: net_bind_service + net_admin
        setcap cap_net_bind_service,cap_net_admin=+ep /usr/local/bin/telemt 2>/dev/null || true
    fi
}

# Установка зависимостей (с проверкой setcap как в офф)
_ensure_deps() {
    local pkgs=()
    command -v curl    &>/dev/null || pkgs+=("curl")
    command -v jq      &>/dev/null || pkgs+=("jq")
    command -v openssl &>/dev/null || pkgs+=("openssl")
    command -v tar     &>/dev/null || pkgs+=("tar")
    command -v setcap  &>/dev/null || pkgs+=("libcap2-bin")
    if (( ${#pkgs[@]} > 0 )); then
        info "Устанавливаю зависимости: ${pkgs[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    fi
}

# Получение публичного IP с фоллбэками
_get_public_ip() {
    local ip
    ip=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -4 --max-time 5 api.ipify.org 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -4 --max-time 5 ipinfo.io/ip 2>/dev/null)
    echo "$ip"
}

# ==============================
# УСТАНОВКА TELEMT
# ==============================
do_install() {
    if systemctl is-active --quiet telemt 2>/dev/null; then
        warn "Telemt уже запущен. Сначала удали (пункт 6)."
        return
    fi

    local TLS_DOMAIN_L="$TLS_DOMAIN"
    local PROXY_PORT_L="$PROXY_PORT"
    local SECRET
    SECRET=$(openssl rand -hex 16)

    # --- Выбор домена маскировки ---
    echo ""
    echo -e "${CYAN}Домены маскировки (TLS 1.3 + HTTP/2):${NC}"
    echo "  --- Россия ---"
    echo "  1.  www.gosuslugi.ru     (по умолчанию)"
    echo "  2.  www.sberbank.ru"
    echo "  3.  www.tinkoff.ru"
    echo "  4.  www.yandex.ru"
    echo "  5.  www.ozon.ru"
    echo "  6.  www.wildberries.ru"
    echo "  --- Европа ---"
    echo "  7.  www.cloudflare.com"
    echo "  8.  www.bbc.co.uk"
    echo "  9.  www.bild.de"
    echo "  10. www.lufthansa.com"
    echo "  --- Своё ---"
    echo "  11. Свой домен"
    echo -ne " Выбор [1-11]: "
    read -r domain_choice
    case $domain_choice in
        2)  TLS_DOMAIN_L="www.sberbank.ru" ;;
        3)  TLS_DOMAIN_L="www.tinkoff.ru" ;;
        4)  TLS_DOMAIN_L="www.yandex.ru" ;;
        5)  TLS_DOMAIN_L="www.ozon.ru" ;;
        6)  TLS_DOMAIN_L="www.wildberries.ru" ;;
        7)  TLS_DOMAIN_L="www.cloudflare.com" ;;
        8)  TLS_DOMAIN_L="www.bbc.co.uk" ;;
        9)  TLS_DOMAIN_L="www.m.bild.de" ;;
        10) TLS_DOMAIN_L="www.lufthansa.com" ;;
        11)
            echo -ne " Введи домен (например: example.ru): "
            read -r custom_domain
            [[ -z "$custom_domain" ]] && { error "Домен не может быть пустым"; return; }
            # Простая валидация: только латиница, цифры, точки, дефисы
            if [[ ! "$custom_domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
                error "Некорректный домен: $custom_domain"
                return
            fi
            TLS_DOMAIN_L="$custom_domain"
            ;;
        *)  TLS_DOMAIN_L="www.gosuslugi.ru" ;;
    esac
    info "Домен маскировки: ${TLS_DOMAIN_L}"

    # --- Выбор middle_proxy ---
    echo ""
    echo -e "${CYAN}Use middle proxy (рекламная статистика Telegram):${NC}"
    echo "  1. true  — по умолчанию в офф репо (рекомендуется)"
    echo "  2. false — без middle proxy"
    echo -ne " Выбор [1-2, Enter=1]: "
    read -r mp_choice
    local USE_MIDDLE_PROXY="true"
    [[ "$mp_choice" == "2" ]] && USE_MIDDLE_PROXY="false"
    info "use_middle_proxy: ${USE_MIDDLE_PROXY}"

    # --- Автовыбор порта ---
    echo ""
    local PORT_CANDIDATES=(443 8443 2053 2083 2087 8080)
    local SUGGESTED_PORT=""
    echo -e "${CYAN}Статус стандартных портов:${NC}"
    for p in "${PORT_CANDIDATES[@]}"; do
        if _port_busy "$p"; then
            echo "  [занят]    $p"
        else
            echo "  [свободен] $p"
            [[ -z "$SUGGESTED_PORT" ]] && SUGGESTED_PORT="$p"
        fi
    done
    echo ""

    if [[ -n "$SUGGESTED_PORT" ]]; then
        echo -ne " Использовать порт ${SUGGESTED_PORT}? [Enter = да / введи другой]: "
    else
        echo -ne " Все стандартные порты заняты. Введи порт вручную: "
    fi
    read -r port_input

    if [[ -z "$port_input" && -n "$SUGGESTED_PORT" ]]; then
        PROXY_PORT_L="$SUGGESTED_PORT"
    elif [[ "$port_input" =~ ^[0-9]+$ ]] && (( port_input >= 1 && port_input <= 65535 )); then
        PROXY_PORT_L="$port_input"
        # Проверяем занятость кастомного порта
        if _port_busy "$PROXY_PORT_L"; then
            error "Порт ${PROXY_PORT_L} уже занят. Освободите его или выберите другой."
            return
        fi
    else
        error "Некорректный порт: $port_input"
        return
    fi
    info "Порт прокси: ${PROXY_PORT_L}"

    _ensure_deps

    # --- Скачивание бинаря ---
    info "Скачиваю последнюю стабильную версию telemt..."
    local TMP
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' RETURN

    local EXTRACTED
    if ! EXTRACTED=$(_download_telemt "latest" "$TMP"); then
        return
    fi

    info "Устанавливаю бинарь..."
    if ! _install_telemt_bin "$EXTRACTED"; then
        error "Не удалось установить бинарь telemt"
        return
    fi

    info "Получаю публичный IP..."
    local PUBLIC_IP
    PUBLIC_IP=$(_get_public_ip)
    [[ -z "$PUBLIC_IP" ]] && { error "Не удалось определить публичный IP"; return; }

    info "Создаю пользователя telemt..."
    if ! getent group telemt &>/dev/null; then
        groupadd -r telemt
    fi
    if ! id telemt &>/dev/null; then
        useradd -r -g telemt -d /opt/telemt -s /bin/false -c "Telemt Proxy" telemt
    fi
    mkdir -p /opt/telemt /opt/telemt/tlsfront
    chown -R telemt:telemt /opt/telemt
    chmod 750 /opt/telemt
    chmod 750 /opt/telemt/tlsfront

    info "Создаю конфиг..."
    mkdir -p /etc/telemt
    # Экранируем спецсимволы в домене (на всякий случай)
    local DOMAIN_ESC
    DOMAIN_ESC=$(printf '%s' "$TLS_DOMAIN_L" | sed 's/\\/\\\\/g; s/"/\\"/g')

    cat > /etc/telemt/telemt.toml <<EOF
[general]
use_middle_proxy = ${USE_MIDDLE_PROXY}

[general.modes]
classic = false
secure = false
tls = true

[general.links]
public_host = "${PUBLIC_IP}"

[server]
port = ${PROXY_PORT_L}

[server.api]
enabled = true
listen = "127.0.0.1:${API_PORT}"
whitelist = ["127.0.0.1/32"]

[censorship]
tls_domain = "${DOMAIN_ESC}"
mask = true
tls_emulation = true
tls_front_dir = "/opt/telemt/tlsfront"

[access.users]
${USERNAME} = "${SECRET}"
EOF

    # Права как в офф install.sh: 750 на директорию, 640 на конфиг, владелец root:telemt
    chown telemt:telemt /etc/telemt
    chmod 750 /etc/telemt
    chown root:telemt /etc/telemt/telemt.toml
    chmod 640 /etc/telemt/telemt.toml

    info "Создаю systemd unit..."
    cat > /etc/systemd/system/telemt.service <<EOF
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/telemt.service

    systemctl daemon-reload
    systemctl enable --now telemt

    # --- UFW ---
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "Открываю порт ${PROXY_PORT_L}/tcp в UFW..."
        ufw allow "${PROXY_PORT_L}/tcp" comment "${UFW_TAG_PROXY}" >/dev/null
    else
        warn "UFW не активен — порт ${PROXY_PORT_L} открой вручную"
    fi

    info "Жду запуск..."
    sleep 5

    if ! systemctl is-active --quiet telemt; then
        error "Сервис не запустился. Проверь: journalctl -u telemt -n 30"
        return
    fi

    local LINK=""
    LINK=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/users" \
        | jq -r '.data[0].links.tls[]? | select(test("server=[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))' \
        2>/dev/null | head -1 || true)

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Telemt установлен и запущен!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e " Порт:      ${PROXY_PORT_L}"
    echo -e " TLS домен: ${TLS_DOMAIN_L}"
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
# ССЫЛКИ КЛИЕНТОВ / СТАТИСТИКА
# ==============================
do_links() {
    if ! systemctl is-active --quiet telemt 2>/dev/null; then
        error "Telemt не запущен."
        return
    fi

    local RAW
    RAW=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/users" 2>/dev/null)
    if [[ -z "$RAW" ]] || ! echo "$RAW" | jq -e '.ok' &>/dev/null; then
        error "API не ответил. Проверь: systemctl status telemt"
        return
    fi

    echo ""
    echo -e "${CYAN}======= Ссылки клиентов (IPv4) =======${NC}"
    echo "$RAW" | jq -r '.data[] |
        "  [" + .username + "]",
        (.links.tls[]? | select(test("server=[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))),
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
# ПОЛНОЕ УДАЛЕНИЕ TELEMT
# ==============================
do_remove() {
    echo -ne "${RED}Удалить telemt полностью? [y/N]: ${NC}"
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }

    info "Останавливаю сервис..."
    systemctl stop telemt 2>/dev/null || true
    systemctl disable telemt 2>/dev/null || true

    info "Удаляю файлы..."
    rm -f /etc/systemd/system/telemt.service
    rm -rf /etc/telemt
    rm -rf /opt/telemt
    rm -f /usr/local/bin/telemt

    info "Удаляю пользователя telemt..."
    if id telemt &>/dev/null; then
        userdel telemt 2>/dev/null || true
    fi
    if getent group telemt &>/dev/null; then
        groupdel telemt 2>/dev/null || true
    fi

    # --- Отключаем автообновление если активно ---
    if crontab -l 2>/dev/null | grep -q "telemt-autoupdate"; then
        info "Отключаю автообновление..."
        crontab -l 2>/dev/null | grep -v "telemt-autoupdate" | crontab -
        rm -f /usr/local/bin/telemt-autoupdate.sh
        rm -f /var/lock/telemt-autoupdate.lock
    fi

    systemctl daemon-reload

    # --- UFW: закрываем ТОЛЬКО наши правила (по комментарию-тегу) ---
    _ufw_delete_by_tag "$UFW_TAG_PROXY"

    echo -e "${GREEN}[+] Telemt полностью удалён.${NC}"
}

# Удаление UFW-правил по тегу в комментарии
_ufw_delete_by_tag() {
    local tag="$1"
    if ! command -v ufw &>/dev/null; then return 0; fi
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then return 0; fi

    # Получаем правила с номерами и комментариями
    # ufw status numbered показывает: [N] PORT/proto ALLOW IN  ... # comment
    local lines
    lines=$(ufw status numbered 2>/dev/null | grep -F "# ${tag}" | grep -oE '^\[[ 0-9]+\]' | tr -d '[] ')
    # Удаляем по номерам в обратном порядке (чтобы нумерация не сдвигалась)
    local nums
    nums=$(echo "$lines" | sort -rn)
    local n
    for n in $nums; do
        [[ -z "$n" ]] && continue
        info "Удаляю UFW правило #${n} (тег ${tag})..."
        yes | ufw delete "$n" >/dev/null 2>&1 || true
    done
}

# ==============================
# ПОЛНОЕ УДАЛЕНИЕ ПАНЕЛИ
# ==============================
do_remove_panel() {
    echo -ne "${RED}Удалить панель полностью? [y/N]: ${NC}"
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }

    info "Останавливаю панель..."
    systemctl stop telemt-panel 2>/dev/null || true
    systemctl disable telemt-panel 2>/dev/null || true

    info "Удаляю файлы..."
    rm -f /etc/systemd/system/telemt-panel.service
    rm -rf /etc/telemt-panel
    rm -f /usr/local/bin/telemt-panel

    systemctl daemon-reload

    # --- UFW: закрываем только наши правила ---
    _ufw_delete_by_tag "$UFW_TAG_PANEL"

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

    if ! echo "$RESP" | jq -e '.ok' &>/dev/null; then
        local ERR
        ERR=$(echo "$RESP" | jq -r '.error.message // "неизвестная ошибка"' 2>/dev/null)
        error "Ошибка API: ${ERR}"
        return
    fi

    local NEW_SECRET LINK
    NEW_SECRET=$(echo "$RESP" | jq -r '.data.secret // empty')
    LINK=$(echo "$RESP" | jq -r '.data.user.links.tls[]? | select(test("server=[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))' \
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
    if _port_busy "$PANEL_PORT"; then
        error "Порт ${PANEL_PORT} уже занят"
        return
    fi

    echo -ne " Логин администратора [по умолчанию admin]: "
    read -r panel_user_input
    local PANEL_USER="${panel_user_input:-admin}"

    # Проверка наличия TTY перед чтением пароля
    local panel_pass=""
    if [[ -t 0 ]] || [[ -r /dev/tty ]]; then
        echo -ne " Пароль администратора: "
        if [[ -r /dev/tty ]]; then
            read -rs panel_pass < /dev/tty
        else
            read -rs panel_pass
        fi
        echo ""
    else
        error "Нет TTY — пароль ввести нельзя. Запустите менеджер интерактивно."
        return
    fi
    [[ -z "$panel_pass" ]] && { error "Пароль не может быть пустым"; return; }

    # Зависимости
    _ensure_deps

    # bcrypt: сначала пробуем существующий модуль, ставим только если нет
    info "Готовлю bcrypt..."
    if ! python3 -c "import bcrypt" &>/dev/null; then
        if command -v pip3 &>/dev/null || command -v pip &>/dev/null; then
            (pip3 install bcrypt --break-system-packages -q 2>/dev/null \
                || pip install bcrypt --break-system-packages -q 2>/dev/null) || true
        fi
        if ! python3 -c "import bcrypt" &>/dev/null; then
            # Фоллбэк через apt
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-bcrypt 2>/dev/null || true
        fi
        if ! python3 -c "import bcrypt" &>/dev/null; then
            error "Не удалось установить модуль bcrypt"
            return
        fi
    fi

    local PASS_HASH
    PASS_HASH=$(printf '%s' "${panel_pass}" | python3 -c "
import bcrypt, sys
pw = sys.stdin.read().encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt(10)).decode())
" 2>/dev/null)
    [[ -z "$PASS_HASH" ]] && { error "Не удалось сгенерировать хеш пароля"; return; }

    local JWT_SECRET
    JWT_SECRET=$(openssl rand -hex 32)

    info "Определяю архитектуру..."
    local ARCH ARCH_SUFFIX
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)  ARCH_SUFFIX="x86_64" ;;
        aarch64|arm64) ARCH_SUFFIX="aarch64" ;;
        *) error "Неподдерживаемая архитектура: $ARCH"; return ;;
    esac
    local BINARY_NAME="telemt-panel-${ARCH_SUFFIX}-linux-gnu.tar.gz"

    info "Получаю последний релиз панели..."
    local DOWNLOAD_URL
    DOWNLOAD_URL=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest" \
        | jq -r --arg bn "$BINARY_NAME" '.assets[]? | select(.name == $bn) | .browser_download_url')
    [[ -z "$DOWNLOAD_URL" ]] && { error "Не удалось найти бинарь ${BINARY_NAME} в релизе"; return; }

    local TMP
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' RETURN

    info "Скачиваю: $DOWNLOAD_URL"
    if ! curl -fsSL "$DOWNLOAD_URL" -o "${TMP}/panel.tar.gz"; then
        error "Не удалось скачать архив"
        return
    fi
    if ! tar -xzf "${TMP}/panel.tar.gz" -C "$TMP"; then
        error "Не удалось распаковать архив панели"
        return
    fi
    rm -f "${TMP}/panel.tar.gz"

    local EXTRACTED_BIN
    EXTRACTED_BIN=$(find "$TMP" -type f -name "telemt-panel-*-linux" -print 2>/dev/null | head -1)
    if [[ -z "$EXTRACTED_BIN" ]]; then
        EXTRACTED_BIN=$(find "$TMP" -type f -executable -print 2>/dev/null | head -1)
    fi
    [[ -z "$EXTRACTED_BIN" ]] && { error "Бинарь не найден после распаковки"; return; }
    install -m 0755 "$EXTRACTED_BIN" /usr/local/bin/telemt-panel

    info "Генерирую самоподписанный TLS сертификат..."
    mkdir -p /etc/telemt-panel/tls
    local PUBLIC_IP
    PUBLIC_IP=$(_get_public_ip)
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="127.0.0.1"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /etc/telemt-panel/tls/key.pem \
        -out    /etc/telemt-panel/tls/cert.pem \
        -subj   "/CN=${PUBLIC_IP}" \
        -addext "subjectAltName=IP:${PUBLIC_IP}" \
        2>/dev/null
    chmod 600 /etc/telemt-panel/tls/key.pem
    chmod 644 /etc/telemt-panel/tls/cert.pem

    info "Создаю конфиг панели..."
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
    chmod 644 /etc/systemd/system/telemt-panel.service

    systemctl daemon-reload
    systemctl enable --now telemt-panel

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "Открываю порт ${PANEL_PORT}/tcp в UFW..."
        ufw allow "${PANEL_PORT}/tcp" comment "${UFW_TAG_PANEL}" >/dev/null
    else
        warn "UFW не активен — порт ${PANEL_PORT} открой вручную"
    fi

    info "Жду запуск..."
    sleep 3

    if ! systemctl is-active --quiet telemt-panel; then
        error "Панель не запустилась. Проверь: journalctl -u telemt-panel -n 30"
        return
    fi

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN} Telemt Panel установлена!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e " URL:    ${GREEN}https://${PUBLIC_IP}:${PANEL_PORT}${NC}"
    echo -e " Логин:  ${PANEL_USER}"
    echo ""
}

# ==============================
# ОБНОВЛЕНИЕ TELEMT
# ==============================
do_update_telemt() {
    if [[ ! -f /etc/systemd/system/telemt.service ]] && [[ ! -x /usr/local/bin/telemt ]]; then
        error "Telemt не установлен"
        return
    fi

    local CURRENT LATEST LATEST_RAW
    CURRENT=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/system/info" \
        | jq -r '.data.version // "unknown"' 2>/dev/null)
    LATEST_RAW=$(curl -s --max-time 10 "https://api.github.com/repos/telemt/telemt/releases/latest" \
        | jq -r '.tag_name // "unknown"')
    LATEST=$(_normalize_version "$LATEST_RAW")
    CURRENT=$(_normalize_version "$CURRENT")

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
            if [[ "$CURRENT" == "$LATEST" && "$LATEST" != "unknown" ]]; then
                info "Уже установлена последняя стабильная версия."
                return
            fi
            echo -ne " Обновить до ${LATEST}? [y/N]: "
            read -r confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
            if _do_telemt_binary_update "latest"; then
                info "Telemt обновлён до ${LATEST}"
            fi
            ;;
        2)
            echo ""
            info "Ищу последний pre-release..."
            local PRERELEASE_RAW PRERELEASE
            PRERELEASE_RAW=$(curl -s --max-time 10 \
                "https://api.github.com/repos/telemt/telemt/releases?per_page=10" \
                | jq -r '[.[] | select(.prerelease == true)] | first | .tag_name // ""')
            PRERELEASE=$(_normalize_version "$PRERELEASE_RAW")

            if [[ -n "$PRERELEASE" ]]; then
                echo -e " Последний pre-release: ${YELLOW}${PRERELEASE}${NC}"
            else
                warn "Pre-release не найден"
            fi
            echo ""
            echo -e " Доступные релизы: ${CYAN}https://github.com/telemt/telemt/releases${NC}"
            echo -ne " Введи версию [Enter = ${PRERELEASE:-вручную}]: "
            read -r custom_ver
            [[ -z "$custom_ver" && -n "$PRERELEASE" ]] && custom_ver="$PRERELEASE"
            [[ -z "$custom_ver" ]] && { error "Версия не может быть пустой"; return; }
            custom_ver=$(_normalize_version "$custom_ver")
            # Валидация версии: только цифры, точки, дефисы, буквы (для pre-release)
            if [[ ! "$custom_ver" =~ ^[0-9A-Za-z._-]+$ ]]; then
                error "Некорректная версия: $custom_ver"
                return
            fi
            echo -ne " Установить версию ${custom_ver}? [y/N]: "
            read -r confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }
            if _do_telemt_binary_update "${custom_ver}"; then
                info "Telemt ${custom_ver} установлен"
            fi
            ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
}

# Внутренняя: скачивает + ставит бинарь + перезапускает сервис
_do_telemt_binary_update() {
    local VERSION="$1"
    local TMP
    TMP=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$TMP'" RETURN

    local EXTRACTED
    if ! EXTRACTED=$(_download_telemt "$VERSION" "$TMP"); then
        return 1
    fi

    info "Останавливаю сервис..."
    systemctl stop telemt 2>/dev/null || true

    if ! _install_telemt_bin "$EXTRACTED"; then
        error "Не удалось установить бинарь"
        systemctl start telemt 2>/dev/null || true
        return 1
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
# ОБНОВЛЕНИЕ ПАНЕЛИ
# ==============================
do_update_panel() {
    if [[ ! -f /usr/local/bin/telemt-panel ]]; then
        error "Панель не установлена."
        return
    fi

    info "Проверяю последний релиз панели..."
    local ARCH ARCH_SUFFIX
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)  ARCH_SUFFIX="x86_64" ;;
        aarch64|arm64) ARCH_SUFFIX="aarch64" ;;
        *) error "Неподдерживаемая архитектура: $ARCH"; return ;;
    esac
    local BINARY_NAME="telemt-panel-${ARCH_SUFFIX}-linux-gnu.tar.gz"

    local LATEST_RAW LATEST
    LATEST_RAW=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest" \
        | jq -r '.tag_name // "unknown"')
    LATEST=$(_normalize_version "$LATEST_RAW")
    echo -e " Последняя версия панели: ${CYAN}${LATEST}${NC}"
    echo ""

    echo -ne " Обновить панель до ${LATEST}? [y/N]: "
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { warn "Отменено."; return; }

    local DOWNLOAD_URL
    DOWNLOAD_URL=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest" \
        | jq -r --arg bn "$BINARY_NAME" '.assets[]? | select(.name == $bn) | .browser_download_url')
    [[ -z "$DOWNLOAD_URL" ]] && { error "Не удалось найти бинарь в релизе"; return; }

    local TMP
    TMP=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$TMP'" RETURN

    info "Скачиваю: $DOWNLOAD_URL"
    if ! curl -fsSL "$DOWNLOAD_URL" -o "${TMP}/panel.tar.gz"; then
        error "Не удалось скачать архив"
        return
    fi
    if ! tar -xzf "${TMP}/panel.tar.gz" -C "$TMP"; then
        error "Не удалось распаковать архив"
        return
    fi
    rm -f "${TMP}/panel.tar.gz"

    local EXTRACTED_BIN
    EXTRACTED_BIN=$(find "$TMP" -type f -name "telemt-panel-*-linux" -print 2>/dev/null | head -1)
    if [[ -z "$EXTRACTED_BIN" ]]; then
        EXTRACTED_BIN=$(find "$TMP" -type f -executable -print 2>/dev/null | head -1)
    fi
    [[ -z "$EXTRACTED_BIN" ]] && { error "Бинарь не найден после распаковки"; return; }

    info "Останавливаю панель..."
    systemctl stop telemt-panel 2>/dev/null || true
    install -m 0755 "$EXTRACTED_BIN" /usr/local/bin/telemt-panel

    info "Запускаю обновлённую панель..."
    systemctl start telemt-panel
    sleep 3

    if systemctl is-active --quiet telemt-panel; then
        info "Панель обновлена до ${LATEST}"
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
            # Проверяем наличие crontab
            if ! command -v crontab &>/dev/null; then
                info "Устанавливаю cron..."
                DEBIAN_FRONTEND=noninteractive apt-get update -qq
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron
                systemctl enable --now cron 2>/dev/null || true
            fi
            if ! command -v flock &>/dev/null; then
                info "Устанавливаю util-linux (flock)..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq util-linux 2>/dev/null || true
            fi
            cat > "$SCRIPT" << 'AUTOUPDATE'
#!/bin/bash
# Автообновление Telemt и Telemt Panel
# Запускается из cron каждые 3 часа.
set -o pipefail

API_PORT="9091"
LOG="/var/log/telemt-autoupdate.log"
LOCK="/var/lock/telemt-autoupdate.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

# --- Защита от параллельных запусков ---
exec 200>"$LOCK"
if ! flock -n 200; then
    log "Другой экземпляр уже работает, выход."
    exit 0
fi

# --- Нормализация версии: срезаем ведущий 'v' ---
norm_ver() { echo "${1#v}"; }

# --- Определение архитектуры (с поддержкой x86_64-v3) ---
detect_arch() {
    local a
    a=$(uname -m)
    case "$a" in
        x86_64|amd64)
            if [[ -r /proc/cpuinfo ]] && grep -q "avx2" /proc/cpuinfo 2>/dev/null \
                    && grep -q "bmi2" /proc/cpuinfo 2>/dev/null; then
                echo "x86_64-v3"
            else
                echo "x86_64"
            fi
            ;;
        aarch64|arm64) echo "aarch64" ;;
        *) echo ""; return 1 ;;
    esac
}

detect_libc() {
    local f
    for f in /lib/ld-musl-*.so.* /lib64/ld-musl-*.so.*; do
        [[ -e "$f" ]] && { echo "musl"; return 0; }
    done
    grep -qE '^ID="?alpine"?' /etc/os-release 2>/dev/null && { echo "musl"; return 0; }
    if command -v ldd &>/dev/null && ldd --version 2>&1 | grep -qi musl; then
        echo "musl"; return 0
    fi
    echo "gnu"
}

# === Обновление Telemt ===
if systemctl is-active --quiet telemt 2>/dev/null; then
    CURRENT_RAW=$(curl -s --max-time 5 "http://127.0.0.1:${API_PORT}/v1/system/info" | jq -r '.data.version // ""')
    LATEST_RAW=$(curl -s --max-time 10 "https://api.github.com/repos/telemt/telemt/releases/latest" | jq -r '.tag_name // ""')
    CURRENT=$(norm_ver "$CURRENT_RAW")
    LATEST=$(norm_ver "$LATEST_RAW")

    if [[ -z "$LATEST" ]]; then
        log "Telemt: не удалось получить последнюю версию с GitHub, пропуск"
    elif [[ -z "$CURRENT" ]]; then
        log "Telemt: не удалось получить текущую версию (API ${API_PORT} не ответил), пропуск"
    elif [[ "$CURRENT" != "$LATEST" ]]; then
        log "Telemt: обновление $CURRENT -> $LATEST"
        ARCH=$(detect_arch); LIBC=$(detect_libc)
        if [[ -z "$ARCH" ]]; then
            log "Telemt: неподдерживаемая архитектура $(uname -m)"
        else
            TMP=$(mktemp -d)
            URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz"

            if ! curl -fsSL "$URL" -o "${TMP}/telemt.tar.gz"; then
                if [[ "$ARCH" == "x86_64-v3" ]]; then
                    log "Telemt: x86_64-v3 не найден, откат на x86_64"
                    ARCH="x86_64"
                    URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz"
                    curl -fsSL "$URL" -o "${TMP}/telemt.tar.gz" || { log "Telemt: ошибка скачивания"; rm -rf "$TMP"; exit 1; }
                else
                    log "Telemt: ошибка скачивания"
                    rm -rf "$TMP"; exit 1
                fi
            fi

            if tar -xzf "${TMP}/telemt.tar.gz" -C "$TMP"; then
                EXT=$(find "$TMP" -type f -name "telemt" | head -1)
                [[ -z "$EXT" ]] && EXT=$(find "$TMP" -type f -executable ! -name "*.tar.gz" | head -1)
                if [[ -n "$EXT" ]]; then
                    systemctl stop telemt
                    if install -m 0755 "$EXT" /usr/local/bin/telemt; then
                        command -v setcap &>/dev/null && \
                            setcap cap_net_bind_service,cap_net_admin=+ep /usr/local/bin/telemt 2>/dev/null
                        systemctl start telemt
                        sleep 3
                        if systemctl is-active --quiet telemt; then
                            log "Telemt: обновлён до $LATEST"
                        else
                            log "Telemt: после обновления сервис не стартовал!"
                        fi
                    else
                        log "Telemt: install не удался"
                        systemctl start telemt
                    fi
                else
                    log "Telemt: бинарь не найден после распаковки"
                fi
            else
                log "Telemt: ошибка распаковки"
            fi
            rm -rf "$TMP"
        fi
    else
        log "Telemt: актуальная версия $CURRENT"
    fi
fi

# === Обновление панели ===
if [[ -f /usr/local/bin/telemt-panel ]]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)  AS="x86_64" ;;
        aarch64|arm64) AS="aarch64" ;;
        *) log "Panel: неподдерживаемая архитектура $ARCH"; exit 0 ;;
    esac
    BN="telemt-panel-${AS}-linux-gnu.tar.gz"

    PANEL_API=$(curl -s --max-time 10 "https://api.github.com/repos/amirotin/telemt_panel/releases/latest")
    LATEST_P_RAW=$(echo "$PANEL_API" | jq -r '.tag_name // ""')
    CURRENT_P_RAW=$(/usr/local/bin/telemt-panel version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    LATEST_P=$(norm_ver "$LATEST_P_RAW")
    CURRENT_P=$(norm_ver "$CURRENT_P_RAW")

    if [[ -z "$LATEST_P" ]]; then
        log "Panel: не удалось получить последнюю версию, пропуск"
    elif [[ "$CURRENT_P" != "$LATEST_P" ]]; then
        log "Panel: обновление $CURRENT_P -> $LATEST_P"
        DL=$(echo "$PANEL_API" | jq -r --arg bn "$BN" '.assets[]? | select(.name == $bn) | .browser_download_url')
        if [[ -n "$DL" ]]; then
            TMP=$(mktemp -d)
            if curl -fsSL "$DL" -o "${TMP}/panel.tar.gz" && tar -xzf "${TMP}/panel.tar.gz" -C "$TMP"; then
                EX=$(find "$TMP" -type f -name "telemt-panel-*-linux" | head -1)
                [[ -z "$EX" ]] && EX=$(find "$TMP" -type f -executable | head -1)
                if [[ -n "$EX" ]]; then
                    systemctl stop telemt-panel
                    if install -m 0755 "$EX" /usr/local/bin/telemt-panel; then
                        systemctl start telemt-panel
                        sleep 3
                        if systemctl is-active --quiet telemt-panel; then
                            log "Panel: обновлена до $LATEST_P"
                        else
                            log "Panel: после обновления сервис не стартовал!"
                        fi
                    else
                        log "Panel: install не удался"
                        systemctl start telemt-panel
                    fi
                else
                    log "Panel: бинарь не найден после распаковки"
                fi
            else
                log "Panel: ошибка скачивания или распаковки"
            fi
            rm -rf "$TMP"
        else
            log "Panel: не найден URL для $BN"
        fi
    else
        log "Panel: актуальная версия $CURRENT_P"
    fi
fi
AUTOUPDATE
            chmod +x "$SCRIPT"
            ( crontab -l 2>/dev/null | grep -v "telemt-autoupdate"; echo "$CRON_JOB" ) | crontab -
            info "Автообновление включено — каждые 3 часа"
            info "Логи: /var/log/telemt-autoupdate.log"
            ;;
        2)
            crontab -l 2>/dev/null | grep -v "telemt-autoupdate" | crontab -
            rm -f "$SCRIPT"
            rm -f /var/lock/telemt-autoupdate.lock
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
    echo -e "${CYAN}║${NC}  --- Telemt ---              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  1. Установка                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  2. Ссылки / статистика      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  3. Добавить клиента         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  4. Удалить клиента          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  5. Обновить Telemt          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  6. Полное удаление          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  --- Панель ---              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  7. Установить панель        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  8. Обновить панель          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  9. Удалить панель           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  --- Система ---             ${CYAN}║${NC}"
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
