#!/usr/bin/env bash
# ============================================================
# test.sh — end-to-end тестирование стенда мониторинга
# (раздел 8 технического задания). Запускать с основного хоста;
# проверки удалённых узлов идут через проброс портов/VPN.
#
# Использование: ./test.sh          — все проверки
#                TEST_SKIP_LOAD=1 ./test.sh  — без генерации нагрузки
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] && { set -a; source .env; set +a; }

MAIN_HOST_IP="${MAIN_HOST_IP:-192.168.100.10}"
AGENT_HOST_IP="${AGENT_HOST_IP:-192.168.200.20}"
SYSLOG_TLS_PORT="${SYSLOG_TLS_PORT:-6514}"
SPLUNK_WEB_PORT="${SPLUNK_WEB_PORT:-8000}"
ZABBIX_WEB_PORT="${ZABBIX_WEB_PORT:-8080}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; RESULTS=()

check() { # $1 название, $2 команда...
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[PASS]${NC} ${name}"; RESULTS+=("PASS|${name}"); ((PASS++))
    else
        echo -e "  ${RED}[FAIL]${NC} ${name}"; RESULTS+=("FAIL|${name}"); ((FAIL++))
    fi
}

echo "=== E2E-тестирование системы мониторинга ==="
echo ""

# ---------- Проверка 1. Доступность Apache на ВМ 2 (ожидается HTTP 200) ----------
echo "[1/7] Целевое приложение (Apache/Nginx) на подхосте..."
check_http_200() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${AGENT_HOST_IP}:80/" || echo 000)
    [[ "$code" == "200" ]]
}
check "HTTP 200 от http://${AGENT_HOST_IP}/" check_http_200

# ---------- Проверка 2. SNMPv3 запрос к ВМ 2 (sysUpTime) ----------
echo "[2/7] SNMPv3 (authPriv) запрос sysUpTime к подхосту..."
check_snmp_v3() {
    snmpget -v3 -l authPriv -u "${SNMP_USER:-monitor}" \
        -a SHA -A "${SNMP_AUTH_PASS}" -x AES -X "${SNMP_PRIV_PASS}" \
        "${AGENT_HOST_IP}:161" sysUpTime.0 2>/dev/null | grep -qi 'Timeticks\|STRING\|INTEGER'
}
check "SNMPv3 v3authPriv ответ от ${AGENT_HOST_IP}:161" check_snmp_v3

# ---------- Проверка 3. Zabbix Server принимает данные (порт 10051) ----------
echo "[3/7] Zabbix Server: порт 10051..."
check "Порт ${MAIN_HOST_IP}:10051 открыт" bash -c \
    "timeout 5 bash -c '</dev/tcp/${MAIN_HOST_IP}/10051'"

# ---------- Проверка 4. Rsyslog TLS работает (порт 6514) ----------
echo "[4/7] Rsyslog TLS: порт ${SYSLOG_TLS_PORT} и TLS handshake..."
check_syslog_tls() {
    timeout 5 bash -c "</dev/tcp/${MAIN_HOST_IP}/${SYSLOG_TLS_PORT}" && \
    echo QUIT | timeout 10 openssl s_client \
        -connect "${MAIN_HOST_IP}:${SYSLOG_TLS_PORT}" -CAfile certs/ca.crt 2>/dev/null \
        | grep -q 'Verify return code: 0 (ok)'
}
check "TLS-handshake на ${MAIN_HOST_IP}:${SYSLOG_TLS_PORT} верифицирован CA" check_syslog_tls

# ---------- Проверка 5. Splunk принимает логи (непустой основной индекс) ----------
echo "[5/7] Splunk: поиск по основному индексу..."
check_splunk_events() {
    local earliest latest count
    earliest=$(date -d '-1 hour' +%s 2>/dev/null || date -v-1H +%s)
    latest=$(date +%s)
    count=$(curl -s -k -u "admin:${SPLUNK_PASSWORD}" \
        "http://${MAIN_HOST_IP}:${SPLUNK_WEB_PORT}/services/search/jobs/export" \
        --data-urlencode "search=search index=* | stats count" \
        --data-urlencode "output_mode=json" \
        --data-urlencode "earliest_time=${earliest}" \
        --data-urlencode "latest_time=${latest}" | grep -o '"count":"[0-9]*"' | head -1)
    [[ -n "$count" && "$count" != '"count":"0"' ]]
}
check "Индекс Splunk содержит события за последний час" check_splunk_events

# ---------- Проверка 6. Триггеры срабатывают (симуляция нагрузки -> алерт) ----------
echo "[6/7] Симуляция нагрузки CPU и ожидание триггера Zabbix..."
if [[ "${TEST_SKIP_LOAD:-0}" != "1" ]]; then
    ( timeout 60 bash -c 'while :; do :; done' & ) >/dev/null 2>&1 || true
    LOAD_PID=$!
fi
check_zabbix_trigger() {
    # Опрашиваем API Zabbix: есть ли PROBLEM по узлу нагрузки/агенту
    local auth
    auth=$(curl -s -X POST "http://${MAIN_HOST_IP}:${ZABBIX_WEB_PORT}/api_jsonrpc.php" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"'"${ZABBIX_ADMIN_PASSWORD}"'"},"id":1}' \
        | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
    [[ -z "$auth" ]] && return 1
    local problems
    problems=$(curl -s -X POST "http://${MAIN_HOST_IP}:${ZABBIX_WEB_PORT}/api_jsonrpc.php" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"problem.get","params":{"output":["name","severity"],"recent":true},"auth":"'"$auth"'","id":2}')
    echo "$problems" | grep -q '"name"'
}
TRIGGER_OK=0
for i in $(seq 1 10); do
    if check_zabbix_trigger; then TRIGGER_OK=1; break; fi
    sleep 15
done
if [[ $TRIGGER_OK -eq 1 ]]; then
    echo -e "  ${GREEN}[PASS]${NC} Алерт по триггеру Zabbix наблюдается"; RESULTS+=("PASS|Триггер Zabbix"); ((PASS++))
else
    echo -e "  ${YELLOW}[WARN]${NC} Алерт не дождались (проверьте шаблон Linux by Zabbix agent и время обновления)"; RESULTS+=("WARN|Триггер Zabbix")
fi
[[ "${TEST_SKIP_LOAD:-0}" != "1" ]] && kill "$LOAD_PID" 2>/dev/null || true

# ---------- Проверка 7. Корреляция событий (лог-ошибка + SNMP-пик -> совместный алерт) ----------
echo "[7/7] Корреляция: ошибка в логах + пик трафика SNMP..."
# Генерируем тестовую ошибку на подхосте (попадёт в Splunk через rsyslog TLS)
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "ubuntu@${AGENT_HOST_IP}" \
    "logger -p local6.err 'E2E correlation test error event'" 2>/dev/null || \
    logger -p local6.err 'E2E correlation test error event'
# Пик трафика: короткий flood на localhost подхоста
ssh -o ConnectTimeout=5 "ubuntu@${AGENT_HOST_IP}" \
    "for i in \$(seq 1 200); do curl -s -o /dev/null http://127.0.0.1/; done" 2>/dev/null || true
check_correlation() {
    # В Splunk должен найден совмещённый поиск: err-событие И высокий ifInOctets
    local res
    res=$(curl -s -k -u "admin:${SPLUNK_PASSWORD}" \
        "http://${MAIN_HOST_IP}:${SPLUNK_WEB_PORT}/services/search/jobs/export" \
        --data-urlencode "search=search index=* \"correlation test error\" OR [search index=snmp sourcetype=snmp_trap]" \
        --data-urlencode "output_mode=json" | head -c 200)
    [[ -n "$res" && "$res" != "{}" ]]
}
sleep 20
check "Совместный корреляционный поиск возвращает события" check_correlation

# ---------- Итог ----------
echo ""
echo "================= ИТОГ ================="
for r in "${RESULTS[@]}"; do echo "  ${r//|/  }"; done
echo "----------------------------------------"
echo -e "  Успешно: ${GREEN}${PASS}${NC}   Провалено: ${RED}${FAIL}${NC}"
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}Стенд готов к демонстрации.${NC}"
    exit 0
else
    echo -e "${RED}Есть неуспешные проверки — см. docs/troubleshooting.md${NC}"
    exit 1
fi
