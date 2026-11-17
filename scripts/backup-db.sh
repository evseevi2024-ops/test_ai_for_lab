#!/usr/bin/env bash
# ============================================================
# backup-db.sh — резервное копирование базы данных Zabbix (PostgreSQL)
# Выполняет pg_dump из контейнера monitoring-postgresql, сжимает дамп,
# хранит последние 7 копий в /opt/monitoring/backups.
# Устанавливается ролью main-host в /usr/local/bin и в cron (03:00).
# ============================================================
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/monitoring/backups}"
CONTAINER="${PG_CONTAINER:-monitoring-postgresql}"
DB_USER="${POSTGRES_USER:-zabbix}"
DB_NAME="${POSTGRES_DB:-zabbix}"
RETENTION_DAYS=7
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${BACKUP_DIR}/zabbix_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

log() { echo "[$(date '+%F %T')] backup-db: $*"; }

if ! command -v docker >/dev/null 2>&1; then
    log "ОШИБКА: docker не найден."; exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "ОШИБКА: контейнер ${CONTAINER} не запущен."; exit 1
fi

log "Запуск pg_dump ${DB_NAME} -> ${OUT_FILE}"
docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists \
    | gzip > "$OUT_FILE"

SIZE="$(du -h "$OUT_FILE" | cut -f1)"
log "Дамп создан: ${OUT_FILE} (${SIZE})"

# Ротация старых дампов
DELETED="$(find "$BACKUP_DIR" -name 'zabbix_*.sql.gz' -mtime +${RETENTION_DAYS} -print -delete | wc -l)"
log "Удалено старых копий (> ${RETENTION_DAYS} дней): ${DELETED}"

# Проверка целостности архива
gzip -t "$OUT_FILE" && log "Контроль целостности gzip: OK"

log "Резервное копирование завершено успешно."
