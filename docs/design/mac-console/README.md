# Mac 视觉稿（合并稿 + 控制台 + 发送到会话）

静态 HTML 视觉稿，用于定 Mac 端下一轮的界面方向。颜色、圆角、字号取自
`FlowCueTokens`（Airy Dark），与 `docs/design/web-console/` 同一套 token。

| 文件 | 画面 |
|---|---|
| `01-inbox-merged-v2.html` | 收件箱（v2）：1040×680，捕获条 + 列表 / 编辑，按 `UI_DIRECTION` 无边框 |
| `02-agents-console-v2.html` | Agent 控制台（v2）：节点/会话 → 对话 → 检查器，审批内联 |
| `03-inbox-send-v2.html` | 收件箱里的「发送到会话」弹层（v2） |
| `04-capture-panel.html` | 捕获面板两版：A 自由浮动 / B 菜单栏 popover |

> v1（`01-inbox-merged.html` 等）是卡片 + 描边 + 多强调色的版本，偏离 `mac/inbox` 的
> 「无边框、输入是唯一锚点」原则，只留作对比。

重新出图：

```bash
cd docs/design/mac-console
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1610,1006 \
  --screenshot="$PWD/01-inbox-merged.png" "file://$PWD/01-inbox-merged.html"
```

## 设计取舍

**01 收件箱（合并稿）**
- 采用 mac/inbox 改版的顶部品牌 + 状态条，布局切换做成 segmented control。
- 路由（来源 / 目标 / 会话）压成编辑区底部一行，不再占两行。
- 右侧详情承担「状态 + 发送到会话 + 相关会话 + 提醒」，把原来散在 sheet 里的信息收回来。
- 收件箱仍是产品主界面：想法优先，不是聊天。

**02 Agent 控制台**
- 三栏：节点 / 会话列表 → 对话 → 检查器。
- 审批卡内联在对话流里（APPROVAL REQUIRED），和 web console 原型保持一致。
- 右栏固定放 session 元信息、节点上的 agents、node 信息、队列状态。
- 队列状态放在审批卡下方，与「已排队 · 等待处理」语义对齐。

**03 发送到会话**
- 从详情触发，弹层里先选 agent（Codex / DSH / Claude），再选会话。
- 明确写「进入当前会话，不会另开新会话」，避免误以为会新建。

## 未做/待定
- 不动收件箱的三栏宽度比例和窗口最小尺寸，等实机验证后调。
- 节点层只在控制台出现；收件箱暂不加节点切换。
- 审批卡多选（allow always / 记住选择）没有画，等确认要不要。
