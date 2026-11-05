#!/usr/bin/env python3
"""MijiaLAN NAS web UI - stdlib only, no pip dependencies.

Serves http://<NAS-IP>:20080 (host network) so the user never has to read a
QR code out of `docker logs`:

* Login: POST /api/login starts `mijia-rust login --region cn` in the
  background, captures the Dense1x2 unicode QR art it prints, and renders
  it as a scannable SVG. Scan it with the Mi Home app and confirm.
* Pairing: reads /data/bridge.log, extracts the HomeKit setup code and the
  bridge QR art, renders it the same way for the iPhone Home app.
* Devices / Discover / bridge restart / log tail.

Security: LAN only. Do NOT port-forward 20080 to the internet. There is no
login on this page by design - it runs on the home LAN behind the NAS.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

DATA = Path(os.environ.get("MIJIALAN_DATA", "/data"))
BRIDGE_LOG = DATA / "bridge.log"
BRIDGE_PID = DATA / "bridge.pid"
WEB_PORT = int(os.environ.get("MIJIALAN_WEB_PORT", "20080"))
BIN = os.environ.get("MIJIA_BIN", "/usr/local/bin/mijia-rust")
BRIDGECTL = os.environ.get("BRIDGECTL", "/usr/local/bin/bridgectl")
HERE = Path(__file__).resolve().parent

# ---------------------------------------------------------------- QR art
# mijia-rust prints QR codes with qrcode::render::unicode::Dense1x2:
# each character is 1 column x 2 rows: ' ' = white/white, '▀' = black/white,
# '▄' = white/black, '█' = black/black. quiet_zone(true) adds a white border.
QR_CHARS = {" ": (0, 0), "▀": (1, 0), "▄": (0, 1), "█": (1, 1)}


def parse_qr_art(text):
    """Extract the largest Dense1x2 QR block from terminal output.

    Returns a list of rows of 0/1, or None. A QR block is a run of lines
    made only of QR_CHARS (plus trailing whitespace) and at least 10 cols.
    """
    lines = text.splitlines()
    best, cur = [], []
    for line in lines:
        s = line.rstrip()
        if s and len(s) >= 10 and all(c in QR_CHARS for c in s):
            cur.append(s)
        else:
            if len(cur) > len(best):
                best = cur
            cur = []
    if len(cur) > len(best):
        best = cur
    if len(best) < 10:
        return None
    width = max(len(r) for r in best)
    grid = []
    for row in best:
        top = [QR_CHARS.get(c, (0, 0))[0] for c in row.ljust(width)]
        bot = [QR_CHARS.get(c, (0, 0))[1] for c in row.ljust(width)]
        grid.append(top)
        grid.append(bot)
    # Trim fully-white outer rows/cols (quiet zone is kept by the SVG margin).
    while grid and not any(grid[0]):
        grid.pop(0)
    while grid and not any(grid[-1]):
        grid.pop()
    if not grid:
        return None
    w = max(len(r) for r in grid)
    cols = [any(grid[r][c] for r in range(len(grid))) for c in range(w)]
    lo = next((i for i, v in enumerate(cols) if v), 0)
    hi = len(cols) - next((i for i, v in enumerate(reversed(cols)) if v), 0)
    return [r[lo:hi] for r in grid]


def qr_svg(grid, cell=8, margin=4):
    if not grid:
        return ""
    h, w = len(grid), len(grid[0])
    rects = []
    for y, row in enumerate(grid):
        x = 0
        for v in row:
            if v:
                rects.append(
                    f'<rect x="{(x + margin) * cell}" y="{(y + margin) * cell}" '
                    f'width="{cell}" height="{cell}"/>'
                )
            x += 1
    total_w, total_h = (w + margin * 2) * cell, (h + margin * 2) * cell
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {total_w} {total_h}" '
        f'width="{total_w}" height="{total_h}" role="img" aria-label="QR code">'
        f'<rect width="{total_w}" height="{total_h}" fill="white"/>'
        f'<g fill="black">{"".join(rects)}</g></svg>'
    )


# ---------------------------------------------------------------- state
def run_cli(*args, timeout=30):
    try:
        r = subprocess.run([BIN, *args], capture_output=True, text=True,
                           timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:  # noqa: BLE001 - surface as text
        return 1, str(e)


class LoginJob:
    def __init__(self):
        self.lock = threading.Lock()
        self.running = False
        self.region = "cn"
        self.output = ""
        self.qr_grid = None
        self.done = False
        self.imported = None

    def start(self, region):
        with self.lock:
            if self.running:
                return False
            self.running, self.done = True, False
            self.region, self.output, self.qr_grid, self.imported = (
                region, "", None, None)
        threading.Thread(target=self._run, daemon=True).start()
        return True

    def _run(self):
        # The bridge polls the same store; stop it while login writes devices.
        subprocess.run([BRIDGECTL, "stop"], capture_output=True, timeout=30)
        try:
            proc = subprocess.Popen(
                [BIN, "login", "--region", self.region],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1)
            out = []
            for line in proc.stdout:
                out.append(line)
                with self.lock:
                    self.output = "".join(out)
                    grid = parse_qr_art(self.output)
                    if grid:
                        self.qr_grid = grid
            proc.wait(timeout=300)
            with self.lock:
                self.output = "".join(out)
                m = re.search(r"导入 (\d+) 台设备", self.output)
                self.imported = int(m.group(1)) if m else None
                self.done = True
        except Exception as e:  # noqa: BLE001
            with self.lock:
                self.output += f"\n[webui] 登录进程出错: {e}"
                self.done = True
        finally:
            with self.lock:
                self.running = False
            subprocess.run([BRIDGECTL, "start"], capture_output=True, timeout=30)

    def state(self):
        with self.lock:
            return {
                "running": self.running, "done": self.done,
                "region": self.region, "imported": self.imported,
                "output_tail": self.output[-2000:],
                "qr_svg": qr_svg(self.qr_grid) if self.qr_grid else "",
                "has_qr": bool(self.qr_grid),
            }


LOGIN = LoginJob()


def bridge_status():
    running = False
    if BRIDGE_PID.exists():
        try:
            pid = int(BRIDGE_PID.read_text().strip())
            os.kill(pid, 0)
            running = True
        except Exception:
            running = False
    log = ""
    if BRIDGE_LOG.exists():
        try:
            log = BRIDGE_LOG.read_text(errors="replace")[-4000:]
        except Exception:
            pass
    code = None
    m = re.search(r"配对码：([0-9-]+)", log)
    if m:
        code = m.group(1)
    grid = parse_qr_art(log)
    return {
        "running": running,
        "pairing_code": code,
        "pairing_qr_svg": qr_svg(grid) if grid else "",
        "has_pairing_qr": bool(grid),
        "log_tail": log[-2000:],
    }


def devices():
    rc, out = run_cli("list", timeout=30)
    if rc != 0:
        return {"error": out.strip()[-500:]}
    try:
        return {"devices": json.loads(out)}
    except Exception:
        return {"error": "list 输出无法解析", "raw": out[-500:]}


# ---------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, body, status=200):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            self._html((HERE / "index.html").read_text(encoding="utf-8"))
        elif u.path == "/api/status":
            self._json({"bridge": bridge_status(), "login": LOGIN.state()})
        elif u.path == "/api/login":
            self._json(LOGIN.state())
        elif u.path == "/api/devices":
            self._json(devices())
        elif u.path == "/api/discover":
            rc, out = run_cli("discover", timeout=30)
            try:
                self._json({"devices": json.loads(out)})
            except Exception:
                self._json({"error": out.strip()[-500:]}, status=500 if rc else 200)
        else:
            self._json({"error": "not found"}, status=404)

    def do_POST(self):
        u = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        if u.path == "/api/login":
            region = str(body.get("region") or "cn")
            started = LOGIN.start(region)
            self._json({"started": started, **LOGIN.state()})
        elif u.path == "/api/bridge/restart":
            subprocess.run([BRIDGECTL, "restart"], capture_output=True, timeout=30)
            self._json({"ok": True, "bridge": bridge_status()})
        elif u.path == "/api/bridge/stop":
            subprocess.run([BRIDGECTL, "stop"], capture_output=True, timeout=30)
            self._json({"ok": True, "bridge": bridge_status()})
        elif u.path == "/api/bridge/start":
            subprocess.run([BRIDGECTL, "start"], capture_output=True, timeout=30)
            self._json({"ok": True, "bridge": bridge_status()})
        else:
            self._json({"error": "not found"}, status=404)


def main():
    print(f"[webui] listening on 0.0.0.0:{WEB_PORT} (LAN only, no auth)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", WEB_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
