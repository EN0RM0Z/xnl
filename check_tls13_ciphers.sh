#!/bin/bash

HOST="keycloak.test.ru"
PORT="443"
TIMEOUT=3

echo "TLS 1.3 cipher suites accepted by $HOST:$PORT"
echo "------------------------------------------------------------"

for cipher in $(openssl ciphers -s -tls1_3 | tr ':' ' '); do

    result=$(timeout "$TIMEOUT" \
        openssl s_client \
            -connect "${HOST}:${PORT}" \
            -servername "$HOST" \
            -tls1_3 \
            -ciphersuites "$cipher" \
            </dev/null 2>&1 |
        grep 'Cipher is' |
        head -1)

    if echo "$result" | grep -q "Cipher is $cipher"; then
        echo "[ACCEPTED] $cipher"
    else
        echo "[REJECTED] $cipher"
    fi

done
