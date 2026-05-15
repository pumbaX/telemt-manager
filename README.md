# Telemt Manager

> Bash-скрипт управления MTProto прокси на базе **[Telemt](https://github.com/telemt/telemt)** + веб-панель **[Telemt Panel](https://github.com/amirotin/telemt_panel)**

---

## 🙏 Благодарности и авторы

### Оригинальные проекты

| Проект | Автор | Ссылка |
|--------|-------|--------|
| **Telemt** — MTProto прокси на Rust + Tokio | [@telemt](https://github.com/telemt) | [github.com/telemt/telemt](https://github.com/telemt/telemt) |
| **Telemt Panel** — Веб-панель управления на Go + React | [@amirotin](https://github.com/amirotin) | [github.com/amirotin/telemt_panel](https://github.com/amirotin/telemt_panel) |

Огромный респект авторам обоих проектов. Telemt решает проблемы ещё до того, как другие вообще понимают, что они существуют.

Telegram-сообщество Telemt: **[t.me/telemtrs](https://t.me/telemtrs)**

---

## Что такое Telemt Manager

`telemt-manager.sh` — интерактивный bash-скрипт для полного управления Telemt MTProto прокси и веб-панелью. Вся логика строго основана на официальной документации и исходниках проектов.

---

## Возможности

### Telemt (MTProto прокси)

- Установка с автоопределением архитектуры (`x86_64` / `aarch64`) и типа libc (`gnu` / `musl`)
- Интерактивный выбор домена TLS-маскировки из списка российских сайтов
- Автоматическое определение свободных портов
- Генерация конфига с `mask = true`, `tls_emulation = true`, `public_host`, `whitelist`
- Создание системного пользователя `telemt` с отдельной группой
- Корректные права на файлы (`root:telemt`, директория `770`, конфиг `660`)
- Автоматическое открытие/закрытие портов в UFW
- Управление клиентами через REST API (`POST/DELETE /v1/users`)
- Просмотр ссылок и статистики через API
- Обновление бинаря с проверкой версии
- Полное удаление с очисткой UFW

### Telemt Panel (веб-панель)

- Установка с автоматической генерацией bcrypt-хеша пароля
- Самоподписанный TLS сертификат (RSA 2048, 10 лет, SAN для IP) — HTTPS из коробки
- Обновление панели с GitHub Releases
- Полное удаление с очисткой UFW

---

## Требования

- Ubuntu / Debian (systemd)
- Root доступ
- Архитектура: `x86_64` или `aarch64`

---

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/pumbaX/telemt-manager/main/telemt-manager.sh -o telemt-manager.sh && sudo bash telemt-manager.sh
```

---

## Меню

```
╔══════════════════════════════╗
║      TELEMT MANAGER               ║
╠══════════════════════════════╣
║  --- Telemt ---                   ║
║  1. Установка                     ║
║  2. Ссылки / статистика           ║
║  3. Добавить клиента              ║
║  4. Удалить клиента               ║
║  5. Обновить Telemt               ║
║  6. Полное удаление               ║
║  --- Панель ---                   ║
║  7. Установить панель             ║
║  8. Обновить панель               ║
║  9. Удалить панель                ║
║  --- Система ---                  ║
║  10. Автообновление               ║
║  0. Выход                         ║
╚══════════════════════════════╝
```

---

## Быстрый старт

### Шаг 1 — Установка Telemt (пункт 1)

Скрипт предложит выбор домена TLS-маскировки:

```
--- Госсервисы ---    --- Банки ---       --- Магазины ---    --- Видео ---
1. www.gosuslugi.ru   2. www.sberbank.ru  5. www.ozon.ru      7.  www.ivi.ru
                      3. www.tinkoff.ru   6. www.wildberries   8.  okko.tv
                      4. www.vtb.ru                            9.  www.kion.ru
                                                               10. wink.ru
                                                               11. www.kinopoisk.ru
12. Свой домен
```

Затем выбор порта — и готовая ссылка для Telegram.

### Шаг 2 — Установка панели (пункт 7)

После установки Telemt запускаем панель. Скрипт спросит порт, логин и пароль, затем автоматически:

- Генерирует bcrypt-хеш пароля и JWT-секрет
- Создаёт самоподписанный TLS сертификат для IP
- Скачивает бинарь с GitHub Releases
- Выводит URL: `https://IP:PORT`

> Браузер покажет предупреждение о самоподписанном сертификате — нажми "Продолжить".

Итого два шага — прокси работает, панель доступна по HTTPS.

---

## HTTPS через nginx + Let's Encrypt (опционально)

Для красивого адреса типа `https://telemt.yourdomain.com`:

```bash
# 1. Добавь A-запись в DNS: telemt.yourdomain.com → IP сервера

# 2. Получи сертификат
apt-get install -y nginx certbot python3-certbot-nginx
certbot certonly --nginx -d telemt.yourdomain.com \
    --non-interactive --agree-tos -m your@email.com

# 3. Nginx конфиг
cat > /etc/nginx/sites-available/telemt-panel <<'EOF'
server {
    listen 80;
    server_name telemt.yourdomain.com;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name telemt.yourdomain.com;
    ssl_certificate     /etc/letsencrypt/live/telemt.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/telemt.yourdomain.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    location / {
        proxy_pass https://127.0.0.1:PANEL_PORT;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

ln -sf /etc/nginx/sites-available/telemt-panel /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

---

## Соответствие документации

| Компонент | Источник |
|-----------|---------|
| Установка бинаря, detect_libc, setcap | `install.sh` из репозитория Telemt |
| Параметры конфига | `docs/CONFIG_PARAMS.en.md` |
| Systemd unit | `contrib/systemd/telemt.service` |
| API endpoints и структуры | `docs/API.md` + `src/api/model.rs` |
| Права на файлы | `install.sh` (адаптировано под API write) |
| Панель конфиг | `config.example.toml` из репозитория Telemt Panel |

---

## Почему Telemt

| | Telemt | MTProxyMax |
|---|---|---|
| Язык | Rust | C |
| API | Полноценный REST | Только Prometheus |
| Веб-панель | Есть | Нет |
| Маскировка | FakeTLS + TLS Emulation | FakeTLS |
| Документация | Подробная | Скудная |

---

## Лицензия

MIT

---

*Оригинальный прокси: [github.com/telemt/telemt](https://github.com/telemt/telemt)*
*Оригинальная панель: [github.com/amirotin/telemt_panel](https://github.com/amirotin/telemt_panel)*
