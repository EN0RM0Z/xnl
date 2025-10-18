#!/bin/bash
#
# Экспорт пользователей Keycloak 16 (MariaDB)
# Без временных файлов в контейнере, с заголовками CSV
# ------------------------------------------------------

### === НАСТРОЙКИ ===

# Имя контейнера MariaDB
MARIADB_CONTAINER="mariadb"

# Имя базы данных
DB_NAME="keycloak"

# Пользователь и пароль БД
DB_USER="keycloak"
DB_PASS="secret"

# Рильм для выгрузки
REALM="myrealm"

# Количество пользователей
LIMIT=10

# Путь к итоговому CSV на хосте
OUTPUT_FILE="./users.csv"

### === КОНЕЦ НАСТРОЕК ===


echo "📤 Экспорт пользователей рильма '$REALM' из контейнера '$MARIADB_CONTAINER'..."

# Заголовки CSV
HEADER='"user_id","realm_id","username","email","first_name","last_name","enabled","email_verified","created_at","service_account_client","attributes","roles","groups","federated_providers"'

# SQL-запрос (без INTO OUTFILE)
SQL_QUERY=$(cat <<EOF
SELECT 
  ue.ID AS user_id,
  ue.REALM_ID AS realm_id,
  ue.USERNAME AS username,
  ue.EMAIL AS email,
  ue.FIRST_NAME AS first_name,
  ue.LAST_NAME AS last_name,
  ue.ENABLED AS enabled,
  ue.EMAIL_VERIFIED AS email_verified,
  FROM_UNIXTIME(ue.CREATED_TIMESTAMP / 1000) AS created_at,
  ue.SERVICE_ACCOUNT_CLIENT_LINK AS service_account_client,
  GROUP_CONCAT(DISTINCT CONCAT(ua.NAME, '=', ua.VALUE) SEPARATOR '; ') AS attributes,
  GROUP_CONCAT(DISTINCT r.NAME SEPARATOR ', ') AS roles,
  GROUP_CONCAT(DISTINCT g.NAME SEPARATOR ', ') AS groups,
  GROUP_CONCAT(DISTINCT fc.IDENTITY_PROVIDER SEPARATOR ', ') AS federated_providers
FROM USER_ENTITY ue
  LEFT JOIN USER_ATTRIBUTE ua ON ue.ID = ua.USER_ID
  LEFT JOIN USER_ROLE_MAPPING ur ON ue.ID = ur.USER_ID
  LEFT JOIN KEYCLOAK_ROLE r ON ur.ROLE_ID = r.ID
  LEFT JOIN USER_GROUP_MEMBERSHIP ugm ON ue.ID = ugm.USER_ID
  LEFT JOIN KEYCLOAK_GROUP g ON ugm.GROUP_ID = g.ID
  LEFT JOIN FEDERATED_IDENTITY fc ON ue.ID = fc.USER_ID
WHERE ue.REALM_ID = '$REALM'
GROUP BY ue.ID
ORDER BY ue.CREATED_TIMESTAMP DESC
LIMIT $LIMIT;
EOF
)

# Выполняем SQL в контейнере и сохраняем CSV на хост
{
  echo "$HEADER"
  docker exec -i "$MARIADB_CONTAINER" \
    mysql -N -B -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "$SQL_QUERY"
} > "$OUTPUT_FILE"

# Проверяем результат
if [[ -f "$OUTPUT_FILE" ]]; then
  echo "✅ Экспорт завершён: $OUTPUT_FILE"
  echo
  echo "Первые строки CSV:"
  head -n 10 "$OUTPUT_FILE"
else
  echo "❌ Ошибка: не удалось создать файл экспорта"
fi
