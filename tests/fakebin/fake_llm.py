#!/usr/bin/env python3
"""Tiny stand-in for llama-server: GET /health, GET /v1/models, POST /v1/chat/completions.
usage: fake_llm.py PORT MODE [API_KEY]   MODE: tool (answers with a get_weather call) | prose
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, mode = int(sys.argv[1]), sys.argv[2]
key = sys.argv[3] if len(sys.argv) > 3 else ""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        return not key or self.headers.get("Authorization") == f"Bearer {key}"

    def do_GET(self):
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        if self.path == "/health":
            return self._send(200, {"status": "ok"})
        if self.path == "/v1/models":
            return self._send(200, {"data": [{"id": "fake-model"}]})
        self._send(404, {})

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        if mode == "tool":
            msg = {"role": "assistant", "content": None, "tool_calls": [
                {"id": "1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\":\"Paris\"}"}}]}
        else:
            msg = {"role": "assistant", "content": "<tool_call>{\"name\": \"get_weather\"}</tool_call>"}
        self._send(200, {"choices": [{"message": msg}]})


HTTPServer(("127.0.0.1", port), H).serve_forever()
