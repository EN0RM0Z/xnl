#!/bin/bash
# ======================================================
# Скрипт быстрого старта Keycloak 16 + MariaDB с дампа
# ======================================================

set -euo pipefail

# ------------------- НАСТРОЙКИ ----------------------
# Пути
DUMP_FILE="/var/backups/keycloak/vkm_18_04_2025.sql.gz"  # Сжатый дамп
LOG_FILE="/var/log/keycloak_init.log"

# MariaDB параметры
DB_CONTAINER="mariadb"
DB_ROOT_PASSWORD="12345"
DB_USER="keycloak"
DB_PASSWORD="keycloak"
DB_NAME="keycloak"

# Keycloak параметры
KC_CONTAINER="keycloak"
KC_ADMIN_USER="admin"
KC_ADMIN_PASSWORD="12345"
KC_FRONTEND_URL="https://keycloak.example.ru/auth"

# Docker сети
NETWORK="keycloak-network"

# Время
START_TIME=$(date +%s)

# ------------------- ФУНКЦИИ ------------------------
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# ------------------- СТАРТ -------------------------
log "===== Начало первого запуска Keycloak + MariaDB ====="

# 1. Создаем сеть, если нет
if ! docker network ls | grep -q "$NETWORK"; then
    docker network create "$NETWORK"
    log "Создана docker-сеть $NETWORK"
fi

# 2. Запуск MariaDB
log "Запуск контейнера MariaDB..."
docker run -d \
  --name "$DB_CONTAINER" \
  --net "$NETWORK" \
  -v /var/keycloak_data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
  -e MYSQL_DATABASE="$DB_NAME" \
  -e MYSQL_USER="$DB_USER" \
  -e MYSQL_PASSWORD="$DB_PASSWORD" \
  mariadb:10.5

# 3. Ждем, пока MariaDB будет готова
log "Ожидание готовности MariaDB..."
until docker exec "$DB_CONTAINER" mysqladmin ping -u"$DB_USER" -p"$DB_PASSWORD" --silent &>/dev/null; do
    echo -n "."
    sleep 2
done
log "MariaDB готова!"

# 4. Восстановление дампа (на лету, без распаковки на диск)
log "Восстановление базы из дампа $DUMP_FILE..."
gunzip -c "$DUMP_FILE" | docker exec -i "$DB_CONTAINER" sh -c "mysql -u$DB_USER -p$DB_PASSWORD $DB_NAME"
log "База восстановлена."

# 5. Запуск Keycloak
log "Запуск контейнера Keycloak 16..."
docker run -d \
  --name "$KC_CONTAINER" \
  --net "$NETWORK" \
  -v /var/keycloak_data_mod/cert:/cert \
  -v /var/keycloak_data_mod/keytab:/etc/keytab \
  -v /var/keycloak_data_mod/conf/krb5.conf:/etc/krb5.conf \
  -v /var/keycloak_data_mod/configuration/standalone-ha.xml:/opt/jboss/keycloak/standalone/configuration/standalone-ha.xml \
  -v /var/keycloak_data_mod/tmp:/tmp \
  -v /var/keycloak_data_mod/themes:/opt/jboss/keycloak/themes \
  -v /var/keycloak_data_mod/log:/opt/jboss/keycloak/standalone/log \
  -v /var/keycloak_data_mod/deployments/metrics-config.json:/opt/jboss/keycloak/standalone/configuration/metrics-config.json \
  -v /var/keycloak_data_mod/deployments/keycloak-metrics-spi-2.5.3.jar:/opt/jboss/keycloak/standalone/deployments/metrics-spi.jar \
  -p 8080:8080 \
  -e KEYCLOAK_USER="$KC_ADMIN_USER" \
  -e KEYCLOAK_PASSWORD="$KC_ADMIN_PASSWORD" \
  -e DB_ADDR="$DB_CONTAINER" \
  -e DB_USER="$DB_USER" \
  -e DB_PASSWORD="$DB_PASSWORD" \
  -e KEYCLOAK_FRONTEND_URL="$KC_FRONTEND_URL" \
  -e KEYCLOAK_PROXY_ADDRESS_FORWARDING=true \
  jboss/keycloak:16.1.1 \
  -Dkeycloak.profile.feature.impersonation=enabled \
  -Dkeycloak.profile.feature.token_exchange=enabled \
  -Dkeycloak.profile.feature.admin_fine_grained_authz=enabled \
  -Dkeycloak.profile.feature.scripts=enabled

# 6. Подсчет времени
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
log "===== Первый запуск завершен! Общее время: $ELAPSED секунд ====="
