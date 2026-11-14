# Substack preheat draft

## Title options

- I built a quiet inbox for ideas that arrive before my coding agent
- The idea I kept losing between my phone and my Mac
- FlowCue: capture first, hand it to an agent later

## Subtitle

A small app for the half hour before you sit down at your computer.

## Body

I built a small app called FlowCue. It has taken much longer than I expected.

The original motivation was embarrassingly specific.

I was using Codex and kept sending it ideas before the previous answer had arrived. One day I sent six ideas at once, spoken into a voice keyboard, not especially well organized. Then I waited. The request failed because of a network problem. All six ideas were gone.

I rewrote them from memory — "first, second, then, another thing, also, and suddenly I thought of..." — and sent them again. Then I copied the whole message into WeChat just in case it failed again.

That was the moment I decided to build FlowCue.

The broader problem was already familiar: ideas arrive while walking, on a train, or in bed. If I have a notebook, I write them there. If I don't, they end up in Notes, WeChat, or a random chat window. By the time I sit at my computer, the context is gone, and I no longer know which ones I have already acted on.

FlowCue is an attempt to fix only that part:

**The phone catches the thought. The Mac decides which agent should receive it.**

A simple flow today:

- Capture an idea on iPhone
- Open the FlowCue inbox on Mac to organize or archive it
- Hand coding tasks to Codex or DSH running on the Mac
- Pair the phone and Mac over the same Wi-Fi to read sessions, send follow-ups, and answer approvals

If the Mac is off, the idea stays on the phone. When you're ready, send it over. Once connected, you can also continue the conversation with the agent from your phone.

What I care about:

- It is not another AI chat box. The first job is making the path from idea to agent feel natural.
- Ideas stay local by default. No account is required.
- Phone-to-Mac remote currently stays on the same Wi-Fi; conversations are not uploaded to a third-party server.
- After the local-network flow is solid, I want remote access from anywhere, as long as the computer is running.
- Codex and DSH sessions are grouped by project folder instead of one long mixed list.
- Images, voice input, and more agent adapters are still being built.

Current status:

- TestFlight beta
- App Store review in progress, not publicly released yet
- Codex and DSH local sessions supported
- Claude Code, OpenCode, and Hermes are still being adapted

FlowCue is not trying to replace coding agents. It is trying to give the half hour before you reach your computer somewhere to live.

If this sounds like a problem you have, reply or send me a note and I'll share a TestFlight invite.
