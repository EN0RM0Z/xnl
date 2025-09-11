# Ждём окончания инициализации
until docker logs mariadb 2>&1 | grep -q "MariaDB init process done. Ready for start up."; do
  sleep 5
  echo "[WAIT] Восстановление базы ещё не закончено..."
done

echo "[INFO] База готова!"
