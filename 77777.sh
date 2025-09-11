echo "[INFO] Ждём, пока база данных будет готова..."
until docker exec mariadb mysql -u keycloak -p1234 -e "SELECT 1;" &>/dev/null; do
  sleep 5
  echo "[WAIT] БД ещё не готова, пробуем снова..."
done

echo "[INFO] БД готова, запускаем Keycloak..."
