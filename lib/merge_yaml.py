#!/usr/bin/env python3
"""Deep-merge a YAML fragment into a YAML file (used for ~/.hermes/config.yaml).

    merge_yaml.py TARGET FRAGMENT [--delete a.b.c ...]   merge, then write TARGET
    merge_yaml.py TARGET --get a.b.c                      print one value

Dicts merge recursively; any other value (including lists) in FRAGMENT replaces
the one in TARGET. --delete paths are removed from TARGET *before* the merge, so
a fragment can replace a whole block. TARGET is created if missing. When the
result differs, the old file is kept next to it as TARGET.bak-<timestamp>.
Note: PyYAML does not preserve comments.
"""
import argparse
import copy
import os
import shutil
import sys
import tempfile
import time

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is missing: sudo apt install python3-yaml")


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if data is None:
        return {}
    if not isinstance(data, dict):
        sys.exit(f"{path}: top level must be a mapping")
    return data


def deep_merge(base, extra):
    for key, val in extra.items():
        if isinstance(val, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], val)
        else:
            base[key] = copy.deepcopy(val)
    return base


def delete_path(data, dotted):
    parts = dotted.split(".")
    node = data
    for p in parts[:-1]:
        node = node.get(p) if isinstance(node, dict) else None
        if node is None:
            return
    if isinstance(node, dict):
        node.pop(parts[-1], None)


def get_path(data, dotted):
    node = data
    for p in dotted.split("."):
        if not isinstance(node, dict) or p not in node:
            return None
        node = node[p]
    return node


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target")
    ap.add_argument("fragment", nargs="?")
    ap.add_argument("--delete", action="append", default=[], metavar="PATH")
    ap.add_argument("--get", metavar="PATH")
    args = ap.parse_args()

    current = load(args.target)
    if args.get:
        val = get_path(current, args.get)
        if val is None:
            sys.exit(1)
        print(val if not isinstance(val, (dict, list)) else yaml.safe_dump(val, sort_keys=False).rstrip())
        return
    if not args.fragment:
        ap.error("FRAGMENT is required unless --get is used")

    merged = copy.deepcopy(current)
    for path in args.delete:
        delete_path(merged, path)
    deep_merge(merged, load(args.fragment))

    if merged == current and os.path.exists(args.target):
        print(f"{args.target}: unchanged")
        return

    mode = 0o600
    if os.path.exists(args.target):
        mode = os.stat(args.target).st_mode & 0o777
        backup = f"{args.target}.bak-{time.strftime('%Y%m%d%H%M%S')}"
        shutil.copy2(args.target, backup)
        print(f"{args.target}: backed up to {backup}")
    os.makedirs(os.path.dirname(os.path.abspath(args.target)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(args.target)))
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        yaml.safe_dump(merged, fh, sort_keys=False, default_flow_style=False, width=1000)
    os.chmod(tmp, mode)
    os.replace(tmp, args.target)
    print(f"{args.target}: updated")


if __name__ == "__main__":
    main()
