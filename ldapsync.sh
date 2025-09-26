#!/bin/bash
#
# Скрипт синхронизации LDAP пользователей в Keycloak 16
# Поддерживает поиск LDAP-компонента через Components API
# Использует config.json с массивом realms[]
#

CONFIG_FILE="config.json"
LOG_FILE="/var/log/keycloak_ldap_sync.log"
TOKEN=""  # глобальная переменная для токена

# -------------------------------
# Проверка аргумента и выбор типа синхронизации
# -------------------------------
case "$1" in
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
# Функция синхронизации LDAP по Components API
# -------------------------------
sync_ldap_component() {
    local BASE_URL=$1
    local REALM_NAME=$2

    write_log "Запрос компонентов UserStorageProvider в realm $REALM_NAME..."

    # Получаем компоненты и HTTP-код в одну переменную
    RESPONSE_AND_CODE=$(curl --silent --location \
        --write-out "HTTPSTATUS:%{http_code}" \
        --request GET "${BASE_URL%/}/admin/realms/${REALM_NAME}/components?type=org.keycloak.storage.UserStorageProvider" \
        --header "Authorization: Bearer $TOKEN" \
        --header "Accept: application/json" \
        --header "Content-Type: application/json")

    # Разделяем тело и код ответа
    HTTP_CODE=$(echo "$RESPONSE_AND_CODE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    COMPONENTS_RESPONSE=$(echo "$RESPONSE_AND_CODE" | sed -e 's/HTTPSTATUS:.*//')

    # Логируем тело ответа
    echo "$COMPONENTS_RESPONSE" | tee -a "$LOG_FILE"

    # Проверка HTTP-кода
    if [[ "$HTTP_CODE" -ne 200 ]]; then
        write_log "Ошибка: не удалось получить компоненты (HTTP_CODE=$HTTP_CODE)" "ERROR"
        return 1
    fi

    write_log "Компоненты успешно получены (HTTP_CODE=$HTTP_CODE)"

    # Извлекаем все LDAP-ID
    LDAP_IDS=$(echo "$COMPONENTS_RESPONSE" | jq -r '.[] | select(.providerId=="ldap") | .id')

    if [[ -z "$LDAP_IDS" ]]; then
        write_log "LDAP-провайдер не найден в realm $REALM_NAME" "WARNING"
        return 0
    fi

    # Цикл по каждому LDAP-провайдеру
    for LDAP_ID in $LDAP_IDS; do
        write_log "Найден LDAP провайдер c ID: $LDAP_ID. Запускаем ${SYNC_NAME} синхронизацию..."

        SYNC_URL="${BASE_URL%/}/admin/realms/${REALM_NAME}/user-storage/${LDAP_ID}/sync?action=${SYNC_TYPE}"

        # Выполняем синхронизацию и получаем тело + код
        SYNC_RESPONSE_AND_CODE=$(curl --silent --location \
            --write-out "HTTPSTATUS:%{http_code}" \
            --request POST "$SYNC_URL" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/x-www-form-urlencoded")  # исправленный Content-Type

        HTTP_CODE_SYNC=$(echo "$SYNC_RESPONSE_AND_CODE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
        CLEAN_JSON=$(echo "$SYNC_RESPONSE_AND_CODE" | sed -e 's/HTTPSTATUS:.*//')

        write_log "Сырой ответ сервера для LDAP_ID $LDAP_ID:" 
        echo "$CLEAN_JSON" | tee -a "$LOG_FILE"

        # Проверка HTTP-кода синхронизации
        if [[ "$HTTP_CODE_SYNC" -ne 200 ]]; then
            write_log "Ошибка синхронизации LDAP_ID $LDAP_ID (HTTP_CODE=$HTTP_CODE_SYNC)" "ERROR"
            continue
        fi

        # Извлечение человекочитаемых данных
        ADDED=$(echo "$CLEAN_JSON" | jq -r '.added')
        UPDATED=$(echo "$CLEAN_JSON" | jq -r '.updated')
        REMOVED=$(echo "$CLEAN_JSON" | jq -r '.removed')
        FAILED=$(echo "$CLEAN_JSON" | jq -r '.failed')
        STATUS=$(echo "$CLEAN_JSON" | jq -r '.status')

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

CONFIG=$(cat "$CONFIG_FILE")
REALMS_COUNT=$(echo "$CONFIG" | jq '.realms | length')

for ((i=0; i<REALMS_COUNT; i++)); do
    write_log "=== Обработка realm №$i ==="

    REALM_URL=$(echo "$CONFIG" | jq -r ".realms[$i].realm_URL")
    REALM_NAME=$(echo "$CONFIG" | jq -r ".realms[$i].realm_name")
    CLIENT_ID=$(echo "$CONFIG" | jq -r ".realms[$i].client_id")
    CLIENT_SECRET=$(echo "$CONFIG" | jq -r ".realms[$i].client_secret")

    write_log "REALM_URL     = $REALM_URL"
    write_log "REALM_NAME    = $REALM_NAME"
    write_log "CLIENT_ID     = $CLIENT_ID"
    write_log "CLIENT_SECRET = $CLIENT_SECRET"

#-------------------------------
    write_log "Запускаем получение токена..."
    
    # Выполняем запрос и сохраняем тело и код ответа в одну переменную
    RESPONSE_AND_CODE=$(curl --silent --location \
        --write-out "HTTPSTATUS:%{http_code}" \
        --request POST "${REALM_URL%/}/realms/${REALM_NAME}/protocol/openid-connect/token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "client_secret=${CLIENT_SECRET}")
    
    # Разделяем тело ответа и код
    HTTP_CODE=$(echo "$RESPONSE_AND_CODE" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE=$(echo "$RESPONSE_AND_CODE" | sed -e 's/HTTPSTATUS:.*//')
    
    # Логируем тело ответа
    echo "$RESPONSE" | tee -a "$LOG_FILE"
    
    # Извлекаем токен
    TMP_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token' 2>/dev/null)
    
    # Проверка
    if [[ -z "$TMP_TOKEN" || "$TMP_TOKEN" == "null" || "$HTTP_CODE" -ne 200 ]]; then
        write_log "Ошибка: токен не получен для realm $REALM_NAME (HTTP_CODE=$HTTP_CODE)" "ERROR"
        TOKEN=""
        exit 1
    fi
    
    TOKEN="$TMP_TOKEN"
    write_log "Токен успешно получен для realm $REALM_NAME (HTTP_CODE=$HTTP_CODE)"
#-------------------------------

    write_log "Запускаем синхронизацию LDAP-компонентов..."
    sync_ldap_component "$REALM_URL" "$REALM_NAME"
done
    
write_log "Скрипт завершил выполнение"

