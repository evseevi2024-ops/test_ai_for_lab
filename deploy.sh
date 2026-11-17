#!/usr/bin/env bash
# ============================================================
# deploy.sh — автоматизированное развёртывание системы мониторинга
#
# Использование:
#   chmod +x deploy.sh && ./deploy.sh
#
# Предварительно скопируйте .env.example в .env и заполните значения.
# Роль узла определяется переменной NODE_ROLE (main | agent).
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- Шаг 0. Проверка зависимостей ----------
check_dependencies() {
    info "Проверка зависимостей..."
    local missing=0

    if ! command -v docker >/dev/null 2>&1; then
        error "Не найден docker. Установка: sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2"
        missing=1
    else
        if ! docker compose version >/dev/null 2>&1; then
            error "Docker Compose v2 недоступен (docker compose). Обновите Docker."
            missing=1
        fi
    fi

    if ! command -v ansible-playbook >/dev/null 2>&1; then
        error "Не найден ansible. Установка: sudo apt-get update && sudo apt-get install -y ansible"
        missing=1
    fi

    # Утилиты SNMP нужны для тестирования; при их отсутствии ставим сами (роль agent)
    if ! command -v snmpget >/dev/null 2>&1; then
        warn "Утилиты snmp не найдены — attempt автоустановки libs-snmp..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y -qq snmp libsnmp-dev >/dev/null 2>&1 || \
                warn "Не удалось автоматически установить snmp-утилиты (потребуются sudo/сеть)."
        fi
    fi

    [[ $missing -eq 0 ]] || { error "Установите недостающие зависимости и повторите запуск."; exit 1; }
    info "Зависимости на месте: docker, ansible, snmp."
}

# ---------- Шаг 1. Чтение .env ----------
load_env() {
    if [[ ! -f .env ]]; then
        error "Файл .env не найден. Выполните: cp .env.example .env и заполните значения."
        exit 1
    fi
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a

    : "${MAIN_HOST_IP:?MAIN_HOST_IP не задан в .env}"
    : "${AGENT_HOST_IP:?AGENT_HOST_IP не задан в .env}"
    : "${NODE_ROLE:?NODE_ROLE не задан в .env (main | agent)}"
    : "${ZABBIX_DB_PASSWORD:?ZABBIX_DB_PASSWORD не задан в .env}"
    : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD не задан в .env}"
    : "${SNMP_USER:?SNMP_USER не задан в .env}"
    : "${SNMP_AUTH_PASS:?SNMP_AUTH_PASS не задан в .env}"
    : "${SNMP_PRIV_PASS:?SNMP_PRIV_PASS не задан в .env}"
    : "${SPLUNK_PASSWORD:?SPLUNK_PASSWORD не задан в .env}"

    export SYSLOG_TLS_PORT="${SYSLOG_TLS_PORT:-6514}"
    info "Переменные окружения загружены. Роль узла: ${NODE_ROLE}"
}

# ---------- Шаг 2. Генерация TLS-сертификатов ----------
generate_certs() {
    info "Генерация TLS-сертификатов для Rsyslog..."
    chmod +x scripts/generate-certs.sh
    ./scripts/generate-certs.sh
}

# ---------- Шаг 3. Запуск Ansible playbook по роли ----------
run_ansible() {
    case "$NODE_ROLE" in
        main)
            info "Запуск Ansible: роль MAIN (Zabbix Server, PostgreSQL, Splunk, Rsyslog-server)..."
            ansible-playbook -i inventory/main.ini roles/base/site.yml --tags base
            ansible-playbook -i inventory/main.ini roles/main-host/site.yml \
                -e "node_role=main main_host_ip=${MAIN_HOST_IP} agent_host_ip=${AGENT_HOST_IP}"
            ;;
        agent)
            info "Запуск Ansible: роль AGENT (Apache/Nginx, Zabbix Agent 2, SNMPd, Rsyslog-client)..."
            ansible-playbook -i inventory/agent.ini roles/base/site.yml --tags base
            ansible-playbook -i inventory/agent-host/site.yml \
                -e "node_role=agent main_host_ip=${MAIN_HOST_IP} agent_host_ip=${AGENT_HOST_IP}"
            ;;
        *)
            error "Неизвестное значение NODE_ROLE='${NODE_ROLE}'. Ожидается main или agent."
            exit 1
            ;;
    esac
}

# ---------- Шаг 4. Итоговый отчёт ----------
final_report() {
    info "Итоговый отчёт о состоянии сервисов:"
    echo "------------------------------------------------------------"
    if [[ "$NODE_ROLE" == "main" ]]; then
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
        ss -ltn | grep -E ':(8080|8000|10051|'"${SYSLOG_TLS_PORT}"')\b' || true
        echo ""
        echo "  Zabbix Web   : http://${MAIN_HOST_IP}:8080  (Admin / <ZABBIX_ADMIN_PASSWORD>)"
        echo "  Splunk Web   : http://${MAIN_HOST_IP}:8000  (admin / <SPLUNK_PASSWORD>)"
        echo "  Zabbix Trapper: ${MAIN_HOST_IP}:10051"
        echo "  Rsyslog TLS  : ${MAIN_HOST_IP}:${SYSLOG_TLS_PORT}"
    else
        systemctl is-active apache2 nginx snmpd zabbix-agent2 rsyslog 2>/dev/null | paste -d' ' -c || true
        ss -ltn | grep -E ':(80|161|10050)\b' || true
        echo ""
        echo "  Apache       : http://${AGENT_HOST_IP}:80"
        echo "  SNMPv3       : udp/${AGENT_HOST_IP}:161 (user=${SNMP_USER}, auth=SHA, priv=AES)"
        echo "  Zabbix Agent2: ${AGENT_HOST_IP}:10050 -> сервер ${MAIN_HOST_IP}:10051"
        echo "  Rsyslog TLS  : клиент -> ${MAIN_HOST_IP}:${SYSLOG_TLS_PORT}"
    fi
    echo "------------------------------------------------------------"
    info "Развёртывание завершено. Проверка работоспособности: ./test.sh"
}

main() {
    info "=== Автоматизированная система мониторинга: развёртывание ==="
    check_dependencies
    load_env
    generate_certs
    run_ansible
    final_report
}

main "$@"
