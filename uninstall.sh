#!/usr/bin/env bash
# ============================================================
# uninstall.sh — полная очистка стенда мониторинга с узла.
# Удаляет Docker-стек, пакеты компонентов, каталоги развёртывания,
# сертификаты и записи cron. Требует подтверждения (или --yes).
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] && { set -a; source .env; set +a; }
NODE_ROLE="${NODE_ROLE:-main}"
ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[UNINSTALL]${NC} $*"; }

echo "Внимание: будет выполнена ПОЛНАЯ очистка роли '${NODE_ROLE}' на этом хосте."
echo "Будут удалены: контейнеры и тома Docker, Zabbix/SNMP/rsyslog-конфиги, /opt/monitoring*, ./certs."
if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Продолжить? [yes/N] " ans
    [[ "$ans" == "yes" ]] || { info "Отменено."; exit 0; }
fi

SUDO=""
[[ $(id -u) -ne 0 ]] && SUDO="sudo"

# ---------- Очистка Docker-стеков ----------
remove_compose() { # $1 = каталог проекта
    if [[ -d "$1" ]]; then
        info "Остановка compose-стека в $1 ..."
        $SUDO docker compose -f "$1"/docker-compose-main.yml down -v --remove-orphans 2>/dev/null || \
        $SUDO docker compose -f "$1"/docker-compose.yml down -v --remove-orphans 2>/dev/null || true
    fi
}

remove_containers_by_prefix() {
    local ids
    ids=$($SUDO docker ps -aq --filter "name=$1" 2>/dev/null || true)
    if [[ -n "$ids" ]]; then
        info "Удаление контейнеров по префику '$1'..."
        $SUDO docker rm -f $ids >/dev/null 2>&1 || true
    fi
}

# ---------- Общие удаления ----------
info "Удаление каталогов развёртывания и сертификатов..."
$SUDO rm -rf /opt/monitoring /opt/monitoring-agent "$SCRIPT_DIR/certs"
$SUDO rm -f /usr/local/bin/backup-db.sh
$SUDO crontab -l 2>/dev/null | grep -v 'zabbix-postgres-backup' | $SUDO tee /etc/crontab >/dev/null 2>&1 || true
$SUDO rm -f /etc/cron.d/zabbix-postgres-backup

# ---------- Роль main ----------
if [[ "$NODE_ROLE" == "main" ]]; then
    remove_compose "/opt/monitoring"
    remove_containers_by_prefix "zabbix"
    remove_containers_by_prefix "monitoring-postgresql"
    remove_containers_by_prefix "splunk"
    remove_containers_by_prefix "rsyslog-tls-server"
    remove_containers_by_prefix "stepca"
    $SUDO docker volume prune -f >/dev/null 2>&1 || true

    info "Удаление пакетов основной роли..."
    $SUDO apt-get purge -y rsyslog-gnutls >/dev/null 2>&1 || true
    $SUDO rm -f /etc/rsyslog.d/10-monitoring-server.conf
    $SUDO systemctl restart rsyslog >/dev/null 2>&1 || true
fi

# ---------- Роль agent ----------
if [[ "$NODE_ROLE" == "agent" ]]; then
    remove_compose "/opt/monitoring-agent"
    remove_containers_by_prefix "custom-monitor-plugin"

    info "Остановка и удаление пакетов агентской роли..."
    for svc in zabbix-agent2 snmpd apache2 nginx; do
        $SUDO systemctl disable --now "$svc" >/dev/null 2>&1 || true
    done
    $SUDO apt-get purge -y zabbix-agent2 snmp snmpd libsnmp-base apache2 nginx >/dev/null 2>&1 || true
    $SUDO apt-get autoremove -y >/dev/null 2>&1 || true
    $SUDO rm -rf /etc/zabbix /etc/snmp /var/lib/snmp
    $SUDO rm -f /etc/rsyslog.d/10-monitoring-client.conf
    $SUDO systemctl restart rsyslog >/dev/null 2>&1 || true
    $SUDO rm -rf /var/www/html
fi

info "Очистка завершена. При необходимости удалите образы: docker image prune -a"
info "Docker и Ansible намеренно оставлены (используются системой)."
