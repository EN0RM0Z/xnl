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

# ------------------------------------------------------------
# МЕТОД ПРОВЕРКИ
#
# HTTP_CODE - проверка HTTP-кода
# TOKEN     - получение access_token
#
# Для переключения метода измените ТОЛЬКО эту строку.
# ------------------------------------------------------------

CHECK_METHOD="TOKEN"


# ============================================================
# HTTP_CODE
# ============================================================

# Используется только при:
# CHECK_METHOD="HTTP_CODE"

HTTP_URL="https://keycloak.test.ru"

# Количество HTTP-проверок
HTTP_CHECK_ATTEMPTS=30

# Минимальное количество успешных HTTP-проверок
#
# 25 из 30 = сайт доступен
#
HTTP_MIN_SUCCESS=25


# ============================================================
# TOKEN
# ============================================================

# Используется только при:
# CHECK_METHOD="TOKEN"

TOKEN_URL="https://keycloak.test.ru/realms/test/protocol/openid-connect/token"

# Client ID
CLIENT_ID="test-client"

# Client Secret
CLIENT_SECRET="xxxxxxxxxxxxxxxxxxxxxxxx"

# Количество проверок получения токена
TOKEN_CHECK_ATTEMPTS=3

# Минимальное количество успешных проверок
#
# 3 из 3 = сайт доступен
#
TOKEN_MIN_SUCCESS=3


# ============================================================
# ОБЩИЕ НАСТРОЙКИ
# ============================================================

# Пауза между проверками, секунд
CHECK_DELAY=1

# Через сколько минут отправлять повторное уведомление,
# если сайт продолжает быть недоступен
NOTIFY_INTERVAL=30

# Таймаут установки соединения
CONNECT_TIMEOUT=5

# Максимальное время одного curl-запроса
MAX_TIME=10

# Специальный User-Agent нашего мониторинга.
#
# Позволяет находить запросы в Nginx access.log
# без изменения конфигурации Nginx.
USER_AGENT="Keycloak-Monitor/1.0 (check-script)"


# ============================================================
# ФАЙЛЫ
# ============================================================

LOGFILE="/opt/keycloak/scripts/log_kk.txt"

STATEFILE="/opt/keycloak/scripts/site_monitor.state"

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
# ОПРЕДЕЛЯЕМ КОЛИЧЕСТВО ПРОВЕРОК И ПОРОГ
# ============================================================

case "$CHECK_METHOD" in

    HTTP_CODE)

        CHECK_ATTEMPTS="$HTTP_CHECK_ATTEMPTS"
        MIN_SUCCESS="$HTTP_MIN_SUCCESS"

        ;;

    TOKEN)

        CHECK_ATTEMPTS="$TOKEN_CHECK_ATTEMPTS"
        MIN_SUCCESS="$TOKEN_MIN_SUCCESS"

        ;;

    *)

        echo "Ошибка: неизвестный CHECK_METHOD: $CHECK_METHOD" >&2
        echo "Допустимые значения: HTTP_CODE или TOKEN" >&2

        exit 1

        ;;

esac


# ============================================================
# ПРОВЕРКА HTTP-КОДА
#
# Успешна только при HTTP 200.
#
# Возвращает:
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
        "$HTTP_URL" \
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
# ПРОВЕРКА ПОЛУЧЕНИЯ TOKEN
#
# Выполняется:
#
# POST TOKEN_URL
#
# client_id
# grant_type=client_credentials
# client_secret
#
# Успешной считается проверка, если получен
# непустой access_token.
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
        --data-urlencode "client_secret=${CLIENT_SECRET}" \
        "$TOKEN_URL" \
        2>/dev/null
    )

    CURL_EXIT=$?

    # --------------------------------------------------------
    # Ошибка curl
    # --------------------------------------------------------

    if [[ "$CURL_EXIT" -ne 0 ]]; then

        echo "000"

        return

    fi


    # --------------------------------------------------------
    # Извлекаем access_token из JSON
    # --------------------------------------------------------

    ACCESS_TOKEN=$(echo "$RESPONSE" | \
        jq -r '.access_token // empty' 2>/dev/null
    )


    # --------------------------------------------------------
    # Проверяем наличие непустого access_token
    # --------------------------------------------------------

    if [[ -n "$ACCESS_TOKEN" ]]; then

        echo "200"

    else

        echo "000"

    fi
}


# ============================================================
# ОБЩАЯ ФУНКЦИЯ ПРОВЕРКИ
#
# Не изменяем логику.
#
# HTTP_CODE -> check_http_code
# TOKEN     -> check_token
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
# ОТПРАВКА УВЕДОМЛЕНИЯ В МЕССЕНДЖЕР
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
# ОТПРАВКА УВЕДОМЛЕНИЯ ПО ПОЧТЕ
#
# Используется mailx.
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
# ЦИКЛ ПРОВЕРОК
# ============================================================

SUCCESS_COUNT=0

LAST_STATUS="000"


for ((i=1; i<=CHECK_ATTEMPTS; i++))
do

    STATUS=$(check_site)

    LAST_STATUS="$STATUS"


    # --------------------------------------------------------
    # Успешная проверка
    # --------------------------------------------------------

    if [[ "$STATUS" == "200" ]]; then

        ((SUCCESS_COUNT++))

    fi


    # --------------------------------------------------------
    # Пауза между проверками
    # --------------------------------------------------------

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


LOG_MESSAGE="${LOG_DATE} ${CHECK_METHOD}: Успешных: ${SUCCESS_COUNT} из ${CHECK_ATTEMPTS}"


# ============================================================
# САЙТ ДОСТУПЕН
# ============================================================

if [[ "$SITE_AVAILABLE" -eq 1 ]]; then


    # --------------------------------------------------------
    # Если до этого сайт был недоступен,
    # значит произошло восстановление
    # --------------------------------------------------------

    if [[ "$SITE_STATE" == "DOWN" ]]; then


        MESSAGE="Keycloak восстановлен. Сайт снова доступен. Метод проверки: ${CHECK_METHOD}. Успешных проверок: ${SUCCESS_COUNT}/${CHECK_ATTEMPTS}"


        # ----------------------------------------------------
        # Отправка в мессенджер
        # ----------------------------------------------------

        if send_messenger "$MESSAGE"; then

            MESSENGER_OK=1

        else

            MESSENGER_OK=0

        fi


        # ----------------------------------------------------
        # Отправка по почте
        # ----------------------------------------------------

        if send_mail "$MESSAGE" "$MAIL_SUBJECT_UP"; then

            MAIL_OK=1

        else

            MAIL_OK=0

        fi


        # ----------------------------------------------------
        # Результат отправки
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
    # Фиксируем состояние UP
    # --------------------------------------------------------

    SITE_STATE="UP"

    LAST_NOTIFICATION=0


# ============================================================
# САЙТ НЕДОСТУПЕН
# ============================================================

else


    # --------------------------------------------------------
    # ПЕРВОЕ ОБНАРУЖЕНИЕ НЕДОСТУПНОСТИ
    # --------------------------------------------------------

    if [[ "$SITE_STATE" != "DOWN" ]]; then


        MESSAGE="Keycloak недоступен! Метод проверки: ${CHECK_METHOD}. Успешных проверок: ${SUCCESS_COUNT}/${CHECK_ATTEMPTS}. Последний результат проверки: ${LAST_STATUS}"


        # ----------------------------------------------------
        # Отправка в мессенджер
        # ----------------------------------------------------

        if send_messenger "$MESSAGE"; then

            MESSENGER_OK=1

        else

            MESSENGER_OK=0

        fi


        # ----------------------------------------------------
        # Отправка по почте
        # ----------------------------------------------------

        if send_mail "$MESSAGE" "$MAIL_SUBJECT_DOWN"; then

            MAIL_OK=1

        else

            MAIL_OK=0

        fi


        # ----------------------------------------------------
        # Результат отправки
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
        # Фиксируем состояние DOWN
        # ----------------------------------------------------

        SITE_STATE="DOWN"

        LAST_NOTIFICATION="$NOW"


    # --------------------------------------------------------
    # САЙТ УЖЕ БЫЛ НЕДОСТУПЕН
    # --------------------------------------------------------

    else


        INTERVAL_SECONDS=$((NOTIFY_INTERVAL * 60))

        ELAPSED=$((NOW - LAST_NOTIFICATION))


        # ----------------------------------------------------
        # Прошёл заданный интервал
        # ----------------------------------------------------

        if [[ "$ELAPSED" -ge "$INTERVAL_SECONDS" ]]; then


            MESSAGE="Keycloak всё ещё недоступен! Метод проверки: ${CHECK_METHOD}. Успешных проверок: ${SUCCESS_COUNT}/${CHECK_ATTEMPTS}. Последний результат проверки: ${LAST_STATUS}. Повторное уведомление."


            # ------------------------------------------------
            # Отправка в мессенджер
            # ------------------------------------------------

            if send_messenger "$MESSAGE"; then

                MESSENGER_OK=1

            else

                MESSENGER_OK=0

            fi


            # ------------------------------------------------
            # Отправка по почте
            # ------------------------------------------------

            if send_mail "$MESSAGE" "$MAIL_SUBJECT_DOWN"; then

                MAIL_OK=1

            else

                MAIL_OK=0

            fi


            # ------------------------------------------------
            # Результат отправки
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


            # ------------------------------------------------
            # Обновляем время последнего уведомления
            # ------------------------------------------------

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
# ЗАПИСЬ ОДНОЙ СТРОКИ В ЛОГ
# ============================================================

echo "$LOG_MESSAGE" >> "$LOGFILE"


exit 0
