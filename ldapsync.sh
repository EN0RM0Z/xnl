#!/bin/bash
#
# Скрипт синхронизации LDAP пользователей в Keycloak 16
# Поддерживает поиск LDAP-компонента через Components API
# Использует config.json с массивом realms[]
#

set -euo pipefail

CONFIG_FILE="config.json"
LOG_FILE="/var/log/keycloak_ldap_sync.log"
TOKEN=""  # глобальная переменная для токена

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
        echo "Использование: $0 <full|changed>"
        exit 1
        ;;
esac

# -------------------------------
# Функция записи логов
# -------------------------------
write_log() {
    local MSG=$1
    local LEVEL=${2:-INFO}
    echo "[$LEVEL] $MSG" | tee -a "$LOG_FILE"
}

# -------------------------------
# Функция получения токена
# -------------------------------
get_access_token() {
    local REALM_URL=$1
    local REALM_NAME=$2
    local CLIENT_ID=$3
    local CLIENT_SECRET=$4

    write_log "Получение токена для realm $REALM_NAME..."

    RESPONSE_AND_CODE=$(curl --silent --location \
        --write-out "HTTPSTATUS:%{http_code}" \
        --request POST "${REALM_URL%/}/realms/${REALM_NAME}/protocol/openid-connect/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "client_secret=${CLIENT_SECRET}")

    HTTP_CODE=$(echo "$RESPONSE_AND_CODE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE=$(echo "$RESPONSE_AND_CODE" | sed -e 's/HTTPSTATUS:.*//')

    TMP_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token // empty')
    if [[ -z "$TMP_TOKEN" || "$HTTP_CODE" -ne 200 ]]; then
        write_log "Ошибка: токен не получен для realm $REALM_NAME (HTTP_CODE=$HTTP_CODE)" "ERROR"
        return 1
    fi

    TOKEN="$TMP_TOKEN"
    write_log "Токен успешно получен для realm $REALM_NAME (HTTP_CODE=$HTTP_CODE)"
}

# -------------------------------
# Функция синхронизации LDAP
# -------------------------------
sync_ldap_component() {
    local BASE_URL=$1
    local REALM_NAME=$2

    write_log "Запрос компонентов UserStorageProvider в realm $REALM_NAME..."

    RESPONSE_AND_CODE=$(curl --silent --location \
        --write-out "HTTPSTATUS:%{http_code}" \
        --request GET "${BASE_URL%/}/admin/realms/${REALM_NAME}/components?type=org.keycloak.storage.UserStorageProvider" \
        --header "Authorization: Bearer $TOKEN" \
        --header "Accept: application/json" \
        --header "Content-Type: application/json")

    HTTP_CODE=$(echo "$RESPONSE_AND_CODE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    COMPONENTS_RESPONSE=$(echo "$RESPONSE_AND_CODE" | sed -e 's/HTTPSTATUS:.*//')

    if [[ "$HTTP_CODE" -ne 200 ]]; then
        write_log "Ошибка: не удалось получить компоненты (HTTP_CODE=$HTTP_CODE)" "ERROR"
        return 1
    fi

    write_log "Компоненты успешно получены (HTTP_CODE=$HTTP_CODE)"
    echo "$COMPONENTS_RESPONSE" | tee -a "$LOG_FILE"

    LDAP_IDS=$(echo "$COMPONENTS_RESPONSE" | jq -r '.[] | select(.providerId=="ldap") | .id // empty')
    if [[ -z "$LDAP_IDS" ]]; then
        write_log "LDAP-провайдер не найден в realm $REALM_NAME" "WARNING"
        return 0
    fi

    for LDAP_ID in $LDAP_IDS; do
        write_log "Найден LDAP провайдер c ID: $LDAP_ID. Запускаем ${SYNC_NAME} синхронизацию..."

        SYNC_URL="${BASE_URL%/}/admin/realms/${REALM_NAME}/user-storage/${LDAP_ID}/sync?action=${SYNC_TYPE}"

        SYNC_RESPONSE_AND_CODE=$(curl --silent --location \
            --write-out "HTTPSTATUS:%{http_code}" \
            --request POST "$SYNC_URL" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/x-www-form-urlencoded")

        HTTP_CODE_SYNC=$(echo "$SYNC_RESPONSE_AND_CODE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
        CLEAN_JSON=$(echo "$SYNC_RESPONSE_AND_CODE" | sed -e 's/HTTPSTATUS:.*//')

        if [[ "$HTTP_CODE_SYNC" -ne 200 ]]; then
            write_log "Ошибка синхронизации LDAP_ID $LDAP_ID (HTTP_CODE=$HTTP_CODE_SYNC)" "ERROR"
            continue
        fi

        write_log "Сырой ответ сервера для LDAP_ID $LDAP_ID:"
        echo "$CLEAN_JSON" | tee -a "$LOG_FILE"

        ADDED=$(echo "$CLEAN_JSON" | jq -r '.added // 0')
        UPDATED=$(echo "$CLEAN_JSON" | jq -r '.updated // 0')
        REMOVED=$(echo "$CLEAN_JSON" | jq -r '.removed // 0')
        FAILED=$(echo "$CLEAN_JSON" | jq -r '.failed // 0')
        STATUS=$(echo "$CLEAN_JSON" | jq -r '.status // empty')

        write_log "Результат синхронизации LDAP_ID $LDAP_ID в realm $REALM_NAME (${SYNC_NAME}):"
        write_log "  Добавлено новых пользователей: $ADDED"
        write_log "  Обновлено пользователей:      $UPDATED"
        write_log "  Удалено пользователей:       $REMOVED"
        write_log "  Не удалось синхронизировать: $FAILED"
        write_log "  Статус: $STATUS"
        write_log "---------------------------------------------"
    done
}

# -------------------------------
# Основной цикл по realms
# -------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    write_log "Файл конфигурации $CONFIG_FILE не найден" "ERROR"
    exit 1
fi

REALMS_COUNT=$(jq '.realms | length' "$CONFIG_FILE")

for ((i=0; i<REALMS_COUNT; i++)); do
    write_log "=== Обработка realm №$i ==="

    REALM_URL=$(jq -r ".realms[$i].realm_URL" "$CONFIG_FILE")
    REALM_NAME=$(jq -r ".realms[$i].realm_name" "$CONFIG_FILE")
    CLIENT_ID=$(jq -r ".realms[$i].client_id" "$CONFIG_FILE")
    CLIENT_SECRET=$(jq -r ".realms[$i].client_secret" "$CONFIG_FILE")

    write_log "REALM_URL  = $REALM_URL"
    write_log "REALM_NAME = $REALM_NAME"
    write_log "CLIENT_ID  = $CLIENT_ID"
    write_log "CLIENT_SECRET = ******"

    get_access_token "$REALM_URL" "$REALM_NAME" "$CLIENT_ID" "$CLIENT_SECRET"

    write_log "Запускаем синхронизацию LDAP-компонентов..."
    sync_ldap_component "$REALM_URL" "$REALM_NAME"
done

write_log "Скрипт завершил выполнение"
