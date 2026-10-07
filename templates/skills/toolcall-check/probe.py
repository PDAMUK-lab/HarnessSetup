#!/usr/bin/env python3
"""Tool-calling probes for an OpenAI-compatible endpoint (the /toolcall-check skill).

    probe.py ENDPOINT [--model ID] [--key KEY] [--timeout SECONDS] [--json]

ENDPOINT is a provider name from ~/.hermes/config.yaml (laptop, desktop, desktop-v100, desktop-night) or a base URL
ending in /v1. A named endpoint brings its own URL, model and key (key_env, read from ~/.hermes/.env). Each probe
sends one chat request with tools and judges the answer; the exit status is 0 only if every probe passed.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

WEATHER = {"type": "function", "function": {
    "name": "get_weather", "description": "Current weather for a city",
    "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}
RUN_TESTS = {"type": "function", "function": {
    "name": "run_tests", "description": "Run a project's test suite",
    "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}}
SEARCH = {"type": "function", "function": {
    "name": "search_files", "description": "Search file contents for a pattern",
    "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}}, "required": ["pattern"]}}}
ISSUE = {"type": "function", "function": {
    "name": "create_issue", "description": "Open an issue in the tracker",
    "parameters": {"type": "object", "required": ["title", "labels", "assignee"], "properties": {
        "title": {"type": "string"},
        "labels": {"type": "array", "items": {"type": "string"}},
        "assignee": {"type": "object", "required": ["login"], "properties": {"login": {"type": "string"}}}}}}}


def user(text):
    return [{"role": "user", "content": text}]


def calls(msg):
    return msg.get("tool_calls") or []


def args_of(call):
    return json.loads(call["function"].get("arguments") or "{}")


def p_single(msg):
    c = calls(msg)
    if not c:
        return False, "no tool call (answered in prose: is the server started with --jinja?)"
    if c[0]["function"]["name"] != "get_weather":
        return False, f"called {c[0]['function']['name']}"
    return ("paris" in str(args_of(c[0]).get("city", "")).lower()), f"args {c[0]['function'].get('arguments')}"


def p_choose(msg):
    c = calls(msg)
    if not c:
        return False, "no tool call"
    name = c[0]["function"]["name"]
    return name == "run_tests" and "api" in str(args_of(c[0]).get("path", "")), f"called {name} {c[0]['function'].get('arguments')}"


def p_nested(msg):
    c = calls(msg)
    if not c or c[0]["function"]["name"] != "create_issue":
        return False, "no create_issue call"
    a = args_of(c[0])
    ok = isinstance(a.get("labels"), list) and "bug" in a["labels"] and isinstance(a.get("assignee"), dict) \
        and a["assignee"].get("login") == "octocat"
    return ok, f"args {c[0]['function'].get('arguments')}"


def p_no_tool(msg):
    if calls(msg):
        return False, f"called {calls(msg)[0]['function']['name']} when no tool was needed"
    return "4" in (msg.get("content") or ""), "answered directly"


def p_follow_up(msg):
    if calls(msg):
        return False, "called a tool again instead of using the result"
    return "18" in (msg.get("content") or ""), "used the tool result"


def p_parallel(msg):
    cities = sorted(str(args_of(c).get("city", "")).lower() for c in calls(msg) if c["function"]["name"] == "get_weather")
    if len(cities) >= 2 and any("paris" in x for x in cities) and any("rome" in x for x in cities):
        return True, "two calls in one turn"
    return False, f"{len(cities)} get_weather call(s): {cities}"


FOLLOW_UP = user("What is the weather in Paris?") + [
    {"role": "assistant", "content": None, "tool_calls": [
        {"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\": \"Paris\"}"}}]},
    {"role": "tool", "tool_call_id": "call_1", "content": "18C, cloudy"}]

# name, critical (an agent cannot work without it), messages, tools, judge
PROBES = [
    ("single call", True, user("What is the weather in Paris?"), [WEATHER], p_single),
    ("right tool of three", True, user("Run the unit tests in ./api"), [WEATHER, SEARCH, RUN_TESTS], p_choose),
    ("nested arguments", True,
     user("Open an issue titled 'Login fails' with the labels bug and auth, assigned to octocat."), [ISSUE], p_nested),
    ("no tool when none is needed", True, user("What is 2+2? Answer directly."), [WEATHER, SEARCH], p_no_tool),
    ("uses a tool result", True, FOLLOW_UP, [WEATHER], p_follow_up),
    ("parallel calls", False, user("What is the weather in Paris and in Rome? Check both."), [WEATHER], p_parallel),
]


def endpoint(name, model, key):
    """(base_url, model, key) for a provider name from ~/.hermes/config.yaml, or for a URL."""
    if name.startswith("http"):
        return name.rstrip("/"), model, key
    import yaml  # python3-yaml, installed by stage 04
    home = os.path.expanduser("~/.hermes")
    cfg = yaml.safe_load(open(os.path.join(home, "config.yaml"), encoding="utf-8")) or {}
    prov = (cfg.get("providers") or {}).get(name)
    if not prov:
        sys.exit(f"no provider '{name}' in {home}/config.yaml (known: {', '.join(cfg.get('providers') or {})})")
    if not key and prov.get("key_env"):
        try:
            for line in open(os.path.join(home, ".env"), encoding="utf-8"):
                k, _, v = line.strip().partition("=")
                if k == prov["key_env"]:
                    key = v.strip("'\"")
        except OSError:
            pass
    return prov["api"].rstrip("/"), model or prov.get("default_model"), key


def ask(base, model, key, messages, tools, timeout):
    body = json.dumps({"model": model, "messages": messages, "tools": tools, "temperature": 0}).encode()
    req = urllib.request.Request(base + "/chat/completions", data=body, headers={"Content-Type": "application/json"})
    if key:
        req.add_header("Authorization", f"Bearer {key}")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["choices"][0]["message"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("endpoint")
    ap.add_argument("--model", default="")
    ap.add_argument("--key", default="")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    base, model, key = endpoint(a.endpoint, a.model, a.key)
    if not model:
        sys.exit("no model: pass --model")
    results = []
    for name, critical, messages, tools, judge in PROBES:
        t0 = time.time()
        try:
            msg = ask(base, model, key, messages, tools, a.timeout)
            ok, note = judge(msg)
        except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError, TypeError) as exc:
            ok, note = False, f"error: {exc}"
        results.append({"probe": name, "critical": critical, "pass": bool(ok), "seconds": round(time.time() - t0, 1),
                        "note": note})
    if a.json:
        print(json.dumps({"endpoint": base, "model": model, "results": results}, indent=2))
    else:
        print(f"{model} at {base}")
        for r in results:
            mark = "PASS" if r["pass"] else ("FAIL" if r["critical"] else "WARN")
            print(f"  {mark:4}  {r['probe']:28} {r['seconds']:>6}s  {r['note']}")
        crit = [r for r in results if r["critical"]]
        print(f"critical: {sum(r['pass'] for r in crit)}/{len(crit)} passed;"
              f" all: {sum(r['pass'] for r in results)}/{len(results)}")
    sys.exit(0 if all(r["pass"] for r in results if r["critical"]) else 1)


if __name__ == "__main__":
    main()
