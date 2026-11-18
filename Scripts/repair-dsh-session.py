#!/usr/bin/env python3
"""Repair malformed DSH user messages written by the early FlowCue bridge.

The first bridge version forwarded {content, source} to Agent.followup without
the required role/id fields. DSH then sent model requests with messages missing
`role` and returned INVALID_REQUEST. This script adds the missing fields.

Run only while DeepSeek Harness is fully quit. A timestamped backup is kept next
to each repaired session log.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

HOME = Path.home()
SESSIONS = HOME / ".dsh" / "sessions"
ZSTD_CANDIDATES = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]


def find_zstd() -> str:
    for candidate in ZSTD_CANDIDATES:
        if os.access(candidate, os.X_OK):
            return candidate
    raise SystemExit("zstd not found")


def dsh_running() -> bool:
    try:
        out = subprocess.run(["pgrep", "-f", "DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"], capture_output=True, text=True)
        return bool(out.stdout.strip())
    except Exception:
        return False


def load_lines(path: Path, zstd: str) -> list[str]:
    proc = subprocess.run([zstd, "-dc", str(path)], capture_output=True, check=True)
    return proc.stdout.decode("utf-8", "replace").splitlines()


def missing_role_count(lines: list[str]) -> int:
    count = 0
    for line in lines:
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") == "user/message" and "role" not in (obj.get("data") or {}):
            count += 1
    return count


def repair_lines(lines: list[str]) -> tuple[list[str], int]:
    fixed = 0
    repaired: list[str] = []
    for line in lines:
        try:
            obj = json.loads(line)
        except Exception:
            repaired.append(line)
            continue
        if obj.get("type") == "user/message":
            data = obj.setdefault("data", {})
            if "role" not in data:
                data["role"] = "user"
                fixed += 1
            if "id" not in data:
                data["id"] = str(uuid.uuid4())
            source = data.get("source")
            if isinstance(source, dict):
                source.setdefault("rpcId", str(uuid.uuid4()))
            elif source is None:
                data["source"] = {"kind": "user", "rpcId": str(uuid.uuid4())}
        repaired.append(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))
    return repaired, fixed


def repair_file(path: Path, zstd: str, dry_run: bool) -> int:
    lines = load_lines(path, zstd)
    missing = missing_role_count(lines)
    if missing == 0:
        print(f"ok   {path} (nothing to repair)")
        return 0
    repaired, fixed = repair_lines(lines)
    remaining = missing_role_count(repaired)
    if remaining:
        print(f"FAIL {path}: {remaining} malformed messages remain", file=sys.stderr)
        return 1
    print(f"need {path}: {fixed} malformed user message(s)")
    if dry_run:
        return 0
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = path.with_name(path.name + f".bak-{stamp}")
    shutil.copy2(path, backup)
    tmp = path.with_name(path.name + ".repaired.tmp")
    tmp.write_text("\n".join(repaired) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    # Compress and atomically replace the original session file.
    compressed = path.with_name(path.name + ".repaired.zstd")
    subprocess.run([zstd, "-q", "-f", "-o", str(compressed), str(tmp)], check=True)
    os.replace(compressed, path)
    tmp.unlink(missing_ok=True)
    print(f"     backup: {backup}")
    print(f"     repaired: {path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", help="repair one session log instead of scanning all")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true", help="repair even if DSH is running (not recommended)")
    args = parser.parse_args()

    if dsh_running() and not args.force and not args.dry_run:
        print("DeepSeek Harness is running. Quit it completely, then run this script again.", file=sys.stderr)
        return 2

    zstd = find_zstd()
    if args.file:
        files = [Path(args.file).expanduser()]
    else:
        files = sorted(SESSIONS.glob("*/*/session.v4.jsonl.zstd"))

    found = 0
    for path in files:
        if not path.is_file():
            continue
        try:
            before = missing_role_count(load_lines(path, zstd))
        except Exception as exc:
            print(f"skip {path}: {exc}", file=sys.stderr)
            continue
        if before == 0 and not args.file:
            continue
        found += 1
        if repair_file(path, zstd, args.dry_run) != 0:
            return 1
    if not found:
        print("No malformed DSH sessions found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
