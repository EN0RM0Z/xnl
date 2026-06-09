#!/bin/bash
# Скрипт резервного копирования MariaDB
# Каждая база сохраняется в отдельный дамп, затем все дампы архивируются

### КОНФИГУРИРУЕМЫЕ ПАРАМЕТРЫ ###
DB_NAMES=("db1" "db2" "db3")             # Массив баз данных для бэкапа
#DB_USER="backup_user"                    # Пользователь БД для бэкапов
#DB_HOST="localhost"                      # Хост БД

LOCAL_BACKUP_DIR="/var/backups/db_dumps" # Локальная директория для бэкапов

REMOTE_BACKUP_DIR="/mnt/backup_storage/db" # Удаленная директория
REMOTE_USER="backupuser"                 # Пользователь для SSH-доступа
REMOTE_HOST="server02"                   # Хост сервера-приемника

RETENTION_DAYS=30                        # Дней хранения бэкапов
COMPRESSION_LEVEL=6                      # Уровень сжатия (1-9)

#COPY_METHOD="RSYNC"                      # Метод копирования: RSYNC
COPY_METHOD="SCP"                        # Метод копирования: SCP

MIN_DUMP_SIZE=10240                      # Минимальный размер дампа (10 КБ)

MYSQL_CNF="/home/backupuser/.my.cnf"     # Файл с учетными данными

BACKUP_PREFIX="db"            # Префикс файла бэкапа

# Параметры почты
MAIL_TO="admin@example.com"
MAIL_FROM="backup@server01"
MAIL_SUBJECT="MySQL backup report"

### КОНЕЦ КОНФИГУРИРУЕМЫХ ПАРАМЕТРОВ ###

# Генерация временной метки
TIMESTAMP=$(date +%Y%m%d)

LOG_FILE="/var/log/mysql_backup.log"

DUMP_DIR="${LOCAL_BACKUP_DIR}/tmp_${BACKUP_PREFIX}_${TIMESTAMP}"
BACKUP_FILE="${BACKUP_PREFIX}_${TIMESTAMP}.tar.gz"
BACKUP_PATH="${LOCAL_BACKUP_DIR}/${BACKUP_FILE}"

# Статус выполнения
HAS_ERROR=0
ERRORS=()
SUCCESS_DUMPS=()

###########################################################################
# ФУНКЦИИ
###########################################################################

log_msg() {
    echo "$1" | tee -a "$LOG_FILE"
}

add_error() {
    HAS_ERROR=1
    ERRORS+=("$1")
    log_msg "[ERROR] $1"
}

send_report() {

    local SUBJECT_PREFIX="[INFO]"

    if [ "$HAS_ERROR" -ne 0 ]; then
        SUBJECT_PREFIX="[ERROR]"
    fi

    {
        echo "Отчет резервного копирования MariaDB"
        echo
        echo "Дата: $(date)"
        echo "Хост: $(hostname)"
        echo

        echo "Успешно сохраненные базы:"
        if [ ${#SUCCESS_DUMPS[@]} -eq 0 ]; then
            echo "  Нет"
        else
            for DB in "${SUCCESS_DUMPS[@]}"; do
                echo "  - $DB"
            done
        fi

        echo

        echo "Ошибки:"
        if [ ${#ERRORS[@]} -eq 0 ]; then
            echo "  Нет"
        else
            for ERR in "${ERRORS[@]}"; do
                echo "  - $ERR"
            done
        fi

        echo
        echo "Последние строки журнала:"
        echo "----------------------------------------"
        tail -50 "$LOG_FILE"
        echo "----------------------------------------"

    } | mail -r "$MAIL_FROM" \
             -s "${SUBJECT_PREFIX} ${MAIL_SUBJECT}" \
             "$MAIL_TO"
}

finish_script() {

    log_msg "===== [$(date)] Процесс завершен ====="

    send_report

    if [ "$HAS_ERROR" -eq 0 ]; then
        exit 0
    else
        exit 1
    fi
}

###########################################################################
# НАЧАЛО РАБОТЫ
###########################################################################

log_msg "===== [$(date)] Начало резервного копирования ====="
log_msg "[INFO] Базы для бэкапа: ${DB_NAMES[*]}"

# Проверка существования директории
if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
    add_error "Директория $LOCAL_BACKUP_DIR не существует"
    finish_script
fi

# Проверка прав записи
if [ ! -w "$LOCAL_BACKUP_DIR" ]; then
    add_error "Нет прав на запись в $LOCAL_BACKUP_DIR"
    finish_script
fi

# Проверка файла конфигурации
if [ ! -f "$MYSQL_CNF" ]; then
    add_error "Файл конфигурации MySQL не найден: $MYSQL_CNF"
    finish_script
fi

# Проверка зависимостей
for cmd in mysqldump gzip ssh tar stat; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        add_error "Отсутствует необходимая команда: $cmd"
        finish_script
    fi
done

# Проверка mail
if ! command -v mail >/dev/null 2>&1; then
    echo "[WARNING] Команда mail не найдена. Отправка отчета невозможна." | tee -a "$LOG_FILE"
fi

# Проверка свободного места (минимум 1 ГБ)
MIN_SPACE_KB=$((1024 * 1024))
AVAILABLE_SPACE=$(df -k --output=avail "$LOCAL_BACKUP_DIR" | awk 'NR==2 {print $1}')

if [ "$AVAILABLE_SPACE" -lt "$MIN_SPACE_KB" ]; then
    add_error "Недостаточно места! Доступно: $((AVAILABLE_SPACE/1024)) MB, требуется: $((MIN_SPACE_KB/1024)) MB"
    finish_script
fi

# Очистка старых временных файлов за сегодня
rm -rf "$DUMP_DIR" 2>/dev/null
rm -f "$BACKUP_PATH" 2>/dev/null

mkdir -p "$DUMP_DIR"

###########################################################################
# СОЗДАНИЕ ДАМПОВ
###########################################################################

log_msg "[INFO] Создание дампов баз данных..."

for DB_NAME in "${DB_NAMES[@]}"; do

    DUMP_FILE="${DB_NAME}_${TIMESTAMP}.sql"
    DUMP_PATH="${DUMP_DIR}/${DUMP_FILE}"

    log_msg "[INFO] Создание дампа базы $DB_NAME"

    if ! mysqldump \
            --defaults-extra-file="$MYSQL_CNF" \
            --single-transaction \
            --quick \
            --routines \
            --triggers \
            --events \
            "$DB_NAME" > "$DUMP_PATH"; then

        add_error "Ошибка создания дампа базы $DB_NAME"

        rm -f "$DUMP_PATH" 2>/dev/null

        continue
    fi

    DUMP_SIZE=$(stat -c%s "$DUMP_PATH")

    if [ "$DUMP_SIZE" -lt "$MIN_DUMP_SIZE" ]; then

        add_error "Размер дампа базы $DB_NAME слишком мал: $DUMP_SIZE байт"

        rm -f "$DUMP_PATH"

        continue
    fi

    SUCCESS_DUMPS+=("$DB_NAME")

    log_msg "[INFO] База $DB_NAME успешно сохранена ($DUMP_SIZE байт)"

done

###########################################################################
# ПРОВЕРКА РЕЗУЛЬТАТА
###########################################################################

if [ ${#SUCCESS_DUMPS[@]} -eq 0 ]; then
    add_error "Не удалось создать ни одного корректного дампа"

    rm -rf "$DUMP_DIR"

    finish_script
fi

###########################################################################
# АРХИВИРОВАНИЕ
###########################################################################

log_msg "[INFO] Создание архива $BACKUP_FILE"

if ! tar -I "gzip -${COMPRESSION_LEVEL}" \
          -cf "$BACKUP_PATH" \
          -C "$DUMP_DIR" .; then

    add_error "Ошибка создания архива"

    rm -rf "$DUMP_DIR"

    finish_script
fi

# Удаляем временные дампы
rm -rf "$DUMP_DIR"

###########################################################################
# ПРОВЕРКА ЦЕЛОСТНОСТИ АРХИВА
###########################################################################

log_msg "[INFO] Проверка целостности архива"

if ! gzip -t "$BACKUP_PATH"; then

    add_error "Создан поврежденный архив"

    rm -f "$BACKUP_PATH"

    finish_script
fi

###########################################################################
# КОПИРОВАНИЕ НА УДАЛЕННЫЙ СЕРВЕР
###########################################################################

log_msg "[INFO] Копирование файла $BACKUP_FILE на $REMOTE_HOST"

if ! ssh "$REMOTE_USER@$REMOTE_HOST" \
     "mkdir -p '$REMOTE_BACKUP_DIR'"; then

    add_error "Не удалось создать каталог на удаленном сервере"

    finish_script
fi

COPY_RC=0

case "$COPY_METHOD" in

    RSYNC)

        log_msg "[DETAIL] Метод: rsync"

        rsync -avz -e ssh \
            "$BACKUP_PATH" \
            "$REMOTE_USER@$REMOTE_HOST:$REMOTE_BACKUP_DIR/"

        COPY_RC=$?
        ;;

    SCP)

        log_msg "[DETAIL] Метод: scp"

        scp \
            -o BatchMode=yes \
            -o ConnectTimeout=30 \
            "$BACKUP_PATH" \
            "$REMOTE_USER@$REMOTE_HOST:$REMOTE_BACKUP_DIR/"

        COPY_RC=$?
        ;;

    *)

        add_error "Недопустимый метод копирования: $COPY_METHOD"

        finish_script
        ;;
esac

if [ "$COPY_RC" -ne 0 ]; then

    add_error "Ошибка копирования архива на удаленный сервер"

    log_msg "[INFO] Ротация пропущена из-за ошибки копирования"

    finish_script
fi

###########################################################################
# РОТАЦИЯ ЛОКАЛЬНЫХ БЭКАПОВ
# Выполняется ТОЛЬКО после успешного копирования
###########################################################################

log_msg "[INFO] Очистка локальных бэкапов старше $RETENTION_DAYS дней"

find "$LOCAL_BACKUP_DIR" \
    -name "${BACKUP_PREFIX}_*.tar.gz" \
    -mtime +"$RETENTION_DAYS" \
    -delete \
    -print | tee -a "$LOG_FILE"

###########################################################################
# УСПЕШНОЕ ЗАВЕРШЕНИЕ
###########################################################################

log_msg "[SUCCESS] Резервное копирование завершено"

log_msg "[INFO] Успешно сохранено баз: ${#SUCCESS_DUMPS[@]}"
log_msg "[INFO] Размер архива: $(stat -c%s "$BACKUP_PATH") байт"
log_msg "[INFO] Локальный файл: $BACKUP_FILE"
log_msg "[INFO] Удаленный файл: $REMOTE_BACKUP_DIR/$BACKUP_FILE"

finish_script
