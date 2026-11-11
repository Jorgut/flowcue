# Evaluation: optional Codex reset monitor for FlowCue

Status: **evaluation only, not scheduled.** This document records why a Codex
quota-reset monitor is adjacent to FlowCue, what it would take, and why it must
not become part of the local-only capture/queue core.

## Why it is adjacent

FlowCue captures an idea and, when the user explicitly chooses, queues it to a
Codex task. Codex usage limits and the occasional reset-card window directly
affect when that queue is useful. A reader who uses FlowCue all day may want to
know when Codex limits reset.

The reference implementation is AIHOT's reset monitor
(https://aihot.news/resets): it follows public posts from OpenAI-related
accounts, converts stated times to the reader's timezone, estimates a window
when no time is given, records a calendar, separates quota resets from reset
cards, and pushes a notification only when there is a clear message. It is
explicitly unofficial and says the client's own display is authoritative.

## Why it does not belong in the core

FlowCue's current guarantees are local and explicit:

- ideas live locally; Queuing happens only after an explicit user action;
- no Accessibility, microphone or Apple Events permission is requested;
- uncertain Queue results are not retried automatically;
- the project has no account, analytics or cloud sync.

A reset monitor is the opposite shape: it needs network access, a polling
schedule, a public-source parser that changes with other people's posts, and a
notification channel. Adding it to the core would:

1. turn a silent, local menu-bar utility into a network client;
2. add a fragile dependency on public posts that can change or disappear;
3. create expectations of real-time accuracy that the source cannot guarantee;
4. mix a content/intelligence feature into an app whose job is capture and
   explicit delivery.

## Options

| Option | Description | Assessment |
|---|---|---|
| A. Nothing in FlowCue | Users follow reset news elsewhere (AIHOT, Agent HUD, vendor status) | ✅ default; keeps FlowCue local |
| B. Separate opt-in companion tool/skill | A small standalone watcher that writes a digest or a local file FlowCue never reads | ✅ preferred if demand appears; independent failure domain |
| C. Optional FlowCue feature | A network permission, polling, parsing and notifications inside the app | ⚠️ possible later, but needs a privacy review, explicit opt-in, rate limits, cache, failure states and a maintenance owner |
| D. Local estimate from Codex logs | Infer quota/usage from local files, no network | ❌ duplicates agent HUD-style tools; log formats are unstable; estimates only |

## If it is ever built

Minimum bar, in this order:

1. **Demand evidence**: repeated requests from real FlowCue users, not only a
   theoretical interest.
2. **Stable public source**: a source that is public, permitted by its terms,
   and unlikely to break weekly.
3. **Privacy review**: network access, what is fetched, what is stored, no
   credentials, no account, no analytics; opt-in off by default.
4. **Honest UI**: label the data unofficial, mark estimates as estimates,
   distinguish "announced" from "effective", show the source, and never imply
   that a reset card has been applied to the user's account.
5. **Failure behaviour**: silent degradation, clear "unverified" state, no
   retries that hammer a source, bounded polling.
6. **No account actions**: never claim or use a reset card, never touch the
   user's Codex account.

## Recommendation

Keep the FlowCue core local-only. Record this as a **deferred, out-of-core**
idea. If demand becomes real, build option B (an independent companion), and
only then decide whether FlowCue should surface its output.

## Boundaries of this document

This is not a product commitment, a schedule, or a claim that public reset
signals are reliable. It does not add any network code, permission, or
dependency to FlowCue.
