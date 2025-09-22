#!/bin/bash

# =====================================================
# Скрипт: анализ размеров таблиц Keycloak
# Упрощенная версия
# =====================================================

# === Настройки ===
BASE_DIR="/var/log/kc_table_stats"
ARC_DIR="$BASE_DIR/archive"
REP_DIR="$BASE_DIR/report"
LOG_FILE="$BASE_DIR/check_kc_tables.log"

MAX_DAY=30
MARIADB_CONTAINER="mariadb"
DB_NAME="keycloak"
DB_USER="root"
DB_PASSWORD="RootPass"

CSV_DELIMITER=";"
DECIMAL_SEPARATOR=","   # Для Excel

mkdir -p "$BASE_DIR" "$ARC_DIR" "$REP_DIR"
DATE=$(date +%Y%m%d_%H%M%S)

CURRENT_FILE="$BASE_DIR/current.csv"
PREVIOUS_FILE="$BASE_DIR/previous.csv"
ARCHIVE_FILE="$ARC_DIR/current_$DATE.csv"
REPORT_FILE="$REP_DIR/report_$DATE.csv"

echo "[INFO] --- Запуск проверки таблиц: $DATE ---" | tee -a "$LOG_FILE"

# =====================================================
# 1. Получаем размеры таблиц из MariaDB
# =====================================================
SQL_QUERY="
SELECT table_name, ROUND((data_length + index_length)/1024/1024,2) AS size_mb
FROM information_schema.tables
WHERE table_schema='$DB_NAME'
ORDER BY data_length DESC;"

docker exec -i "$MARIADB_CONTAINER" \
  mysql -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -N -B -e "$SQL_QUERY" \
  | tr '\t' "$CSV_DELIMITER" > "$CURRENT_FILE"

# =====================================================
# 2. Архивируем текущий снимок
# =====================================================
cp "$CURRENT_FILE" "$ARCHIVE_FILE"
echo "[INFO] Архив сохранен: $ARCHIVE_FILE" | tee -a "$LOG_FILE"

# =====================================================
# 3. Формируем отчет с разницей
# =====================================================
if [[ -f "$PREVIOUS_FILE" ]]; then
    # Создаем заголовок отчета
    echo "Table${CSV_DELIMITER}Previous (MB)${CSV_DELIMITER}Current (MB)${CSV_DELIMITER}Change (MB)" > "$REPORT_FILE"
    
    # Объединяем данные и вычисляем разницу
    join -t"$CSV_DELIMITER" -a1 -a2 -e0 -o 0,1.2,2.2 <(sort "$PREVIOUS_FILE") <(sort "$CURRENT_FILE") \
    | while IFS="$CSV_DELIMITER" read -r tbl prev cur; do
        # Вычисляем разницу
        diff=$(echo "$cur - $prev" | bc)
        # Форматируем строку
        echo "${tbl}${CSV_DELIMITER}${prev}${CSV_DELIMITER}${cur}${CSV_DELIMITER}${diff}"
    done | sort -t"$CSV_DELIMITER" -k3,3nr >> "$REPORT_FILE"  # Сортировка по текущему размеру (столбец 3)

    echo "[INFO] Отчет сохранён: $REPORT_FILE" | tee -a "$LOG_FILE"
else
    echo "First snapshot, no comparison" > "$REPORT_FILE"
    echo "[INFO] Нет предыдущего снимка, формируем первый отчет" | tee -a "$LOG_FILE"
fi

# =====================================================
# 4. Заменяем точку на запятую только в отчетах для Excel
# =====================================================
if [[ -f "$REPORT_FILE" ]]; then
    sed -i "s/\./$DECIMAL_SEPARATOR/g" "$REPORT_FILE"
fi
if [[ -f "$ARCHIVE_FILE" ]]; then
    sed -i "s/\./$DECIMAL_SEPARATOR/g" "$ARCHIVE_FILE"
fi

# =====================================================
# 5. Подготовка к следующему запуску
# =====================================================
mv -f "$CURRENT_FILE" "$PREVIOUS_FILE"

# =====================================================
# 6. Удаление старых файлов
# =====================================================
find "$ARC_DIR" -type f -mtime +"$MAX_DAY" -exec rm -f {} \;
find "$REP_DIR" -type f -mtime +"$MAX_DAY" -exec rm -f {} \;

echo "[INFO] Старые файлы (старше $MAX_DAY дней) удалены" | tee -a "$LOG_FILE"
echo "[INFO] --- Завершено ---" | tee -a "$LOG_FILE"
