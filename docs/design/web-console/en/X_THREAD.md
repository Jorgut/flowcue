# X thread — the build story

Post this as a 7-tweet thread. Attach `card-4x5.png` to tweet 1 and
`demo.mp4` to tweet 4. Keep the demo link out of tweet 1; put it in tweet 6
or the first reply so it does not eat reach.

---

**1/**

Your coding agent is trapped on the machine that started it.

Start a task on your desktop, walk away, and the agent waits. You wait.

We're building FlowCue so the agent doesn't care which screen you're holding.

---

**2/**

The setup: every machine runs a small Go node. It exposes that machine's Codex
sessions through a paired, local-first API.

Your phone — or any browser — becomes the console.

Sessions. Messages. Approvals.

---

**3/**

The hard part wasn't the UI. It was approvals.

A turn started by `codex queue` belongs to another process. Its approval
prompts never reach your phone.

So the node has to own the turn: `codex app-server` + `turn/start`, then answer
the JSON-RPC approval requests.

---

**4/**

That's the interaction:

Codex asks to run `npm test`.
You tap Allow once from the couch.
The turn continues.

No screen streaming. No remote desktop. Just the agent's actual work.

---

**5/**

Under the hood:

– Go single binary, no runtime
– Embedded web console, desktop + phone
– 6-digit pairing → HttpOnly cookie
– 8s session poll, 3s message poll
– Codex today; Claude and DSH next

---

**6/**

We're testing on a 2013 Windows laptop, a Mac, an iPhone and a Pixel.

One user. Many machines. One console.

Interactive demo (sample data): [DEMO LINK]

What would you run on it first?

---

**7/**

If you build with coding agents: what's the one thing you'd want to control
from your phone?

Approvals? Session handoff? Long-running jobs?

That's what shapes the next build.

---

## Alt text

**Tweet 1 image (`card-4x5.png`):**

> A phone showing a Codex conversation. Codex asks to write
> AuthController.swift; an approval card offers “Allow once” and “Deny”.
> Headline: “Your agents. Every device.”

**Tweet 4 video (`demo.mp4`):**

> Screen recording of the FlowCue console: switch sessions, approve a command
> with “Allow once”, and send a follow-up message.

---

## Long-form version (X Article / LinkedIn)

**Your coding agent is trapped on one machine**

*We're building a cross-device console for coding agents. The UI was easy.
Turn ownership was not.*

I have a Windows laptop, a Mac, an iPhone and a Pixel. Like most people who
work with coding agents, I don't sit at one machine all day.

But my agents do.

Start a Codex task on the laptop, walk to the couch, and the work continues —
but you can't see it, steer it, or approve the one file write it's waiting on.
You're tied to the machine that started the turn.

FlowCue is our attempt to fix that. Not with remote desktop. With a small node
on every machine and one console on whatever screen you're holding.

**A node, not a stream**

Each machine runs a Go binary. It exposes the local agent sessions over a
paired, local-first API. The phone or browser is just a client.

The node is not an agent. It doesn't call a model. It starts and reads the
agent that's already installed, and it keeps the session list, messages and
approvals in one place.

That distinction matters: streaming pixels is a different product. We want the
agent's work, not its desktop.

**The part that took the longest**

The first version sent messages with `codex queue`. It worked — messages landed
in the right thread. But approvals never appeared on the phone.

The reason is ownership. A turn started by `codex queue` belongs to the process
that owns the session (a TUI, another client). Approval requests are delivered
to that client. Our node was a bystander.

To answer "Allow once" from a phone, the node has to own the turn. That means a
persistent `codex app-server` connection, `turn/start`, and a JSON-RPC loop that
handles server-initiated approval requests. Then the node can hold the request,
show it in the console, and send back `accept` or `decline`.

That's the whole trick. Not a UI feature — a protocol boundary.

The trade-off: if the thread is already running in another Codex process, our
`turn/start` fails. We chose to fail loudly instead of silently queueing the
message somewhere the phone can't see.

**What works today**

- A Go node on macOS. Windows and Linux binaries are cross-compiled; the
  Windows laptop test is next.
- The node serves its own web console at `/`. No separate deployment.
- Pair with a 6-digit code; the browser gets an HttpOnly cookie.
- Codex sessions: list, read, send.
- Approvals: command and file-change requests, with Allow once / Deny.
- The iPhone app still uses the existing `/v1` contract.

It is not a finished product. Claude and DSH adapters are next. The demo uses
sample data; the live node is LAN-first.

**Why build this now**

Coding agents are becoming genuinely useful. The interface around them is still
shaped like a desktop IDE: one machine, one window, one person sitting in front
of it.

But the work is increasingly asynchronous. You kick off a task, go do something
else, and come back. The agent needs a way to reach you — not a way to stream a
screen.

Approvals are the sharpest version of that. It's the one moment where the agent
must ask a human, and the human is often not at the desk.

**What's next**

- Claude Code adapter.
- Windows node on the 2013 laptop, then a Windows service install.
- A permanent home for the demo.
- Session handoff between machines.

If you're building with coding agents: what's the one thing you'd want to
control from your phone? Approvals? Handoff? Long-running jobs?

That answer decides what we build next.

---

## Posting notes

- Replace `[DEMO LINK]` with the permanent demo URL before posting. The current
  Cloudflare quick tunnel is temporary.
- Attach the 4:5 card to tweet 1; the 6.4s video to tweet 4.
- Put the link in tweet 6 or a reply, not tweet 1.
- Pin the thread. Reply to early questions with the demo link.
- Do not claim Claude/DSH are supported; they are next.
- Do not claim “works anywhere”; the shipped path is LAN-first.
- 2–3 hashtags max: `#AIagents #Codex #buildinpublic`.
