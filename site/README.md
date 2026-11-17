# site/

官网静态页面。无构建步骤，直接部署这个目录。

## 结构

```
site/
├── mac/index.html        → /mac 下载页
├── assets/icon-512.png   → 页面用的图标
└── downloads/            → 发布脚本放 DMG 在这里（不入库）
```

## 下载页怎么更新

`Scripts/release-macos.sh` 出包后会：

1. 把 DMG 拷进 `site/downloads/`
2. 改 `/mac` 页面里的下载链接文件名
3. 改页面上的 `Version x · y MB`

所以**不要手改**下载链接和版本号，跑一次发布脚本即可。

## 部署

任意静态托管（Vercel / Cloudflare Pages / GitHub Pages）：

- 根目录指向 `site/`
- `/mac` → `site/mac/index.html`
- `/downloads/*.dmg` 需要允许大文件（当前 4.7 MB）
- 建议给 DMG 配 `Content-Type: application/octet-stream`

## 待补

| 项 | 说明 |
|---|---|
| 隐私政策页 | 页面底部已链接 `/privacy`，还没内容 |
| Changelog | 同上 |
| App Store 链接 | 现在是占位 `id0000000000` |
| 中文版 | 目前仅英文，可加语言切换 |
