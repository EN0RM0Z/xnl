#!/bin/bash
# Пример: ./analyze_logs.sh /var/log/nginx/access.log

LOGFILE="$1"
MODEL="llama3"
OLLAMA_URL="http://olama-srv:11434/api/generate"

if [ ! -f "$LOGFILE" ]; then
  echo "Файл не найден: $LOGFILE"
  exit 1
fi

# --- Этап 1: Подготовка ---
TMP_SUMMARY="/tmp/log-summary.txt"

echo "=== Анализ файла: $LOGFILE ===" > "$TMP_SUMMARY"
echo >> "$TMP_SUMMARY"

# Статистика по строкам
echo "Общая статистика:" >> "$TMP_SUMMARY"
wc -l "$LOGFILE" >> "$TMP_SUMMARY"
grep -Eo '\b(INFO|WARN|ERROR|CRITICAL|DEBUG)\b' "$LOGFILE" | sort | uniq -c >> "$TMP_SUMMARY"
echo >> "$TMP_SUMMARY"

# Частые и редкие записи
echo "Наиболее частые записи:" >> "$TMP_SUMMARY"
sort "$LOGFILE" | uniq -c | sort -nr | head -n 20 >> "$TMP_SUMMARY"
echo >> "$TMP_SUMMARY"

echo "Редкие записи:" >> "$TMP_SUMMARY"
sort "$LOGFILE" | uniq -c | sort -n | head -n 20 >> "$TMP_SUMMARY"

# --- Этап 2: Отправка в Ollama ---
PROMPT=$(cat <<EOF
Ты аналитик системных логов Linux. Перед тобой сводка журнала системы.
Найди закономерности, необычные события, отклонения от нормы или интересные паттерны.
Сделай краткий, но содержательный анализ.
EOF
)

SUMMARY_TEXT=$(cat "$TMP_SUMMARY" | head -c 6000)  # ограничение, чтобы не переполнить prompt

curl -s -X POST "$OLLAMA_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"prompt\": \"$PROMPT\n\n$SUMMARY_TEXT\"
  }" | jq -r '.response' | tr -d '\n'

echo

