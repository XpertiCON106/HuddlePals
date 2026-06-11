# Vault

A private, daily photo-sharing app for small groups (2–8 people). One photo per person per day goes into a shared vault. Today's photos from the others stay **blurred until you deposit your own** (the reciprocity gate). Streaks belong to the group, not the individual. Over time the vault becomes a permanent collective archive — the opposite of Instagram: private, permanent, small, daily.

This is the **MVP architecture scaffold**: every service is a protocol with a mock implementation, so the Supabase backend can be added later **without touching a single view**.

## Run it

1. Open `Vault.xcodeproj` in **Xcode 16**.
2. Select the **Vault** scheme and any **iOS 17+** simulator.
3. ⌘R. First launch seeds ~30 days of history and opens directly into the **LOCKED** state — the three other members of "The Crew" 🏔 have deposited today; you haven't.
4. Tap **Add today's memory**, pick any photo from the simulator library, deposit → the lock springs open and today is revealed.
5. ⌘U runs the `VaultEngine` unit tests.

**Demo tools** live in Profile → DEBUG: force the gate shut ("simulate: I haven't posted today"), advance the mock clock a day at a time to exercise streak math, and regenerate the seed world from scratch.

## File map

```
Vault/
├── Vault.xcodeproj
├── README.md
├── Vault/
│   ├── VaultApp.swift                  @main — builds AppDependencies, injects environment
│   ├── App/
│   │   ├── AppDependencies.swift       Composition root + AppSession + DebugSettings
│   │   └── AppRouter.swift             Tab + typed NavigationStack routes
│   ├── Models/
│   │   └── SchemaModels.swift          SwiftData @Models: User, Vault, Membership,
│   │                                   Deposit, Reaction, Comment (+ MembershipRole)
│   ├── Engine/
│   │   └── VaultEngine.swift           Pure logic: dayKey, gate, streaks, backfill,
│   │                                   same-day replacement, captions, invite codes
│   ├── Services/
│   │   ├── AuthService.swift           AuthServiceProtocol + MockAuthService
│   │   ├── VaultService.swift          VaultServiceProtocol + MockVaultService + SkipLedger
│   │   ├── DepositService.swift        DepositServiceProtocol + MockDepositService
│   │   ├── MediaService.swift          MediaServiceProtocol + MockMediaService
│   │   └── NotificationService.swift   NotificationServiceProtocol + MockNotificationService
│   ├── Seeding/
│   │   ├── SeedDataService.swift       First-launch world: 4 users, 30 days, mixed participation
│   │   └── PlaceholderImageGenerator.swift  Gradient + SF Symbol via UIGraphicsImageRenderer
│   ├── ViewModels/                     @Observable, one per screen; the only layer
│   │   │                               allowed to call services
│   │   ├── RootViewModel.swift         ├── OnboardingViewModel.swift
│   │   ├── VaultHomeViewModel.swift    ├── ComposeViewModel.swift
│   │   ├── ArchiveViewModel.swift      ├── DepositDetailViewModel.swift
│   │   ├── VaultManagementViewModels.swift  (Create / Join / Settings)
│   │   └── ProfileViewModel.swift
│   ├── Views/
│   │   ├── RootView.swift              Splash → Onboarding → MainTabView router
│   │   ├── Onboarding/OnboardingView.swift
│   │   ├── Home/VaultHomeView.swift    LOCKED grid / UNLOCKED feed + unlock reveal
│   │   ├── Compose/ComposeView.swift   PhotosPicker + caption + Deposit
│   │   ├── Archive/ArchiveView.swift   Month → day → horizontal photo rows + backfill
│   │   ├── Detail/DepositDetailView.swift  Reactions + comments
│   │   ├── VaultManagement/            CreateVaultView / JoinVaultView / VaultSettingsView
│   │   └── Profile/ProfileView.swift   Profile + sign out + DEBUG tools
│   ├── Components/                     BlurredDepositCard, DepositCard, AvatarStack,
│   │                                   StreakBadge, EmptyVaultState, PrimaryButton,
│   │                                   CaptionTextField (80-char enforcement)
│   ├── Support/                        Theme, Haptics, DateProviding (injectable clock)
│   └── Assets.xcassets
└── VaultTests/
    └── VaultEngineTests.swift          Deterministic engine tests (pinned calendar + clock)
```

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
│        Service layer (mocks)        │   │         VaultEngine           │
│ AuthService      VaultService       │   │  dayKey · reciprocity gate ·  │
│ DepositService   MediaService       │   │  group streak · backfill ·    │
│ NotificationService                 │   │  same-day replacement         │
│   // TODO: BACKEND → Supabase       │   │  (no SwiftData, no UIKit)     │
└──────────┬──────────────────────────┘   └───────────────────────────────┘
           │
┌──────────▼──────────────────────────┐
│   SwiftData (local store) + files   │
│   in Documents/Media (images)       │
└─────────────────────────────────────┘

AppDependencies (composition root, in SwiftUI Environment)
  ├── ModelContainer          ├── VaultEngine        ├── AppDateProvider (mock clock)
  ├── AppSession (@Observable)├── DebugSettings      └── all five services + seeder
```

Key decisions:

- **Engine is value-typed and dependency-free.** `VaultEngine` operates on `DepositSnapshot` values, an injected `Calendar`, and an explicit `now: Date` — never on SwiftData models or the wall clock. That's what makes the streak/gate math trivially testable and lets the DEBUG "advance mock day" feature work by shifting one injected clock.
- **One deposit per user per day** is enforced in `MockDepositService.createDeposit` (delete-then-insert); the engine's `applying(_:to:)` documents the rule as a pure function and the backend will enforce it with a unique constraint.
- **Skip tokens** decrement on `Membership`; *who skipped which day* lives in the in-memory `SkipLedger` (a real `skips` table later — see TODOs).
- **Images** are stored under `Documents/Media/` and referenced by **relative** path, because the sandbox container path changes between launches.

## Swapping mocks for Supabase

Each protocol gets a `Supabase*Service` sibling; `AppDependencies.makeMock()` gets a `makeLive()` twin. Views and view models do not change. Every integration point is marked in source with `// TODO: BACKEND — …`. Summary:

| Protocol | Mock today | Supabase replacement (see inline TODOs) |
|---|---|---|
| `AuthServiceProtocol` | Auto-signs-in seeded "You"; session id in UserDefaults | `supabase.auth` session restore, magic-link/Apple sign-in, `profiles` upsert |
| `VaultServiceProtocol` | SwiftData CRUD; invite-code lookup in store; `SkipLedger` in memory | `vaults`/`memberships` tables; join + create as RPCs (atomic code validation, 8-member cap, keeper reassignment); `skips` table; streak recompute as an edge function on deposit insert |
| `DepositServiceProtocol` | SwiftData CRUD; replacement via delete-then-insert | `deposits` with unique `(vault_id, author_id, day_key)` → upsert; `reactions` toggle via delete-or-insert; `comments` over Realtime |
| `MediaServiceProtocol` | Writes JPEGs to `Documents/Media/` | Upload to Storage bucket `deposits`; local files become the offline cache; signed-URL download on cache miss |
| `NotificationServiceProtocol` | No-op | `UNUserNotificationCenter` daily trigger at the vault's hour; later server-driven APNs ("everyone else has deposited") |

Other marked points: `CreateVaultViewModel.shareURL` (stub `vault://join/{code}` → universal link) and `VaultEngine.canBackfill` (MVP backfill doesn't repair broken streaks; repair becomes a server-side recompute).

## Business rules (as implemented)

- **dayKey** — `"yyyy-MM-dd"` in the device timezone; lexicographic order == chronological order. A deposit at 23:59 belongs to that day; 00:01 starts a new locked day.
- **Reciprocity gate** — unlocked ⇔ current user has a deposit with today's dayKey. Locked cards show author name + avatar over a frosted stand-in tinted with the author's color; the actual image bytes are never loaded while locked. Previous days are always visible.
- **Group streak** — a day counts when every current member deposited **or** spent a skip token. Counting runs backward from today (if complete) or yesterday (an in-progress today never breaks the streak); the first incomplete *ended* day stops it. Recomputed on launch and after every deposit.
- **Backfill** — a past day can receive a deposit within 48h of that day's start (in practice: yesterday), surfaced in Archive as "Add to yesterday". No streak repair in MVP (TODO).

## Testing

`VaultTests/VaultEngineTests.swift` pins the calendar to `America/Los_Angeles` and feeds explicit dates, covering: perfect-day increment, missing-member reset, incomplete-today preservation, skip-token preservation, same-day replacement, dayKey boundary (23:59 / 00:01 gate flip), backfill window (yesterday ✓ / 2 days ✗ / today ✗ / future ✗), backfill-vs-streak documentation test, gate semantics, caption sanitization, and invite-code shape.
