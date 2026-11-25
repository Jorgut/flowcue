# Agent parity standard

Updated 2026-11-25. Reference implementation: **DSH** (`AgentChatView` is the
generic path for Codex / Claude; `ChatScreen` is the DSH path).

## Why this exists

Remote connection can be "working" for one agent while another still loses
messages, cannot copy text, or silently fails. A connection-level pass is not
enough. An agent is only **accepted** when it passes every gate below on a
physical iPhone, against the real agent on the Mac.

**Codex gates 3–5 now pass** (real-device optimistic bubble; Simulator
convergence; fault-injected Retry). Claude Code is supported for users with a
working CLI, but this Mac cannot verify send because its CLI is logged out.
Claude Desktop is a separate, not-yet-integrated agent.

## Acceptance gates

| # | Gate | Evidence required |
|---|---|---|
| 1 | Sessions list loads, groups by project, shows error/empty states | Screenshot + real data |
| 2 | Opening a session reads messages and keeps the latest reply | Real message count |
| 3 | Sending shows the message **immediately** (optimistic bubble) and keeps it visible while the agent queues it | Real send from phone |
| 4 | The sent message converges with the agent's stored message within 3 polls (≤10s) without leaving/re-entering | Log/screenshot after send |
| 5 | Send failure is visible, the bubble becomes failed, and Retry works | Forced failure / stopped Mac |
| 6 | Assistant reply renders Markdown (bold, code fence, inline code, lists, tables) | UI test |
| 7 | User and assistant text can be long-pressed, selected, and copied | UI test (`Copy` menu) |
| 8 | Activity ("working…") appears and clears | Real running turn |
| 9 | Slash menu lists local skills and inserts the chosen skill | UI test (`/atlas`) |
| 10 | Approvals / questions only where the agent supports them; no dead cards | Real approval |
| 11 | Offline/error banners are actionable; no infinite spinner | Fault injection |
| 12 | Dynamic Type / dark + light theme do not clip the chat UI | Screenshots at AX size |

## Current status (2026-11-24)

| Gate | DSH | Codex | Claude |
|---|---|---|---|
| 1 sessions | ✅ | ✅ 84 sessions | ✅ 31 sessions / 7 projects |
| 2 read | ✅ | ✅ 80+ messages | ✅ 13 messages (local CLI auth errors in content) |
| 3 optimistic send | ✅ `ChatScreen` pending bubble | ✅ 真机 2026-11-25 截图通过 | 代码共享；需登录 CLI 的测试用户验收 |
| 4 convergence ≤10s | ✅ 3s poll | ✅ 模拟器 UI 测试：测试消息 + `ok` 回复均在底部可见 | 代码共享；待登录测试 |
| 5 retry | ✅ | ✅ 故障注入 UI 测试：失败→Retry→重新发送通过 | 代码共享；待登录测试 |
| 6 Markdown | ✅ | ✅ (UI test) | 代码共享；待登录测试 |
| 7 copy/select | ✅ | ✅ (UI test) | 代码共享；待登录测试 |
| 8 activity | ✅ | ❌ 无 Codex activity | ❌ 无 Claude activity |
| 9 slash menu | n/a | ✅ (UI test) | 待登录测试 |
| 10 approvals/questions | ✅ | n/a | n/a |
| 11 offline errors | ✅ | ✅ | 读取正常；发送需 CLI 登录 |
| 12 Dynamic Type | ✅ (after 2026-11-24 fixes) | shared | shared |

**Claude Code is supported for users who have a working CLI.** Local
`claude auth status` is `{"loggedIn": false}`, so this Mac's send cannot be
accepted; that is an environment limit, not a reason to withdraw the agent.
Testers with their own Claude Code login/quota should be able to list, read and
send. Claude Desktop (`claude-app`) is a **separate** agent: it has no local API
and needs its own UI-automation adapter (`claude-desktop`); never merge its
sessions, cache, auth or quota with Claude Code.

## Iteration rule

1. Change the shared behavior / DSH path first.
2. Propagate it to `AgentChatView` (Codex + Claude) in the same change or the
   next one; never leave the generic path behind silently.
3. Re-run the gates on the affected agents on a **physical device**.
4. Update the matrix above and `PROJECT_STATE.md`; an agent without fresh
   evidence is still "未验收".

## Evidence commands

```bash
# Unit/integration (safe, no real turns)
swift test
CODEX_IDEA_DOCK_REAL_TEST=1 swift test --filter CodexBridgeTests/testRealAppServerReadIsOptIn

# Simulator UI checks (LAN pairing; no relay needed)
xcodebuild test -project RerouteMobile.xcodeproj -scheme RerouteMobile \
  -destination "platform=iOS Simulator,id=<UDID>" \
  -only-testing:RerouteMobileUITests/... 
```

UI test files are kept out of the committed suite until a stable simulator
fixture exists; they are currently added temporarily during a review run.
