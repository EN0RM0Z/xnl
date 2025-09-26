#!/bin/bash
#
# Скрипт синхронизации LDAP пользователей в Keycloak 16
# Поддерживает поиск LDAP-компонента через Components API
# Использует config.json с массивом realms[]
#

CONFIG_FILE="config.json"
LOG_FILE="/var/log/keycloak_ldap_sync.log"

# -------------------------------
# Проверка зависимостей
# -------------------------------
for cmd in curl jq; do
    if ! command -v $cmd &>/dev/null; then
        echo "Не найден $cmd, установите его перед запуском скрипта" | tee -a "$LOG_FILE"
        exit 1
    fi
done

# -------------------------------
# Проверка аргумента и выбор типа синхронизации
# -------------------------------
case "${1:-}" in
    full)
        SYNC_TYPE="triggerFullSync"
        SYNC_NAME="полная"
        ;;
    changed)
        SYNC_TYPE="triggerChangedUsersSync"
        SYNC_NAME="только изменённые пользователи"
        ;;
    *)
        echo "Использование: $0 <full|changed>" | tee -a "$LOG_FILE"
        exit 1
        ;;
esac

# -------------------------------
# Функция логирования
# -------------------------------
write_log() {
    local MSG=$1
    local LEVEL=${2:-INFO}
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $MSG" | tee -a "$LOG_FILE"
}

# -------------------------------
# Функция выполнения HTTP-запроса
# -------------------------------
http_request() {
    local METHOD=$1
    local URL=$2
    local DATA=${3:-}
    shift 3
    local HEADERS=("$@")

    local RESPONSE_AND_CODE
    if [[ "$METHOD" == "POST" ]]; then
        RESPONSE_AND_CODE=$(curl --silent --location \
            --write-out "HTTPSTATUS:%{http_code}" \
            --request POST "$URL" \
            "${HEADERS[@]}" \
            --data "$DATA")
    else
        RESPONSE_AND_CODE=$(curl --silent --location \
            --write-out "HTTPSTATUS:%{http_code}" \
            --request GET "$URL" \
            "${HEADERS[@]}")
    fi

    local HTTP_CODE=${RESPONSE_AND_CODE##*HTTPSTATUS:}
    local BODY=${RESPONSE_AND_CODE%HTTPSTATUS:*}

    echo "$BODY|$HTTP_CODE"
}

# -------------------------------
# Функция получения токена для realm
# -------------------------------
get_token() {
    local REALM_URL=$1
    local REALM_NAME=$2
    local CLIENT_ID=$3
    local CLIENT_SECRET=$4

    local DATA="grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}"
    local HEADERS=(-H "Content-Type: application/x-www-form-urlencoded")

    local BODY_AND_CODE
    BODY_AND_CODE=$(http_request "POST" "${REALM_URL%/}/realms/${REALM_NAME}/protocol/openid-connect/token" "$DATA" "${HEADERS[@]}")
    local RESPONSE=${BODY_AND_CODE%|*}
    local HTTP_CODE=${BODY_AND_CODE#*|}

    if [[ "$HTTP_CODE" -ne 200 ]]; then
        write_log "Ошибка получения токена для realm $REALM_NAME (HTTP_CODE=$HTTP_CODE)" "ERROR"
        return 1
    fi

    local TOKEN
    TOKEN=$(echo "$RESPONSE" | jq -r '.access_token' 2>/dev/null)
    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
        write_log "Токен не получен для realm $REALM_NAME" "ERROR"
        return 1
    fi

    echo "$TOKEN"
}

# -------------------------------
# Функция синхронизации одного LDAP-провайдера
# -------------------------------
process_ldap_provider() {
    local BASE_URL=$1
    local REALM_NAME=$2
    local LDAP_ID=$3
    local TOKEN=$4

    write_log "Запускаем ${SYNC_NAME} синхронизацию для LDAP_ID $LDAP_ID..."

    local SYNC_URL="${BASE_URL%/}/admin/realms/${REALM_NAME}/user-storage/${LDAP_ID}/sync?action=${SYNC_TYPE}"
    local HEADERS=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/x-www-form-urlencoded")

    local BODY_AND_CODE
    BODY_AND_CODE=$(http_request "POST" "$SYNC_URL" "" "${HEADERS[@]}")
    local BODY=${BODY_AND_CODE%|*}
    local HTTP_CODE=${BODY_AND_CODE#*|}

    if [[ "$HTTP_CODE" -ne 200 ]]; then
        write_log "Ошибка синхронизации LDAP_ID $LDAP_ID (HTTP_CODE=$HTTP_CODE)" "ERROR"
        return 1
    fi

    local ADDED UPDATED REMOVED FAILED STATUS
    ADDED=$(echo "$BODY" | jq -r '.added')
    UPDATED=$(echo "$BODY" | jq -r '.updated')
    REMOVED=$(echo "$BODY" | jq -r '.removed')
    FAILED=$(echo "$BODY" | jq -r '.failed')
    STATUS=$(echo "$BODY" | jq -r '.status')

    write_log "Результат синхронизации LDAP_ID $LDAP_ID в realm $REALM_NAME (${SYNC_NAME}):"
    write_log "  Добавлено новых пользователей: $ADDED"
    write_log "  Обновлено пользователей:      $UPDATED"
    write_log "  Удалено пользователей:       $REMOVED"
    write_log "  Не удалось синхронизировать: $FAILED"
    write_log "  Статус: $STATUS"
    write_log "---------------------------------------------"
}

# -------------------------------
# Функция синхронизации всех LDAP-провайдеров в realm
# -------------------------------
sync_ldap_component() {
    local BASE_URL=$1
    local REALM_NAME=$2
    local TOKEN=$3

    write_log "Получаем компоненты UserStorageProvider для realm $REALM_NAME..."

    local HEADERS=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/json" -H "Content-Type: application/json")
    local BODY_AND_CODE
    BODY_AND_CODE=$(http_request "GET" "${BASE_URL%/}/admin/realms/${REALM_NAME}/components?type=org.keycloak.storage.UserStorageProvider" "" "${HEADERS[@]}")
    local BODY=${BODY_AND_CODE%|*}
    local HTTP_CODE=${BODY_AND_CODE#*|}

    if [[ "$HTTP_CODE" -ne 200 ]]; then
        write_log "Ошибка получения компонентов (HTTP_CODE=$HTTP_CODE)" "ERROR"
        return 1
    fi

    local LDAP_IDS
    LDAP_IDS=$(echo "$BODY" | jq -r '.[] | select(.providerId=="ldap") | .id')

    if [[ -z "$LDAP_IDS" ]]; then
        write_log "LDAP-провайдер не найден в realm $REALM_NAME" "WARNING"
        return 0
    fi

    for LDAP_ID in $LDAP_IDS; do
        process_ldap_provider "$BASE_URL" "$REALM_NAME" "$LDAP_ID" "$TOKEN"
    done
}

# -------------------------------
# Основной цикл по realms
# -------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    write_log "Файл конфигурации $CONFIG_FILE не найден" "ERROR"
    exit 1
fi

write_log "Загружаем конфигурацию из $CONFIG_FILE"

jq -c '.realms[]' "$CONFIG_FILE" | while read -r REALM; do
    REALM_URL=$(echo "$REALM" | jq -r '.realm_URL')
    REALM_NAME=$(echo "$REALM" | jq -r '.realm_name')
    CLIENT_ID=$(echo "$REALM" | jq -r '.client_id')
    CLIENT_SECRET=$(echo "$REALM" | jq -r '.client_secret')

    write_log "=== Обработка realm: $REALM_NAME ==="

    TOKEN=$(get_token "$REALM_URL" "$REALM_NAME" "$CLIENT_ID" "$CLIENT_SECRET") || continue
    write_log "Токен успешно получен"

    sync_ldap_component "$REALM_URL" "$REALM_NAME" "$TOKEN"
done

write_log "Скрипт завершил выполнение"

