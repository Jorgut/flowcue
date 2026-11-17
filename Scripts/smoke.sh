#!/bin/zsh
# FlowCue 冒烟测试：启动各窗口，确认可见且不崩溃。
# 用法：zsh Scripts/smoke.sh [--build]
set -u
cd "$(dirname "$0")/.."
APP="$PWD/dist/FlowCue.app"
BIN="FlowCue.app/Contents/MacOS"
pass=0; fail=0

if [[ "${1:-}" == "--build" ]]; then
  zsh Scripts/build-app.sh >/dev/null 2>&1 || { echo "构建失败"; exit 1; }
fi

# 窗口清单辅助（不依赖 System Events）
cat > /tmp/flowcue-listwin.swift <<'SWIFT'
import AppKit
import CoreGraphics
let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for info in raw {
    let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
    guard owner.localizedCaseInsensitiveContains("flowcue") else { continue }
    let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
    guard onscreen else { continue }
    let b = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let w = Int(b["Width"] as? CGFloat ?? 0), h = Int(b["Height"] as? CGFloat ?? 0)
    print("\(w)x\(h)")
}
SWIFT

check() {
  local label=$1; shift
  pkill -f "$BIN" 2>/dev/null
  # 等 LaunchServices 也注销，否则 open 会发给正在退出的旧实例（error -600）
  for i in {1..20}; do
    pgrep -f "$BIN" >/dev/null || [[ -z "$(lsappinfo find bundleID=com.archintera.FlowCue.Mac 2>/dev/null)" ]] && break
    sleep 0.5
  done
  if ! open -a "$APP" --args "$@" 2>/dev/null; then
    sleep 1
    open -a "$APP" --args "$@"
  fi
  # 面板有约 2 秒的延迟显示，轮询到出现为止（最多 15 秒）
  local count=0
  for i in {1..15}; do
    sleep 1
    count=$(swift /tmp/flowcue-listwin.swift 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" -ge 1 ]] && break
  done
  if [[ "$count" -ge 1 ]]; then
    echo "✅ $label：$count 个可见窗口"
    ((pass++))
  else
    echo "❌ $label：没有可见窗口"
    ((fail++))
  fi
  pkill -f "$BIN" 2>/dev/null
}

check "收件箱" -inbox
check "设置" -settings
check "本机 Agent" -agents
check "捕获面板" -panel

pkill -f "$BIN" 2>/dev/null; sleep 1
if pgrep -f "$BIN" >/dev/null; then
  echo "❌ 退出后仍有残留进程"; ((fail++))
else
  echo "✅ 退出干净"; ((pass++))
fi

crashes=$(find ~/Library/Logs/DiagnosticReports -name "CodexIdeaDock-*.ips" -mmin -10 2>/dev/null | wc -l | tr -d ' ')
if [[ "$crashes" -eq 0 ]]; then
  echo "✅ 最近 10 分钟无崩溃"; ((pass++))
else
  echo "❌ 最近 10 分钟有 $crashes 个崩溃报告"; ((fail++))
fi

echo "—— 通过 $pass · 失败 $fail ——"
[[ "$fail" -eq 0 ]]
