# 分支与仓库策略

`Jorgut/flowcue` 是**公开**仓库，推上去就等于公开，删掉也删不掉历史。所以默认私有，公开需要显式决定。

## 一条判断规则

**公开 = 已经决定对外承诺的内容。** 拿不准的一律留在本地与私有镜像，等决定后再推。

## 归属

| 分支 | 去哪 |
| --- | --- |
| `main`（官网线）、`ui/merge-inbox`（开发主线） | 公开 |
| `ios/screens`、`mac/inbox`、`site/landing` | 公开 |
| `docs/*`、`chore/*` | 公开（纯文档与品牌整理） |
| `android/mvp`、`feat/device-tokens`、`wip/*` | 只本地 + 私有镜像 |
| `feat/subscription-paywall` | 只本地 + 私有镜像，商业策略未定 |

白名单文件：`.githooks/public-branches.txt`。要新开一条公开分支，先登记再推。

## 日常命令

```bash
# 推主线（钩子会拦住不在白名单里的分支）
git push origin ui/merge-inbox

# 镜像全部本地分支与 tag 到私有备份（只增不删，幂等）
zsh Scripts/mirror-backup.sh
```

在新克隆里先装钩子，否则白名单不生效：

```bash
git config core.hooksPath .githooks
```

## 私有镜像的定位

- 它是**容灾备份**，不是第二条主线：不要在它上面直接改代码或开分支。
- **只增不删**：本地删掉的分支在镜像里仍保留，作为补救。
- 恢复一条分支：

  ```bash
  git fetch backup 'refs/heads/*:refs/remotes/backup/*'
  git switch -c <branch> backup/<branch>
  ```

## 仍然适用

- 设计、宣发、历史发布包放在 `../FlowCue-Assets`，**不入库**（公开与私有都不进）。
- 证书、描述文件、`.env`、App Store Connect 密钥一律不进仓库；镜像会忠实复制，所以私有仓库也不能放。
- tag 只在真正对外发布时打；镜像会带上 tag。
- 大文件（ipa、截图、视频）不放仓库，用 `dist/` 或外部存储。
