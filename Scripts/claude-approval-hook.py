#!/usr/bin/env python3
"""Claude Code PreToolUse hook → FlowCue 审批。

stdin: Claude 传来的 JSON（tool_name / tool_input / session_id）
stdout: hook 决定的 JSON
超时或连不上 FlowCue 时 fail-open（允许），避免把 Claude 卡死。
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

BASE = "http://127.0.0.1:47824"


def pairing_code() -> str:
    """从 Mac 的 FlowCue 偏好里读当前配对码（它会重新生成，不能写死）。"""
    if os.environ.get("FLOWCUE_PAIRING_CODE"):
        return os.environ["FLOWCUE_PAIRING_CODE"]
    try:
        out = subprocess.run(
            ["defaults", "read", "com.archintera.FlowCue.Mac", "FlowCue.remotePairingCode"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        if len(out) == 6:
            return out
    except Exception:
        pass
    return ""


CODE = pairing_code()
TIMEOUT_SECONDS = 90


def call(path, payload=None, method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method or ("POST" if data else "GET"),
        headers={"Authorization": f"Bearer {CODE}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode() or "{}")


def log(message: str) -> None:
    try:
        path = os.path.expanduser("~/.flowcue/claude_approval_hook.log")
        with open(path, "a") as handle:
            handle.write(f"{time.strftime('%F %T')} {message}\n")
    except Exception:
        pass


def emit(decision, reason=""):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return  # 解析不了就不干预

    if not CODE:
        log("no pairing code; skipping")
        return

    tool = payload.get("tool_name", "tool")
    tool_input = payload.get("tool_input", {})
    detail = json.dumps(tool_input, ensure_ascii=False)[:300]

    try:
        created = call("/v1/approvals", {
            "agent": "claude",
            "sessionId": payload.get("session_id"),
            "title": f"Claude 想执行 {tool}",
            "detail": detail,
        })
        approval_id = created.get("id")
        if not approval_id:
            return
    except Exception as error:
        log(f"create failed: {error}")
        return  # 连不上 FlowCue：不拦截

    deadline = time.time() + TIMEOUT_SECONDS
    while time.time() < deadline:
        try:
            status = call(f"/v1/approvals/{approval_id}").get("status", "pending")
        except Exception:
            status = "pending"
        if status == "approved":
            emit("allow", "FloweCue: approved on phone")
        if status == "denied":
            emit("deny", "FlowCue: denied on phone")
        time.sleep(1.5)
    # 超时按允许处理，保持原有行为
    return


if __name__ == "__main__":
    main()
