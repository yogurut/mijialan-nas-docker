#!/bin/sh
# MijiaLAN-rs NAS entrypoint: unlock gnome-keyring (Secret Service), then
# run the HomeKit bridge in the background and the web UI in the foreground.
#
#   Bridge:  mijia-rust bridge  (log: /data/bridge.log, pid: /data/bridge.pid)
#   Web UI:  python3 /app/webui/app.py  on http://<NAS-IP>:8080
#            - scan the Mi Home login QR in the browser, no terminal needed
#            - shows the HomeKit pairing code + QR, devices, logs
#
# The master key lives in Secret Service (service "xyz.ipocket.MijiaLAN.Rust",
# entry "master-key-v1"); encrypted tokens / HomeKit identity live in
# /data/config/MijiaLAN Rust/. The app never falls back to plaintext.
set -eu

if [ -z "${MIJIALAN_KEYRING_PASSWORD:-}" ]; then
  echo "ERROR: MIJIALAN_KEYRING_PASSWORD is not set." >&2
  echo "Set it in .env (same value every time - losing it means re-importing" >&2
  echo "all devices and re-pairing HomeKit). See README.md." >&2
  exit 1
fi

mkdir -p /data/config /data/local/share /tmp/runtime-mijia
chmod 700 /data /data/config /data/local/share 2>/dev/null || true
export HOME=/data
export XDG_CONFIG_HOME=/data/config
export XDG_DATA_HOME=/data/local/share
export XDG_RUNTIME_DIR=/tmp/runtime-mijia
export MIJIALAN_DATA=/data
export MIJIALAN_WEB_PORT="${MIJIALAN_WEB_PORT:-8080}"

# 1) Session D-Bus (Secret Service lives on the session bus).
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1)
  export DBUS_SESSION_BUS_ADDRESS
fi

# 2) Start + unlock gnome-keyring.
gnome-keyring-daemon --start --components=secrets >/dev/null 2>&1 || true
printf '%s' "$MIJIALAN_KEYRING_PASSWORD" \
  | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1 \
  || { echo "ERROR: failed to unlock gnome-keyring - check MIJIALAN_KEYRING_PASSWORD." >&2; exit 1; }

# 3) One-off command? `docker compose run --rm mijialan list` etc. should
#    NOT start the bridge + web UI - just run the CLI and exit. The web UI
#    is now the normal way to log in, so `login` via run is only a fallback.
case "${1:-bridge}" in
  login|list|discover|add|set|action|refresh|remove|--help|-h)
    exec /usr/local/bin/mijia-rust "$@"
    ;;
  web)
    exec python3 /app/webui/app.py
    ;;
esac

# 4) Normal mode: bridge in background, web UI in foreground.
#    If no devices are imported yet, the bridge still starts (0 accessories)
#    and the page will tell the user to do step 1 (scan login QR).
if [ ! -f "/data/config/MijiaLAN Rust/devices.json" ]; then
  echo "NOTE: no devices yet - open http://<NAS-IP>:${MIJIALAN_WEB_PORT} and scan the Mi Home login QR." >&2
fi
/usr/local/bin/bridgectl start || true

# If the bridge exits, leave the web UI up so the user can see the log and
# restart it from the page instead of staring at a dead container.
exec python3 /app/webui/app.py
