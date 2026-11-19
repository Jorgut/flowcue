#!/bin/zsh
# 一键开发循环：构建当前源码 → 退出旧实例 → 启动 dist 里的新构建。
# 用法：Scripts/dev-run.sh [debug|release]（默认 release）
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_directory="$(cd -- "$script_directory/.." && pwd -P)"
configuration="${1:-release}"
app_path="$project_directory/dist/FlowCue.app"
bundle_identifier="com.archintera.FlowCue.Mac"
process_pattern="FlowCue.app/Contents/MacOS/CodexIdeaDock"

quit_running_instance() {
    pgrep -f "$process_pattern" >/dev/null 2>&1 || return 0

    osascript -e "tell application id \"$bundle_identifier\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -f "$process_pattern" >/dev/null 2>&1 || return 0
        sleep 0.25
    done

    printf '%s\n' "FlowCue 没有在 5 秒内退出，强制结束。" >&2
    pkill -f "$process_pattern" 2>/dev/null || true
    sleep 1
}

quit_running_instance
zsh "$script_directory/build-app.sh" "$configuration"
open "$app_path"
printf '%s\n' "已启动：$app_path"
