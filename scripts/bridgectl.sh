#!/bin/sh
# Bridge supervisor for the web UI: start/stop/restart `mijia-rust bridge`
# with its stdout/stderr in /data/bridge.log and pid in /data/bridge.pid.
# The web UI calls this; it never touches devices.json / credentials.enc
# directly. Bridge and login must not run at the same time: the web UI
# stops the bridge before login and starts it again afterwards.
BIN="${MIJIA_BIN:-/usr/local/bin/mijia-rust}"
LOG="${MIJIALAN_DATA:-/data}/bridge.log"
PIDF="${MIJIALAN_DATA:-/data}/bridge.pid"

pid_alive() {
  [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
}
start() {
  if pid_alive; then echo "bridge already running pid $(cat "$PIDF")"; exit 0; fi
  mkdir -p "$(dirname "$LOG")"
  # setsid so the bridge survives the web request that started it.
  setsid "$BIN" bridge >>"$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDF"
  echo "bridge started pid $(cat "$PIDF")"
}
stop() {
  if pid_alive; then
    kill "$(cat "$PIDF")" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pid_alive || break; sleep 1; done
    pid_alive && kill -9 "$(cat "$PIDF")" 2>/dev/null || true
  fi
  rm -f "$PIDF"
  echo "bridge stopped"
}
status() { pid_alive && echo "running pid $(cat "$PIDF")" || echo "stopped"; }
case "${1:-status}" in
  start) start ;; stop) stop ;; restart) stop; sleep 1; start ;; *) status ;;
esac
