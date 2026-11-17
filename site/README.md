# site/

官网静态页面。无构建步骤，直接部署这个目录。

## 结构

```
site/
├── index.html            → / 主页
├── mac/index.html        → /mac 下载页
├── privacy/index.html    → /privacy 隐私政策
├── changelog/index.html  → /changelog 更新日志
├── assets/               → 图标 + 共享样式 page.css
├── _headers              → 响应头（Cloudflare Pages / Netlify）
└── downloads/            → 发布脚本放 DMG 在这里（不入库）
```

三个页面都内置 EN / 中文切换，共用 `assets/page.css`。

## 下载页怎么更新

`Scripts/release-macos.sh` 出包后会：

1. 把 DMG 拷进 `site/downloads/`
2. 改 `/mac` 页面里的下载链接文件名
3. 改页面上的 `Version x · y MB`

所以**不要手改**下载链接和版本号，跑一次发布脚本即可。

## 多语言

页面内置 EN / 中文 切换：

- 语言来源优先级：`?lang=zh` → localStorage → `navigator.language`
- 文案在 `index.html` 底部的 `I18N` 字典里，键名对应 `data-i18n`
- 新增语言：加一个字典分支 + 一个切换按钮
- iOS 里的链接可用 `?lang=zh` 强制中文

## 部署

上线地址：`https://flowcue.altn.vision`（自定义域指向本目录）。

连接仓库，构建目录设成 `site`，无构建命令；响应头由 `_headers` 生效。
命令行部署：`npx wrangler pages deploy site --project-name flowcue`；
当前生产地址 `https://flowcuepro.pages.dev`，自定义域 `flowcue.altn.vision`
需在 WordPress.com DNS 加 `CNAME flowcue → flowcuepro.pages.dev`。
后续支付接口放 Pages Functions（`functions/`），静态站本身不受影响。`_headers` 已配好：

- `/downloads/*` → `application/octet-stream` + 一年 immutable 缓存
- `/mac` → 10 分钟缓存
- 全站 `nosniff` / `Referrer-Policy`

其它候选：

| 平台 | 说明 |
|---|---|
| **Cloudflare Pages** | 免费、不限流量、亚洲节点快，`_headers` 原生支持 |
| Vercel | 免费 100GB/月，配置简单；已用 Vercel 的话可少一个账号 |
| GitHub Pages | 免费，但不支持自定义响应头，大文件走 LFS 不便 |

## 待补

| 项 | 说明 |
|---|---|
| App Store 链接 | 三处占位 `id0000000000`，上架后替换 |
| 更新日志维护 | 每次发版在 `changelog/index.html` 顶部加一条，中英各写一遍 |
| 隐私政策法律审阅 | 当前版本按实现事实撰写，正式上线前建议过一遍法律 |

## 分支

官网只存在于 `site/landing` 分支，不随 `ios/screens`、`mac/inbox` 等应用开发分支合入；
改动走 `site/landing` → `main` 的 PR，部署根目录为 `site/`。
