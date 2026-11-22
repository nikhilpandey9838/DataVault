
#!/bin/bash

# DataVault - Automated PostgreSQL Backup Engine
# Version: 3.0

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
S3_BUCKET="${S3_BUCKET:-datavault-backups-2500}"
S3_PREFIX="${S3_PREFIX:-backups}"


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

exec 9>"$BACKUP_DIR/.backup.lock"

if ! flock -n 9; then
    log "ERROR: Another backup process is already running"
    exit 1
fi

log "========================================"
log "DataVault backup process started"
log "Database: $DB_NAME"

for command in docker gzip flock find du grep aws; do
    if ! command -v "$command" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $command"
        exit 1
    fi
done

if ! docker inspect \
    -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -qx true; then

    log "ERROR: PostgreSQL container is not running"
    exit 1
fi

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

if ! gzip -dc "$TEMP_FILE" | grep -F 'PostgreSQL database dump' >/dev/null; then
    log "ERROR: Invalid PostgreSQL dump format"
    exit 1
fi

# ---------------- PUBLISH LOCAL BACKUP ----------------
mv "$TEMP_FILE" "$BACKUP_FILE"
TEMP_FILE=""

log "Local backup created: $BACKUP_FILE"

# ---------------- AWS S3 UPLOAD ----------------

S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}/"

log "Uploading backup to AWS S3"

if ! aws s3 cp "$BACKUP_FILE" "$S3_URI" --only-show-errors; then
    log "ERROR: AWS S3 upload failed"
    log "Local backup preserved: $BACKUP_FILE"
    exit 1
fi

log "AWS S3 upload completed: $S3_URI"

# ---------------- BACKUP SUMMARY ----------------

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "Backup completed successfully"
log "Backup file: $BACKUP_FILE"
log "Backup size: $BACKUP_SIZE"
log "Execution time: ${DURATION} seconds"

# ---------------- RETENTION MANAGEMENT ----------------

log "Applying local retention policy: ${RETENTION_DAYS} days"

find "$BACKUP_DIR" \
    -maxdepth 1 \
    -type f \
    -name "${DB_NAME}_*.sql.gz" \
    -mtime "+$RETENTION_DAYS" \
    -delete

log "Local retention cleanup completed"
log "DataVault backup process finished successfully"
log "========================================"
