#!/usr/bin/env python3
"""
Lightweight HTTP file server for sandbox file transfers.
Runs on port 9090, serves files from /workspace.

Endpoints:
  GET  /health              - Health check
  GET  /files/<path>        - Download file (streaming)
  POST /files/<path>        - Upload file (raw body)
  GET  /list/<path>         - List directory as JSON
"""

import os
import json
import hmac
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import unquote

WORKSPACE = "/workspace"
PORT = 9090
MAX_UPLOAD_SIZE = 200 * 1024 * 1024  # 200MB
AUTH_TOKEN = os.environ.get("FILE_SERVER_TOKEN", "")


class FileHandler(BaseHTTPRequestHandler):
    def _check_auth(self):
        """Verify Bearer token. Returns True if authorized, sends 401 and returns False otherwise."""
        if not AUTH_TOKEN:
            return True  # No token configured — allow (dev/legacy mode)
        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {AUTH_TOKEN}"
        if hmac.compare_digest(auth, expected):
            return True
        self._send_json(401, {"error": "unauthorized"})
        return False

    def _resolve_path(self, url_path, prefix):
        """Resolve URL path to filesystem path, ensuring it stays within WORKSPACE."""
        rel = unquote(url_path[len(prefix):]).lstrip("/")
        full = os.path.normpath(os.path.join(WORKSPACE, rel))
        if full != WORKSPACE and not full.startswith(WORKSPACE + "/"):
            return None
        return full

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
            return

        if not self._check_auth():
            return

        if self.path.startswith("/list/") or self.path == "/list":
            self._handle_list()
            return

        if self.path.startswith("/files/"):
            self._handle_download()
            return

        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self._check_auth():
            return
        if not self.path.startswith("/files/"):
            self._send_json(404, {"error": "not found"})
            return
        self._handle_upload()

    def _handle_download(self):
        fpath = self._resolve_path(self.path, "/files/")
        if fpath is None:
            self._send_json(403, {"error": "path traversal blocked"})
            return
        if not os.path.isfile(fpath):
            self._send_json(404, {"error": "file not found"})
            return

        size = os.path.getsize(fpath)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.end_headers()

        with open(fpath, "rb") as f:
            while chunk := f.read(65536):
                self.wfile.write(chunk)

    def _handle_upload(self):
        fpath = self._resolve_path(self.path, "/files/")
        if fpath is None:
            self._send_json(403, {"error": "path traversal blocked"})
            return

        cl_header = self.headers.get("Content-Length")
        if cl_header is None:
            self._send_json(411, {"error": "Content-Length required"})
            return
        content_length = int(cl_header)
        if content_length > MAX_UPLOAD_SIZE:
            self._send_json(413, {"error": "file too large", "max_bytes": MAX_UPLOAD_SIZE})
            return

        os.makedirs(os.path.dirname(fpath), exist_ok=True)

        with open(fpath, "wb") as f:
            remaining = content_length
            while remaining > 0:
                chunk_size = min(65536, remaining)
                chunk = self.rfile.read(chunk_size)
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)

        actual_size = os.path.getsize(fpath)
        self._send_json(201, {"path": fpath, "size": actual_size})

    def _handle_list(self):
        dpath = self._resolve_path(self.path, "/list/") if self.path != "/list" else WORKSPACE
        if dpath is None:
            self._send_json(403, {"error": "path traversal blocked"})
            return
        if not os.path.isdir(dpath):
            self._send_json(404, {"error": "directory not found"})
            return

        entries = []
        for name in sorted(os.listdir(dpath)):
            full = os.path.join(dpath, name)
            try:
                stat = os.stat(full)
                entries.append({
                    "name": name,
                    "path": full,
                    "size": stat.st_size,
                    "is_dir": os.path.isdir(full),
                })
            except OSError:
                pass

        self._send_json(200, {"entries": entries})

    def _send_json(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        """Suppress default logging to stderr."""
        pass


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), FileHandler)
    print(f"File server listening on port {PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
