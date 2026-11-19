# macOS 发布流程（直接下载）

Mac 版不上 App Store：它要读 `~/.claude`、`~/.codex`、扫描本机 CLI，沙盒下做不到。
同类的 Agent HUD 也是这条路——`Notarized Developer ID` + 无沙盒 + 无 App Store 收据。

## 前置条件（一次性）

| 项 | 检查命令 |
|---|---|
| Developer ID Application 证书 | `security find-identity -v -p codesigning \| grep "Developer ID Application"` |
| notarytool 凭据 | `xcrun notarytool history --keychain-profile flowcue` |

创建公证凭据（需要 Apple ID + App 专用密码）：

```bash
xcrun notarytool store-credentials flowcue \
  --apple-id "you@example.com" \
  --team-id "GB38532D8G" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

## 出包

```bash
export FLOWCUE_CODE_SIGN_IDENTITY="Developer ID Application: hong liang zhu (GB38532D8G)"
export FLOWCUE_NOTARY_PROFILE="flowcue"
export FLOWCUE_UNIVERSAL=1          # 同时出 arm64 + x86_64
zsh Scripts/release-macos.sh
```

公证凭据已存放在 Keychain（profile `flowcue`，用 App Store Connect API Key 创建），
不需要再输入密码。

只验证签名与打包（跳过公证，无需凭据）：

```bash
FLOWCUE_CODE_SIGN_IDENTITY="Developer ID Application: ..." FLOWCUE_SKIP_NOTARIZE=1 \
  zsh Scripts/release-macos.sh
```

## 产物

发布脚本会同步官网并直接提交、推送到 `main`（Cloudflare 收到 push 即部署）。
官网自 2026-11-19 起是同一仓库的 worktree：`../FlowCue-Worktrees/site`，脚本自动定位；
也可用 `FLOWCUE_SITE_DIR` 指定。构建前会校验它确实是 Git 仓库、在 `main`、工作区干净，
否则立即退出，避免公证跑完才发现改动落在不会部署的分支上。

设置 `FLOWCUE_SKIP_SITE_COMMIT=1` 可只更新文件、不提交。

```
dist/releases/
├── FlowCue-0.1.4-macOS-x86_64-arm64.dmg          ← 给用户下载（公证 + 装订）
├── FlowCue-0.1.4-macOS-x86_64-arm64.dmg.sha256
├── FlowCue-0.1.4-macOS-x86_64-arm64.zip          ← 自动更新用
└── FlowCue-0.1.4-macOS-x86_64-arm64.zip.sha256
```

DMG 里是 `FlowCue.app` + 指向 `/Applications` 的快捷方式，用户拖进去即可。
`site/downloads/` 在 `main` 上是入库的，发布提交会带上 5 MB 左右的二进制。

## 常见问题：notarytool 拒收或卡住

- 报错 `must be a zip archive (.zip), flat installer package (.pkg), or UDIF disk image (.dmg)`：
  多半是 DMG 在生成或校验过程中被动过/被残留的 `diskimages-helper` 占着。
  用 `lsof dist/releases/<dmg>` 查占用，结束孤儿进程后删除 DMG，从已装订的
  `dist/FlowCue.app` 重新 `hdiutil create` + `codesign`，再提交一次即可（2026-11-19 实测）。
- 不要在中途 kill `notarytool`：它的子进程 `diskimages-helper` 会残留并锁住 DMG，
  下一次提交就卡在 pre-submission checks。先 `pkill -f notarytool`，再清理 helper。

## 验证清单

```bash
codesign -dv --verbose=2 dist/FlowCue.app       # 应为 Developer ID + flags=runtime
spctl -a -vvv dist/FlowCue.app                  # 公证后应为 accepted / Notarized Developer ID
hdiutil verify dist/releases/*.dmg              # CRC 校验
spctl -a -vvv -t open --context context:primary-signature dist/releases/*.dmg
```

实测（未公证状态）：

```
flags=0x10000(runtime)                  ← Hardened Runtime 已开
Authority=Developer ID Application: hong liang zhu (GB38532D8G)
spctl: rejected / source=Unnotarized Developer ID   ← 公证前必然如此
hdiutil verify: VALID
```

## 已完成验证（2026-11-17）

```
app:  accepted / Notarized Developer ID
dmg:  accepted / Notarized Developer ID
arch: x86_64 arm64（主程序与 helper 都是通用二进制）
dmg:  4.5 MB · zip: 3.9 MB
```

## 已知限制

| 项 | 说明 |
|---|---|
| 包体积 | Universal 4.5 MB（arm64 单架构 2.8 MB） |
| 自动更新 | 未接；zip + sha256 已备好，接 Sparkle 或自建更新检查时用 |
| 签名身份 | 个人 Developer ID（hong liang zhu）。证书名显示个人姓名，不影响分发；想让用户看到公司名需另注册组织账号 |
