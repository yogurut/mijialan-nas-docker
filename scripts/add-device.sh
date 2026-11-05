#!/bin/sh
# Add one device by hand when you already know its IP + 32-hex token.
# Usage: ./scripts/add-device.sh 192.168.31.20 "书桌台灯"
# The token prompt does not echo. The token is NOT stored in shell history.
set -eu
cd "$(dirname "$0")/.."
IP="${1:?usage: add-device.sh <ip> [name]}"
NAME="${2:-}"
if [ -n "$NAME" ]; then
  docker compose run --rm -it mijialan add "$IP" --name "$NAME"
else
  docker compose run --rm -it mijialan add "$IP"
fi
docker compose run --rm mijialan list
