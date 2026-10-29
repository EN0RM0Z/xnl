
#!/bin/bash

# ============================================================
# МОНИТОРИНГ KEYCLOAK И MARIADB
#
# Oracle Linux 8
#
# Рекомендуемый запуск через cron каждую минуту:
# * * * * * /opt/keycloak/scripts/monitor_all.sh
#
# Проверки:
#   1. SQL: SELECT 1 внутри контейнера MariaDB.
#   2. TCP: соединение из контейнера Keycloak к MariaDB.
#   3. CPU: загрузка процессора по /proc/stat.
#
# Дополнительно:
#   - подробная диагностика при ошибках БД/TCP;
#   - уведомления о проблеме и восстановлении;
#   - повторные уведомления при длительной аварии;
#   - опциональный запуск скрипта перезапуска Keycloak.
# ============================================================


# ============================================================
# 1. НЕЗАВИСИМЫЕ МОДУЛИ
#
# 1 - включить
# 0 - выключить
#
# Отключение модуля исключает его из оценки состояния UP/DOWN.
# ============================================================

ENABLE_DB_SQL=1
ENABLE_KC_TCP=1
ENABLE_DB_DIAGNOSTICS=1
ENABLE_CPU=1

# Общий выключатель уведомлений и настройки каналов.
ENABLE_NOTIFICATIONS=0
ENABLE_MESSENGER=0
ENABLE_MAIL=0


# ============================================================
# 2. ИДЕНТИФИКАЦИЯ ЭКЗЕМПЛЯРА KEYCLOAK
#
# KEYCLOAK_INFO используется только в уведомлениях.
# В локальные журналы это значение не добавляется.
# ============================================================

KEYCLOAK_INFO="Keycloak(npofl.25v)"

# Имя сервера используется в темах писем и уведомлениях.
SERVER_NAME=$(hostname)


# ============================================================
# 3. ПРОВЕРКА MARIADB
# ============================================================

DB_CONTAINER="mariadb"
DB_HOST="mariadb"
DB_PORT=3306

DB_USER="keycloak"
DB_NAME="keycloak"

# Укажите настоящий пароль пользователя БД.
DB_PASSWORD="ЗАМЕНИТЬ_НА_РЕАЛЬНЫЙ_ПАРОЛЬ"

DB_TIMEOUT=8
KC_TCP_TIMEOUT=6


# ============================================================
# 4. МОНИТОРИНГ CPU
# ============================================================

CPU_LOG="/home/FC/weeee/cputest/cpu_monitor.log"
CPU_STATE="/var/tmp/cpu_monitor.state"

# Разделитель между временем и значением загрузки.
CPU_SEPARATOR=" | "

# При достижении порога состояние мониторинга считается DOWN.
CPU_CRITICAL_THRESHOLD=90


# ============================================================
# 5. ПОДРОБНАЯ ДИАГНОСТИКА БД
# ============================================================

DIAG_DIR="/var/log/keycloak-db-diagnostics"

# Минимальный интервал между подробными отчётами, секунд.
# 900 секунд = 15 минут.
DETAIL_COOLDOWN=900

LAST_REPORT_FILE="/var/tmp/keycloak-db-last-report"


# ============================================================
# 6. УВЕДОМЛЕНИЯ
# ============================================================

# Интервал повторных уведомлений при продолжающейся аварии,
# минут. Первое уведомление отправляется сразу при переходе
# UP -> DOWN, следующее — не раньше заданного интервала.
NOTIFY_INTERVAL=30

NOTIFY_STATE_FILE="/var/tmp/keycloak-monitor-notify.state"

# Настройки API мессенджера.
NOTIFY_URL="https://send.test.ru/message"
SEVERITY="info"
SENDER="ALERT_SENDER"
CHAT_ID="123-123456478"
BOT_TOKEN="123456.fgjhgjhgjhgjhgjhgjh"

# Настройки электронной почты.
SMTP_SERVER="smtp.test.ru"
MAIL_FROM="alert@test.ru"
MAIL_TO="адреса@получате.ля"

# В теме письма указываются уровень, экземпляр и сервер.
MAIL_SUBJECT_DOWN="[FATAL][KEYCLOAK]: ${KEYCLOAK_INFO} недоступен [${SERVER_NAME}]"
MAIL_SUBJECT_UP="[WARN][KEYCLOAK]: ${KEYCLOAK_INFO} восстановлен [${SERVER_NAME}]"


# ============================================================
# 7. АВТОМАТИЧЕСКИЙ ПЕРЕЗАПУСК KEYCLOAK
# ============================================================

# 1 - разрешить запуск скрипта перезапуска при первом DOWN.
# 0 - не запускать автоматически.
#
# Перезапуск запускается в фоне и не ожидает завершения.
# Повторно при уже зафиксированном DOWN не запускается.
RESTART_KEYCLOAK=0

RESTART_SCRIPT="/opt/keycloak/scripts/restartkeyc.sh"


# ============================================================
# 8. СЛУЖЕБНЫЕ ФАЙЛЫ
# ============================================================

LOG_FILE="/var/log/keycloak-monitor.log"
LOCK_FILE="/var/tmp/keycloak-monitor.lock"

# Внутренние значения состояния.
SITE_STATE="UP"
LAST_NOTIFICATION=0
CRITICAL=0
CRITICAL_REASON=""

DB_STATUS="SKIP"
KC_STATUS="SKIP"
CPU_STATUS="SKIP"
CPU_USAGE="N/A"

DB_RESULT=""
KC_RESULT=""


# ============================================================
# 9. ПОДГОТОВКА ФАЙЛОВ И ЗАЩИТА ОТ ПАРАЛЛЕЛЬНОГО ЗАПУСКА
# ============================================================

umask 077

# Каталоги создаются только для включённых модулей.
mkdir -p "$(dirname "$LOG_FILE")" || exit 1
touch "$LOG_FILE" || exit 1

if [[ "$ENABLE_CPU" -eq 1 ]]; then
    mkdir -p "$(dirname "$CPU_LOG")" || exit 1
    touch "$CPU_LOG" || exit 1
fi

if [[ "$ENABLE_DB_DIAGNOSTICS" -eq 1 ]]; then
    mkdir -p "$DIAG_DIR" || exit 1
fi

exec 200>"$LOCK_FILE"

# Если предыдущий запуск ещё работает, новый завершается.
if ! flock -n 200; then
    exit 0
fi


# ============================================================
# 10. ФУНКЦИЯ SQL-ЗАПРОСА К MARIADB
#
# Используется как для SELECT 1, так и для диагностики.
# Пароль передаётся через MYSQL_PWD, чтобы не помещать его
# непосредственно в аргументы командной строки клиента.
# ============================================================

db_query()
{
    local SQL="$1"

    timeout "$DB_TIMEOUT" docker exec \
        -e MYSQL_PWD="$DB_PASSWORD" \
        "$DB_CONTAINER" \
        mariadb \
        --protocol=tcp \
        -h 127.0.0.1 \
        -u "$DB_USER" \
        "$DB_NAME" \
        -N -e "$SQL" 2>&1
}


# ============================================================
# 11. SQL-ПРОВЕРКА ДОСТУПНОСТИ БД
#
# Успех: запрос SELECT 1 вернул 1.
# Неудача: ошибка клиента, таймаут или другой ответ.
# ============================================================

check_db_sql()
{
    local RESULT
    local RC

    RESULT=$(db_query "SELECT 1")
    RC=$?

    if [[ "$RC" -eq 0 ]] && [[ "$RESULT" == "1" ]]; then
        DB_STATUS="OK"
        DB_RESULT="SELECT 1 выполнен успешно"
    else
        DB_STATUS="FAIL"
        DB_RESULT="$RESULT"
        CRITICAL=1
        CRITICAL_REASON="${CRITICAL_REASON}DB_SQL_FAILED,"
    fi
}


# ============================================================
# 12. TCP-ПРОВЕРКА ИЗ КОНТЕЙНЕРА KEYCLOAK
#
# Проверяем соединение именно со стороны Keycloak.
# Проверка не выполняет запросов к БД.
# ============================================================

check_kc_tcp()
{
    local RC

    if ! docker inspect "$KC_CONTAINER" >/dev/null 2>&1; then
        KC_STATUS="FAIL"
        KC_RESULT="Контейнер Keycloak не найден"
        CRITICAL=1
        CRITICAL_REASON="${CRITICAL_REASON}KC_TCP_FAILED,"
        return
    fi

    timeout "$KC_TCP_TIMEOUT" docker exec "$KC_CONTAINER" \
        bash -c "timeout 4 bash -c '</dev/tcp/${DB_HOST}/${DB_PORT}'" \
        >/dev/null 2>&1

    RC=$?

    if [[ "$RC" -eq 0 ]]; then
        KC_STATUS="OK"
        KC_RESULT="TCP-соединение доступно"
    else
        KC_STATUS="FAIL"
        KC_RESULT="TCP-соединение к ${DB_HOST}:${DB_PORT} не установлено"
        CRITICAL=1
        CRITICAL_REASON="${CRITICAL_REASON}KC_TCP_FAILED,"
    fi
}


# ============================================================
# 13. ЗАПИСЬ ЗАГРУЗКИ CPU
#
# Сравниваем два последовательных снимка /proc/stat.
# Первый запуск только сохраняет начальные счётчики.
#
# idle и iowait не учитываются как занятое CPU — это
# соответствует логике исходного CPU-монитора.
# ============================================================

log_cpu()
{
    local USER NICE SYSTEM IDLE IOWAIT IRQ SOFTIRQ STEAL
    local TOTAL BUSY
    local PTOTAL PUSER PNICE PSYSTEM PIDLE PIOWAIT PIRQ PSOFTIRQ PSTEAL
    local DT

    read -r _ USER NICE SYSTEM IDLE IOWAIT IRQ SOFTIRQ STEAL _ < /proc/stat

    TOTAL=$((USER + NICE + SYSTEM + IDLE + IOWAIT + IRQ + SOFTIRQ + STEAL))

    if [[ ! -f "$CPU_STATE" ]]; then
        echo "$TOTAL $USER $NICE $SYSTEM $IDLE $IOWAIT $IRQ $SOFTIRQ $STEAL" > "$CPU_STATE"
        CPU_STATUS="INIT"
        return
    fi

    read -r PTOTAL PUSER PNICE PSYSTEM PIDLE PIOWAIT PIRQ PSOFTIRQ PSTEAL < "$CPU_STATE"

    # Сохраняем текущие значения для следующего запуска.
    echo "$TOTAL $USER $NICE $SYSTEM $IDLE $IOWAIT $IRQ $SOFTIRQ $STEAL" > "$CPU_STATE"

    DT=$((TOTAL - PTOTAL))

    if [[ "$DT" -le 0 ]]; then
        CPU_STATUS="INIT"
        return
    fi

    BUSY=$((DT - (IDLE - PIDLE) - (IOWAIT - PIOWAIT)))
    CPU_USAGE=$((BUSY * 100 / DT))

    echo "$(date '+%Y-%m-%d %H:%M:%S')${CPU_SEPARATOR}${CPU_USAGE}%" >> "$CPU_LOG"

    if [[ "$CPU_USAGE" -ge "$CPU_CRITICAL_THRESHOLD" ]]; then
        CPU_STATUS="FAIL"
        CRITICAL=1
        CRITICAL_REASON="${CRITICAL_REASON}CPU_HIGH,"
    else
        CPU_STATUS="OK"
    fi
}


# ============================================================
# 14. ПОДРОБНЫЙ ДИАГНОСТИЧЕСКИЙ ОТЧЁТ
#
# Создаётся при ошибке SQL или TCP-проверки.
# Повторный отчёт разрешён после DETAIL_COOLDOWN секунд.
#
# Ошибка отдельных диагностических SQL-команд не мешает
# сохранению остальных разделов отчёта.
# ============================================================

collect_db_diagnostics()
{
    local NOW LAST_REPORT REPORT_FILE

    NOW=$(date +%s)
    LAST_REPORT=0

    if [[ -f "$LAST_REPORT_FILE" ]]; then
        read -r LAST_REPORT < "$LAST_REPORT_FILE"
    fi

    if [[ "$LAST_REPORT" =~ ^[0-9]+$ ]] &&
       (( NOW - LAST_REPORT < DETAIL_COOLDOWN )); then
        return
    fi

    REPORT_FILE="${DIAG_DIR}/db-diagnostic-$(date '+%Y%m%d-%H%M%S')-$$.log"

    {
        echo "============================================================"
        echo "KEYCLOAK / MARIADB DIAGNOSTIC REPORT"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hostname: $(hostname)"
        echo "============================================================"

        echo
        echo "[1] MONITORING RESULTS"
        echo "DB_SQL_STATUS: $DB_STATUS"
        echo "DB_SQL_RESULT: $DB_RESULT"
        echo "KC_TCP_STATUS: $KC_STATUS"
        echo "KC_TCP_RESULT: $KC_RESULT"

        echo
        echo "[2] MARIADB CONTAINER INSPECT"
        docker inspect --format \
            'State={{.State.Status}} RestartCount={{.RestartCount}} StartedAt={{.State.StartedAt}}' \
            "$DB_CONTAINER" 2>&1

        echo
        echo "[3] DOCKER STATS"
        docker stats --no-stream "$DB_CONTAINER" "$KC_CONTAINER" 2>&1

        echo
        echo "[4] MARIADB PROCESSLIST"
        db_query "SHOW FULL PROCESSLIST" 2>&1

        echo
        echo "[5] INNODB STATUS"
        db_query "SHOW ENGINE INNODB STATUS" 2>&1

        echo
        echo "[6] MARIADB GLOBAL STATUS"
        db_query "SHOW GLOBAL STATUS WHERE Variable_name IN
          ('Threads_connected','Threads_running','Max_used_connections',
           'Connections','Aborted_connects','Slow_queries')" 2>&1

        echo
        echo "[7] MARIADB GLOBAL VARIABLES"
        db_query "SHOW GLOBAL VARIABLES WHERE Variable_name IN
          ('max_connections','wait_timeout','interactive_timeout',
           'connect_timeout','innodb_buffer_pool_size')" 2>&1

        echo
        echo "[8] MARIADB CONTAINER LOGS — LAST 5 MINUTES"
        docker logs --since 5m "$DB_CONTAINER" 2>&1

        echo
        echo "[9] KEYCLOAK CONTAINER LOGS — LAST 5 MINUTES"
        docker logs --since 5m "$KC_CONTAINER" 2>&1

        echo
        echo "============================================================"
        echo "END OF REPORT"
        echo "============================================================"

    } > "$REPORT_FILE" 2>&1

    echo "$NOW" > "$LAST_REPORT_FILE"
}


# ============================================================
# 15. ОТПРАВКА УВЕДОМЛЕНИЯ В МЕССЕНДЖЕР
#
# Успех: HTTP 2xx и успешное выполнение curl.
# ============================================================

send_messenger()
{
    local MESSAGE="$1"
    local HTTP_CODE CURL_EXIT DATA

    command -v jq >/dev/null 2>&1 || return 1

    DATA=$(jq -n \
        --arg severity "$SEVERITY" \
        --arg sender "$SENDER" \
        --arg chat_id "$CHAT_ID" \
        --arg bot_token "$BOT_TOKEN" \
        --arg text "$MESSAGE" \
        '{
            severity: $severity,
            sender: $sender,
            chat_id: $chat_id,
            bot_token: $bot_token,
            text: $text
        }') || return 1

    HTTP_CODE=$(curl \
        --silent \
        --output /dev/null \
        --write-out "%{http_code}" \
        --request POST \
        --header "accept: */*" \
        --header "Content-Type: application/json" \
        --data "$DATA" \
        --connect-timeout 5 \
        --max-time 10 \
        "$NOTIFY_URL" 2>/dev/null)

    CURL_EXIT=$?

    if [[ "$CURL_EXIT" -eq 0 ]] &&
       [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    fi

    return 1
}


# ============================================================
# 16. ОТПРАВКА УВЕДОМЛЕНИЯ ПО ПОЧТЕ
# ============================================================

send_mail()
{
    local MESSAGE="$1"
    local SUBJECT="$2"

    echo "$MESSAGE" | mailx \
        -s "$SUBJECT" \
        -S smtp="$SMTP_SERVER" \
        -S from="$MAIL_FROM" \
        "$MAIL_TO" >/dev/null 2>&1

    return $?
}


# ============================================================
# 17. ЕДИНАЯ ФУНКЦИЯ УВЕДОМЛЕНИЙ
#
# В локальные логи KEYCLOAK_INFO не добавляется.
# В сообщение включаются экземпляр Keycloak и hostname.
# ============================================================

notify_all()
{
    local LEVEL="$1"
    local MESSAGE="$2"
    local SUBJECT="$3"

    local MESSENGER_OK=0
    local MAIL_OK=0
    local CHANNELS=0
    local RESULT=""

    if [[ "$ENABLE_NOTIFICATIONS" -ne 1 ]]; then
        NOTIFY_RESULT="УВЕДОМЛЕНИЯ ОТКЛЮЧЕНЫ"
        return
    fi

    if [[ "$ENABLE_MESSENGER" -eq 1 ]]; then
        CHANNELS=1
        if send_messenger "$MESSAGE"; then
            MESSENGER_OK=1
        fi
    fi

    if [[ "$ENABLE_MAIL" -eq 1 ]]; then
        CHANNELS=1
        if send_mail "$MESSAGE" "$SUBJECT"; then
            MAIL_OK=1
        fi
    fi

    if [[ "$CHANNELS" -eq 0 ]]; then
        NOTIFY_RESULT="КАНАЛЫ УВЕДОМЛЕНИЙ ОТКЛЮЧЕНЫ"
        return
    fi

    if [[ "$ENABLE_MESSENGER" -eq 1 ]] && [[ "$MESSENGER_OK" -eq 1 ]]; then
        RESULT="МЕССЕНДЖЕР ОТПРАВЛЕН"
    elif [[ "$ENABLE_MESSENGER" -eq 1 ]]; then
        RESULT="МЕССЕНДЖЕР НЕ ОТПРАВЛЕН"
    fi

    if [[ "$ENABLE_MAIL" -eq 1 ]]; then
        if [[ -n "$RESULT" ]]; then
            RESULT="${RESULT}, "
        fi

        if [[ "$MAIL_OK" -eq 1 ]]; then
            RESULT="${RESULT}ПОЧТА ОТПРАВЛЕНА"
        else
            RESULT="${RESULT}ПОЧТА НЕ ОТПРАВЛЕНА"
        fi
    fi

    NOTIFY_RESULT="$RESULT"
}


# ============================================================
# 18. ЧТЕНИЕ СОХРАНЁННОГО СОСТОЯНИЯ
#
# Состояние нужно, чтобы обнаруживать переходы:
# UP -> DOWN: проблема появилась.
# DOWN -> UP: проблема устранена.
# ============================================================

if [[ -f "$NOTIFY_STATE_FILE" ]]; then
    # Файл формируется этим скриптом и содержит только две
    # переменные состояния.
    source "$NOTIFY_STATE_FILE"
fi

# Значения по умолчанию, если файл новый или неполный.
SITE_STATE="${SITE_STATE:-UP}"
LAST_NOTIFICATION="${LAST_NOTIFICATION:-0}"


# ============================================================
# 19. ВЫПОЛНЕНИЕ ВКЛЮЧЁННЫХ ПРОВЕРОК
# ============================================================

if [[ "$ENABLE_DB_SQL" -eq 1 ]]; then
    check_db_sql
fi

if [[ "$ENABLE_KC_TCP" -eq 1 ]]; then
    check_kc_tcp
fi

if [[ "$ENABLE_CPU" -eq 1 ]]; then
    log_cpu
fi

# Подробная диагностика запускается только при сбое SQL/TCP.
if [[ "$ENABLE_DB_DIAGNOSTICS" -eq 1 ]] &&
   { [[ "$DB_STATUS" == "FAIL" ]] || [[ "$KC_STATUS" == "FAIL" ]]; }; then
    collect_db_diagnostics
fi


# ============================================================
# 20. ОПРЕДЕЛЕНИЕ ОБЩЕГО СОСТОЯНИЯ
#
# CRITICAL=1 означает, что хотя бы одна включённая
# критическая проверка обнаружила проблему.
# ============================================================

NOW=$(date +%s)
LOG_DATE=$(date '+%Y-%m-%d %H:%M:%S')

LOG_MESSAGE="${LOG_DATE} DB_SQL=${DB_STATUS} KC_TCP=${KC_STATUS} CPU=${CPU_USAGE}%"

if [[ "$CRITICAL" -eq 1 ]]; then
    LOG_MESSAGE="${LOG_MESSAGE} CRITICAL=${CRITICAL_REASON}"
fi


# ============================================================
# 21. ОБРАБОТКА ПЕРЕХОДА UP -> DOWN
#
# Это первое обнаружение критической ситуации.
# Отправляем [FATAL] и при необходимости запускаем рестарт.
# ============================================================

if [[ "$CRITICAL" -eq 1 ]]; then

    if [[ "$SITE_STATE" != "DOWN" ]]; then

        MESSAGE="[FATAL] ${KEYCLOAK_INFO} недоступен или обнаружена критическая проблема. Сервер: ${SERVER_NAME}. DB_SQL: ${DB_STATUS}. KC_TCP: ${KC_STATUS}. CPU: ${CPU_USAGE}%. Причина: ${CRITICAL_REASON}"

        notify_all "FATAL" "$MESSAGE" "$MAIL_SUBJECT_DOWN"

        LOG_MESSAGE="${LOG_MESSAGE}, ПРОБЛЕМА: ${NOTIFY_RESULT}"

        # Перезапуск только при первом обнаружении DOWN.
        if [[ "$RESTART_KEYCLOAK" -eq 1 ]]; then
            if [[ -x "$RESTART_SCRIPT" ]]; then
                "$RESTART_SCRIPT" >/dev/null 2>&1 &
                LOG_MESSAGE="${LOG_MESSAGE}, ПЕРЕЗАПУСК KEYCLOAK: ЗАПУЩЕН"
            else
                LOG_MESSAGE="${LOG_MESSAGE}, ПЕРЕЗАПУСК KEYCLOAK: СКРИПТ НЕ НАЙДЕН ИЛИ НЕ ИСПОЛНЯЕМЫЙ"
            fi
        fi

        SITE_STATE="DOWN"
        LAST_NOTIFICATION="$NOW"

    else

        # Проблема продолжается: повторяем уведомление
        # только после заданного интервала.
        INTERVAL_SECONDS=$((NOTIFY_INTERVAL * 60))
        ELAPSED=$((NOW - LAST_NOTIFICATION))

        if [[ "$ELAPSED" -ge "$INTERVAL_SECONDS" ]]; then

            MESSAGE="[FATAL] ${KEYCLOAK_INFO} всё ещё находится в критическом состоянии. Сервер: ${SERVER_NAME}. DB_SQL: ${DB_STATUS}. KC_TCP: ${KC_STATUS}. CPU: ${CPU_USAGE}%. Причина: ${CRITICAL_REASON}. Повторное уведомление."

            notify_all "FATAL" "$MESSAGE" "$MAIL_SUBJECT_DOWN"

            LOG_MESSAGE="${LOG_MESSAGE}, ПОВТОРНОЕ УВЕДОМЛЕНИЕ: ${NOTIFY_RESULT}"

            LAST_NOTIFICATION="$NOW"
        fi
    fi


# ============================================================
# 22. ОБРАБОТКА ПЕРЕХОДА DOWN -> UP
#
# Проблема устранена: отправляем [WARN] о восстановлении.
# ============================================================

else

    if [[ "$SITE_STATE" == "DOWN" ]]; then

        MESSAGE="[WARN] ${KEYCLOAK_INFO} восстановлен. Критические проверки снова успешны. Сервер: ${SERVER_NAME}. DB_SQL: ${DB_STATUS}. KC_TCP: ${KC_STATUS}. CPU: ${CPU_USAGE}%."

        notify_all "WARN" "$MESSAGE" "$MAIL_SUBJECT_UP"

        LOG_MESSAGE="${LOG_MESSAGE}, ВОССТАНОВЛЕНИЕ: ${NOTIFY_RESULT}"

    fi

    SITE_STATE="UP"
    LAST_NOTIFICATION=0
fi


# ============================================================
# 23. СОХРАНЕНИЕ СОСТОЯНИЯ
#
# В этом файле нет KEYCLOAK_INFO: он нужен только для
# определения предыдущего состояния и интервала уведомлений.
# ============================================================

cat > "$NOTIFY_STATE_FILE" <<EOF
SITE_STATE="$SITE_STATE"
LAST_NOTIFICATION=$LAST_NOTIFICATION
EOF


# ============================================================
# 24. ЗАПИСЬ РЕЗУЛЬТАТА
#
# В журнал пишем состояние проверок и результат уведомлений,
# но не имя экземпляра из KEYCLOAK_INFO.
# ============================================================

echo "$LOG_MESSAGE" >> "$LOG_FILE"

exit 0
