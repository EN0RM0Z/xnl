#!/bin/bash

# ============================================================
# МОНИТОРИНГ ДОСТУПНОСТИ KEYCLOAK
#
# Oracle Linux 8
#
# Запуск через cron каждые 5 минут:
#
# */5 * * * * /opt/keycloak/scripts/check_keycloak.sh
# ============================================================


# ============================================================
# НАСТРОЙКИ ПРОВЕРКИ
# ============================================================

# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
# МЕТОД ПРОВЕРКИ
#
# HTTP_CODE - проверка HTTP-кода ответа
# TOKEN     - получение access_token
#
# Для переключения метода измените ТОЛЬКО эту строку.
# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

CHECK_METHOD="HTTP_CODE"


# ============================================================
# ОБЩИЕ НАСТРОЙКИ
# ============================================================

# URL сайта.
# Используется при CHECK_METHOD="HTTP_CODE"
URL="https://keycloak.test.ru"

# Количество проверок за один запуск
CHECK_ATTEMPTS=30

# Пауза между проверками, секунд
CHECK_DELAY=1

# Минимальное количество успешных проверок,
# при котором сайт считается доступным
MIN_SUCCESS=25

# Через сколько минут отправлять повторное уведомление,
# если сайт продолжает быть недоступен
NOTIFY_INTERVAL=30

# Таймаут установки соединения
CONNECT_TIMEOUT=5

# Максимальное время одного запроса
MAX_TIME=10

# User-Agent нашего скрипта.
# Позволяет находить запросы мониторинга в Nginx access.log
USER_AGENT="Keycloak-Monitor/1.0 (check-script)"


# ============================================================
# НАСТРОЙКИ ПРОВЕРКИ TOKEN
#
# Используются только при:
#
# CHECK_METHOD="TOKEN"
# ============================================================

# URL получения токена
TOKEN_URL="https://keycloak.test.ru/realms/test/protocol/openid-connect/token"

# Client ID
CLIENT_ID="test-client"

# Client Secret
CLIENT_SECRET="xxxxxxxxxxxxxxxxxxxxxxxx"

# Scope
TOKEN_SCOPE="openid"


# ============================================================
# ФАЙЛЫ
# ============================================================

LOGFILE="/opt/keycloak/scripts/log_kk.txt"

# Файл состояния между запусками
STATEFILE="/opt/keycloak/scripts/site_monitor.state"

# Файл блокировки от параллельного запуска
LOCKFILE="/opt/keycloak/scripts/site_monitor.lock"


# ============================================================
# НАСТРОЙКИ МЕССЕНДЖЕРА
# ============================================================

NOTIFY_URL="https://send.test.ru/message"

SEVERITY="info"
SENDER="ALERT_SENDER"
CHAT_ID="123-123456478"
BOT_TOKEN="123456.fgjhgjhgjhgjhgjhgjh"


# ============================================================
# НАСТРОЙКИ ПОЧТЫ
# ============================================================

SMTP_SERVER="smtp.test.ru"

MAIL_FROM="alert@test.ru"

MAIL_TO="адреса@получате.ля"

MAIL_SUBJECT_DOWN="ALERT: Keycloak недоступен"
MAIL_SUBJECT_UP="OK: Keycloak восстановлен"


# ============================================================
# ФУНКЦИЯ ПРОВЕРКИ ПО HTTP-КОДУ
#
# Успешна только при HTTP 200.
#
# Возвращает HTTP-код:
#
# 200 - успешно
# 000 - ошибка соединения/curl
# ============================================================

check_http_code()
{
    local STATUS
    local CURL_EXIT

    STATUS=$(curl \
        --head \
        --insecure \
        --location \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        --user-agent "$USER_AGENT" \
        --write-out "%{http_code}" \
        --silent \
        --output /dev/null \
        "$URL" \
        2>/dev/null
    )

    CURL_EXIT=$?

    if [[ "$CURL_EXIT" -ne 0 ]]; then
        echo "000"
    else
        echo "$STATUS"
    fi
}


# ============================================================
# ФУНКЦИЯ ПРОВЕРКИ ПОЛУЧЕНИЯ TOKEN
#
# Выполняет:
#
# POST TOKEN_URL
#
# client_id
# grant_type=client_credentials
# scope=openid
# client_secret
#
# Успешна, если в ответе есть непустой access_token.
#
# Возвращает:
#
# 200 - token получен
# 000 - token не получен
# ============================================================

check_token()
{
    local RESPONSE
    local CURL_EXIT
    local ACCESS_TOKEN

    RESPONSE=$(curl \
        --insecure \
        --location \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        --user-agent "$USER_AGENT" \
        --silent \
        --request POST \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "scope=${TOKEN_SCOPE}" \
        --data-urlencode "client_secret=${CLIENT_SECRET}" \
        "$TOKEN_URL" \
        2>/dev/null
    )

    CURL_EXIT=$?

    # Ошибка curl
    if [[ "$CURL_EXIT" -ne 0 ]]; then
        echo "000"
        return
    fi

    # Пытаемся получить access_token из JSON.
    #
    # jq используется для того, чтобы не просто искать
    # текст "access_token", а проверить наличие самого
    # непустого значения.
    ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token // empty' 2>/dev/null)

    if [[ -n "$ACCESS_TOKEN" ]]; then
        echo "200"
    else
        echo "000"
    fi
}


# ============================================================
# ОБЩАЯ ФУНКЦИЯ ПРОВЕРКИ
#
# В зависимости от CHECK_METHOD вызывает:
#
# check_http_code
#
# или
#
# check_token
# ============================================================

check_site()
{
    case "$CHECK_METHOD" in

        HTTP_CODE)
            check_http_code
            ;;

        TOKEN)
            check_token
            ;;

        *)
            echo "000"
            ;;

    esac
}


# ============================================================
# ФУНКЦИЯ ОТПРАВКИ В МЕССЕНДЖЕР
#
# Возвращает:
#
# 0 - успешно
# 1 - ошибка
# ============================================================

send_messenger()
{
    local MESSAGE="$1"

    local DATA
    local HTTP_CODE
    local CURL_EXIT

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
        }'
    )

    HTTP_CODE=$(curl \
        --silent \
        --show-error \
        --output /dev/null \
        --write-out "%{http_code}" \
        --request POST \
        --header "accept: */*" \
        --header "Content-Type: application/json" \
        --data "$DATA" \
        --connect-timeout 5 \
        --max-time 10 \
        "$NOTIFY_URL" \
        2>/dev/null
    )

    CURL_EXIT=$?

    if [[ "$CURL_EXIT" -eq 0 ]] && \
       [[ "$HTTP_CODE" -ge 200 ]] && \
       [[ "$HTTP_CODE" -lt 300 ]]; then

        return 0

    else

        return 1

    fi
}


# ============================================================
# ФУНКЦИЯ ОТПРАВКИ ПОЧТЫ
#
# Используется mailx:
#
# echo "текст" | mailx \
#   -s "тема" \
#   -S smtp="smtp.test.ru" \
#   -S from="alert@test.ru" \
#   "получатель@test.ru"
#
# Возвращает:
#
# 0 - успешно
# 1 - ошибка
# ============================================================

send_mail()
{
    local MESSAGE="$1"
    local SUBJECT="$2"

    echo "$MESSAGE" | mailx \
        -s "$SUBJECT" \
        -S smtp="$SMTP_SERVER" \
        -S from="$MAIL_FROM" \
        "$MAIL_TO"

    if [[ "$?" -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}


# ============================================================
# ЗАЩИТА ОТ ПАРАЛЛЕЛЬНОГО ЗАПУСКА
# ============================================================

exec 200>"$LOCKFILE"

if ! flock -n 200; then
    exit 0
fi


# ============================================================
# ЧТЕНИЕ ПРЕДЫДУЩЕГО СОСТОЯНИЯ
# ============================================================

SITE_STATE="UP"
LAST_NOTIFICATION=0

if [[ -f "$STATEFILE" ]]; then
    source "$STATEFILE"
fi


# ============================================================
# ПРОВЕРКА САЙТА
# ============================================================

SUCCESS_COUNT=0
LAST_STATUS="000"

for ((i=1; i<=CHECK_ATTEMPTS; i++))
do

    STATUS=$(check_site)

    LAST_STATUS="$STATUS"

    # Для обоих методов успешная проверка
    # обозначается кодом 200.
    if [[ "$STATUS" == "200" ]]; then
        ((SUCCESS_COUNT++))
    fi

    if [[ "$i" -lt "$CHECK_ATTEMPTS" ]]; then
        sleep "$CHECK_DELAY"
    fi

done


# ============================================================
# ОПРЕДЕЛЯЕМ ДОСТУПНОСТЬ
# ============================================================

if [[ "$SUCCESS_COUNT" -ge "$MIN_SUCCESS" ]]; then
    SITE_AVAILABLE=1
else
    SITE_AVAILABLE=0
fi


# ============================================================
# ТЕКУЩЕЕ ВРЕМЯ
# ============================================================

NOW=$(date +%s)

LOG_DATE=$(date +"%Y-%m-%d %T")

LOG_MESSAGE="${LOG_DATE} Успешных: ${SUCCESS_COUNT} из ${CHECK_ATTEMPTS}"


# ============================================================
# САЙТ ДОСТУПЕН
# ============================================================

if [[ "$SITE_AVAILABLE" -eq 1 ]]; then

    # --------------------------------------------------------
    # ЕСЛИ ДО ЭТОГО БЫЛ DOWN — ПРОИЗОШЛО ВОССТАНОВЛЕНИЕ
    # --------------------------------------------------------

    if [[ "$SITE_STATE" == "DOWN" ]]; then

        MESSAGE="Keycloak восстановлен. Сайт снова доступен: ${URL}. Успешных проверок: ${SUCCESS_COUNT}/${CHECK_ATTEMPTS}"

        # ----------------------------------------------------
        # МЕССЕНДЖЕР
        # ----------------------------------------------------

        if send_messenger "$MESSAGE"; then
            MESSENGER_OK=1
        else
            MESSENGER_OK=0
        fi


        # ----------------------------------------------------
        # ПОЧТА
        # ----------------------------------------------------

        if send_mail "$MESSAGE" "$MAIL_SUBJECT_UP"; then
            MAIL_OK=1
        else
            MAIL_OK=0
        fi


        # ----------------------------------------------------
        # РЕЗУЛЬТАТ
        # ----------------------------------------------------

        if [[ "$MESSENGER_OK" -eq 1 ]] && \
           [[ "$MAIL_OK" -eq 1 ]]; then

            LOG_MESSAGE="${LOG_MESSAGE}, САЙТ ВОССТАНОВЛЕН: УВЕДОМЛЕНИЯ ОТПРАВЛЕНЫ"

        elif [[ "$MESSENGER_OK" -eq 1 ]] && \
             [[ "$MAIL_OK" -eq 0 ]]; then

            LOG_MESSAGE="${LOG_MESSAGE}, САЙТ ВОССТАНОВЛЕН: МЕССЕНДЖЕР ОТПРАВЛЕН, ПОЧТА НЕ ОТПРАВЛЕНА"

        elif [[ "$MESSENGER_OK" -eq 0 ]] && \
             [[ "$MAIL_OK" -eq 1 ]]; then

            LOG_MESSAGE="${LOG_MESSAGE}, САЙТ ВОССТАНОВЛЕН: МЕССЕНДЖЕР НЕ ОТПРАВЛЕН, ПОЧТА ОТПРАВЛЕНА"

        else

            LOG_MESSAGE="${LOG_MESSAGE}, САЙТ ВОССТАНОВЛЕН: СБОЙ ОТПРАВКИ УВЕДОМЛЕНИЙ"

        fi

    fi


    # --------------------------------------------------------
    # Состояние UP
    # --------------------------------------------------------

    SITE_STATE="UP"

    # Сбрасываем таймер повторных уведомлений
    LAST_NOTIFICATION=0


# ============================================================
# САЙТ НЕДОСТУПЕН
# ============================================================

else

    # --------------------------------------------------------
    # ПЕРВОЕ ОБНАРУЖЕНИЕ НЕДОСТУПНОСТИ
    # --------------------------------------------------------

    if [[ "$SITE_STATE" != "DOWN" ]]; then

        MESSAGE="Keycloak недоступен! URL: ${URL}. Успешных проверок: ${SUCCESS_COUNT}/${CHECK_ATTEMPTS}. Последний результат проверки: ${LAST_STATUS}"

        # ----------------------------------------------------
        # МЕССЕНДЖЕР
        # ----------------------------------------------------

        if send_messenger "$MESSAGE"; then
            MESSENGER_OK=1
        else
            MESSENGER_OK=0
        fi


        # ----------------------------------------------------
        # ПОЧТА
        # ----------------------------------------------------

        if send_mail "$MESSAGE" "$MAIL_SUBJECT_DOWN"; then
            MAIL_OK=1
        else
            MAIL_OK=0
        fi


        # ----------------------------------------------------
        # РЕЗУЛЬТАТ
        # ----------------------------------------------------

        if [[ "$MESSENGER_OK" -eq 1 ]] && \
           [[ "$MAIL_OK" -eq 1 ]]; then

            LOG_MESSAGE="${LOG_MESSAGE}, САЙТ НЕ ДОСТУПЕН: УВЕДОМЛЕНИЯ ОТПРАВЛЕНЫ"

        elif [[ "$MESSENGER_OK" -eq 1 ]] && \
             [[ "$MAIL_OK" -eq 0 ]]; then

            LOG_MESSAGE="${LOG_MESSAGE}, САЙТ НЕ ДОСТУПЕН: МЕССЕНДЖЕР ОТПРАВЛЕН, ПОЧТА НЕ ОТПРАВЛЕНА"

        elif [[ "$MESSENGER_OK" -eq 0 ]] && \
             [[ "$MAIL_OK" -eq 1 ]]; then

            LOG_MESSAGE="${LOG_MESSAGE}, САЙТ НЕ ДОСТУПЕН: МЕССЕНДЖЕР НЕ ОТПРАВЛЕН, ПОЧТА ОТПРАВЛЕНА"

        else

            LOG_MESSAGE="${LOG_MESSAGE}, САЙТ НЕ ДОСТУПЕН: СБОЙ ОТПРАВКИ УВЕДОМЛЕНИЙ"

        fi


        # ----------------------------------------------------
        # Фиксируем DOWN
        # ----------------------------------------------------

        SITE_STATE="DOWN"

        # Время первой попытки уведомления
        LAST_NOTIFICATION="$NOW"


    # --------------------------------------------------------
    # САЙТ УЖЕ БЫЛ НЕДОСТУПЕН
    # --------------------------------------------------------

    else

        INTERVAL_SECONDS=$((NOTIFY_INTERVAL * 60))

        ELAPSED=$((NOW - LAST_NOTIFICATION))


        # ----------------------------------------------------
        # ПРОШЛО 30 МИНУТ
        # ----------------------------------------------------

        if [[ "$ELAPSED" -ge "$INTERVAL_SECONDS" ]]; then

            MESSAGE="Keycloak всё ещё недоступен! URL: ${URL}. Успешных проверок: ${SUCCESS_COUNT}/${CHECK_ATTEMPTS}. Последний результат проверки: ${LAST_STATUS}. Повторное уведомление."

            # ------------------------------------------------
            # МЕССЕНДЖЕР
            # ------------------------------------------------

            if send_messenger "$MESSAGE"; then
                MESSENGER_OK=1
            else
                MESSENGER_OK=0
            fi


            # ------------------------------------------------
            # ПОЧТА
            # ------------------------------------------------

            if send_mail "$MESSAGE" "$MAIL_SUBJECT_DOWN"; then
                MAIL_OK=1
            else
                MAIL_OK=0
            fi


            # ------------------------------------------------
            # РЕЗУЛЬТАТ
            # ------------------------------------------------

            if [[ "$MESSENGER_OK" -eq 1 ]] && \
               [[ "$MAIL_OK" -eq 1 ]]; then

                LOG_MESSAGE="${LOG_MESSAGE}, САЙТ НЕ ДОСТУПЕН: УВЕДОМЛЕНИЯ ОТПРАВЛЕНЫ"

            elif [[ "$MESSENGER_OK" -eq 1 ]] && \
                 [[ "$MAIL_OK" -eq 0 ]]; then

                LOG_MESSAGE="${LOG_MESSAGE}, САЙТ НЕ ДОСТУПЕН: МЕССЕНДЖЕР ОТПРАВЛЕН, ПОЧТА НЕ ОТПРАВЛЕНА"

            elif [[ "$MESSENGER_OK" -eq 0 ]] && \
                 [[ "$MAIL_OK" -eq 1 ]]; then

                LOG_MESSAGE="${LOG_MESSAGE}, САЙТ НЕ ДОСТУПЕН: МЕССЕНДЖЕР НЕ ОТПРАВЛЕН, ПОЧТА ОТПРАВЛЕНА"

            else

                LOG_MESSAGE="${LOG_MESSAGE}, САЙТ НЕ ДОСТУПЕН: СБОЙ ОТПРАВКИ УВЕДОМЛЕНИЙ"

            fi


            # Обновляем время последнего уведомления
            LAST_NOTIFICATION="$NOW"

        fi

    fi

fi


# ============================================================
# СОХРАНЯЕМ СОСТОЯНИЕ
# ============================================================

cat > "$STATEFILE" <<EOF
SITE_STATE="$SITE_STATE"
LAST_NOTIFICATION=$LAST_NOTIFICATION
EOF


# ============================================================
# ОДНА СТРОКА В ЛОГ
# ============================================================

echo "$LOG_MESSAGE" >> "$LOGFILE"

exit 0
