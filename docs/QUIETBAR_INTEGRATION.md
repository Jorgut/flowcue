# Reroute + QuietBar integration plan

Prepared 2026-11-05. Scope: code inventory and migration plan, not a completed merge.

## Confirmed direction

Reroute remains the primary product and repository. QuietBar contributes optional macOS menu-bar organization. Preserve both original projects, release records, identities and user data. iOS remains capture/inbox/sync only. The interactive notch concept is a design preview, not a running native feature.

## Verified inventory

| Concern | Reroute | QuietBar | Integration decision |
|---|---|---|---|
| Platform | macOS 14+, Swift 6; separate iOS target | macOS 13+, Swift 5 | Keep Reroute baseline; original QuietBar retains 13+ |
| Lifecycle | AppDelegate, existing status item, single inbox window | QuietBarApp/main, StatusItemController | One Reroute lifecycle; do not copy second app entry point |
| Organization | Not implemented | Own status-item divider length; reveal/compact and cancellable timer | Port minimal behavior into a macOS-only component |
| Recognition | Not required | MenuBarItemHider/MenuBarScanner, optional Accessibility in direct build | Exclude from first integration; no permission prompt |
| Preferences | Own UserDefaults, SwiftData, opt-in CloudKit | Local UserDefaults; generic keys such as autoCollapseDelay | New Reroute-prefixed local keys; no cross-app reads or automatic migration |
| Shortcuts | Control-Option-Space | Control-Option-Q | Keep capture shortcut; do not register duplicate QuietBar shortcut initially |
| Login item | Separate current app lifecycle | SMAppService.mainApp | Do not import registration or change existing login items |
| Store identity | com.altn.reroute.ideainbox | com.archintera.QuietBar | Keep both existing identities and store records |
| Usage | CLI direct build; sandbox connection unresolved | None | Separate Usage work; no claim integration solves it |

Sources inspected: QuietBar README, AGENTS, PROJECT_STATE, AppSettings.swift, StatusItemController.swift, AppModel.swift and MenuBarItemHider.swift; Reroute state, Package.swift, Store project settings and documented persistence identities. Source paths are references, not runtime dependencies.

## Important physical constraint

QuietBar does not move menu-bar icons into a notch panel. Its actual reveal/compact operation changes the length of its own divider status item. Users arrange items relative to the divider with Command-drag. A top-center floating panel can control this behavior, but cannot replace the divider or promise arbitrary icon placement inside its UI.

Preserve an accessible Reroute control outside the collapsible region. Do not hide the control item, write other applications' visibility preferences, terminate Control Center, or request Accessibility/Apple Events permissions for validation.

## Ordered implementation

### A. Isolated organization behavior

- Define revealed/collapsed state and delay choices (off, 5/15/30/60 seconds), disabled by default until user opts in.
- Implement one macOS-only controller owning the divider; use explicit Swift 6 main-actor isolation.
- Reuse the Reroute menu for enable/reveal/compact actions; keep functional Settings and Quit regardless of presentation.
- Add namespaced placement/preferences keys; avoid copying QuietBar's generic keys or startup layout resets.
- On disable or app termination, cancel timers and release owned status items. Do not quit or change the separately running QuietBar app; tell users to disable one organizer to avoid competing dividers.
- Preserve QuietBar provenance/license when copying adapted code; record the exact source revision at port time. No remote merge or source deletion is required.

Validation: isolated defaults and scheduler tests for timer replacement/cancellation/disable; GitHub and sandbox builds; user-authorized GUI check of own divider and control visibility. No production notes used as test fixtures.

### B. Native notch shell

- Implement a nonactivating top-center panel, positioning from actual screen geometry; put content outside the physical camera cutout.
- Provide compact/expanded states, click-outside/Escape dismissal, reduced motion and keyboard-accessible fallback.
- Include capture and organization controls without duplicating the main inbox window. Hide/disable unsupported actions honestly.
- Test external displays, no-notch displays, menu-bar auto-hide, full screen and screen changes. Do not assume preview dimensions are hardware coordinates.

Validation: isolated preview model, native UI walkthrough, no additional privacy permission requests. Keep normal menu/inbox available if notch panel is disabled.

### C. Real data and release

- Connect genuine Usage with explicit unavailable/stale states. Existing proposed companion is still unapproved; this plan does not authorize installation or account access expansion.
- Connect capture save and existing optional sync; keep Queue explicitly triggered and uncertain delivery non-retryable.
- Review combined privacy statements: QuietBar was entirely local; Reroute's optional cloud content must not be described as entirely local. Organizer preferences remain local.
- Reconcile current Apple replies before replacing any review submission. Store readiness is not established by build success.

## Non-goals for this migration

No git-history rewrite, repository archival, remote push, App Store record transfer, automatic settings/database migration, new login service, shell/agent endpoint, or third-party menu item control. Existing downloads and standalone QuietBar remain intact.

## Exit criteria

One Reroute process provides capture/inbox plus optional organization, without extra permission prompts, lost notes, duplicate shortcut registrations or inaccessible Quit. Native notch behavior and real Usage require their own evidence before claiming completion.
