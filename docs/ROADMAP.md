# FlowCue roadmap

## Current product line — global

- iPhone app: ideas inbox, Codex / DSH agent sessions, same-Wi-Fi remote
- Mac app: capture inbox, Codex queue, local LAN server, DSH bridge
- Subscription: FlowCue Pro monthly, TestFlight beta unlock
- Distribution: App Store (China mainland excluded), Developer ID Mac app

## Planned work, in order

1. **Stability**
   - Fix voice input crash (build 22)
   - Verify DSH send / fork / subagent UX on a real iPhone
   - Finish TestFlight validation before replacing the App Store review build
2. **Conversation parity**
   - Unified event stream for Codex and DSH instead of 3-second polling
   - Image/attachment sending through the Mac bridge
   - True live activity (tool calls, running turn) in the chat view
3. **Idea workflow**
   - Optional due date and local reminder for an idea
   - Clear separation between “route to agent” and “schedule for later”
4. **DSH maturity**
   - Stable plugin install/uninstall, versioned bridge protocol
   - Reliable approval and session semantics across DSH upgrades
5. **China edition — separate app, same core**

## China edition

Decision: keep a **separate China product line** once DSH and remote are mature,
not a fork of the codebase.

### Principles

- Local-first: ideas and DSH stay on the user's Mac/iPhone; no FlowCue relay.
- No Google/GitHub OAuth or overseas third-party SDKs.
- No account required for the core app; if an account becomes necessary, use
  Sign in with Apple and add WeChat only when a mainland entity and compliance
  process exist.
- AI features remain user-configured; do not resell or proxy an external model
  API unless the relevant Chinese filing/registration is in place.
- Separate `com.archintera.FlowCue.CN` bundle ID and App Store record.
- China mainland storefront only; separate privacy policy and support contact.
- Complete mobile app ICP filing and any required app/AI registration before
  submission.

### Technical shape

- Shared Swift core, separate build configuration (`FLOWCUE_CHINA`).
- Disable: overseas relay, Google/GitHub login, non-local network discovery.
- Keep: local ideas, iCloud private sync if compliant, LAN Codex/DSH pairing,
  StoreKit subscriptions.
- Gate any feature that depends on a server or overseas service behind the
  build flag so the global and China binaries cannot drift accidentally.

### Entry gate

Start the China edition only after:

- DSH plugin/bridge is stable across at least one DSH release
- LAN remote is validated on real devices
- subscription products and App Store review are live
- legal/compliance scope (ICP, privacy, AI content) has been reviewed
