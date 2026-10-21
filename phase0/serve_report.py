#!/usr/bin/env python3
"""Open a report through a tiny local web server, for browsers (e.g. Safari)
that won't play sounds straight from disk.

Only the sound files listed in that report can be fetched, read-only, and
only from this Mac (127.0.0.1). Stop it with Ctrl+C.

Example:
    python serve_report.py ~/SoundLab/groups-20261021-153000/groups_report.html
"""

from __future__ import annotations

import argparse
import mimetypes
import re
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

URI_RE = re.compile(r'"uri":\s*"(file://[^"]+)"')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report", type=Path, help="a *_report.html file")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    report = args.report.expanduser().resolve()
    html = report.read_text(encoding="utf-8")
    allowed = {}
    for uri in URI_RE.findall(html):
        uri = uri.replace("\\/", "/")
        allowed[uri] = Path(unquote(urlparse(uri).path))
    print(f"Serving {report.name} with {len(allowed)} playable files on http://127.0.0.1:{args.port}/")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):  # noqa: N802
            url = urlparse(self.path)
            if url.path in ("/", "/report"):
                body = html.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if url.path == "/audio":
                uri = parse_qs(url.query).get("u", [""])[0]
                path = allowed.get(uri)
                if path is None or not path.is_file():
                    self.send_error(404)
                    return
                self.send_file(path)
                return
            self.send_error(404)

        def send_file(self, path: Path):
            size = path.stat().st_size
            ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            start, end = 0, size - 1
            rng = self.headers.get("Range")
            m = re.match(r"bytes=(\d*)-(\d*)", rng or "")
            if m and (m.group(1) or m.group(2)):
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else size - 1
                else:
                    start = max(0, size - int(m.group(2)))
                end = min(end, size - 1)
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            else:
                self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            with open(path, "rb") as f:  # read-only
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = f.read(min(1 << 20, left))
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        return
                    left -= len(chunk)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    webbrowser.open(f"http://127.0.0.1:{args.port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
