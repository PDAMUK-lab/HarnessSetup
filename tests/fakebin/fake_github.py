#!/usr/bin/env python3
"""Tiny stand-in for GitHub's list-releases API, as an anonymous caller (the installers) sees it.
usage: fake_github.py PORT LOG
  GET /repos/OWNER/REPO/releases?per_page=N&page=P; the Link header points to /repositories/612354784/REPO/releases
  REPO llama.cpp: 1500 releases, b1500 (newest) down to b1; the newest 120 have no Windows zip yet (still uploading)
  REPO nNNN:      NNN releases, each with a Windows Vulkan zip
Pages the way GitHub does: per_page (default 30, at most 100), a Link header whose rel="next" is on every page but the
last (also past the cap) and no Link header when everything fits one page, and HTTP 422 "Only the first 1000 results
are available." for a page that starts past result 1000. Every request path is appended to LOG.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

port, log = int(sys.argv[1]), sys.argv[2]
CAP = 1000


def release(repo, n, windows):
    tag = f"b{n}"
    names = [f"llama-{tag}-bin-ubuntu-x64.tar.gz"]
    if windows:
        names += [f"llama-{tag}-bin-win-cpu-x64.zip", f"llama-{tag}-bin-win-vulkan-x64.zip"]
    return {"tag_name": tag, "draft": False, "prerelease": True, "body": f"build {tag}",
            "assets": [{"name": a, "browser_download_url": f"https://github.com/fake/{repo}/releases/download/{tag}/{a}"}
                       for a in names]}


def releases(repo):
    if repo == "llama.cpp":
        return [release(repo, n, n <= 1380) for n in range(1500, 0, -1)]
    m = re.fullmatch(r"n([0-9]+)", repo)
    return [release(repo, n, True) for n in range(int(m.group(1)), 0, -1)] if m else None


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj, link=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if link:
            self.send_header("Link", link)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        with open(log, "a") as f:
            f.write(self.path + "\n")
        url = urlsplit(self.path)
        m = re.fullmatch(r"/(?:repos/[^/]+|repositories/612354784)/([^/]+)/releases", url.path)
        repo = m.group(1) if m else ""
        rels = releases(repo)
        if rels is None:
            return self._send(404, {"message": "Not Found", "status": "404"})
        q = parse_qs(url.query)
        per = min(int(q.get("per_page", ["30"])[0]), 100)
        page = int(q.get("page", ["1"])[0])
        if (page - 1) * per >= CAP:
            return self._send(422, {"message": "Only the first 1000 results are available.",
                                    "documentation_url": "https://docs.github.com/rest/releases/releases#list-releases",
                                    "status": "422"})
        last = max(1, -(-len(rels) // per))
        at = lambda p: f"<http://127.0.0.1:{port}/repositories/612354784/{repo}/releases?per_page={per}&page={p}>"
        parts = []
        if page > 1:
            parts.append(f'{at(page - 1)}; rel="prev"')
        if page < last:
            parts += [f'{at(page + 1)}; rel="next"', f'{at(last)}; rel="last"']
        if page > 1:
            parts.append(f'{at(1)}; rel="first"')
        self._send(200, rels[(page - 1) * per:page * per], ", ".join(parts) or None)


HTTPServer(("127.0.0.1", port), H).serve_forever()
