# Connected iPhone–Mac workflow proposal

Status: proposed, not implemented. Updated 2026-10-06.

## Intended behavior

Capture or edit an idea on iPhone, see it in the Mac inbox without manual copying, then explicitly choose an agent/task and Send. Saving/syncing must never execute an agent instruction. Delivery status returns to the phone.

## Proposed first implementation

Use the same Apple Account and an opt-in private CloudKit container for shared ideas. Keep the existing local store intact; introduce a separate sync representation so task caches, process diagnostics, and device preferences stay local. Preserve stable idea IDs and test migration and simultaneous edits with isolated stores before enabling existing notes. Show offline, pending sync, synced, pending delivery, delivered, failed, and uncertain states accurately.

The Mac is the executor for desktop Codex tasks. The existing GitHub Mac edition has the CLI bridge; the currently submitted sandboxed Mac App Store edition only supports Copy and Open Codex. Automatic task insertion from the store edition needs a separately installed, explicitly paired Mac companion or another supported agent endpoint. This is an additional component, not functionality present in build 6.

A phone Send action creates an explicit delivery request addressed to a selected paired Mac and task. Only the designated executor may process it. Persist request IDs and outcome state; do not claim exactly-once delivery when the upstream API does not provide idempotency. If an interruption leaves delivery uncertain, stop automatic retries and show that state. Never send merely because a note arrived.

CloudKit syncing is asynchronous and cannot guarantee instant delivery. The initial target is automatic synchronization while connected, with clear pending states. A sleeping/offline Mac cannot execute a desktop agent command; requests wait. If strict low-latency behavior is required, evaluate an authenticated live connection in addition to durable sync before promising real-time operation.

Start with Codex. Other agents require individually verified interfaces and adapters; no unsupported integrations should appear as available.

## Verification gates

1. Isolated iPhone/Mac stores: create, edit, archive, restart, offline recovery, simultaneous edit conflict preservation, and duplicate record handling.
2. Same-account two-device sync using synthetic notes only after cloud use is approved.
3. Paired Mac delivery using a fake executor: explicit consent, executor selection, duplicate requests, disconnects, and uncertain outcomes.
4. User-authorized real Codex delivery to a chosen test task; verify acknowledgement and status on the phone.
5. Update privacy/support/store descriptions, signing entitlements and provisioning; then TestFlight installation on the user's phone.

## Current release

Mac 0.1.0 (6) is awaiting review and remains local-only. The iOS prototype builds and launches but is local-only and has not been uploaded to TestFlight. No cloud capability, production migration, account access, or remote executor has been enabled by this proposal.

## Decision needed

Approve same-account private iCloud synchronization plus a paired Mac executor as the first connected version, or specify that cloud transport must be avoided. This changes architecture and the privacy boundary and therefore needs explicit direction before implementation under AGENTS.md section 5.

## Implementation progress — 2026-10-06

The user approved the architecture. Added `SharedIdeaSync.swift`, `CloudKitIdeaTransport.swift`, and `RemoteDelivery.swift`, with local-store import/export. Notes use an independent append-only revision journal and atomic durable outbox; concurrent branches retain both texts. Private CloudKit uses encrypted payload fields, immutable revision IDs, paginated reads, ancestor-first uploads, and conditional saves. Task routing/cache/diagnostics are excluded from shared note snapshots.

The local Mac delivery gate verifies the paired phone and designated executor, persists a processing marker before calling the bridge, rejects altered reuse of request IDs, stores payload fingerprints instead of note bodies in delivery diagnostics, and converts interrupted processing to uncertain on restart. It is not yet a network executor: cloud-side claim, pairing UI, phone Send and status display still require implementation. The transport and sync session are not yet started from app UI, so current app behavior remains local-only.

Validation: 61 XCTest cases, 60 passed and 1 opt-in real connection skipped, zero failures. Both iOS device Release and sandboxed Mac Release builds succeeded. No production note upload or real Queue was performed. Apple App ID was inspected; iCloud is disabled. Enabling that capability/container requires an action-time access permission confirmation under computer-use policy; the specific question is pending. Existing build 6 submission remains Waiting for Review.


### UI integration and account blocker

Added `IdeaSyncController` and wired opt-in/state/manual sync to iOS settings and Mac menu. Foreground iOS tasks cancel on scene inactivity; Mac cancels on termination. No configured container means sync remains unavailable and no CloudKit transport is created. Build configuration and entitlements are intentionally still unchanged until Apple container association and signing are completed.

The user authorized capability activation by saying continue. The Apple session expired on Configure, before Save; no successful capability change has been confirmed. Apple Developer sign-in is open and awaits user authentication. This is a login blocker, not a new architecture approval request. Latest verification: 63 tests (62 passed, 1 skipped), both Mac and iOS Release builds succeeded. Full phone/Mac delivery remains unfinished.

### CloudKit capability configured

Apple registered `iCloud.com.altn.reroute.ideainbox` and saved its association with the formal app identifier. Both Store Mac and iOS configuration now refer to this container and include CloudKit entitlements; sync remains opt-in. 63 tests completed with 62 passed, one skipped and zero failures; the unsigned iOS Release build succeeded. Actual cloud exchange remains unverified. Development signing is blocked by the unregistered current Mac and missing development profile. Automatic approval rejected device registration as outside the specific prior authorization; explicit user approval is required before registering it. Build 6 under review was not changed.

### Development signing verified — 2026-10-07

After explicit user approval, Xcode registered the current Mac and generated the Mac development profile. The signed Debug build succeeded and strict deep signature verification passed with access to the system trust service. The embedded profile includes one device, team GB38532D8G and the intended CloudKit container. Real cloud exchange and the paired delivery workflow remain unverified/unimplemented; no TestFlight upload or replacement of the current review submission occurred.

### Real isolated CloudKit verification — 2026-10-07

The signed probe confirmed an available iCloud account and encrypted synthetic data round-trip. The original app query failed with CKError 11 because the revision record type did not exist in the new container. The transport now uses a dedicated private RerouteIdeas zone and paginated record-zone changes, allowing an empty zone to bootstrap without querying a nonexistent schema type. Uploads use that zone as well. A probe compiled the actual transport with only its zone name replaced by RerouteIsolatedTransportProbe: empty-zone fetch, two independent clients' identical revision round-trip and duplicate-upload idempotency passed. This is a single-Mac two-client test, not physical iPhone/Mac validation. 62 tests passed, one skipped; signed Mac Debug and unsigned iOS Release builds succeeded. Synthetic records remain in dedicated development test zones; no local production store, Queue or review submission was changed.

### Production schema deployed — 2026-10-07

After explicit user approval, CloudKit Console confirmed “Changes Deployed” and “The schema is deployed to Production” for the reviewed encrypted revision/probe record types and associated default roles. Schema deployment did not copy development records or local notes. TestFlight build 7 was still processing at the last observation; physical-device production sync remains unverified.
