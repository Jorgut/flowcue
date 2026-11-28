# Agent parity standard

Updated 2026-11-27. Reference implementation: **DSH** (`AgentChatView` is the
generic path for Codex / Claude; `ChatScreen` is the DSH path).

## Why this exists

Remote connection can be "working" for one agent while another still loses
messages, cannot copy text, or silently fails. A connection-level pass is not
enough. An agent is only **accepted** when it passes every gate below on a
physical iPhone, against the real agent on the Mac.

Codex previously passed optimistic display, convergence and forced failure
checks. The current CloudKit candidate still needs a fresh real-device pass for
these gates. Claude Code requires a working CLI login to verify real sends.
Claude Desktop is a separate, not-yet-integrated agent.

## Acceptance gates

| # | Gate | Evidence required |
|---|---|---|
| 1 | Sessions list loads, groups by project, shows error/empty states | Screenshot + real data |
| 2 | Opening a session reads messages and keeps the latest reply | Real message count |
| 3 | Sending shows the message **immediately** (optimistic bubble) and keeps it visible while the agent queues it | Real send from phone |
| 4 | The sent message converges with the agent's stored message within 3 polls (≤10s) without leaving/re-entering | Log/screenshot after send |
| 5 | Definite rejection is visible and can be retried. An uncertain delivery stays visible and checks the original request without resending | Forced failure / stopped Mac |
| 6 | Assistant reply renders Markdown (bold, code fence, inline code, lists, tables) | UI test |
| 7 | User and assistant text can be long-pressed, selected, and copied | UI test (`Copy` menu) |
| 8 | Activity ("working…") appears and clears | Real running turn |
| 9 | Slash menu lists local skills and inserts the chosen skill | UI test (`/atlas`) |
| 10 | Approvals / questions only where the agent supports them; no dead cards | Real approval |
| 11 | Offline/error banners are actionable; no infinite spinner | Fault injection |
| 12 | Dynamic Type / dark + light theme do not clip the chat UI | Screenshots at AX size |
| 13 | Voice input inserts editable text and sends only on explicit action | Physical iPhone dictation |
| 14 | Safe step titles and tool status appear in conversation order and a completed step remains readable | Real Agent events plus physical iPhone check |
| 15 | Pick, preview and remove images; attach them to the intended session, including an image-only message | Physical iPhone and real agent confirms image contents |

## Current status (2026-11-24)

| Gate | DSH | Codex | Claude |
|---|---|---|---|
| 1 sessions | ✅ | ✅ 84 sessions | ✅ 31 sessions / 7 projects |
| 2 read | ✅ | First 20, older pages, and incremental updates implemented; current build needs device QA | Same paging UI; current build needs device QA |
| 3 optimistic send | ✅ `ChatScreen` pending bubble | ✅ 真机 2026-11-25 截图通过 | 代码共享；需登录 CLI 的测试用户验收 |
| 4 convergence ≤10s | ✅ 3s poll | ✅ 模拟器 UI 测试：测试消息 + `ok` 回复均在底部可见 | 代码共享；待登录测试 |
| 5 retry / receipt | ✅ 延迟回执夹具及 CloudKit 真机发送通过 | 已接待确认与原请求查回执；当前版本待真机故障注入 | 同 Codex；真实发送需 CLI 登录 |
| 6 Markdown | ✅ | ✅ (UI test) | 代码共享；待登录测试 |
| 7 copy/select | ✅ | ✅ (UI test) | 代码共享；待登录测试 |
| 8 activity | ✅ | 已接 Mac 会话活动独立轮询；真实运行中出现和消失待真机验收 | 适配器缺少可验证的活动信号 |
| 9 slash menu | n/a | ✅ (UI test) | 待登录测试 |
| 10 approvals/questions | ✅ | No session approval/question source wired into the current adapter | Session-scoped approval card wired to existing Claude hooks; real decision and question support still pending |
| 11 offline errors | ✅ | Connecting, unreachable/reconnect, and request errors have distinct UI; current build needs device QA | Shared UI; real send needs CLI login |
| 12 Dynamic Type | ✅ (after 2026-11-24 fixes) | shared | shared |
| 13 voice input | 已有入口 | 已接 iOS 听写；真机验收待做 | 复用 Codex 输入组件；真机验收待做 |
| 14 inline progress | 已有运行提示，历史步骤待核对 | 实际 Mac 已从 Codex 会话读到步骤标题和命令完成/失败状态；iOS 显示已接，真机页面待核对 | 缺少已验证的同类事件来源 |
| 15 images | 已有附件发送 | 最多 20 张，逐张上传与续传，收齐后一次投递；真实识图仍需验收 | 当前 CLI 适配器只发送文本 |

The generic history window uses message IDs so a full adapter window can
advance without losing new messages. It supports older pages within the latest
1,000 messages exposed by the Mac. The iPhone accepts the older Mac array
response for compatibility. Codex accepts up to 20 selected images. Each JPEG
is uploaded independently. The Mac stages files privately, reports which
uploads it already has, and submits a single message once the set is complete.
A delivery marker prevents duplicate submission after an uncertain receipt.
The iPhone stores unfinished batches in protected, non-backed-up app storage
scoped to the selected Mac and Codex session. Reopening the chat resumes only
an upload that has not reached submission. For submitted batches, it reads
the original receipt and history without issuing another submission.
Staged folders are pruned after seven days on later attachment sends in the
same session. Rendering historical Codex attachments, session-level
controls and user questions still need adapter work. An uncertain delivery
continues checking its original request instead of sending again.

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
