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
zsh Scripts/release-macos.sh
```

只验证签名与打包（跳过公证，无需凭据）：

```bash
FLOWCUE_CODE_SIGN_IDENTITY="Developer ID Application: ..." FLOWCUE_SKIP_NOTARIZE=1 \
  zsh Scripts/release-macos.sh
```

## 产物

```
dist/releases/
├── FlowCue-0.1.0-macOS-arm64.dmg          ← 给用户下载
├── FlowCue-0.1.0-macOS-arm64.dmg.sha256
├── FlowCue-0.1.0-macOS-arm64.zip          ← 自动更新用
└── FlowCue-0.1.0-macOS-arm64.zip.sha256
```

DMG 里是 `FlowCue.app` + 指向 `/Applications` 的快捷方式，用户拖进去即可。

## 脚本做了什么

1. `build-app.sh release` 构建并签名（含 helper 进程）
2. `codesign --verify --deep --strict`
3. zip → `notarytool submit --wait` → `stapler staple` → `spctl` 评估
4. 生成 DMG（UDZO），单独签名并**再次公证**
5. 输出 SHA-256

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

## 已知限制

| 项 | 说明 |
|---|---|
| 架构 | 当前只出 **arm64**。Intel Mac 需要 universal 构建（`build-app.sh` 增加 `-arch x86_64`） |
| 自动更新 | 未接；zip + sha256 已备好，接 Sparkle 或自建更新检查时用 |
| 签名身份 | 用个人 Developer ID（hong liang zhu）；正式发布前确认是否换成团队账号 |
