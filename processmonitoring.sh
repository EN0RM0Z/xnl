#!/bin/bash

# НАСТРОЙКИ
MONITOR_UID="1001"
ITERATION_COUNT=10
INTERVAL=5
LOG_FILE="/opt/keycloak/scripts/cputest/logs/cpu_monitor.log"

mkdir -p "$(dirname "$LOG_FILE")"

for ((i=1; i<=ITERATION_COUNT; i++)); do
    timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    
    # Общая загрузка системы
    system_cpu=$(top -bn1 | grep 'Cpu(s)' | awk '{printf "%.1f%%", $2 + $4}')
    
    # Использование pidstat для точного подсчета (требует установки sysstat)
    user_cpu=$(pidstat -u -r -p ALL 1 1 | awk -v uid="$MONITOR_UID" '$2 == uid {sum += $7} END {printf "%.1f", sum}')
    
    process_count=$(ps -u "$MONITOR_UID" --no-headers 2>/dev/null | wc -l)
    
    # Вывод в лог файл
    echo "$timestamp | Iteration: $i/$ITERATION_COUNT | UID: $MONITOR_UID | Processes: $process_count | CPU: ${user_cpu}% | System CPU: $system_cpu" >> "$LOG_FILE"
    
    # Вывод в консоль
    echo "Iteration $i: ${user_cpu}% CPU by $process_count processes (UID: $MONITOR_UID)"
    
    sleep "$INTERVAL"
done
