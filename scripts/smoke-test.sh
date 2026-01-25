#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"

echo "[*] GET /healthz"
curl -fsS "$BASE_URL/healthz" | jq .

echo
echo "[*] GET /v1/models"
curl -fsS "$BASE_URL/v1/models" | jq '.data[:5]'

echo
echo "[*] POST /v1/chat/completions"
curl -fsS "$BASE_URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Say hello in one sentence."}
    ],
    "temperature": 0.2
  }' | jq '.choices[0].message.content'
