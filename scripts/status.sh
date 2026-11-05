#!/bin/sh
# Quick status: container, bridge log tail, known devices.
set -eu
cd "$(dirname "$0")/.."
docker compose ps
echo "--- logs (last 30 lines) ---"
docker compose logs --tail 30 mijialan
echo "--- known devices ---"
docker compose run --rm mijialan list || true
