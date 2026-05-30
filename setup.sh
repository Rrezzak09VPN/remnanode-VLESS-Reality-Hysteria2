#!/bin/bash
#
# setup.sh — Автоматическая подготовка ноды Remnanode (eGamesAPI) для VLESS+Hysteria
#
set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok_msg() { echo -e "${GREEN}[OK]${NC} $1"; }
warn_msg() { echo -e "${YELLOW}[INFO]${NC} $1"; }
error_exit() {
    echo -e "${RED}[ERROR]${NC} $1"
    if [[ -n "${2:-}" ]]; then echo -e "${YELLOW}[RECOMMENDATION]${NC} $2"; fi
    exit 1
}

echo "=== Подготовка сервера для VLESS + Hysteria ==="

# 1. Проверка root
[[ "$EUID" -ne 0 ]] && error_exit "Требуется root." "Запустите: sudo bash $0"
ok_msg "Права root: OK"

# 2. Проверка Docker
command -v docker &>/dev/null || error_exit "Docker не установлен."
docker info &>/dev/null || error_exit "Docker демон не запущен."
ok_msg "Docker: OK"

# 3. Проверка контейнера remnanode
docker inspect remnanode &>/dev/null || error_exit "Контейнер 'remnanode' не найден."
[[ "$(docker inspect remnanode --format '{{.State.Status}}')" != "running" ]] && error_exit "remnanode не запущен."
ok_msg "Контейнер remnanode: running"

# 4. Проверка монтирования /dev/shm
docker inspect remnanode --format '{{json .Mounts}}' | grep -q '/dev/shm' || error_exit "/dev/shm не примонтирован в контейнер."
ok_msg "Монтирование /dev/shm: OK"

# 5. Поиск домена и сертификатов
[[ ! -d /etc/letsencrypt/live ]] && error_exit "Let's Encrypt не найден."
DOMAIN=$(ls /etc/letsencrypt/live/ | grep -v README | head -n1)
[[ -z "$DOMAIN" ]] && error_exit "Домен не найден."
CERT_SRC="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_SRC="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
[[ ! -f "$CERT_SRC" || ! -f "$KEY_SRC" ]] && error_exit "Файлы сертификатов присутствуют не полностью."
ok_msg "Домен: $DOMAIN | Сертификаты: OK"

# 6. UFW и порты
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(ufw status 2>/dev/null | head -n1 | awk '{print $2}')
    if [[ "$UFW_STATUS" == "active" ]]; then
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ufw allow 443/udp >/dev/null 2>&1 || true
        ok_msg "UFW: порты 443/tcp и 443/udp открыты"
    else
        warn_msg "UFW не активен. Убедитесь, что порты 443 открыты другим фаерволом."
    fi
else
    warn_msg "UFW не установлен. Убедитесь, что порты 443 открыты."
fi

# 7. Копирование сертификатов (Идемпотентно через MD5)
SHM_CERT="/dev/shm/hysteria_cert.pem"
SHM_KEY="/dev/shm/hysteria_key.pem"
NEED_COPY=false

if [[ ! -f "$SHM_CERT" || ! -f "$SHM_KEY" ]]; then
    NEED_COPY=true
else
    SRC_CERT_SUM=$(md5sum "$CERT_SRC" | awk '{print $1}')
    SHM_CERT_SUM=$(md5sum "$SHM_CERT" | awk '{print $1}')
    [[ "$SRC_CERT_SUM" != "$SHM_CERT_SUM" ]] && NEED_COPY=true
fi

if [[ "$NEED_COPY" == true ]]; then
    cp -f "$CERT_SRC" "$SHM_CERT"
    cp -f "$KEY_SRC" "$SHM_KEY"
    chmod 644 /dev/shm/hysteria_*.pem
    ok_msg "Сертификаты скопированы в /dev/shm"
else
    ok_msg "Сертификаты в /dev/shm уже актуальны"
fi

# 8. Cron-задачи (Идемпотентно)
CRON_REBOOT="@reboot cp $CERT_SRC $SHM_CERT && cp $KEY_SRC $SHM_KEY && chmod 644 /dev/shm/*.pem && sleep 15 && docker restart remnanode"
CRON_DAILY="0 4 * * * cp $CERT_SRC $SHM_CERT && cp $KEY_SRC $SHM_KEY && chmod 644 /dev/shm/*.pem && docker restart remnanode"

if crontab -l 2>/dev/null | grep -q "hysteria_cert.pem"; then
    ok_msg "Cron-задачи уже настроены (идемпотентность)"
else
    (crontab -l 2>/dev/null; echo ""; echo "$CRON_REBOOT"; echo "$CRON_DAILY") | crontab -
    ok_msg "Cron-задачи добавлены"
fi

# 9. Перезапуск
ok_msg "Перезапуск remnanode..."
docker restart remnanode >/dev/null
sleep 3

echo ""
echo "✅ Серверная часть полностью готова!"
echo "Теперь примените новый конфиг через панель Remnawave."
