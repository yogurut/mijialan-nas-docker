#!/bin/sh
# First-run device import: prints a QR code in the terminal.
# Scan it with the Mi Home app and confirm. Run from the project folder.
# NOTE: run this BEFORE `docker compose up -d`, or stop the bridge first -
# two bridge instances must not run at the same time, and login writes to
# the same /data the bridge uses.
set -eu
cd "$(dirname "$0")/.."
REGION="${MIJIALAN_REGION:-cn}"
echo "Importing devices for region: $REGION"
echo "Scan the QR code below with the Mi Home app and confirm on your phone."
echo "Press Ctrl+C in this terminal to cancel the login wait."
docker compose run --rm -it mijialan login --region "$REGION"
echo "---"
echo "Imported. Check what came in:"
docker compose run --rm mijialan list
