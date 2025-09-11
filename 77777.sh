#!/bin/bash
set -e

TARGET_DIR="/var/ntm"

# Проверяем, существует ли директория
if [ ! -d "$TARGET_DIR" ]; then
    echo "[ERROR] Директория $TARGET_DIR не существует!"
    exit 1
fi

# Удаляем всё содержимое (все файлы, папки и подпапки)
echo "[INFO] Очищаем $TARGET_DIR..."
rm -rf "${TARGET_DIR:?}/"*

# Проверяем, пуста ли директория
if [ "$(ls -A "$TARGET_DIR")" ]; then
    echo "[ERROR] Директория $TARGET_DIR всё ещё содержит файлы!"
    exit 1
else
    echo "[SUCCESS] Директория $TARGET_DIR успешно очищена."
fi

