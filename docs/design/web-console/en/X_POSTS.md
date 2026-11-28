# FlowCue — X pre-launch kit

English demo: **https://loose-hero-part-digital.trycloudflare.com/en/**

The tunnel is temporary. For a durable link, deploy this `en/` directory to
Cloudflare Pages / Netlify, or point a domain at it.

## Assets

| File | Size | Use |
|---|---|---|
| `card-4x5.png` | 1080×1350 | Primary X image; fills the mobile feed |
| `desktop-1600x900.png` | 1600×900 | 16:9 post, link preview fallback |
| `mobile-1080x1920.png` | 1080×1920 | Stories / vertical crop |
| `og.png` | 1200×630 | Open Graph card for the demo link |
| `demo.mp4` | 1600×900, 6.4 s | Attach to the launch tweet |
| `index.html` | — | Interactive demo (session switch, approval, send) |

All data in the demo is sample data. Codex is the only adapter wired to a real
node today; Claude and DSH are the roadmap.

## Tweet 1 — the hook (no link, keeps reach)

> Your agents shouldn't be chained to one machine.
>
> FlowCue is one console for every Codex, Claude & DSH session across your Mac,
> Windows PC and phone.
>
> Approve a file write from the couch. Send the next instruction from anywhere.
>
> Pre-launch preview below.

Attach `card-4x5.png`.

Alt text:

> A phone showing a Codex conversation with an approval card: “Codex wants to
> write AuthController.swift” and Allow once / Deny buttons.

## Reply 1 — drop the demo link

> Interactive demo (sample data):
> https://loose-hero-part-digital.trycloudflare.com/en/
>
> Codex today. Claude and DSH next. Mac, Windows, Linux, iOS, Android.

## Thread option — 6 tweets

1. AI agents can write code, run tests and ship changes. But they're still
   trapped on the machine that started them.
2. Start a task on your desktop, leave the desk, and the agent waits. You wait.
3. FlowCue turns every machine into a node and gives you one console:
   sessions, messages, approvals — from your phone or any browser.
4. This is the interaction that matters: Codex asks to write a file. You tap
   **Allow once**. The work continues while you're away.
5. Codex today. Claude Code and DSH adapters next. Mac, Windows, Linux, iOS,
   Android.
6. Pre-launch preview. Demo → https://loose-hero-part-digital.trycloudflare.com/en/

Attach `demo.mp4` to tweet 3 or 4, `card-4x5.png` to tweet 1.

## Builder option — #buildinpublic

> Building FlowCue: a cross-device console for coding agents.
>
> - Node on each machine (Go, single binary)
> - Web console + iPhone app
> - Codex now; Claude & DSH next
> - Approvals from your phone
>
> Demo (sample data) → https://loose-hero-part-digital.trycloudflare.com/en/
>
> #buildinpublic #AIagents

## Copy rules

- Say **sample data** where the demo is shown. Do not imply real users.
- Do not claim Claude/DSH are supported yet; say “next”.
- Do not claim “works over the internet” yet. The shipped path is LAN, with
  Tailscale/relay planned.
- Keep hashtags to 2–3. The link usually performs better in a reply than in
  the first tweet.
- Alt text every image; X accessibility matters and it is visible to power
  users.

## Posting order

1. Day 0: tweet 1 with `card-4x5.png`; reply with the demo link.
2. Day 1: quote the tweet with `demo.mp4` and one concrete workflow
   (“approve a file write from the couch”).
3. Day 2: builder thread with the node architecture and the Go binary.
4. Pin the thread; reply to questions with the demo link, not a waitlist.
