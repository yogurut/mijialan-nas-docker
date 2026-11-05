#!/bin/sh
# MijiaLAN-rs NAS entrypoint: unlock gnome-keyring (Secret Service) and
# then exec the CLI. Must run before ANY mijia-rust command, because the
# app stores its 32-byte master key in Secret Service (service
# "xyz.ipocket.MijiaLAN.Rust", entry "master-key-v1") and the encrypted
# device tokens / HomeKit identity in /data/config/MijiaLAN Rust/.
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

# 1) Session D-Bus (Secret Service lives on the session bus, not the
#    system bus). Reuse it if the caller already provided one.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address=1)
  export DBUS_SESSION_BUS_ADDRESS
fi

# 2) Start + unlock gnome-keyring. --unlock reads the password from stdin
#    and unlocks (creating if needed) the "Login" collection.
#    gnome-keyring-daemon --start prints the bus address if it started its
#    own daemon; with a bus already running it just attaches to it.
gnome-keyring-daemon --start --components=secrets >/dev/null 2>&1 || true
printf '%s' "$MIJIALAN_KEYRING_PASSWORD" \
  | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1 \
  || { echo "ERROR: failed to unlock gnome-keyring - check MIJIALAN_KEYRING_PASSWORD." >&2; exit 1; }

# 3) No separate Secret Service probe here: `secret-tool search` exits 1
#    on an empty keyring, which would false-alarm on first run. If the
#    service is really unreachable, mijia-rust itself fails with
#    "系统凭据存储不可用" - that message is authoritative.

# 4) Friendly first-run hint (does not block startup).
CONFIG_DIR="/data/config/MijiaLAN Rust"
if [ ! -f "$CONFIG_DIR/devices.json" ]; then
  echo "NOTE: no devices yet at $CONFIG_DIR/devices.json" >&2
  echo "Run once (interactive, to scan the QR code with the Mi Home app):" >&2
  echo "  docker compose run --rm -it mijialan login --region cn" >&2
  echo "or add a device by hand if you already know its token:" >&2
  echo "  docker compose run --rm -it mijialan add 192.168.x.x --name '书桌台灯'" >&2
fi

exec /usr/local/bin/mijia-rust "$@"
