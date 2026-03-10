#!/usr/bin/env python3
"""
Minimal Docker container reload sidecar — zero external dependencies.

Exposes a single HTTP endpoint that restarts (or sends a signal to)
a target Docker container via the Docker Engine Unix socket.

Environment variables
---------------------
TARGET_CONTAINER : str   — container name/id to reload    (default: freeradius)
RELOAD_MODE      : str   — "restart" | "signal"           (default: restart)
RELOAD_SIGNAL    : str   — signal name when mode=signal    (default: HUP)
RELOAD_TOKEN     : str   — bearer token for auth           (default: "" = no auth)
PORT             : int   — listen port                     (default: 9090)
RESTART_TIMEOUT  : int   — seconds before SIGKILL          (default: 10)
"""

from __future__ import annotations

import http.client
import http.server
import json
import os
import socket
import sys
from typing import Any

# ── configuration ──────────────────────────────────────────────
DOCKER_SOCKET: str = "/var/run/docker.sock"
DOCKER_API: str = "v1.43"
TARGET_CONTAINER: str = os.environ.get("TARGET_CONTAINER", "freeradius")
RELOAD_MODE: str = os.environ.get("RELOAD_MODE", "restart")
RELOAD_SIGNAL: str = os.environ.get("RELOAD_SIGNAL", "HUP")
TOKEN: str = os.environ.get("RELOAD_TOKEN", "")
PORT: int = int(os.environ.get("PORT", "9090"))
RESTART_TIMEOUT: int = int(os.environ.get("RESTART_TIMEOUT", "10"))


# ── docker client over unix socket ───────────────────────────
def _docker_request(method: str, path: str) -> tuple[int, str]:
    """Send an HTTP request to the Docker daemon over the Unix socket."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(30)
    sock.connect(DOCKER_SOCKET)
    conn = http.client.HTTPConnection("localhost")
    conn.sock = sock
    conn.request(method, f"/{DOCKER_API}{path}")
    resp = conn.getresponse()
    body = resp.read().decode()
    status = resp.status
    conn.close()
    return status, body


def _container_running() -> bool:
    """Quick health check — is the target container running?"""
    try:
        status, body = _docker_request("GET", f"/containers/{TARGET_CONTAINER}/json")
    except Exception:  # noqa: BLE001
        return False
    if status != 200:
        return False
    info: dict[str, Any] = json.loads(body)
    state: dict[str, Any] = info.get("State", {})
    return bool(state.get("Running", False))


def reload_container() -> tuple[bool, str]:
    """Reload the target container using the configured mode."""
    if RELOAD_MODE == "signal":
        status, body = _docker_request(
            "POST",
            f"/containers/{TARGET_CONTAINER}/kill?signal={RELOAD_SIGNAL}",
        )
        if status == 204:
            return True, f"signal {RELOAD_SIGNAL} sent"
        return False, f"Docker API {status}: {body}"

    status, body = _docker_request(
        "POST",
        f"/containers/{TARGET_CONTAINER}/restart?t={RESTART_TIMEOUT}",
    )
    if status == 204:
        return True, "container restarted"
    return False, f"Docker API {status}: {body}"


# ── HTTP handler ──────────────────────────────────────────────
class ReloadHandler(http.server.BaseHTTPRequestHandler):
    """GET /health, POST /reload."""

    def do_GET(self) -> None:  # noqa: N802
        """Handle GET requests."""
        if self.path == "/health":
            target_ok = _container_running()
            self._json(
                200,
                {
                    "status": "ok",
                    "target_container": TARGET_CONTAINER,
                    "target_running": target_ok,
                },
            )
        else:
            self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        """Handle POST requests."""
        if self.path != "/reload":
            self.send_error(404)
            return

        if TOKEN:
            auth = self.headers.get("Authorization", "")
            if auth != f"Bearer {TOKEN}":
                self._json(403, {"ok": False, "error": "forbidden"})
                return

        success, detail = reload_container()
        if success:
            self._json(
                200,
                {
                    "ok": True,
                    "detail": detail,
                    "container": TARGET_CONTAINER,
                },
            )
            self._log(f"✓ reload success: {detail}")
        else:
            self._json(
                502,
                {
                    "ok": False,
                    "error": detail,
                    "container": TARGET_CONTAINER,
                },
            )
            self._log(f"✗ reload failed: {detail}")

    def _json(self, code: int, data: dict[str, Any]) -> None:
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _log(self, msg: str) -> None:
        print(f"[reload] {msg}", file=sys.stderr, flush=True)

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: ARG002
        """Quieter default logging."""
        if args:
            self._log(f"{self.address_string()} {args[0]}")


# ── entrypoint ────────────────────────────────────────────────
def main() -> None:
    """Start the reload sidecar HTTP server."""
    banner = (
        f"reload-sidecar | port={PORT} target={TARGET_CONTAINER} mode={RELOAD_MODE}"
    )
    if RELOAD_MODE == "signal":
        banner += f" signal={RELOAD_SIGNAL}"
    print(banner, file=sys.stderr, flush=True)

    server = http.server.HTTPServer(("0.0.0.0", PORT), ReloadHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print("reload-sidecar stopped", file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
