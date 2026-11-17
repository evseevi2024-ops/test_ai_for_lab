#!/usr/bin/env bash
# ============================================================
# generate-certs.sh — генерация TLS-сертификатов для Rsyslog (ЛР 3)
# и опционального внутреннего ЦС Smallstep.
#
# Создаёт в каталоге ./certs :
#   ca.crt / ca.key            — корневой центр стенда
#   server.crt / server.key    — сертификат основного хоста (ВМ 1)
#   client.crt / client.key    — сертификат подхоста (ВМ 2)
#
# IP-адреса берутся из .env (MAIN_HOST_IP, AGENT_HOST_IP).
# Повторный запуск не пересоздаёт существующие сертификаты.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

CERTS_DIR="$SCRIPT_DIR/certs"
TPL_DIR="$SCRIPT_DIR/files/cert-templates"
DAYS_CA=1825
DAYS_HOST=825

# Загрузка .env при наличии
if [[ -f .env ]]; then
    set -a; source .env; set +a
fi
MAIN_HOST_IP="${MAIN_HOST_IP:-192.168.100.10}"
AGENT_HOST_IP="${AGENT_HOST_IP:-192.168.200.20}"

mkdir -p "$CERTS_DIR"
chmod 700 "$CERTS_DIR"

log() { echo "[certs] $*"; }

# ---------- Корневой CA ----------
if [[ ! -f "$CERTS_DIR/ca.key" || ! -f "$CERTS_DIR/ca.crt" ]]; then
    log "Генерация корневого CA..."
    openssl genrsa -out "$CERTS_DIR/ca.key" 4096
    openssl req -x509 -new -nodes -key "$CERTS_DIR/ca.key" \
        -sha256 -days "$DAYS_CA" \
        -out "$CERTS_DIR/ca.crt" \
        -config <(sed 's|./certs|'"$CERTS_DIR"'|' "$TPL_DIR/ca.cnf.template")
else
    log "CA уже существует — пропускаю."
fi

# Индекс/серийник для подписания
touch "$CERTS_DIR/index.txt"
[[ -f "$CERTS_DIR/serial" ]] || echo 1000 > "$CERTS_DIR/serial"

sign_csr() {  # $1 = имя хоста, $2 = CSR
    local name="$1" csr="$2" ext="$3"
    openssl ca -batch -config <(sed 's|./certs|'"$CERTS_DIR"'|' "$TPL_DIR/ca.cnf.template") \
        -extensions "$ext" -days "$DAYS_HOST" -notext -md sha256 \
        -in "$csr" -out "$CERTS_DIR/${name}.crt"
}

make_host_cert() {  # $1 = имя, $2 = CN, $3 = IP
    local name="$1" cn="$2" ip="$3"
    if [[ -f "$CERTS_DIR/${name}.crt" ]]; then
        log "Сертификат ${name} уже существует — пропускаю."
        return 0
    fi
    log "Выпуск сертификата ${name} (CN=${cn}, IP=${ip})..."
    local cnf="$CERTS_DIR/${name}.cnf"
    sed -e "s|__COMMON_NAME__|${cn}|g" -e "s|__HOST_IP__|${ip}|g" \
        "$TPL_DIR/host.cnf.template" > "$cnf"
    openssl genrsa -out "$CERTS_DIR/${name}.key" 2048
    chmod 600 "$CERTS_DIR/${name}.key"
    openssl req -new -key "$CERTS_DIR/${name}.key" -out "$CERTS_DIR/${name}.csr" -config "$cnf"
    sign_csr "$name" "$CERTS_DIR/${name}.csr" v3_req
    rm -f "$CERTS_DIR/${name}.csr" "$cnf"
    openssl verify -CAfile "$CERTS_DIR/ca.crt" "$CERTS_DIR/${name}.crt"
}

# Сервер: основной хост; клиент: подхост
make_host_cert server "main-host.monitoring.local" "$MAIN_HOST_IP"
make_host_cert client "agent-host.monitoring.local" "$AGENT_HOST_IP"

# Права
chmod 644 "$CERTS_DIR"/*.crt
chown -R root:root "$CERTS_DIR" 2>/dev/null || true

log "Готово. Каталог сертификатов: $CERTS_DIR"
ls -l "$CERTS_DIR"
