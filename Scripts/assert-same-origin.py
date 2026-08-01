#!/usr/bin/env python3
"""Load the built site in a real browser and fail if it fetches anything off-origin.

This is the gate. `check-selfcontained.py` is a static pre-check that reads the markup and
predicts what will be fetched; this measures what a browser actually does, so it catches
vectors neither it nor its author thought of. A review defeated the static scanner 15 times
with attribute-syntax tricks and then 7 more times with inline CSS and URL normalisation —
each round fixed by hand, each round finding more. Predicting a parser is a losing game;
observing one is not.

How it works, without needing a browser-automation dependency:

  * a local HTTP server serves the staged site and records the Host header of every request
  * Chrome is launched headless with `--host-resolver-rules=MAP * 127.0.0.1:<port>`, which
    points every hostname at that server

Any request the page makes therefore arrives here regardless of the host it named, and the
Host header says which host that was. A request for `fonts.googleapis.com` shows up with
`Host: fonts.googleapis.com`. Anything that is not our own origin is an external fetch.

Exit 0 when every request was same-origin, 1 otherwise, 2 when no browser was found — the
last is reported distinctly so a missing Chrome cannot be mistaken for a clean run.
"""

from __future__ import annotations

import http.server
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

# How long to let the page load before killing the browser and reading the request log.
LOAD_SECONDS = 25

CHROME_CANDIDATES = [
    "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
]

seen_hosts: list[tuple[str, str]] = []
seen_lock = threading.Lock()


def find_browser() -> str | None:
    for candidate in CHROME_CANDIDATES:
        found = shutil.which(candidate) or (candidate if Path(candidate).exists() else None)
        if found:
            return found
    return None


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main(root: str) -> int:
    directory = Path(root).resolve()
    if not (directory / "index.html").exists():
        print(f"error: {directory}/index.html not found", file=sys.stderr)
        return 1

    browser = find_browser()
    if not browser:
        print("error: no Chrome or Chromium found; cannot assert what the page fetches.",
              file=sys.stderr)
        print("       Tried: " + ", ".join(CHROME_CANDIDATES), file=sys.stderr)
        return 2

    port = free_port()
    origins = {f"127.0.0.1:{port}", f"localhost:{port}"}

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(directory), **kwargs)

        def do_GET(self):  # noqa: N802 - name fixed by the base class
            with seen_lock:
                seen_hosts.append((self.headers.get("Host", "?"), self.path))
            super().do_GET()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    # Chrome is launched and then killed rather than waited on. With every hostname mapped
    # to this server it reliably loads the page, makes its requests, and then does not exit
    # — some internal network operation never resolves. That does not matter: the assertion
    # is about which requests were made, and those have already arrived. Waiting for a clean
    # exit would trade a working check for a hang.
    with tempfile.TemporaryDirectory() as profile:
        process = subprocess.Popen(
            [browser, "--headless", "--disable-gpu", "--no-sandbox",
             f"--user-data-dir={profile}",
             # Required, not hygiene: `MAP *` also redirects Chrome's own background
             # traffic onto this server. Without these, a request to clients2.google.com
             # for network time shows up as an "external fetch" the page never made.
             "--disable-background-networking", "--disable-component-update",
             "--disable-sync", "--no-first-run", "--no-default-browser-check",
             "--disable-default-apps", "--metrics-recording-only",
             "--disable-client-side-phishing-detection",
             "--safebrowsing-disable-auto-update",
             "--disable-features=NetworkTimeServiceQuerying,OptimizationHints",
             f"--host-resolver-rules=MAP * 127.0.0.1:{port}",
             "--virtual-time-budget=8000",
             "--dump-dom", f"http://localhost:{port}/index.html"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        try:
            process.wait(timeout=LOAD_SECONDS)
        except subprocess.TimeoutExpired:
            pass
        finally:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                process.kill()
            process.wait(timeout=30)

    server.shutdown()

    with seen_lock:
        requests = list(seen_hosts)

    # The page fetching itself is the proof that the browser got that far. Without it, an
    # empty request log would mean "the browser never ran", which must not read as "clean".
    if not any(host in origins and path.endswith("index.html") for host, path in requests):
        print("error: the browser never fetched index.html, so nothing was asserted.",
              file=sys.stderr)
        for host, path in requests:
            print(f"  saw {host}{path}", file=sys.stderr)
        return 1

    external = [(host, path) for host, path in requests if host not in origins]
    for host, path in requests:
        marker = "EXTERNAL" if host not in origins else "ok      "
        print(f"  {marker} {host}{path}")

    if external:
        print(f"\n::error::the page fetched {len(external)} resource(s) from another origin",
              file=sys.stderr)
        for host, path in external:
            print(f"::error::  https://{host}{path}", file=sys.stderr)
        return 1

    print(f"\n{len(requests)} request(s), all same-origin.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1] if len(sys.argv) > 1 else "_site"))
