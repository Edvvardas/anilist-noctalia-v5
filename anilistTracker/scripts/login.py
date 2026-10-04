#!/usr/bin/env python3
"""Browser login helper for Anilist Tracker.

Opens the AniList approval page and waits on a temporary localhost server for
the redirect. AniList's implicit grant puts the token in the URL fragment,
which browsers never send to a server, so the callback page hands it back with
a small script. Prints exactly one JSON line and exits:
    {"ok": true, "access_token": "..."}  or  {"ok": false, "error": "..."}
"""

from __future__ import annotations

import json
import secrets
import shutil
import subprocess
import sys
import threading
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = 7823
AUTH_URL = "https://anilist.co/api/v2/oauth/authorize"
TIMEOUT_SECONDS = 300

# Ties the token hand-off to the page this helper served, so another local page
# can't feed in a token of its own.
NONCE = secrets.token_urlsafe(16)

CALLBACK_PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Anilist Tracker</title>
  <style>
    body { font-family: system-ui, sans-serif; background: #0b1622; color: #e2e8f0;
           display: grid; place-items: center; min-height: 100vh; margin: 0; }
    .card { background: #152232; border-radius: 12px; padding: 32px 40px;
            max-width: 420px; text-align: center; }
    h1 { margin: 0 0 8px; font-size: 22px; color: #3db4f2; }
    p { margin: 0; color: #9fadbd; }
  </style>
</head>
<body>
  <div class="card">
    <h1 id="title">Connecting…</h1>
    <p id="msg">Finishing login.</p>
  </div>
  <script>
    const params = new URLSearchParams(location.hash.slice(1));
    const token = params.get("access_token");
    const error = params.get("error_description") || params.get("error") || "no token received";
    const query = new URLSearchParams({ nonce: "__NONCE__" });
    if (token) query.set("access_token", token); else query.set("error", error);
    history.replaceState(null, "", location.pathname);
    fetch("/token?" + query).then((res) => {
      const ok = token && res.ok;
      document.getElementById("title").textContent = ok ? "Connected to AniList" : "Login failed";
      document.getElementById("msg").textContent = ok
        ? "You can close this tab and go back to Noctalia."
        : "Go back to Noctalia and try again.";
    });
  </script>
</body>
</html>
""".replace("__NONCE__", NONCE)


def emit(payload: dict) -> None:
    print(json.dumps(payload), flush=True)


def open_browser(url: str) -> None:
    if shutil.which("xdg-open"):
        subprocess.Popen(
            ["xdg-open", url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    else:
        webbrowser.open(url)


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        emit({"ok": False, "error": "usage: login.py <client_id>"})
        return 1
    client_id = sys.argv[1].strip()

    result: dict = {}
    done = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/callback" and not done.is_set():
                self._send(200, "text/html; charset=utf-8", CALLBACK_PAGE)
                return

            if parsed.path == "/token" and not done.is_set():
                params = urllib.parse.parse_qs(parsed.query)
                if params.get("nonce", [""])[0] != NONCE:
                    self._send(403, "text/plain", "forbidden")
                    return
                token = params.get("access_token", [""])[0].strip()
                if token:
                    result.update(ok=True, access_token=token)
                else:
                    result.update(ok=False, error=params.get("error", ["login failed"])[0])
                self._send(200 if token else 400, "text/plain", "ok")
                done.set()
                return

            self._send(404, "text/plain", "not found")

        def log_message(self, format: str, *args) -> None:  # noqa: A002
            return

        def _send(self, status: int, content_type: str, body: str) -> None:
            encoded = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)

    try:
        server = HTTPServer((HOST, PORT), Handler)
    except OSError:
        emit({"ok": False, "error": f"port {PORT} is busy; another login may still be running"})
        return 1
    server.timeout = 1

    def serve() -> None:
        while not done.is_set():
            server.handle_request()

    threading.Thread(target=serve, daemon=True).start()
    open_browser(f"{AUTH_URL}?client_id={urllib.parse.quote(client_id)}&response_type=token")

    if not done.wait(TIMEOUT_SECONDS):
        result.update(ok=False, error="login timed out")
    server.server_close()

    emit(result)
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
