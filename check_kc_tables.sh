#!/bin/bash

# =====================================================
# Скрипт: анализ размеров таблиц Keycloak
# Формирует CSV-отчет для Excel с архивированием и отчетами
# =====================================================

# === Настройки ===
BASE_DIR="/var/log/kc_table_stats"
ARC_DIR="$BASE_DIR/archive"
REP_DIR="$BASE_DIR/report"
LOG_FILE="$BASE_DIR/check_kc_tables.log"

MAX_DAY=30                 # сколько дней хранить архив и отчёты
MARIADB_CONTAINER="mariadb"
DB_NAME="keycloak"
DB_USER="root"
DB_PASSWORD="RootPass"

CSV_DELIMITER=";"          # CSV разделитель колонок
DECIMAL_SEPARATOR=","      # десятичный разделитель для Excel

# Создаем необходимые папки
mkdir -p "$BASE_DIR" "$ARC_DIR" "$REP_DIR"

DATE=$(date +%Y%m%d_%H%M%S)

# === Файлы текущего и предыдущего снимка ===
CURRENT_FILE="$BASE_DIR/current.csv"
PREVIOUS_FILE="$BASE_DIR/previous.csv"
ARCHIVE_FILE="$ARC_DIR/current_$DATE.csv"
REPORT_FILE="$REP_DIR/report_$DATE.csv"

echo "[INFO] --- Запуск проверки таблиц: $DATE ---" | tee -a "$LOG_FILE"

# =====================================================
# 1. SQL-запрос на получение размеров таблиц
# =====================================================
SQL_QUERY="
SELECT table_name, ROUND((data_length + index_length)/1024/1024,2) AS size_mb
FROM information_schema.tables
WHERE table_schema='$DB_NAME'
ORDER BY data_length DESC;"

# =====================================================
# 2. Выполнение запроса в контейнере MariaDB
#    Формируем CSV с:
#    - кавычками вокруг каждого значения
#    - заменой NULL на пустое значение
#    - заменой десятичного разделителя
# =====================================================
docker exec -i "$MARIADB_CONTAINER" \
  mysql -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -N -B -e "$SQL_QUERY" \
  | awk -F'\t' -v OFS="$CSV_DELIMITER" -v DEC="$DECIMAL_SEPARATOR" '{
        for(i=1;i<=NF;i++){
            if($i=="NULL") $i=""
            # заменяем точку на DECIMAL_SEPARATOR
            gsub(/\./, DEC, $i)
            printf "\"%s\"%s", $i, (i==NF?RS:OFS)
        }
    }' \
  > "$CURRENT_FILE"

# =====================================================
# 3. Архивируем текущий снимок
# =====================================================
cp "$CURRENT_FILE" "$ARCHIVE_FILE"
echo "[INFO] Архив сохранен: $ARCHIVE_FILE" | tee -a "$LOG_FILE"

# =====================================================
# 4. Формируем CSV-отчет с изменениями по сравнению с предыдущим снимком
#    Сортируем по Current (MB) размеру, убывание
# =====================================================
if [[ -f "$PREVIOUS_FILE" ]]; then
    {
      # Заголовок CSV (на английском)
      echo "\"Table\"${CSV_DELIMITER}\"Previous (MB)\"${CSV_DELIMITER}\"Current (MB)\"${CSV_DELIMITER}\"Change (MB)\""

      # Сравниваем предыдущий и текущий снимок
      join -t"$CSV_DELIMITER" -a1 -a2 -e0 -o 0,1.2,2.2 <(sort "$PREVIOUS_FILE") <(sort "$CURRENT_FILE") \
      | while IFS="$CSV_DELIMITER" read -r tbl prev cur; do
          # убираем кавычки вокруг чисел
          prev_val=$(echo "$prev" | tr -d '"')
          cur_val=$(echo "$cur" | tr -d '"')
          # вычисляем разницу
          diff=$(echo "$cur_val - $prev_val" | bc)
          # формируем значения для CSV с десятичным разделителем
          prev_val_csv=$(echo "$prev_val" | sed "s/\./$DECIMAL_SEPARATOR/")
          cur_val_csv=$(echo "$cur_val" | sed "s/\./$DECIMAL_SEPARATOR/")
          diff_csv=$(echo "$diff" | sed "s/\./$DECIMAL_SEPARATOR/")
          printf "\"%s\"%s\"%s\"%s\"%s\"%s\"%s\"\n" \
                 "$tbl" "$CSV_DELIMITER" "$prev_val_csv" "$CSV_DELIMITER" "$cur_val_csv" "$CSV_DELIMITER" "$diff_csv"
      done
    } | sort -t"$CSV_DELIMITER" -k3,3nr > "$REPORT_FILE"   # сортировка по Current (MB), убывание
    echo "[INFO] Отчет сохранён: $REPORT_FILE" | tee -a "$LOG_FILE"
else
    # Первый запуск, сравнения нет
    echo "\"First snapshot, no comparison\"" > "$REPORT_FILE"
    echo "[INFO] Нет предыдущего снимка, формируем первый отчет" | tee -a "$LOG_FILE"
fi

# =====================================================
# 5. Подготовка к следующему запуску
# =====================================================
mv -f "$CURRENT_FILE" "$PREVIOUS_FILE"

# =====================================================
# 6. Удаление старых архивов и отчетов
# =====================================================
find "$ARC_DIR" -type f -mtime +"$MAX_DAY" -exec rm -f {} \;
find "$REP_DIR" -type f -mtime +"$MAX_DAY" -exec rm -f {} \;

echo "[INFO] Старые файлы (старше $MAX_DAY дней) удалены" | tee -a "$LOG_FILE"
echo "[INFO] --- Завершено ---" | tee -a "$LOG_FILE"

