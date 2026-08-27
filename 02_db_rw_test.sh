#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

mkdir -p "$LOG_DIR"

echo "=========================================="
echo " Patroni HA test - READ/WRITE"
echo "=========================================="
echo "Host       : $DB_HOST"
echo "Port       : $DB_PRIMARY_PORT"
echo "Database   : $DB_NAME"
echo "Table      : $TEST_TABLE"
echo "Interval   : ${RW_INTERVAL}s"
echo "Timeout    : ${CONNECT_TIMEOUT}s"
echo "Log        : $RW_LOG"
echo
echo "Для остановки нажмите Ctrl+C"
echo "=========================================="
echo

while true
do

    # ======================================
    # Уникальный ID и значение
    # ======================================

    TEST_ID=$(date +%s%N)
    TEST_VALUE="TEST_${TEST_ID}"
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S.%3N')


    # ======================================
    # INSERT
    # ======================================

    START=$(date +%s%3N)

    INSERT_ERROR_FILE=$(mktemp)

    psql \
        "host=${DB_HOST} port=${DB_PRIMARY_PORT} dbname=${DB_NAME} user=${DB_USER} password=${DB_PASSWORD} connect_timeout=${CONNECT_TIMEOUT}" \
        -X \
        -q \
        -v ON_ERROR_STOP=1 \
        -c "
            INSERT INTO ${TEST_TABLE}(id, test_value)
            VALUES (${TEST_ID}, '${TEST_VALUE}');
        " \
        > /dev/null 2>"$INSERT_ERROR_FILE"

    INSERT_RC=$?

    END=$(date +%s%3N)
    INSERT_TIME=$((END - START))

    INSERT_ERROR_TEXT=$(tr '\n' ' ' < "$INSERT_ERROR_FILE")
    rm -f "$INSERT_ERROR_FILE"


    # ======================================
    # SELECT
    # ======================================

    if [ "$INSERT_RC" -eq 0 ]; then

        START=$(date +%s%3N)

        SELECT_ERROR_FILE=$(mktemp)

        SELECT_RESULT=$(psql \
            "host=${DB_HOST} port=${DB_PRIMARY_PORT} dbname=${DB_NAME} user=${DB_USER} password=${DB_PASSWORD} connect_timeout=${CONNECT_TIMEOUT}" \
            -X \
            -A \
            -t \
            -q \
            -v ON_ERROR_STOP=1 \
            -c "
                SELECT
                    id || '|' ||
                    test_value || '|' ||
                    inet_server_addr() || '|' ||
                    CASE
                        WHEN pg_is_in_recovery()
                        THEN 'REPLICA'
                        ELSE 'PRIMARY'
                    END
                FROM ${TEST_TABLE}
                WHERE id=${TEST_ID};
            " \
            2>"$SELECT_ERROR_FILE")

        SELECT_RC=$?

        END=$(date +%s%3N)
        SELECT_TIME=$((END - START))

        SELECT_ERROR_TEXT=$(tr '\n' ' ' < "$SELECT_ERROR_FILE")
        rm -f "$SELECT_ERROR_FILE"

        # Убираем пробелы/переводы строк вокруг результата
        SELECT_RESULT=$(echo "$SELECT_RESULT" | xargs)

        # ----------------------------------
        # Проверяем прочитанную строку
        # ----------------------------------

        EXPECTED_PREFIX="${TEST_ID}|${TEST_VALUE}|"

        if [ "$SELECT_RC" -eq 0 ] &&
           echo "$SELECT_RESULT" | grep -q "^${EXPECTED_PREFIX}"
        then
            SELECT_STATUS="OK"
        else
            SELECT_STATUS="FAIL"
        fi

    else

        SELECT_STATUS="SKIP"
        SELECT_TIME=0
        SELECT_RESULT="-"
        SELECT_ERROR_TEXT=""

    fi


    # ======================================
    # Общий результат
    # ======================================

    if [ "$INSERT_RC" -eq 0 ] && [ "$SELECT_STATUS" = "OK" ]; then
        STATUS="OK"
    else
        STATUS="FAIL"
    fi


    # ======================================
    # Определяем сервер и роль
    # ======================================

    SERVER="-"
    ROLE="-"

    if [ "$SELECT_STATUS" = "OK" ]; then
        SERVER=$(echo "$SELECT_RESULT" | awk -F'|' '{print $3}')
        ROLE=$(echo "$SELECT_RESULT" | awk -F'|' '{print $4}')
    fi


    # ======================================
    # Запись в лог
    # ======================================

    if [ "$STATUS" = "OK" ]; then

        echo "${TIMESTAMP} | STATUS=OK | ID=${TEST_ID} | INSERT=OK(${INSERT_TIME}ms) | SELECT=OK(${SELECT_TIME}ms) | SERVER=${SERVER} | ROLE=${ROLE}" \
            >> "$RW_LOG"

        echo "${TIMESTAMP} | OK | DB=${SERVER} | ${ROLE} | INSERT=${INSERT_TIME}ms | SELECT=${SELECT_TIME}ms"

    else

        # ----------------------------------
        # Формируем информацию об ошибке
        # ----------------------------------

        ERROR_TEXT=""

        if [ "$INSERT_RC" -ne 0 ]; then
            ERROR_TEXT="INSERT_ERROR=${INSERT_ERROR_TEXT}"
        fi

        if [ "$SELECT_STATUS" = "FAIL" ]; then

            if [ -n "$ERROR_TEXT" ]; then
                ERROR_TEXT="${ERROR_TEXT} ; "
            fi

            ERROR_TEXT="${ERROR_TEXT}SELECT_ERROR=${SELECT_ERROR_TEXT}"

        fi

        # ----------------------------------
        # Лог ошибки
        # ----------------------------------

        echo "${TIMESTAMP} | STATUS=FAIL | ID=${TEST_ID} | INSERT=${INSERT_RC}(${INSERT_TIME}ms) | SELECT=${SELECT_STATUS}(${SELECT_TIME}ms) | ${ERROR_TEXT}" \
            >> "$RW_LOG"

        echo "${TIMESTAMP} | FAIL | INSERT=${INSERT_RC} | SELECT=${SELECT_STATUS} | ${ERROR_TEXT}"

    fi


    # ======================================
    # Следующая итерация
    # ======================================

    sleep "$RW_INTERVAL"

done
