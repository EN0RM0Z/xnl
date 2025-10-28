#!/bin/bash

# НАСТРОЙКИ
MONITOR_UID="999"
ITERATION_COUNT=10
INTERVAL=5
LOG_FILE="/opt/keycloak/scripts/cputest/logs/cpu_monitor.log"

mkdir -p "$(dirname "$LOG_FILE")"

# Получаем количество ядер процессора
CPU_CORES=$(nproc)

for ((i=1; i<=ITERATION_COUNT; i++)); do
    timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    
    # Общая загрузка системы
    system_cpu=$(top -bn1 | grep 'Cpu(s)' | awk '{printf "%.1f%%", $2 + $4}')
    
    # Использование CPU процессами пользователя (нормализованное на количество ядер)
    user_cpu=$(ps -u "$MONITOR_UID" -o %cpu --no-headers 2>/dev/null | awk -v cores="$CPU_CORES" '{sum += $1} END {printf "%.1f", sum/cores}')
    
    process_count=$(ps -u "$MONITOR_UID" --no-headers 2>/dev/null | wc -l)
    
    # Вывод в лог файл
    echo "$timestamp | Iteration: $i/$ITERATION_COUNT | UID: $MONITOR_UID | Processes: $process_count | User CPU: ${user_cpu}% | System CPU: $system_cpu" >> "$LOG_FILE"
    
    # Вывод в консоль
    echo "Iteration $i: ${user_cpu}% CPU by $process_count processes (UID: $MONITOR_UID) | System: $system_cpu"
    
    sleep "$INTERVAL"
done


#!/bin/bash

MONITOR_UID="999"
echo "=== DEBUG PIDSTAT OUTPUT ==="
pidstat -u -r 1 1
echo "=== FILTERED FOR UID $MONITOR_UID ==="
pidstat -u -r 1 1 | grep -E "^[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+$MONITOR_UID"
echo "=== COLUMNS ==="
pidstat -u -r 1 1 | grep -E "^[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+$MONITOR_UID" | head -1 | cat -A

