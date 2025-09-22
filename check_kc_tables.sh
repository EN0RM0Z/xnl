#!/bin/bash

# === Настройки ===
BASE_DIR="/var/log/kc_table_stats"
ARC_DIR="$BASE_DIR/archive"
REP_DIR="$BASE_DIR/report"
LOG_FILE="$BASE_DIR/check_kc_tables.log"

MAX_DAY=30   # сколько дней хранить архив и отчёты

CONTAINER="mariadb"
DB="keycloak"
USER="root"
PASS="RootPass"

mkdir -p "$BASE_DIR" "$ARC_DIR" "$REP_DIR"

DATE=$(date +%Y%m%d_%H%M%S)

CURRENT_FILE="$BASE_DIR/current.csv"
PREVIOUS_FILE="$BASE_DIR/previous.csv"
ARCHIVE_FILE="$ARC_DIR/current_$DATE.csv"
REPORT_FILE="$REP_DIR/report_$DATE.txt"

echo "[INFO] --- Запуск проверки таблиц: $DATE ---" | tee -a "$LOG_FILE"

# 1. Получаем размеры таблиц (сразу сортируем по размеру)
docker exec -i "$CONTAINER" \
  mysql -u"$USER" -p"$PASS" -N -e "
    SELECT table_name, ROUND(data_length/1024/1024,2) AS data_mb
    FROM information_schema.tables
    WHERE table_schema='$DB'
    ORDER BY data_length DESC;" > "$CURRENT_FILE"

# 2. Сохраняем копию в архив
cp "$CURRENT_FILE" "$ARCHIVE_FILE"
echo "[INFO] Архивная копия сохранена: $ARCHIVE_FILE" | tee -a "$LOG_FILE"

# 3. Формируем отчет
if [[ -f "$PREVIOUS_FILE" ]]; then
    {
      echo "Отчет об изменении размеров таблиц (MB)"
      echo "Таблица; Было; Стало; Изменение"
      echo "-------------------------------------------"
      join -t $'\t' -a1 -a2 -e0 -o 0,1.2,2.2 \
           <(sort "$PREVIOUS_FILE") <(sort "$CURRENT_FILE") | \
      while IFS=$'\t' read -r tbl prev cur; do
          diff=$(echo "$cur - $prev" | bc)
          printf "%s; %s; %s; %+s\n" "$tbl" "$prev" "$cur" "$diff"
      done | sort -t';' -k3 -nr
    } > "$REPORT_FILE"
    echo "[INFO] Отчет сохранён: $REPORT_FILE" | tee -a "$LOG_FILE"
else
    echo "Первый запуск, сравнения нет" > "$REPORT_FILE"
fi

# 4. Подготовка к следующему запуску
mv -f "$CURRENT_FILE" "$PREVIOUS_FILE"

# 5. Удаление старых архивов и отчетов
find "$ARC_DIR" -type f -mtime +"$MAX_DAY" -exec rm -f {} \;
find "$REP_DIR" -type f -mtime +"$MAX_DAY" -exec rm -f {} \;

echo "[INFO] Старые файлы (старше $MAX_DAY дней) удалены" | tee -a "$LOG_FILE"
echo "[INFO] --- Завершено ---" | tee -a "$LOG_FILE"
