#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$LOG_DIR"

echo "=========================================="
echo " Patroni HA test - CSV export"
echo "=========================================="
echo
echo "Host       : $DB_HOST"
echo "Port       : $DB_PRIMARY_PORT"
echo "Database   : $DB_NAME"
echo "Table      : $TEST_TABLE"
echo "CSV file   : $CSV_FILE"
echo

# ==========================================
# Создаём CSV с UTF-8 BOM
# ==========================================

printf '\xEF\xBB\xBF' > "$CSV_FILE"

if [ $? -ne 0 ]; then
    echo "ОШИБКА: невозможно создать файл:"
    echo "$CSV_FILE"
    exit 1
fi

# ==========================================
# Экспорт таблицы
# ==========================================

psql \
    "host=${DB_HOST} port=${DB_PRIMARY_PORT} dbname=${DB_NAME} user=${DB_USER} password=${DB_PASSWORD} connect_timeout=${CONNECT_TIMEOUT}" \
    -X \
    -v ON_ERROR_STOP=1 \
    -c "\copy (
        SELECT
            id,
            created_at,
            test_value
        FROM ${TEST_TABLE}
        ORDER BY id
    ) TO STDOUT WITH (
        FORMAT CSV,
        HEADER,
        DELIMITER ';',
        FORCE_QUOTE *
    )" >> "$CSV_FILE"

RC=$?

# ==========================================
# Проверяем результат
# ==========================================

if [ "$RC" -eq 0 ]; then

    echo "Экспорт успешно завершён."
    echo
    echo "Файл:"
    echo "$CSV_FILE"
    echo

    echo "Размер файла:"
    ls -lh "$CSV_FILE"

    echo
    echo "Количество строк:"
    wc -l "$CSV_FILE"

else

    echo
    echo "ОШИБКА: экспорт не выполнен."

    # Удаляем неполный файл
    rm -f "$CSV_FILE"

    exit 1
fi
