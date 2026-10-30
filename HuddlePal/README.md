# HuddlePals

> **New here? Read [OVERVIEW.md](OVERVIEW.md)** — the complete guide with diagrams. [DEVELOPMENT.md](DEVELOPMENT.md) is the developer reference; [DEPLOYMENT.md](DEPLOYMENT.md) is the go-live runbook.

A private, daily photo-sharing app for small groups: up to 4 people, or 10 when the huddle's keeper has HuddlePals+. One photo per person per day (or, with Plus, a video of up to 6 seconds) goes into a shared huddle. Today's photos from the others stay **blurred until you deposit your own** (the reciprocity gate). Streaks belong to the group, not the individual. Over time the huddle becomes a permanent collective archive — the opposite of Instagram: private, permanent, small, daily.

Every service is a protocol with two implementations — a seeded offline **mock** and a **live** Supabase one — picked once at launch (live when a filled-in `Supabase.plist` is bundled). No view or view model knows which one is running.

## Run it

1. Open `HuddlePal.xcodeproj` in **Xcode 16**.
2. Select the **HuddlePal** scheme and any **iOS 17+** simulator.
3. ⌘R. A hug-mark launch animation, then the **Terms of Service** (the mock signs the seeded account in on first launch, and the Terms come right after sign-in; again after the Terms' version changes): scroll to the end, then tap **Agree** to continue (Decline signs out, back to the welcome cards). It lands on the **Huddles** shelf: two seeded huddles ("The Crew" 🏔 and "Sunday Dinners" 🍝), both LOCKED — the other members deposited today; you haven't.
4. Tap **Add today's memory** → take a photo with the camera (deposits are camera-only; on the Simulator, which has no camera, Compose shows a "no camera" state — run on a device to deposit), confirm the permanence prompt → the lock springs open and today is revealed.
5. ⌘U runs the test suite (engine rules, critical mock flows, live sync reconciliation, sign-in input, profile editor, photo encryption).

**Demo tools** live in Profile → DEBUG: force the gate shut ("simulate: I haven't posted today"), simulate HuddlePals+ (or Plus that ends in a minute) and a subscription linked to another account, advance the mock clock a day at a time to exercise streak math, and regenerate the seed world from scratch.

**Age screening** comes before sign-in: enter a birthday without a
preselected adult date. An under-13 answer stops sign-in and keeps only the
next eligible UTC date locally, across sign-out and relaunch. An eligible
birthday is held locally until recorded eligibility is confirmed. In live mode,
`complete_profile` saves the profile and birthday atomically;
`save_birthday` handles an older account without one. The server requires a
recorded birthday showing 13 completed years by its UTC date for huddle
access and refuses birthday changes. An
unresolved eligibility check keeps the app at the age gate. Both backends
follow this flow; this is a self-reported check, not identity verification.
An existing account whose recorded birthday is not yet eligible stays
blocked, with sign-out and account deletion available.

The matching live release requires **migration 019_age_eligibility.sql**
before shipping. The migration is prepared in this branch and has not been
applied to production by this change; follow [DEPLOYMENT.md](DEPLOYMENT.md).

## File map

```
HuddlePal/
├── HuddlePal.xcodeproj
├── README.md
├── HuddlePal/
│   ├── HuddlePalApp.swift                  @main — builds AppDependencies, injects environment
│   ├── App/
│   │   ├── AppDependencies.swift       Composition root + AppSession + DebugSettings
│   │   └── AppRouter.swift             Typed NavigationStack routes + the unsaved-Profile guard
│   ├── Models/
│   │   └── SchemaModels.swift          SwiftData @Models: User, Huddle, Membership,
│   │                                   Deposit, Reaction, Comment (+ MembershipRole)
│   ├── Engine/
│   │   ├── HuddleEngine.swift           Pure logic: dayKey, gate, streaks, backfill,
│   │   │                               permanence, recovery window, captions, the
│   │   │                               archive window, the plans' join and create rules
│   │   └── HuddleLimits.swift           The free plan's and Plus's limits
│   ├── Services/
│   │   ├── AuthService.swift           AuthServiceProtocol + MockAuthService
│   │   ├── HuddleService.swift          HuddleServiceProtocol + MockHuddleService + SkipLedger
│   │   ├── DepositService.swift        DepositServiceProtocol + MockDepositService
│   │   ├── MediaService.swift          MediaServiceProtocol + MockMediaService
│   │   ├── ModerationService.swift     ModerationServiceProtocol + MockModerationService
│   │   ├── PushTokenService.swift      PushTokenServiceProtocol + MockPushTokenService
│   │   ├── PlusService.swift           PlusServiceProtocol + MockPlusService, PlanStatus
│   │   ├── MockPlanLedger.swift        Who has Plus in the offline world
│   │   ├── Live/                       SupabaseClient, SupabaseStore, DTOs, KeychainStore,
│   │   │                               BackendConfig, Live*Service ×7 (LivePlusService:
│   │   │                               StoreKit 2 + verify-subscription), and E2EE photos:
│   │   │                               PhotoCrypto, InviteCrypto, IdentityKeychain,
│   │   │                               LivePhotoKeyring
│   │   (notifications: Support/DailyReminders.swift — local reminders;
│   │    Support/PlusPromotion.swift — the HuddlePals+ intro and opt-in reminders;
│   │    Support/PushNotifications.swift — server pushes through APNs;
│   │    Support/InviteCode.swift — the invite code format)
│   ├── Seeding/
│   │   ├── SeedDataService.swift       First-launch world: 4 users, 45 days, mixed participation, one video
│   │   ├── PlaceholderImageGenerator.swift  Gradient + SF Symbol via UIGraphicsImageRenderer
│   │   └── PlaceholderVideoGenerator.swift  A placeholder photo zooming in, as an H.264 MP4
│   ├── ViewModels/                     @Observable, one per screen; the only layer
│   │   │                               allowed to call services
│   │   ├── RootViewModel.swift         ├── OnboardingViewModel.swift
│   │   ├── HuddleHomeViewModel.swift    ├── ComposeViewModel.swift
│   │   ├── ArchiveViewModel.swift      ├── DepositDetailViewModel.swift
│   │   ├── HuddleManagementViewModels.swift  (Create / Join / Settings)
│   │   ├── PaywallViewModel.swift      ├── ArchiveGate.swift (the free plan's 30 days)
│   │   └── ProfileViewModel.swift
│   ├── Views/
│   │   ├── RootView.swift              Splash → Onboarding → MainView (one stack, no tabs)
│   │   ├── Onboarding/OnboardingView.swift  Terms of Service gate (Agree required) + sign-in steps
│   │   ├── Onboarding/WelcomeIllustrations.swift  The welcome cards' pictures (DayGoesByScene behind the first)
│   │   ├── Home/HuddleHomeView.swift    LOCKED grid / UNLOCKED feed + unlock reveal
│   │   ├── Compose/ComposeView.swift   Camera capture (photo, or video with Plus) + caption + permanence confirm
│   │   ├── Archive/ArchiveView.swift   Month → day → horizontal photo rows + backfill
│   │   ├── Detail/DepositDetailView.swift  Reactions + comments
│   │   ├── HuddleManagement/            CreateHuddleView / JoinHuddleView / HuddleSettingsView
│   │   ├── Plus/PaywallView.swift      HuddlePals+: plans, renewal terms, Restore Purchases, welcome
│   │   ├── Plus/PlusIntroSheet.swift   HuddlePals+ intro after a first post (Remind me later)
│   │   ├── Profile/DeleteAccountView.swift  Delete account: what goes, then DELETE typed
│   │   ├── Profile/BirthdayCheckView.swift  The birthday, asked once of accounts from before
│   │   └── Profile/ProfileView.swift   Draft editing + confirmed save, the Plan section,
│   │                                   sign out + DEBUG tools; TermsReaderView
│   ├── Components/                     AppDialog (the app's own alerts and choices), BirthdayEntry + BirthdayRow,
│   │                                   BlurredDepositCard, DepositCard,
│   │                                   AvatarStack (+ AvatarImageCache, pictures shown at once),
│   │                                   StreakBadge, EmptyHuddleState, PrimaryButton,
│   │                                   HuddleSpinner (every loading spinner) +
│   │                                   HuddleRefreshSpinner (pull to refresh),
│   │                                   ScreenCrossfade (fades out of a session),
│   │                                   ClipTrimBar (trimming a video),
│   │                                   CaptionTextField (80-char enforcement),
│   │                                   CodeEntryField, CameraPicker, TermsDocumentView,
│   │                                   VideoRecorder + VideoCaptureView (6-second clips),
│   │                                   DepositVideoPlayer (plays decrypted clips from memory)
│   ├── Support/                        Theme, Haptics, DateProviding (injectable clock),
│   │                                   DailyReminders, PlusPromotion, AgeScreening, ImageDownscaler, AppleSignInNonce,
│   │                                   CaptureFiles + PreparedClip (a recording's short life on disk),
│   │                                   TermsOfService (bundled text + TermsAcceptance)
│   ├── Legal/TermsOfService.md         The Terms of Service shown in-app; host it at huddlepals.com/terms
│   └── Assets.xcassets
└── HuddlePalTests/
    ├── HuddleEngineTests.swift          Deterministic engine tests (pinned calendar + clock)
    ├── CriticalFlowTests.swift         Mock-stack smoke tests: launch, gate, create/join
    ├── LiveSyncTests.swift             SupabaseStore reconciliation, incl. Former member
    ├── AuthInputTests.swift            Session persistence, phone input, code length
    ├── ProfileConfirmationTests.swift  Profile editor's confirmed-draft rules
    ├── PhotoEncryptionTests.swift      E2EE: key wrap, photo seal/open, report disclosure
    ├── TermsAgreementTests.swift       Terms gate: after sign-in, Decline signs out, re-ask per version
    ├── PlanRulesTests.swift            The free plan's and Plus's rules, the archive window
    ├── PlusServiceTests.swift          StoreKit 2 via SKTestSession (StoreKit/HuddlePalsPlus.storekit)
    ├── PlusGateTests.swift             The paywall and every gate's view model
    └── VideoDropTests.swift            Video seal, recording, playback from memory, Compose
```

Next to the app: `supabase/` (schema.sql, migrations 001–021, `scripts/reset_database.sql`, the
edge functions `delete-account`, `delete-huddle`, `send-push`, `verify-subscription` and `app-store-notifications`,
and their Node tests) and `tools/` (app icon generator, `decrypt_reported_photo` for
moderation).

> **Widgets/** — intentionally absent. A home-screen widget ("did everyone deposit yet?") is planned post-MVP; it will live in a `Widgets/` extension target sharing the SwiftData container via an app group.

## Architecture

```
┌────────────────────────────  Views (SwiftUI)  ───────────────────────────┐
│  RootView · Onboarding · Home · Compose · Archive · Detail · Create ·    │
│  Join · Settings · Profile          (never touch services directly)      │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │ @Observable view models, injected deps
┌───────────────────────────────────▼──────────────────────────────────────┐
│                         ViewModels (Observation)                         │
│  own all service calls · expose plain state · translate models→snapshots │
└──────────┬──────────────────────────────────────────────┬────────────────┘
           │ protocols only                               │ pure functions
┌──────────▼──────────────────────────┐   ┌───────────────▼───────────────┐
│   Service layer: Mock | Live        │   │         HuddleEngine           │
│ AuthService      HuddleService       │   │  dayKey · reciprocity gate ·  │
│ DepositService   MediaService       │   │  group streak · backfill ·    │
│ ModerationService                   │   │  permanence + recovery        │
│ (reminders: DailyReminders)         │   │  (no SwiftData, no UIKit)     │
└──────────┬──────────────────────────┘   └───────────────────────────────┘
           │
┌──────────▼──────────────────────────┐
│   SwiftData (local store) + files   │
│   in Documents/Media (images)       │
│   Live: synced from Supabase        │
└─────────────────────────────────────┘

AppDependencies (composition root, in SwiftUI Environment)
  ├── ModelContainer          ├── HuddleEngine        ├── AppDateProvider (mock clock)
  ├── AppSession (@Observable)├── DebugSettings      └── five services + seeder + reminders
```

Key decisions:

- **Engine is value-typed and dependency-free.** `HuddleEngine` operates on `DepositSnapshot` values, an injected `Calendar`, and an explicit `now: Date` — never on SwiftData models or the wall clock. That's what makes the streak/gate math trivially testable and lets the DEBUG "advance mock day" feature work by shifting one injected clock.
- **Once and permanent.** One deposit per member per huddle per day, refused on repeat (`DepositError.alreadyDepositedToday`) by both backends; the database has no update/delete policies on deposits, and the engine's `hasDeposit` + `recovery(...)` carry the pure-logic rules.
- **Skip tokens** decrement on `Membership`; *who skipped which day* lives in the in-memory `SkipLedger` (mock) or the `skips` table via the `spend_skip_token` RPC (live).
- **Images** are stored under `Documents/Media/` and referenced by **relative** path, because the sandbox container path changes between launches.

## Mock vs live

`AppDependencies.makeMock()` and `makeLive(config:)` are the only two wirings; each protocol has a `Mock*Service` and a `Live*Service` (in `Services/Live/`). Views and view models are identical in both modes. Summary:

| Protocol | Mock | Live (Supabase) |
|---|---|---|
| `AuthServiceProtocol` | Auto-signs-in seeded "You"; fake code `123456` for email/phone | GoTrue: Sign in with Apple (native id_token + nonce), email/SMS OTP (code length from `Supabase.plist`, default 6), Keychain sessions with auto-refresh; account deletion via the `delete-account` edge function |
| `HuddleServiceProtocol` | SwiftData CRUD; invite-code lookup in store; `SkipLedger` in memory | `huddles`/`memberships` tables; create as an RPC; join with `redeem_huddle_invite` (the invite carries the huddle key; 8-member cap); invite show / reset; `skips` table + `spend_skip_token`; `recompute_streak` RPC (the server's streak is canonical) |
| `DepositServiceProtocol` | SwiftData insert-only (permanence enforced) | `deposits` plain insert, unique `(huddle_id, author_id, day_key)`; `reactions` toggle via delete-or-insert; `comments`; one-query "who posted today" for the huddle list |
| `MediaServiceProtocol` | Writes JPEGs to `Documents/Media/` | Insert-only upload to Storage bucket `deposits`; huddle photos **end-to-end encrypted** first (ciphertext in Storage and in the local cache, decrypted in memory for display); local files are the offline cache; authenticated download on cache miss |
| `ModerationServiceProtocol` | Reports logged (DEBUG); blocks in UserDefaults | `reports` + `blocks` tables; photo, comment and profile reports; only a photo report carries a key (that photo's own) |
| `PushTokenServiceProtocol` | Remembers the token in memory (nothing sends) | `device_tokens` upsert / delete; database triggers call the `send-push` edge function, which sends through APNs |
| _(reminders)_ | Per-user local `UNUserNotificationCenter` reminders in `Support/DailyReminders.swift` (not a backend service) | Same |

Still marked with `// TODO: BACKEND — …`: orphaned Storage cleanup in `LiveMediaService`. The remaining TODOs in the mock services are notes on what their live twins do.

## Business rules (as implemented)

- **dayKey** — `"yyyy-MM-dd"` in the device timezone; lexicographic order == chronological order. A deposit at 23:59 belongs to that day; 00:01 starts a new locked day.
- **Once and permanent** — one photo per member per huddle per day, behind a "This is permanent — post it?" confirmation. No edits, no deletes, no retakes — enforced in the client and by the database (deposits have no update/delete policies).
- **Recovery window** — a broken streak isn't dead for 24 hours: a live countdown runs until the end of the day after the miss; if the missing members backfill in time the streak is restored, otherwise the reset is permanent.
- **Reciprocity gate** — unlocked ⇔ current user has a deposit with today's dayKey. Locked cards show author name + avatar over a frosted stand-in tinted with the author's color; the actual image bytes are never loaded while locked. Previous days are always visible.
- **Group streak** — a day counts when every member it waits on deposited **or** spent a skip token. A day waits on members who joined *before* it: your join day is free, so joining never breaks a streak, and you count from the next day. Counting runs backward from today (if complete) or yesterday (an in-progress today never breaks the streak); the first incomplete *ended* day stops it. Recomputed on launch and after every deposit.
- **Backfill** — a past day can receive a deposit within 48h of that day's start (in practice: yesterday), surfaced in Archive as "Add to yesterday". The next full-history recompute picks the backfilled day up — that's how the recovery window restores a streak.
- **End-to-end encrypted photos (live)** — the backend only ever holds ciphertext. Each photo has its own key, sealed with its huddle's key, which each member's device holds wrapped to that member's identity key (iCloud Keychain). A new member's invite code carries the huddle key, sealed so only the code's secret opens it: they see every photo the moment they join, with nobody else online, and the server never holds the secret. Reporting a photo discloses that one photo's key so it can be reviewed. Captions, comments, and profiles are not encrypted.
- **Former member** — photos and comments outlive their author: a deleted account (or a member who left, whose profile you can no longer read) shows as "Former member". The photo stays, and stays reportable. Only a huddle with no other member left goes with the account.

## Testing

**One command runs everything** (database and access rules, unit tests, UI journeys):

```
HuddlePal/scripts/test-all.sh
```

It builds with `Supabase.plist` excluded, so a test run can never reach the live backend. The UI tests reset HuddlePals' data on the simulator they use, so run them on a test-only simulator (`SIMULATOR="HuddlePals Tests"` by default; the script header shows how to create it). The database suite alone is `cd supabase/tests && npm install && npm test`: it runs `schema.sql` and the migrations on an in-process Postgres (PGlite) and checks every access rule both ways.

⌘U runs the app's XCTest suites:

- `HuddleEngineTests` pins the calendar to `America/Los_Angeles` and feeds explicit dates, covering: perfect-day increment, missing-member reset, incomplete-today preservation, skip-token preservation, joining mid-streak, once-and-permanent, the recovery window (opens / restores / expires), dayKey boundary (23:59 / 00:01 gate flip), backfill window (yesterday ✓ / 2 days ✗ / today ✗ / future ✗), backfill repairing a streak on recompute, gate semantics, caption sanitization, and invite-code shape.
- `CriticalFlowTests` drives the assembled mock stack: launch into two locked huddles, deposit → unlock → repeat refused, create/join, sign-out, and the huddle list's "who posted today" read.
- `LiveSyncTests` checks `SupabaseStore` reconciliation without a network, including Former-member rows.
- `AuthInputTests` covers sign-in plumbing: the Keychain session surviving a relaunch, phone numbers without +1, and code lengths from `Supabase.plist`.
- `ProfileConfirmationTests` covers the profile editor's confirmed-draft and dirty-exit rules.
- `PhotoEncryptionTests` covers the E2EE crypto: huddle-key wrap/unwrap, photo seal/open, wrong keys failing cleanly, a report's key opening only that photo, the identity key's Keychain round-trip, and the store carrying the wrapped photo key.
- `PlanRulesTests`, `PlanLimitTests`, `PlusServiceTests` and `PlusGateTests` cover HuddlePals+ and the free plan: the rules, the mock server's caps, StoreKit 2 through `SKTestSession` (purchase, restore, renewals and refunds while the app runs), and the paywall and gates. `VideoDropTests` covers video drops from recording to playback. `PlusJourneyTests` and `VideoJourneyTests` walk them in the UI.
- `TermsAgreementTests` covers the Terms of Service gate: the Terms come right after sign-in (before the profile or the app, for each account), Agree works only after scrolling to the end, Decline signs out back to the first welcome card, and agreement persists per `TermsOfService.version` (which must match the Terms' "Last updated" date).
