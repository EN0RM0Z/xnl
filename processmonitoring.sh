#!/bin/bash

# НАСТРОЙКИ
MONITOR_UID="1001"           # UID пользователя для мониторинга
ITERATION_COUNT=5           # Количество повторов
INTERVAL=3                  # Интервал в секундах
LOG_FILE="/opt/keycloak/scripts/cputest/logs/cpu_monitor.log"

# Создаем директорию для логов
mkdir -p "$(dirname "$LOG_FILE")"

# Заголовок лога
echo "=== Monitoring UID: $MONITOR_UID ===" >> "$LOG_FILE"

# Цикл мониторинга
for ((i=1; i<=ITERATION_COUNT; i++)); do
    timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    total_cpu=$(ps -u "$MONITOR_UID" -o %cpu --no-headers 2>/dev/null | awk '{sum += $1} END {printf "%.1f", sum}')
    process_count=$(ps -u "$MONITOR_UID" --no-headers 2>/dev/null | wc -l)
    
    echo "$timestamp | Iteration: $i/$ITERATION_COUNT | UID: $MONITOR_UID | Processes: $process_count | CPU: ${total_cpu}%" >> "$LOG_FILE"
    
    # Вывод в консоль
    echo "Iteration $i: ${total_cpu}% CPU by $process_count processes (UID: $MONITOR_UID)"
    
    # Пауза кроме последней итерации
    if [ "$i" -lt "$ITERATION_COUNT" ]; then
        sleep "$INTERVAL"
    fi
done

echo "Monitoring completed. Results saved to: $LOG_FILE"
