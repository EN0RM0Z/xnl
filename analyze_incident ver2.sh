#!/bin/bash

# Скрипт автоматического анализа инцидента
# Использование: ./analyze_incident.sh [дата_в_формате_YYYYMMDD]
# Пример: ./analyze_incident.sh 20251026

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -z "$1" ]; then
    LOG_DIR="/var/log/incident_$(date +%Y%m%d)"
else
    LOG_DIR="/var/log/incident_$1"
fi

if [ ! -d "$LOG_DIR" ]; then
    echo -e "${RED}[ОШИБКА]${NC} Директория не найдена: $LOG_DIR"
    exit 1
fi

REPORT_FILE="$LOG_DIR/INCIDENT_ANALYSIS_REPORT_$(date +%Y%m%d_%H%M%S).txt"

echo "=== АВТОМАТИЧЕСКИЙ АНАЛИЗ ИНЦИДЕНТА ===" | tee "$REPORT_FILE"
echo "Дата анализа: $(date)" | tee -a "$REPORT_FILE"
echo "Анализируемая директория: $LOG_DIR" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# Функция для вывода заголовков
print_header() {
    echo "" | tee -a "$REPORT_FILE"
    echo "========================================" | tee -a "$REPORT_FILE"
    echo "$1" | tee -a "$REPORT_FILE"
    echo "========================================" | tee -a "$REPORT_FILE"
}

# 1. Общая информация о логах
print_header "1. ОБЩАЯ ИНФОРМАЦИЯ О ЛОГАХ"
echo "Количество файлов логов: $(ls -1 $LOG_DIR/*.log 2>/dev/null | wc -l)" | tee -a "$REPORT_FILE"
echo "Общий размер: $(du -sh $LOG_DIR | cut -f1)" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Файлы логов:" | tee -a "$REPORT_FILE"
ls -lh $LOG_DIR/*.log 2>/dev/null | awk '{print $9, $5}' | tee -a "$REPORT_FILE"

# 2. Временной диапазон инцидента
print_header "2. ВРЕМЕННОЙ ДИАПАЗОН ИНЦИДЕНТА"
FIRST_TIMESTAMP=$(grep -h "TIMESTAMP:" $LOG_DIR/*.log 2>/dev/null | head -1 | awk '{print $2, $3}')
LAST_TIMESTAMP=$(grep -h "TIMESTAMP:" $LOG_DIR/*.log 2>/dev/null | tail -1 | awk '{print $2, $3}')
echo "Начало мониторинга: $FIRST_TIMESTAMP" | tee -a "$REPORT_FILE"
echo "Конец мониторинга: $LAST_TIMESTAMP" | tee -a "$REPORT_FILE"

# Поиск критического момента (00:00)
echo "" | tee -a "$REPORT_FILE"
echo "Записи около 00:00:00 МСК:" | tee -a "$REPORT_FILE"
grep -h "TIMESTAMP:.*00:00:" $LOG_DIR/*.log 2>/dev/null | head -10 | tee -a "$REPORT_FILE"

# 3. Анализ загрузки CPU
print_header "3. АНАЛИЗ ЗАГРУЗКИ CPU"
if [ -f $LOG_DIR/processes_cpu_*.log ]; then
    echo "Максимальная загрузка CPU по процессам MariaDB:" | tee -a "$REPORT_FILE"
    grep -A30 "TOP 30 CPU PROCESSES" $LOG_DIR/processes_cpu_*.log | grep -E 'mariadb|mysql' | \
        awk '{print $3, $11}' | sort -rn | head -20 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Количество процессов MariaDB во времени:" | tee -a "$REPORT_FILE"
    grep "MARIADB PROCESS COUNT" -A1 $LOG_DIR/processes_cpu_*.log | grep -v "^--$" | \
        awk '/TIMESTAMP:/ {ts=$2" "$3} /^[0-9]+$/ {print ts, $1}' | tail -20 | tee -a "$REPORT_FILE"
else
    echo "Лог процессов не найден" | tee -a "$REPORT_FILE"
fi

# 4. Анализ сетевых соединений
print_header "4. АНАЛИЗ СЕТЕВЫХ СОЕДИНЕНИЙ"
if [ -f $LOG_DIR/network_connections_*.log ]; then
    echo "Количество соединений к MariaDB (3306) во времени:" | tee -a "$REPORT_FILE"
    grep "MARIADB CONNECTIONS" -A5 $LOG_DIR/network_connections_*.log | \
        awk '/TIMESTAMP:/ {ts=$2" "$3} /ESTAB/ {count++} /^TIMESTAMP:/ && count {print ts, count; count=0}' | \
        tail -20 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Соединения в состоянии TIME-WAIT:" | tee -a "$REPORT_FILE"
    grep "TIME-WAIT CONNECTIONS" -A1 $LOG_DIR/network_connections_*.log | \
        grep -v "^--$" | awk '/TIMESTAMP:/ {ts=$2" "$3} /^[0-9]+$/ {print ts, $1}' | tail -20 | tee -a "$REPORT_FILE"
else
    echo "Лог сетевых соединений не найден" | tee -a "$REPORT_FILE"
fi

# 5. Анализ запросов MariaDB
print_header "5. АНАЛИЗ ЗАПРОСОВ MARIADB"
if [ -f $LOG_DIR/mariadb_queries_*.log ]; then
    echo "Количество активных соединений в PROCESSLIST:" | tee -a "$REPORT_FILE"
    grep "PROCESSLIST" -A20 $LOG_DIR/mariadb_queries_*.log | \
        awk '/TIMESTAMP:/ {ts=$2" "$3} /^[0-9]+\s+rows/ {print ts, $1}' | tail -20 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Долгие запросы (>5 секунд):" | tee -a "$REPORT_FILE"
    grep -A10 "LONG RUNNING QUERIES" $LOG_DIR/mariadb_queries_*.log | \
        grep -v "^--$" | grep -v "Empty set" | head -30 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Заблокированные запросы:" | tee -a "$REPORT_FILE"
    grep -A10 "LOCKED QUERIES" $LOG_DIR/mariadb_queries_*.log | \
        grep -v "^--$" | grep -v "Empty set" | head -20 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "InnoDB Deadlocks:" | tee -a "$REPORT_FILE"
    grep -i "deadlock" $LOG_DIR/mariadb_queries_*.log | head -10 | tee -a "$REPORT_FILE"
else
    echo "Лог запросов MariaDB не найден" | tee -a "$REPORT_FILE"
fi

# 6. Анализ памяти
print_header "6. АНАЛИЗ ИСПОЛЬЗОВАНИЯ ПАМЯТИ"
if [ -f $LOG_DIR/memory_swap_*.log ]; then
    echo "Использование памяти (samples):" | tee -a "$REPORT_FILE"
    grep -A10 "MEMORY OVERVIEW" $LOG_DIR/memory_swap_*.log | \
        grep "Mem:" | head -10 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Использование SWAP:" | tee -a "$REPORT_FILE"
    grep -A10 "MEMORY OVERVIEW" $LOG_DIR/memory_swap_*.log | \
        grep "Swap:" | head -10 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Top процессы по памяти (MariaDB):" | tee -a "$REPORT_FILE"
    grep -A30 "TOP 30 MEMORY PROCESSES" $LOG_DIR/memory_swap_*.log | \
        grep -E 'mariadb|mysql' | awk '{print $4, $11}' | sort -rn | head -10 | tee -a "$REPORT_FILE"
else
    echo "Лог памяти не найден" | tee -a "$REPORT_FILE"
fi

# 7. Анализ дисковой активности
print_header "7. АНАЛИЗ ДИСКОВОЙ АКТИВНОСТИ"
if [ -f $LOG_DIR/disk_io_*.log ]; then
    echo "Недавно измененные файлы в момент инцидента:" | tee -a "$REPORT_FILE"
    grep -A20 "RECENTLY MODIFIED FILES" $LOG_DIR/disk_io_*.log | \
        grep "/opt/mariadb/data" | head -20 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Топ файлов по I/O:" | tee -a "$REPORT_FILE"
    grep -A20 "TOP I/O PROCESSES" $LOG_DIR/disk_io_*.log | \
        grep -v "^--$" | head -20 | tee -a "$REPORT_FILE"
else
    echo "Лог дисковой активности не найден" | tee -a "$REPORT_FILE"
fi

# 8. Анализ логов MariaDB
print_header "8. АНАЛИЗ ЛОГОВ MARIADB"
if [ -f $LOG_DIR/mariadb_logs_*.log ]; then
    echo "Медленные запросы из лога:" | tee -a "$REPORT_FILE"
    grep -A5 "NEW SLOW QUERIES" $LOG_DIR/mariadb_logs_*.log | \
        grep -v "^--$" | grep -v "No new" | head -30 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Ошибки из error.log:" | tee -a "$REPORT_FILE"
    grep -A5 "NEW ERRORS" $LOG_DIR/mariadb_logs_*.log | \
        grep -v "^--$" | grep -v "No new" | head -30 | tee -a "$REPORT_FILE"
else
    echo "Лог файлов MariaDB не найден" | tee -a "$REPORT_FILE"
fi

# 9. Анализ Nginx
print_header "9. АНАЛИЗ NGINX"
if [ -f $LOG_DIR/nginx_*.log ]; then
    echo "Ошибки 500 из Nginx:" | tee -a "$REPORT_FILE"
    grep "500 ERRORS" -A10 $LOG_DIR/nginx_*.log | \
        grep -v "^--$" | grep -v "No new" | head -20 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Timeout ошибки:" | tee -a "$REPORT_FILE"
    grep "TIMEOUT ERRORS" -A5 $LOG_DIR/nginx_*.log | \
        grep -i "timeout" | head -10 | tee -a "$REPORT_FILE"
else
    echo "Лог Nginx не найден" | tee -a "$REPORT_FILE"
fi

# 10. Системные события
print_header "10. СИСТЕМНЫЕ СОБЫТИЯ"
if [ -f $LOG_DIR/system_*.log ]; then
    echo "Cron задачи:" | tee -a "$REPORT_FILE"
    grep -A20 "CRON JOBS" $LOG_DIR/system_*.log | head -30 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Systemd timers:" | tee -a "$REPORT_FILE"
    grep -A20 "SYSTEMD TIMERS" $LOG_DIR/system_*.log | head -30 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Kernel messages (dmesg) около 00:00:" | tee -a "$REPORT_FILE"
    grep "00:00" $LOG_DIR/system_*.log | grep -A5 "KERNEL MESSAGES" | head -20 | tee -a "$REPORT_FILE"
else
    echo "Системный лог не найден" | tee -a "$REPORT_FILE"
fi

# 11. Keycloak статус
print_header "11. KEYCLOAK СТАТУС"
if [ -f $LOG_DIR/keycloak_*.log ]; then
    echo "Логи Keycloak около 00:00:" | tee -a "$REPORT_FILE"
    grep "00:00" -A10 $LOG_DIR/keycloak_*.log | head -30 | tee -a "$REPORT_FILE"
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Соединения к MariaDB из Keycloak:" | tee -a "$REPORT_FILE"
    grep "CONNECTIONS TO MARIADB" -A1 $LOG_DIR/keycloak_*.log | \
        awk '/TIMESTAMP:/ {ts=$2" "$3} /^[0-9]+$/ {print ts, $1}' | tail -20 | tee -a "$REPORT_FILE"
else
    echo "Лог Keycloak не найден" | tee -a "$REPORT_FILE"
fi

# 12. ВЫВОДЫ И РЕКОМЕНДАЦИИ
print_header "12. АВТОМАТИЧЕСКИЕ ВЫВОДЫ"

# Проверка на пул соединений
CONN_COUNT=$(grep "MARIADB CONNECTIONS" -A5 $LOG_DIR/network_connections_*.log 2>/dev/null | grep "ESTAB" | wc -l)
if [ "$CONN_COUNT" -gt 100 ]; then
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} Обнаружено большое количество соединений к MariaDB ($CONN_COUNT)" | tee -a "$REPORT_FILE"
    echo "  Рекомендация: Проверить настройки пула соединений в Keycloak" | tee -a "$REPORT_FILE"
fi

# Проверка на высокую загрузку CPU
CPU_HIGH=$(grep -E 'mariadb|mysql' $LOG_DIR/processes_cpu_*.log 2>/dev/null | awk '{print $3}' | awk '{if($1>50)print $1}' | wc -l)
if [ "$CPU_HIGH" -gt 10 ]; then
    echo -e "${RED}[КРИТИЧНО]${NC} Обнаружены процессы MariaDB с высокой загрузкой CPU" | tee -a "$REPORT_FILE"
    echo "  Рекомендация: Проанализировать медленные запросы" | tee -a "$REPORT_FILE"
fi

# Проверка на SWAP
SWAP_USED=$(grep "Swap:" $LOG_DIR/memory_swap_*.log 2>/dev/null | awk '{print $3}' | grep -v "0B" | wc -l)
if [ "$SWAP_USED" -gt 5 ]; then
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} Обнаружено использование SWAP" | tee -a "$REPORT_FILE"
    echo "  Рекомендация: Увеличить RAM или оптимизировать использование памяти" | tee -a "$REPORT_FILE"
fi

# Проверка на медленные запросы
SLOW_QUERIES=$(grep -i "Query_time" /opt/mariadb/data/slow_query.log 2>/dev/null | wc -l)
if [ "$SLOW_QUERIES" -gt 0 ]; then
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} Обнаружено $SLOW_QUERIES медленных запросов" | tee -a "$REPORT_FILE"
    echo "  Рекомендация: Проанализировать /opt/mariadb/data/slow_query.log" | tee -a "$REPORT_FILE"
fi

# Проверка на cron задачи в 00:00
CRON_MIDNIGHT=$(grep "0 0 \* \* \*" /etc/cron* -r 2>/dev/null | wc -l)
if [ "$CRON_MIDNIGHT" -gt 0 ]; then
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} Обнаружены cron задачи, запускаемые в 00:00" | tee -a "$REPORT_FILE"
    echo "  Рекомендация: Проверить задачи и перенести их на другое время" | tee -a "$REPORT_FILE"
fi

# 13. Топ-10 подозрительных моментов
print_header "13. ТОП-10 ПОДОЗРИТЕЛЬНЫХ МОМЕНТОВ"

echo "1. Пиковая загрузка CPU:" | tee -a "$REPORT_FILE"
grep "load average" $LOG_DIR/system_*.log 2>/dev/null | \
    awk -F'average:' '{print $2}' | sort -t',' -k1 -rn | head -5 | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "2. Максимальное количество процессов MariaDB:" | tee -a "$REPORT_FILE"
grep "MARIADB PROCESS COUNT" -A1 $LOG_DIR/processes_cpu_*.log 2>/dev/null | \
    grep -v "^--$" | awk '/TIMESTAMP:/ {ts=$2" "$3} /^[0-9]+$/ {print ts, $1}' | \
    sort -k3 -rn | head -5 | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "3. Самые частые SQL запросы:" | tee -a "$REPORT_FILE"
if [ -f /opt/mariadb/data/general_query.log ]; then
    grep "SELECT\|INSERT\|UPDATE\|DELETE" /opt/mariadb/data/general_query.log 2>/dev/null | \
        awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | tee -a "$REPORT_FILE"
else
    echo "  General log не найден" | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "4. Таймауты и ошибки соединений:" | tee -a "$REPORT_FILE"
grep -i "timeout\|connection.*failed\|can't connect" $LOG_DIR/*.log 2>/dev/null | head -10 | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "5. InnoDB статус - ожидания блокировок:" | tee -a "$REPORT_FILE"
grep "lock_waits\|row_lock" $LOG_DIR/mariadb_queries_*.log 2>/dev/null | head -10 | tee -a "$REPORT_FILE"

# Финальный вывод
print_header "АНАЛИЗ ЗАВЕРШЕН"
echo "Полный отчет сохранен в: $REPORT_FILE" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Следующие шаги:" | tee -a "$REPORT_FILE"
echo "1. Изучите топ-10 подозрительных моментов" | tee -a "$REPORT_FILE"
echo "2. Проанализируйте медленные запросы: /opt/mariadb/data/slow_query.log" | tee -a "$REPORT_FILE"
echo "3. Проверьте запланированные задачи (cron, systemd timers)" | tee -a "$REPORT_FILE"
echo "4. Оптимизируйте конфигурацию MariaDB и пул соединений Keycloak" | tee -a "$REPORT_FILE"
echo "5. При необходимости обратитесь к базе знаний или поддержке" | tee -a "$REPORT_FILE"

echo ""
echo -e "${GREEN}=== ОТЧЕТ ГОТОВ ===${NC}"
echo "Файл отчета: $REPORT_FILE"
echo ""
echo "Для просмотра отчета:"
echo "  less $REPORT_FILE"
echo "  или"
echo "  cat $REPORT_FILE"



# где /logs/general.log — твой лог MariaDB
grep -n "FROM REALM" /logs/general.log | tail -n 200

# или более конкретно по фрагменту с REALM_ATTRIBUTE:
grep -n "REALM_ATTRIBUTE" /logs/general.log | tail -n 200

# или полное вхождение (часть запроса):
grep -n "left outer join REALM_ATTRIBUTE" /logs/general.log | tail -n 200

