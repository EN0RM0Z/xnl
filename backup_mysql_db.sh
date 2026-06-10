#!/bin/bash

set -o pipefail

# =========================
# КОНФИГУРАЦИЯ
# =========================

DB_NAMES=("db1" "db2" "db3")

DB_USER="backup_user"
DB_HOST="localhost"

LOCAL_BACKUP_DIR="/var/backups/db_dumps"

REMOTE_BACKUP_DIR="/mnt/backup_storage/db"
REMOTE_USER="backupuser"
REMOTE_HOST="server02"

RETENTION_DAYS=30
COMPRESSION_LEVEL=6

COPY_METHOD="RSYNC"

MIN_DUMP_SIZE=10240

MYSQL_CNF="/home/backupuser/.my.cnf"

BACKUP_PREFIX="mysql"

LOG_FILE="/var/log/mysql_backup.log"

TIMESTAMP=$(date +%Y%m%d)

# =========================
# СТАТУС
# =========================

HAS_ERROR=0
ERRORS=()
SUCCESS_DUMPS=()
SUCCESS_COPIED=()

# =========================
# ФУНКЦИИ
# =========================

log_msg() {
    echo "$1" | tee -a "$LOG_FILE"
}

add_error() {
    HAS_ERROR=1
    ERRORS+=("$1")
    log_msg "[ERROR] $1"
}

write_final_status() {
    if [ "$HAS_ERROR" -eq 0 ]; then
        log_msg "[INFO] MySQL backup report"
    else
        log_msg "[ERROR] MySQL backup report"
    fi
}

finish_script() {
    log_msg "===== [$(date)] Процесс завершен ====="
    write_final_status

    if [ "$HAS_ERROR" -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

# =========================
# НАЧАЛО
# =========================

log_msg "===== [$(date)] Начало резервного копирования ====="
log_msg "[INFO] Базы для бэкапа: ${DB_NAMES[*]}"

if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
    add_error "Директория $LOCAL_BACKUP_DIR не существует"
    finish_script
fi

if [ ! -w "$LOCAL_BACKUP_DIR" ]; then
    add_error "Нет прав на запись в $LOCAL_BACKUP_DIR"
    finish_script
fi

if [ ! -f "$MYSQL_CNF" ]; then
    add_error "Файл конфигурации MySQL не найден: $MYSQL_CNF"
    finish_script
fi

for cmd in mysqldump gzip rsync scp stat find; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        add_error "Отсутствует команда: $cmd"
        finish_script
    fi
done

MIN_SPACE_KB=$((1024 * 1024))
AVAILABLE_SPACE=$(df -k --output=avail "$LOCAL_BACKUP_DIR" | awk 'NR==2 {print $1}')

if [ "$AVAILABLE_SPACE" -lt "$MIN_SPACE_KB" ]; then
    add_error "Недостаточно места на диске"
    finish_script
fi

rm -f "${LOCAL_BACKUP_DIR}/${BACKUP_PREFIX}_*.sql.gz" 2>/dev/null

# =========================
# ДАМПЫ
# =========================

log_msg "[INFO] Создание дампов"

for DB_NAME in "${DB_NAMES[@]}"; do

    BACKUP_FILE="${BACKUP_PREFIX}_${DB_NAME}_${TIMESTAMP}.sql.gz"
    BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_FILE}"

    log_msg "[INFO] Дамп базы $DB_NAME"

    if ! mysqldump \
        --defaults-extra-file="$MYSQL_CNF" \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        "$DB_NAME" | gzip -"$COMPRESSION_LEVEL" > "$BACKUP_PATH"; then

        add_error "Ошибка дампа $DB_NAME"
        rm -f "$BACKUP_PATH"
        continue
    fi

    if ! gzip -t "$BACKUP_PATH"; then
        add_error "Поврежден архив $DB_NAME"
        rm -f "$BACKUP_PATH"
        continue
    fi

    SIZE=$(stat -c%s "$BACKUP_PATH")

    if [ "$SIZE" -lt "$MIN_DUMP_SIZE" ]; then
        add_error "Слишком маленький дамп $DB_NAME"
        rm -f "$BACKUP_PATH"
        continue
    fi

    SUCCESS_DUMPS+=("$DB_NAME")
    log_msg "[INFO] $DB_NAME успешно сохранена ($SIZE байт)"

done

if [ ${#SUCCESS_DUMPS[@]} -eq 0 ]; then
    add_error "Не создано ни одного дампа"
    finish_script
fi

# =========================
# КОПИРОВАНИЕ
# =========================

log_msg "[INFO] Копирование на удаленный сервер"

for DB_NAME in "${SUCCESS_DUMPS[@]}"; do

    BACKUP_FILE="${BACKUP_PREFIX}_${DB_NAME}_${TIMESTAMP}.sql.gz"
    BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_FILE}"

    if [ "$COPY_METHOD" == "RSYNC" ]; then

        rsync -avz -e ssh \
            "$BACKUP_PATH" \
            "$REMOTE_USER@$REMOTE_HOST:$REMOTE_BACKUP_DIR/"

    else

        scp "$BACKUP_PATH" \
            "$REMOTE_USER@$REMOTE_HOST:$REMOTE_BACKUP_DIR/"
    fi

    if [ $? -ne 0 ]; then
        add_error "Ошибка копирования $DB_NAME"
        continue
    fi

    SUCCESS_COPIED+=("$DB_NAME")

done

# =========================
# РОТАЦИЯ
# =========================

if [ "$HAS_ERROR" -eq 0 ]; then
    log_msg "[INFO] Ротация старых бэкапов"

    find "$LOCAL_BACKUP_DIR" \
        -name "${BACKUP_PREFIX}_*.sql.gz" \
        -mtime +"$RETENTION_DAYS" \
        -delete \
        -print | tee -a "$LOG_FILE"
else
    log_msg "[INFO] Ротация пропущена из-за ошибок"
fi

# =========================
# ИТОГ
# =========================

log_msg "[SUCCESS] Успешно сохранено: ${#SUCCESS_DUMPS[@]} БД"
log_msg "[SUCCESS] Успешно скопировано: ${#SUCCESS_COPIED[@]} БД"

finish_script
