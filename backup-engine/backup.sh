
#!/bin/bash

# DataVault - Automated PostgreSQL Backup Engine
# Version: 2.0

set -Eeuo pipefail
umask 077

# ---------------- CONFIGURATION ----------------

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BACKUP_DIR="${BACKUP_DIR:-$PROJECT_DIR/backups}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
LOG_FILE="$LOG_DIR/backup.log"

CONTAINER_NAME="${CONTAINER_NAME:-datavault-postgres}"
DB_NAME="${DB_NAME:-datavault_db}"
DB_USER="${DB_USER:-datavault}"

RETENTION_DAYS="${RETENTION_DAYS:-7}"

TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql.gz"
TEMP_FILE=""

# ---------------- INITIALIZATION ----------------

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

cleanup() {
    if [[ -n "$TEMP_FILE" && -f "$TEMP_FILE" ]]; then
        rm -f "$TEMP_FILE"
    fi
}

trap cleanup EXIT

START_TIME=$(date +%s)

# ---------------- VALIDATION ----------------

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    log "ERROR: RETENTION_DAYS must be a non-negative integer"
    exit 1
fi

# Prevent overlapping backup executions
exec 9>"$BACKUP_DIR/.backup.lock"

if ! flock -n 9; then
    log "ERROR: Another backup process is already running"
    exit 1
fi

log "========================================"
log "DataVault backup process started"
log "Database: $DB_NAME"

# Check required commands
for command in docker gzip flock find du; do
    if ! command -v "$command" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $command"
        exit 1
    fi
done

# Check PostgreSQL container
if ! docker inspect \
    -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx true; then

    log "ERROR: PostgreSQL container is not running"
    exit 1
fi

# Check database connectivity
if ! docker exec "$CONTAINER_NAME" \
    pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then

    log "ERROR: PostgreSQL database is not accepting connections"
    exit 1
fi

# ---------------- BACKUP GENERATION ----------------

TEMP_FILE="$BACKUP_DIR/.${DB_NAME}_${TIMESTAMP}.tmp"

log "Generating PostgreSQL backup"

if ! docker exec "$CONTAINER_NAME" pg_dump \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    | gzip -c > "$TEMP_FILE"; then

    log "ERROR: Backup generation failed"
    exit 1
fi

# Reject empty backups
if [[ ! -s "$TEMP_FILE" ]]; then
    log "ERROR: Generated backup is empty"
    exit 1
fi

# ---------------- INTEGRITY VERIFICATION ----------------

log "Checking backup integrity"

if ! gzip -t "$TEMP_FILE"; then
    log "ERROR: Gzip integrity verification failed"
    exit 1
fi

# Verify PostgreSQL dump structure
if ! gzip -dc "$TEMP_FILE" | grep -q 'PostgreSQL database dump'; then
    log "ERROR: Invalid PostgreSQL dump format"
    exit 1
fi

# ---------------- PUBLISH BACKUP ----------------

mv "$TEMP_FILE" "$BACKUP_FILE"
TEMP_FILE=""

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "Backup completed successfully"
log "Backup file: $BACKUP_FILE"
log "Backup size: $BACKUP_SIZE"
log "Execution time: ${DURATION} seconds"

# ---------------- RETENTION MANAGEMENT ----------------

log "Applying retention policy: ${RETENTION_DAYS} days"

find "$BACKUP_DIR" \
    -maxdepth 1 \
    -type f \
    -name "${DB_NAME}_*.sql.gz" \
    -mtime "+$RETENTION_DAYS" \
    -delete

log "Retention cleanup completed"
log "DataVault backup process finished successfully"
log "========================================"
