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

CUR_FILE="$BASE_DIR/current.csv"
PREV_FILE="$BASE_DIR/previous.csv"
ARCHIVE_FILE="$ARC_DIR/current_$DATE.csv"
REPORT_FILE="$REP_DIR/report_$DATE.txt"

echo "[INFO] --- Запуск проверки: $DATE ---" | tee -a "$LOG_FILE"

# === Снимаем текущий размер таблиц ===
docker exec -i "$CONTAINER" \
  mysql -u"$USER" -p"$PASS" -N -e "
    SELECT table_name,
           ROUND((data_length+index_length)/1024/1024,2) AS size_mb
    FROM information_schema.tables
    WHERE table_schema='$DB'
    ORDER BY table_name;" > "$CUR_FILE"

# === Архивируем копию current.csv ===
cp "$CUR_FILE" "$ARCHIVE_FILE"
echo "[INFO] Архивная копия сохранена: $ARCHIVE_FILE" | tee -a "$LOG_FILE"

# === Сравнение с предыдущим снимком ===
if [[ -f "$PREV_FILE" ]]; then
    {
      echo "Отчет по изменениям размеров таблиц ($DB):"
      echo "Таблица; Было (МБ); Стало (МБ); Изменение (МБ)"
      echo "--------------------------------------------------------"
      join -t $'\t' -a1 -a2 -e0 -o 0,1.2,2.2 "$PREV_FILE" "$CUR_FILE" | \
      while IFS=$'\t' read -r table prev cur; do
          diff=$(echo "$cur - $prev" | bc)
          printf "%s; %s; %s; %+s\n" "$table" "$prev" "$cur" "$diff"
      done
    } > "$REPORT_FILE"
    echo "[INFO] Отчет сохранён: $REPORT_FILE" | tee -a "$LOG_FILE"
else
    echo "[INFO] Нет предыдущего снимка, сохраняю первый замер." | tee -a "$LOG_FILE"
    echo "Первый снимок, отчет не формировался" > "$REPORT_FILE"
fi

# === Подготовка к следующему запуску ===
mv -f "$CUR_FILE" "$PREV_FILE"

# === Удаление старых файлов ===
find "$ARC_DIR" -type f -mtime +"$MAX_DAY" -exec rm -f {} \;
find "$REP_DIR" -type f -mtime +"$MAX_DAY" -exec rm -f {} \;

echo "[INFO] Старые файлы (старше $MAX_DAY дней) удалены" | tee -a "$LOG_FILE"
echo "[INFO] --- Завершено ---" | tee -a "$LOG_FILE"
