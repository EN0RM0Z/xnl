#!/bin/bash

# НАСТРОЙКИ
PROCESS_NAMES="mariadb|mysql|mysqld"
ITERATION_COUNT=10
INTERVAL=5

for ((i=1; i<=ITERATION_COUNT; i++)); do
    clear
    echo "=== Мониторинг CPU - Итерация $i/$ITERATION_COUNT ==="
    echo "Время: $(date '+%H:%M:%S')"
    echo ""
    
    # Общая загрузка
    echo "📊 ОБЩАЯ ЗАГРУЗКА:"
    top -bn1 | grep "Cpu(s)" | awk '{print "  " $2 "% пользователь + " $4 "% система = " $2+$4 "% всего"}'
    echo ""
    
    # Процессы
    echo "🔍 ПРОЦЕССЫ ($PROCESS_NAMES):"
    pids=$(pgrep -f "$PROCESS_NAMES")
    
    if [ -z "$pids" ]; then
        echo "  Не найдены"
    else
        echo "  PID   %CPU   ПРОЦЕСС"
        echo "  --------------------"
        for pid in $pids; do
            ps -p $pid -o pid=%cpu,comm --no-headers 2>/dev/null | awk '{print "  " $1 "   " $2 "%   " $3}'
        done
        
        total_cpu=$(ps -p "$pids" -o %cpu --no-headers 2>/dev/null | awk '{sum += $1} END {printf "%.1f", sum}')
        count=$(echo "$pids" | wc -w)
        echo "  --------------------"
        echo "  Всего: $count процессов, суммарно ${total_cpu}% CPU"
    fi
    
    echo ""
    echo "⏳ Следующее обновление через $INTERVAL сек..."
    sleep "$INTERVAL"
done
