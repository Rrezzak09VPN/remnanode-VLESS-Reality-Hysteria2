#!/bin/bash
#
# setup.sh — Remnawave Node Multi-Protocol Setup v2.0.0
# by Rezzosoft KVN | https://remna.xyz/pages/convert/
#
set -uo pipefail

# Маркер версии cron-заданий. При изменении логики cron — увеличивать.
# Гарантирует, что старые задания будут заменены новыми при запуске скрипта.
CRON_MARKER="rrp-hysteria-v1"

# Пути можно переопределить для тестов (в обычной работе не используются).
LE_LIVE_DIR="${LE_LIVE_DIR:-/etc/letsencrypt/live}"
CADDY_DATA_FALLBACK="${CADDY_DATA_FALLBACK:-/var/lib/docker/volumes/caddy_data/_data}"
CRONTAB_BACKUP="${CRONTAB_BACKUP:-/root/.crontab.rrp-hysteria.backup}"

show_logo() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║     ██████╗ ███████╗███╗   ███╗███╗   ██╗ █████╗ ██╗    ██╗      ║
║     ██╔══██╗██╔════╝████╗ ████║████╗  ██║██╔══██╗██║    ██║      ║
║     ██████╔╝█████╗  ██╔████╔██║██╔██╗ ██║███████║██║ █╗ ██║      ║
║     ██╔══██╗██╔══╝  ██║╚██╔╝██║██║╚██╗██║██╔══██║██║███╗██║      ║
║     ██║  ██║███████╗██║ ╚═╝ ██║██║ ╚████║██║  ██║╚███╔███╔╝      ║
║     ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚══╝╚══╝       ║
║                                                                  ║
║           Remnawave Node Multi-Protocol Setup v2.0.0             ║
║                      by Rezzosoft KVN                            ║
║                                                                  ║
║   Конвертер конфигов: https://remna.xyz/pages/convert/           ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
EOF
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
log_info() { echo -e "${BLUE}[•]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error(){ echo -e "${RED}[✗]${NC} $1"; }

fatal() {
    log_error "$1"
    [[ -n "${2:-}" ]] && log_warn "$2"
    exit 1
}

# ============================================================================
# SPINNER — для операций, которые выполняются не мгновенно
# В интерактивном терминале — крутящийся индикатор с очисткой строки,
# в пайпе/скриптах вывода — обычная информационная строка.
# ============================================================================
SPIN_PID=""

spin_start() {
    local msg="$1"
    if [[ -t 1 ]]; then
        (
            frames='|/-\'
            i=0
            while :; do
                printf '\r%s %s' "$msg" "${frames:i++%4:1}"
                sleep 0.2
            done
        ) &
        SPIN_PID=$!
    else
        log_info "$msg"
    fi
}

spin_stop() {
    if [[ -n "${SPIN_PID:-}" ]]; then
        kill "$SPIN_PID" 2>/dev/null || true
        wait "$SPIN_PID" 2>/dev/null || true
        printf '\r\033[2K'
        SPIN_PID=""
    fi
}

trap 'spin_stop' EXIT
trap 'spin_stop; exit 130' INT
trap 'spin_stop; exit 143' TERM

# ============================================================================
# STAGES — цветные заголовки этапов (прогресс выполнения скрипта)
# ============================================================================
STAGES_TOTAL=4
stage() {
    echo ""
    echo -e "${BLUE}━━━ [$1/$STAGES_TOTAL] $2 ━━━${NC}"
}

# ============================================================================
# WEB SERVER DETECTION
# Определяет, какой веб-сервер обслуживает ноду: Nginx или Caddy.
# Имена контейнеров сверены с исходниками eGames remnawave-reverse-proxy:
#   node-only  : caddy-remnawave | remnawave-nginx
#   panel+node : remnawave-caddy | remnawave-nginx
# Сначала проверяются контейнеры, затем — docker-compose.yml
# (на случай остановленного контейнера).
# ============================================================================
detect_webserver() {
    local containers
    containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null)

    if echo "$containers" | grep -qE '^(caddy-remnawave|remnawave-caddy)$'; then
        echo "caddy"
        return 0
    fi

    if echo "$containers" | grep -qE '^(remnawave-nginx|nginx-remnawave)$'; then
        echo "nginx"
        return 0
    fi

    # Fallback: проверяем docker-compose.yml
    local compose_dir compose_file
    for compose_dir in /opt/remnanode /opt/remnawave; do
        compose_file="${compose_dir}/docker-compose.yml"
        if [ -f "$compose_file" ]; then
            if grep -qE 'container_name:[[:space:]]*(caddy-remnawave|remnawave-caddy)' "$compose_file" 2>/dev/null; then
                echo "caddy"
                return 0
            fi
            if grep -qE 'container_name:[[:space:]]*(remnawave-nginx|nginx-remnawave)' "$compose_file" 2>/dev/null; then
                echo "nginx"
                return 0
            fi
        fi
    done

    echo "unknown"
}

# ============================================================================
# HELPER: серверные домены SelfSteal из nginx.conf
# Извлекает server_name из блоков server, содержащих root /var/www/html
# (именно так eGames пишет маскировочный сайт). Поддерживает node-only
# (/opt/remnanode/nginx.conf) и panel+node (/opt/remnawave/nginx.conf).
# ============================================================================
nginx_selfsteal_domains() {
    local f
    local paths="${NGINX_CONF_PATHS:-/opt/remnanode/nginx.conf:/opt/remnawave/nginx.conf}"
    local -a files=()
    IFS=':' read -r -a files <<< "$paths"
    for f in "${files[@]}"; do
        [ -f "$f" ] || continue
        awk '
            {
                line = $0
                opens  = gsub(/\{/, "{", line)
                closes = gsub(/\}/, "}", line)
                if (depth > 0) {
                    if ($0 ~ /server_name/) {
                        s = $0
                        sub(/.*server_name[[:space:]]+/, "", s)
                        sub(/;.*/, "", s)
                        sn = sn " " s
                    }
                    if ($0 ~ /root[[:space:]]+\/var\/www\/html/) hasroot = 1
                }
                depth += opens - closes
                if (depth <= 0) {
                    depth = 0
                    if (hasroot && sn != "") {
                        n = split(sn, a, /[[:space:]]+/)
                        for (i = 1; i <= n; i++)
                            if (a[i] != "" && a[i] != "_" && a[i] !~ /^\$/) print a[i]
                    }
                    sn = ""; hasroot = 0
                }
            }
        ' "$f"
    done
}

# ============================================================================
# HELPER: покрывает ли lineage (возможно "*.base") домен
# ============================================================================
lineage_covers() {
    local lineage="$1" domain="$2"
    if [ "$lineage" = "$domain" ]; then
        return 0
    fi
    if [[ "$lineage" == \*.* ]]; then
        local base="${lineage#\*.}"
        if [ "$domain" = "$base" ] || [[ "$domain" == *."$base" ]]; then
            return 0
        fi
    fi
    # lineage example.com покрывает node.example.com (wildcard-выпуск
    # Let's Encrypt DNS-01 кладёт сертификат в каталог базового домена)
    if [[ "$domain" == *."$lineage" ]]; then
        return 0
    fi
    return 1
}

# ============================================================================
# CERTIFICATE RESOLUTION — NGINX
# Классический путь Let's Encrypt: /etc/letsencrypt/live/<domain>/
#
# Стратегии (по убыванию приоритета):
#   1. Домены SelfSteal из nginx.conf + существующие lineages в live/.
#   2. Lineage, проброшенный в контейнер remnawave-nginx (docker mounts).
#   3. Ровно один lineage в live/ — берём его.
#   4. Несколько кандидатов — отказ (return 2), НЕ угадываем.
#
# Возврат: 0 = найдено, 1 = не найдено, 2 = неоднозначно.
# ============================================================================
resolve_nginx_certificates() {
    local live="$LE_LIVE_DIR"
    [ -d "$live" ] || return 1

    # Собираем валидные lineages: dirname -> paths
    local -a lineages=()
    local d name
    for d in "$live"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        case "$name" in
            README*) continue ;;
        esac
        [ -f "$d/fullchain.pem" ] && [ -f "$d/privkey.pem" ] || continue
        lineages+=("$name")
    done
    [ "${#lineages[@]}" -eq 0 ] && return 1

    # Стратегия 1: домены SelfSteal из nginx.conf
    local -a conf_domains=()
    while IFS= read -r name; do
        [ -n "$name" ] && conf_domains+=("$name")
    done < <(nginx_selfsteal_domains)

    local -a matched=()
    local l c
    for c in "${conf_domains[@]}"; do
        for l in "${lineages[@]}"; do
            if lineage_covers "$l" "$c"; then
                matched+=("$l")
            fi
        done
    done
    # Дедупликация matched
    if [ "${#matched[@]}" -gt 0 ]; then
        local -a uniq=()
        local m u seen
        for m in "${matched[@]}"; do
            seen=false
            for u in "${uniq[@]}"; do [ "$u" = "$m" ] && seen=true && break; done
            [ "$seen" = false ] && uniq+=("$m")
        done
        matched=("${uniq[@]}")
        if [ "${#matched[@]}" -eq 1 ]; then
            DOMAIN="${matched[0]}"
            CERT_PATH="$live/$DOMAIN/fullchain.pem"
            KEY_PATH="$live/$DOMAIN/privkey.pem"
            [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ] && return 0
        elif [ "${#matched[@]}" -gt 1 ]; then
            log_warn "Неоднозначный выбор сертификата Nginx, кандидаты:"
            for m in "${matched[@]}"; do log_warn "  - $m"; done
            return 2
        fi
    fi

    # Стратегия 2: lineage, проброшенный в контейнер remnawave-nginx
    local container=""
    local cn
    for cn in remnawave-nginx nginx-remnawave; do
        if docker inspect "$cn" &>/dev/null; then
            container="$cn"
            break
        fi
    done
    if [ -n "$container" ]; then
        local -a mount_lineages=()
        local src dst
        while IFS=' ' read -r src dst; do
            [ -n "${src:-}" ] || continue
            case "$dst" in
                /etc/nginx/ssl/*/fullchain.pem)
                    local ln
                    ln=$(basename "$(dirname "$dst")")
                    [ -f "$live/$ln/fullchain.pem" ] && mount_lineages+=("$ln")
                    ;;
            esac
        done < <(docker inspect "$container" --format '{{range .Mounts}}{{.Source}} {{.Destination}}{{println}}{{end}}' 2>/dev/null)

        if [ "${#mount_lineages[@]}" -eq 1 ]; then
            DOMAIN="${mount_lineages[0]}"
            CERT_PATH="$live/$DOMAIN/fullchain.pem"
            KEY_PATH="$live/$DOMAIN/privkey.pem"
            [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ] && return 0
        elif [ "${#mount_lineages[@]}" -gt 1 ]; then
            # Пересекаем с conf-доменами
            matched=()
            for c in "${conf_domains[@]}"; do
                for l in "${mount_lineages[@]}"; do
                    if lineage_covers "$l" "$c"; then matched+=("$l"); fi
                done
            done
            if [ "${#matched[@]}" -ge 1 ]; then
                DOMAIN="${matched[0]}"
                CERT_PATH="$live/$DOMAIN/fullchain.pem"
                KEY_PATH="$live/$DOMAIN/privkey.pem"
                [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ] && return 0
            fi
        fi
    fi

    # Стратегия 3: ровно один lineage
    if [ "${#lineages[@]}" -eq 1 ]; then
        DOMAIN="${lineages[0]}"
        CERT_PATH="$live/$DOMAIN/fullchain.pem"
        KEY_PATH="$live/$DOMAIN/privkey.pem"
        [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ] && return 0
        return 1
    fi

    # Стратегия 4: неоднозначность
    log_warn "Найдено несколько сертификатов Nginx, кандидаты:"
    for l in "${lineages[@]}"; do log_warn "  - $l"; done
    return 2
}

# ============================================================================
# CERTIFICATE RESOLUTION — CADDY
# Caddy хранит сертификаты в Docker volume (caddy_data):
#   <mountpoint>/caddy/certificates/<CA-directory>/<domain>/<domain>.crt + .key
#
# Монтируемый путь берётся из `docker volume inspect caddy_data`
# (а не хардкодится), каталоги ВСЕХ CA перечисляются (Let's Encrypt,
# ZeroSSL и др.).
#
# Домен: env SELF_STEAL_DOMAIN контейнера caddy -> docker-compose.yml ->
# ровно один домен в хранилище -> отказ (return 2).
#
# Возврат: 0 = найдено, 1 = не найдено, 2 = неоднозначно.
# ============================================================================
resolve_caddy_certificates() {
    local container=""
    local cn
    for cn in caddy-remnawave remnawave-caddy; do
        if docker inspect "$cn" &>/dev/null; then
            container="$cn"
            break
        fi
    done

    # 1) Том Caddy: из контейнера, затем volume inspect, затем стандартный путь
    local mountpoint=""
    if [ -n "$container" ]; then
        mountpoint=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
    fi
    if [ -z "$mountpoint" ]; then
        mountpoint=$(docker volume inspect caddy_data --format '{{.Mountpoint}}' 2>/dev/null)
    fi
    if [ -z "$mountpoint" ] && [ -d "$CADDY_DATA_FALLBACK" ]; then
        mountpoint="$CADDY_DATA_FALLBACK"
    fi
    [ -n "$mountpoint" ] || return 1

    local cert_root="$mountpoint/caddy/certificates"
    [ -d "$cert_root" ] || return 1

    # 2) Домен: env контейнера (источник истины), затем compose
    local domain=""
    if [ -n "$container" ]; then
        domain=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
                 | sed -n 's/^SELF_STEAL_DOMAIN=//p' | head -n1)
    fi
    if [ -z "$domain" ]; then
        local compose_file
        for compose_file in /opt/remnanode/docker-compose.yml /opt/remnawave/docker-compose.yml; do
            [ -f "$compose_file" ] || continue
            domain=$(grep -oP 'SELF_STEAL_DOMAIN=\K[^,"[:space:]]+' "$compose_file" 2>/dev/null | head -n1)
            [ -n "$domain" ] && break
        done
    fi

    # 3) Поиск файлов домена по ВСЕМ CA-каталогам
    if [ -n "$domain" ]; then
        local crt key
        while IFS= read -r crt; do
            key="${crt%.crt}.key"
            if [ -f "$key" ]; then
                DOMAIN="$domain"
                CERT_PATH="$crt"
                KEY_PATH="$key"
                return 0
            fi
        done < <(find "$cert_root" -type f -name "${domain}.crt" 2>/dev/null)
        return 1
    fi

    # 4) Домен неизвестен: перечисляем все хранимые домены
    local -a found_domains=()
    local dir base
    while IFS= read -r dir; do
        base=$(basename "$(dirname "$dir")")
        local seen=false u
        for u in "${found_domains[@]}"; do [ "$u" = "$base" ] && seen=true && break; done
        [ "$seen" = false ] && found_domains+=("$base")
    done < <(find "$cert_root" -type f -name '*.crt' 2>/dev/null)

    if [ "${#found_domains[@]}" -eq 1 ]; then
        domain="${found_domains[0]}"
        local crt key
        while IFS= read -r crt; do
            key="${crt%.crt}.key"
            if [ -f "$key" ]; then
                DOMAIN="$domain"
                CERT_PATH="$crt"
                KEY_PATH="$key"
                return 0
            fi
        done < <(find "$cert_root" -type f -name "${domain}.crt" 2>/dev/null)
        return 1
    elif [ "${#found_domains[@]}" -gt 1 ]; then
        log_warn "Неоднозначный выбор сертификата Caddy, кандидаты:"
        for domain in "${found_domains[@]}"; do log_warn "  - $domain"; done
        return 2
    fi

    return 1
}

# ============================================================================
# KEY PERMISSIONS DETECTION
# chmod 600 безопасен ТОЛЬКО если процессы в контейнере работают от root.
#
# UID определяется по РЕАЛЬНОМУ процессу rw-core через /proc:
#   1) docker exec ... sh -c 'cat /proc/<pid>/status' для rw-core
#   2) fallback — /proc/1/status
# Команда 'id' может отсутствовать в минимальных образах (в некоторых
# сборках образа ноды), поэтому она используется только последней.
#
# Логика выбора:
#   - UID = 0 (root)      -> 600 (ключ защищён)
#   - UID != 0            -> 644 (иначе нода не прочитает ключ)
#   - UID не определился  -> 644 (безопасный фоллбэк, не ломаем ноду)
# ============================================================================
detect_key_perms() {
    local node_uid=""

    # Способ 1: UID процесса rw-core (тот, кто читает ключ hysteria)
    node_uid=$(docker exec remnanode sh -c '
        for p in /proc/[0-9]*; do
            c=$(cat "$p/comm" 2>/dev/null) || continue
            if [ "$c" = "rw-core" ]; then
                grep -m1 "^Uid:" "$p/status" 2>/dev/null | awk "{print \$2}"
                exit 0
            fi
        done
        exit 1
    ' 2>/dev/null) || node_uid=""
    node_uid=$(printf '%s' "$node_uid" | head -n1 | tr -cd '0-9')

    # Способ 2: /proc/1/status (init-процесс, не зависит от утилит)
    if [ -z "$node_uid" ]; then
        local uid_line
        uid_line=$(docker exec remnanode cat /proc/1/status 2>/dev/null | grep -m1 '^Uid:' || echo "")
        if [[ "$uid_line" =~ Uid:[[:space:]]+([0-9]+) ]]; then
            node_uid="${BASH_REMATCH[1]}"
        fi
    fi

    # Способ 3: 'id' (может отсутствовать в минимальных образах)
    if [ -z "$node_uid" ]; then
        node_uid=$(docker exec remnanode id -u 2>/dev/null | head -n1) || node_uid=""
        node_uid=$(printf '%s' "$node_uid" | tr -cd '0-9')
    fi

    if [ "$node_uid" = "0" ]; then
        KEY_PERMS="600"
        log_ok "Контейнер remnanode работает от root (UID 0) — ключ будет защищён (600)"
    elif [ -n "$node_uid" ]; then
        KEY_PERMS="644"
        log_warn "Контейнер remnanode работает от UID $node_uid (не root)"
        log_warn "Ключ остаётся 644 — иначе Hysteria2 не сможет его прочитать"
    else
        KEY_PERMS="644"
        log_warn "Не удалось определить UID контейнера"
        log_warn "Ключ остаётся 644 для совместимости (безопасный фоллбэк)"
        log_warn "Проверьте вручную: docker exec remnanode cat /proc/1/status | grep Uid:"
        log_warn "Если Uid: 0 — выполните: chmod 600 /dev/shm/hysteria_key.pem"
    fi
}

# ============================================================================
# CERTIFICATE SANITY (openssl)
# ============================================================================
verify_certificate() {
    command -v openssl &>/dev/null || return 0

    if openssl x509 -in "$CERT_PATH" -noout -checkhost "$DOMAIN" 2>/dev/null; then
        log_ok "Сертификат покрывает домен $DOMAIN"
    else
        log_warn "Не удалось подтвердить, что сертификат покрывает $DOMAIN"
        log_warn "Проверьте: openssl x509 -in $CERT_PATH -noout -subject -ext subjectAltName"
    fi

    if ! openssl x509 -in "$CERT_PATH" -noout -checkend 604800 2>/dev/null; then
        log_warn "Сертификат истекает менее чем через 7 дней — проверьте автопродление"
    fi
}

# ============================================================================
# 443/TCP PROBE (с учётом network mode)
# Возвращает 0, если Xray слушает 443/tcp. Используется в preflight с
# ожиданием и в apply_config после restart.
# ============================================================================
port443_up() {
    port443_via="host"
    if [[ "${NETWORK_MODE:-host}" != "host" ]]; then
        if docker exec remnanode command -v ss &>/dev/null; then
            port443_via="container"
            docker exec remnanode ss -ltnp 2>/dev/null | grep -q ':443 '
            return $?
        fi
        port443_via="host-fallback"
    fi
    ss -ltnp 2>/dev/null | grep -q ':443 '
}

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================
preflight_checks() {
    [[ "$EUID" -ne 0 ]] && fatal "Скрипт требует прав root" "Запустите: sudo bash $0"
    log_ok "Права root подтверждены"

    # Обязательные утилиты: их отсутствие ломает скрипт молча
    local -a missing=()
    local util
    for util in docker ss cmp stat crontab grep openssl; do
        command -v "$util" &>/dev/null || missing+=("$util")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        fatal "Отсутствуют обязательные утилиты: ${missing[*]}" \
              "Debian/Ubuntu: apt-get install -y iproute2 diffutils coreutils cron openssl"
    fi
    log_ok "Обязательные утилиты найдены (docker ss cmp stat crontab grep openssl)"

    spin_start "Проверка Docker daemon..."
    docker info &>/dev/null
    local di_rc=$?
    spin_stop
    if [[ "$di_rc" -ne 0 ]]; then
        fatal "Docker daemon не запущен" "Выполните: systemctl start docker"
    fi
    log_ok "Docker daemon работает"

    docker inspect remnanode &>/dev/null || fatal "Контейнер 'remnanode' не найден" "Установите ноду Remnawave (eGames reverse-proxy)"

    local container_status
    container_status=$(docker inspect remnanode --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    [[ "$container_status" != "running" ]] && fatal "Контейнер 'remnanode' не запущен (статус: $container_status)"
    log_ok "Контейнер remnanode запущен"

    # =========================================================================
    # WEB SERVER DETECTION
    # =========================================================================
    WEBSERVER=$(detect_webserver)

    if [[ "$WEBSERVER" == "unknown" ]]; then
        fatal "Не удалось определить веб-сервер" \
              "Ожидался контейнер caddy-remnawave / remnawave-caddy / remnawave-nginx или compose-файл в /opt/remnanode либо /opt/remnawave"
    fi
    log_ok "Определён веб-сервер: ${WEBSERVER^^}"

    # =========================================================================
    # CERTIFICATE RESOLUTION (ВЕТВЛЕНИЕ ПО ВЕБ-СЕРВЕРУ)
    # =========================================================================
    local rc=0
    case "$WEBSERVER" in
        nginx) resolve_nginx_certificates || rc=$? ;;
        caddy) resolve_caddy_certificates || rc=$? ;;
    esac

    if [ "$rc" -eq 2 ]; then
        fatal "Неоднозначный выбор сертификата — автовыбор отключён" \
              "Укажите нужный сертификат вручную или удалите лишние из хранилища"
    fi
    if [ "$rc" -ne 0 ]; then
        case "$WEBSERVER" in
            nginx) fatal "Сертификаты Let's Encrypt не найдены" "Проверьте $LE_LIVE_DIR/" ;;
            caddy) fatal "Сертификаты Caddy не найдены" "Проверьте <caddy_data>/caddy/certificates/" ;;
        esac
    fi

    log_ok "Сертификаты найдены для: $DOMAIN (веб-сервер: ${WEBSERVER})"
    log_info "Источник: $CERT_PATH"
    verify_certificate

    # =========================================================================
    # KEY PERMISSIONS DETECTION
    # =========================================================================
    detect_key_perms

    # =========================================================================
    # Network mode check
    # Xray после перезапуска поднимает 443/tcp за несколько секунд —
    # ждём до 30 секунд, чтобы повторный запуск скрипта сразу после
    # restart не падал ложным fatal.
    # =========================================================================
    local network_mode
    network_mode=$(docker inspect remnanode --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || echo "unknown")
    NETWORK_MODE="$network_mode"

    local waited=0
    until port443_up; do
        if [[ "$waited" -ge 30 ]]; then
            spin_stop
            fatal "Порт 443/tcp не слушается (ожидание 30 с)" \
                  "Xray упал или не запустился. Логи: docker logs remnanode"
        fi
        [[ "$waited" -eq 0 ]] && spin_start "Xray ещё не слушает 443/tcp — ждём готовности (до 30 с)"
        sleep 3
        waited=$((waited + 3))
    done
    spin_stop
    if [[ "$network_mode" == "host" ]]; then
        log_ok "Xray слушает порт 443/tcp (проверено на хосте, network mode: host)"
    elif [[ "$port443_via" == "container" ]]; then
        log_ok "Xray слушает порт 443/tcp (проверено внутри контейнера)"
    else
        log_ok "Xray слушает порт 443/tcp (fallback проверка на хосте)"
    fi

    docker inspect remnanode --format '{{json .Mounts}}' 2>/dev/null | grep -q '/dev/shm' || \
        fatal "/dev/shm не примонтирован" "Добавьте в docker-compose.yml: - /dev/shm:/dev/shm"
    log_ok "/dev/shm доступен"

    # =========================================================================
    # UFW check
    # =========================================================================
    if command -v ufw &>/dev/null; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -n1 | awk '{print $2}')
        if [[ "$ufw_status" == "active" ]]; then
            log_ok "UFW активен"
            UFW_ACTIVE=true
        else
            log_warn "UFW не активен. Откройте порты вручную"
            UFW_ACTIVE=false
        fi
    else
        log_warn "UFW не установлен"
        UFW_ACTIVE=false
    fi

    echo ""
}

# ============================================================================
# PORT 443/UDP CHECK (Hysteria2)
# ============================================================================
check_udp_443() {
    local listeners
    listeners=$(ss -lunp 2>/dev/null | grep -E ':443([^0-9]|$)' || true)

    if [[ -z "$listeners" ]]; then
        log_ok "Порт 443/udp свободен (Hysteria2)"
        return 0
    fi

    # rw-core на 443/udp = наша же Hysteria2, настроенная ранее — это норма
    if echo "$listeners" | grep -q 'rw-core'; then
        log_ok "Порт 443/udp уже слушает rw-core (Hysteria2 настроена ранее)"
        return 0
    fi

    fatal "Порт 443/udp занят чужим процессом" \
          "$(echo "$listeners" | head -n2 | tr '\n' '; ')"
}

# ============================================================================
# PORT MANAGEMENT (UFW)
# ============================================================================
is_port_open_in_ufw() {
    local port="$1"
    local proto="${2:-tcp}"
    ufw status 2>/dev/null | grep -qE "^${port}/${proto}[[:space:]]+ALLOW"
}

open_port() {
    local port="$1"
    local proto="${2:-tcp}"
    local desc="$3"

    [[ "$UFW_ACTIVE" != "true" ]] && return 0

    if is_port_open_in_ufw "$port" "$proto"; then
        log_ok "Порт $port/$proto уже открыт ($desc)"
        return 0
    fi

    if ufw allow "$port/$proto" &>/dev/null; then
        log_ok "Порт $port/$proto открыт ($desc)"
        return 0
    else
        log_error "Не удалось открыть $port/$proto"
        return 1
    fi
}

# ============================================================================
# CERTIFICATE SYNC TO /dev/shm
# Копирует сертификаты источника (nginx или caddy) в /dev/shm, откуда их
# читает Hysteria2 (пути совпадают с конвертером remna.xyz:
# /dev/shm/hysteria_cert.pem + /dev/shm/hysteria_key.pem).
# Права выставляются ВСЕГДА, а не только при копировании.
#
# Возврат 0 = файлы были скопированы (нужен перезапуск), 1 = уже актуальны.
# ============================================================================
sync_certs_to_shm() {
    local shm_cert="/dev/shm/hysteria_cert.pem"
    local shm_key="/dev/shm/hysteria_key.pem"
    local copied=false

    if [[ ! -f "$shm_cert" ]] || [[ ! -f "$shm_key" ]] || \
       ! cmp -s "$CERT_PATH" "$shm_cert" || ! cmp -s "$KEY_PATH" "$shm_key"; then
        cp -f "$CERT_PATH" "$shm_cert"
        cp -f "$KEY_PATH" "$shm_key"
        copied=true
        log_ok "Сертификаты синхронизированы в /dev/shm (источник: ${WEBSERVER})"
    else
        log_ok "Сертификаты в /dev/shm актуальны"
    fi

    # Права проверяются и исправляются независимо от факта копирования
    local cert_perms key_perms perms_fixed=false

    cert_perms=$(stat -c '%a' "$shm_cert" 2>/dev/null) || cert_perms=""
    key_perms=$(stat -c '%a' "$shm_key" 2>/dev/null) || key_perms=""

    [[ "$cert_perms" != "644" ]] && perms_fixed=true
    [[ "$key_perms" != "$KEY_PERMS" ]] && perms_fixed=true

    chmod 644 "$shm_cert"
    chmod "$KEY_PERMS" "$shm_key"

    if [[ "$perms_fixed" == "true" ]]; then
        log_ok "Права доступа исправлены (cert: 644, key: ${KEY_PERMS})"
    fi

    [[ "$copied" == "true" ]] && return 0
    return 1
}

# ============================================================================
# CERTIFICATE CRON
# Две задачи:
#   @reboot  — дождаться Docker, восстановить сертификаты в /dev/shm,
#              перезапустить ноду
#   0 4 * * * — проверить и обновить сертификаты, перезапускать ноду
#              ТОЛЬКО если файлы реально изменились
#
# Задания несут маркер версии (CRON_MARKER). При запуске скрипт проверяет
# СОДЕРЖИМОЕ существующих заданий: устаревшие задания заменяются.
# Перед первой модификацией crontab сохраняется бэкап.
# ============================================================================
setup_cert_cron() {
    local sync_cmd="cp '${CERT_PATH}' /dev/shm/hysteria_cert.pem && cp '${KEY_PATH}' /dev/shm/hysteria_key.pem && chmod 644 /dev/shm/hysteria_cert.pem && chmod ${KEY_PERMS} /dev/shm/hysteria_key.pem"

    # Ожидание готовности Docker-демона после загрузки (гонка с @reboot)
    local docker_wait='for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done'
    local cron_reboot="@reboot { ${docker_wait}; ${sync_cmd} && sleep 10 && docker restart remnanode; } # ${CRON_MARKER}"

    # Перезапуск только при фактическом изменении сертификатов
    local cron_daily="0 4 * * * { [ ! -f /dev/shm/hysteria_cert.pem ] || [ ! -f /dev/shm/hysteria_key.pem ] || ! cmp -s '${CERT_PATH}' /dev/shm/hysteria_cert.pem || ! cmp -s '${KEY_PATH}' /dev/shm/hysteria_key.pem; } && { ${sync_cmd} && docker restart remnanode; } # ${CRON_MARKER}"

    local existing marked_lines
    existing=$(crontab -l 2>/dev/null) || existing=""

    if echo "$existing" | grep -q "hysteria_cert.pem"; then
        local needs_update=false

        # 1. Обе строки должны нести актуальный маркер версии
        marked_lines=$(echo "$existing" | grep -cF "${CRON_MARKER}") || marked_lines=0
        [[ "$marked_lines" -lt 2 ]] && needs_update=true

        # 2. Путь к источнику должен совпадать (веб-сервер мог смениться)
        echo "$existing" | grep -qF "${CERT_PATH}" || needs_update=true

        # 3. Устаревший небезопасный паттерн: chmod 644 на wildcard
        echo "$existing" | grep -qF 'hysteria_*.pem' && needs_update=true

        # 4. Права ключа в cron должны соответствовать текущим KEY_PERMS
        echo "$existing" | grep -qF "chmod ${KEY_PERMS} /dev/shm/hysteria_key.pem" || needs_update=true

        # 5. Старая логика без ожидания Docker (@reboot со sleep 15)
        echo "$existing" | grep -qF 'sleep 15 && docker restart remnanode' && needs_update=true

        if [[ "$needs_update" == "false" ]]; then
            log_ok "Cron уже настроен (актуальная версия ${CRON_MARKER})"
            return 0
        fi

        log_info "Обновление cron (устаревшая конфигурация)..."
        # Бэкап ДО вырезания старых строк — фиксируем реальное прошлое состояние
        if [[ -n "$existing" && ! -f "$CRONTAB_BACKUP" ]]; then
            printf '%s\n' "$existing" > "$CRONTAB_BACKUP" 2>/dev/null && \
                log_info "Бэкап crontab: $CRONTAB_BACKUP"
        fi
        existing=$(echo "$existing" | grep -v "hysteria_cert.pem") || existing=""
    else
        # Дописываем новые строки к чужому crontab — бэкап до первой правки
        if [[ -n "$existing" && ! -f "$CRONTAB_BACKUP" ]]; then
            printf '%s\n' "$existing" > "$CRONTAB_BACKUP" 2>/dev/null && \
                log_info "Бэкап crontab: $CRONTAB_BACKUP"
        fi
    fi

    {
        [[ -n "$existing" ]] && printf '%s\n' "$existing"
        printf '%s\n' "$cron_reboot"
        printf '%s\n' "$cron_daily"
    } | crontab -

    log_ok "Cron для сертификатов настроен (источник: ${WEBSERVER}, версия: ${CRON_MARKER})"
}

# ============================================================================
# MENU & PROTOCOL SELECTION
# ============================================================================
show_menu() {
    echo ""
    log_info "Выберите дополнительные протоколы:"
    echo ""
    echo -e "${BLUE}  [1]${NC} Hysteria2 (QUIC) — 443/udp"
    echo -e "${BLUE}  [2]${NC} VLESS gRPC + Reality — 8443/tcp"
    echo -e "${BLUE}  [3]${NC} VLESS XHTTP + Reality — 4443/tcp"
    echo -e "${BLUE}  [4]${NC} Все три (1+2+3)"
    echo ""
    echo -n "Ваш выбор (1-4): "
    read -r user_input || fatal "Ввод не получен" "Запустите скрипт в интерактивном терминале"

    # Обрезка ведущих/концевых пробелов (" 1 " -> "1")
    user_input="${user_input#"${user_input%%[![:space:]]*}"}"
    user_input="${user_input%"${user_input##*[![:space:]]}"}"

    SELECTED=()

    # Одна или несколько цифр 1-4, разделённых пробелами/табуляцией
    [[ ! "$user_input" =~ ^[1-4]([[:space:]]+[1-4])*$ ]] && \
        fatal "Неверный формат" "Используйте цифры 1-4. Пример: 1 2"

    for num in $user_input; do
        case "$num" in
            1) [[ ! " ${SELECTED[*]} " =~ " hy2 " ]] && SELECTED+=("hy2") ;;
            2) [[ ! " ${SELECTED[*]} " =~ " grpc " ]] && SELECTED+=("grpc") ;;
            3) [[ ! " ${SELECTED[*]} " =~ " xhttp " ]] && SELECTED+=("xhttp") ;;
            4) SELECTED=("hy2" "grpc" "xhttp"); break ;;
        esac
    done

    log_ok "Выбрано: ${SELECTED[*]}"
    echo ""
}

# ============================================================================
# APPLY CONFIG
# ============================================================================
apply_config() {
    local certs_changed=false

    for proto in "${SELECTED[@]}"; do
        case "$proto" in
            hy2)
                check_udp_443
                open_port 443 "udp" "Hysteria2"
                sync_certs_to_shm && certs_changed=true
                setup_cert_cron
                ;;
            grpc)
                open_port 8443 "tcp" "VLESS gRPC"
                ;;
            xhttp)
                open_port 4443 "tcp" "VLESS XHTTP"
                ;;
        esac
    done

    if [[ "$certs_changed" == "true" ]]; then
        spin_start "Перезапуск контейнера remnanode..."
        if docker restart remnanode &>/dev/null; then
            spin_stop
            # Ждём, пока Xray снова поднимет 443/tcp — нода не должна
            # остаться «полуживой» после выхода скрипта
            local waited=0
            until port443_up; do
                [[ "$waited" -ge 30 ]] && break
                [[ "$waited" -eq 0 ]] && spin_start "Ожидаем готовности Xray после перезапуска (до 30 с)"
                sleep 3
                waited=$((waited + 3))
            done
            spin_stop
            if port443_up; then
                log_ok "Контейнер перезапущен, Xray слушает 443/tcp"
            else
                log_warn "Контейнер перезапущен, но 443/tcp ещё не поднялся"
                log_warn "Проверьте: docker logs remnanode"
            fi
        else
            spin_stop
            log_error "Не удалось перезапустить контейнер"
        fi
    else
        log_ok "Перезапуск не требуется"
    fi

    echo ""
}

# ============================================================================
# FINALIZE
# ============================================================================
finalize() {
    echo "═══════════════════════════════════════════════════════════"
    echo -e "${GREEN}✓ Настройка завершена!${NC}"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    echo -e "${BLUE}📋 Сводка:${NC}"
    echo "   • Домен: $DOMAIN"
    echo "   • Веб-сервер: ${WEBSERVER^^}"
    echo "   • Источник сертификата: $CERT_PATH"
    echo "   • Права ключа: ${KEY_PERMS}"
    echo "   • Базовый: 443/tcp — VLESS TCP Reality"

    local hy2_enabled=false
    for proto in "${SELECTED[@]}"; do
        case "$proto" in
            hy2)   echo "   • 443/udp — Hysteria2"; hy2_enabled=true ;;
            grpc)  echo "   • 8443/tcp — VLESS gRPC" ;;
            xhttp) echo "   • 4443/tcp — VLESS XHTTP" ;;
        esac
    done

    echo ""
    echo -e "${BLUE}🔧 Следующие шаги:${NC}"
    echo "   1. Откройте панель Remnawave"
    echo "   2. Используйте конвертер:"
    echo -e "      ${BLUE}https://remna.xyz/pages/convert/${NC}"
    echo "   3. Вставьте конфиг в профиль ноды"

    if [[ "$hy2_enabled" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}⚠ Не забудьте:${NC}"
        echo "   • Открыть 443/udp в файрволе облака (security group / iptables провайдера)"
        echo "   • Cron-задачи: $(crontab -l 2>/dev/null | grep -cF "$CRON_MARKER") шт. (маркер ${CRON_MARKER})"
        [[ -f "$CRONTAB_BACKUP" ]] && echo "   • Бэкап crontab: $CRONTAB_BACKUP"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    clear 2>/dev/null || true
    show_logo
    echo ""
    stage 1 "Проверки окружения"
    preflight_checks
    stage 2 "Выбор протоколов"
    show_menu
    stage 3 "Применение конфигурации"
    apply_config
    stage 4 "Завершение"
    finalize
}

main "$@"
