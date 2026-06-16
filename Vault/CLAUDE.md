# CLAUDE.md — Vault project context

This file makes any fresh session productive immediately. Read it fully, then
consult [OVERVIEW.md](OVERVIEW.md) for the deep narrative (diagrams of every
flow), [README.md](README.md) for quick start, [DEPLOYMENT.md](DEPLOYMENT.md)
for the go-live runbook, and [supabase/schema.sql](supabase/schema.sql) for
the entire backend. Those four docs are accurate and maintained — when you
change behavior, update them.

## What this is

**Vault** — a private, daily photo-sharing iOS app for groups of 2–8. One
photo per member per day; today's photos from others stay blurred until you
deposit your own (the "reciprocity gate"); streaks belong to the group.
SwiftUI, iOS 17.0+, Xcode 16 project, **zero third-party dependencies**.
Dual-backend: a seeded offline **mock** world and a **live** Supabase backend
behind identical service protocols — the app picks at launch based on whether
`Vault/Vault/Supabase.plist` exists with real values.

**Project status (as of 2026-06-11):** feature-complete MVP. All logic
verified to the extent possible without Xcode (see "Verification" below).
Never yet compiled in Xcode or run against a real Supabase project — the
owner is currently setting up an Apple Developer account and a Supabase
project to TestFlight it. Expect the next sessions to involve: first ⌘R
build errors (if any), live wire-format fixes, TestFlight prep, then
production hardening.

## Hard constraints — never violate

1. **Zero third-party dependencies.** Apple frameworks + raw URLSession only.
   Do not add SPM packages (not even supabase-swift) without explicit owner
   approval.
2. **Views never touch services.** Views render view-model state and forward
   taps. Only `@Observable @MainActor` view models call services. (Sanctioned
   exception: `LocalDepositImage` resolves image bytes via
   `deps.mediaService` as a display concern.)
3. **`VaultEngine` stays pure.** No SwiftData, no UIKit, no `Date()`/wall
   clock — calendar and `now` are always injected. It operates on
   `DepositSnapshot` values, never models.
4. **Mock and live implement the same protocols with the same semantics.**
   Any protocol change must update both, plus call sites.
5. **Observation framework only** (`@Observable`) — no ObservableObject, no
   Combine.
6. **Business-rule changes must be mirrored in three places**: `VaultEngine`
   (client), `supabase/schema.sql` (constraints + `recompute_streak` RPC),
   and `VaultTests`. The server is the streak source of truth in live mode.
7. **Images are referenced by Documents-relative paths** (sandbox absolute
   paths change between launches). Cache path = `Media/<storage path>`;
   storage object path = `<vault_id>/<uuid>.jpg`.
8. Swift 5 language mode (`SWIFT_VERSION = 5.0`), deployment target iOS 17.0.
   Don't use APIs newer than iOS 17.0 or stdlib additions newer than Swift 5
   mode allows.

## Architecture (one minute)

```
Views (9 screens) → ViewModels (one per screen) → Service protocols → {Mock | Live}
                          ↘ VaultEngine (pure rules)
Mock → SwiftData + Documents/Media          Live → Supabase + same local store as cache
```

- **Composition root**: `Vault/App/AppDependencies.swift`. `makeMock()` /
  `makeLive(config:)` are the only two wirings; built once in
  `VaultApp.init`, injected via `.environment(...)`. Holds: ModelContainer,
  `VaultEngine`, `AppDateProvider` (injectable clock w/ debug `dayOffset`),
  `AppSession` (currentUser, pendingInviteCode, needsProfileSetup, isReady),
  `DebugSettings`, `AppearanceSettings`, the four services, the seeder,
  `reminders` (ReminderCoordinator), and `isLive`.
- **Services (protocol → mock / live)**: `AuthServiceProtocol`,
  `VaultServiceProtocol`, `DepositServiceProtocol`, `MediaServiceProtocol`.
  All `@MainActor` except Media. Notifications are NOT a service: the
  single notification path is the backend-agnostic per-user
  `ReminderCoordinator` (`Support/DailyReminders.swift`, on `deps.reminders`).
  The old per-vault `NotificationService` was removed once the per-user
  reminder superseded it — Vault Settings' hour picker now only stores the
  vault's `notificationHour`, it doesn't schedule anything.
- **Navigation (v2, multi-vault)**: two tabs — Vaults / Profile. The Vaults
  tab is one `NavigationStack` (`router.vaultsPath`): VaultListView →
  vaultHome(Vault) → archive/detail/settings/userProfile. Home, Archive,
  and Compose view models are vault-scoped (vault passed in init);
  `AppSession.activeVault` no longer exists. Deep link `vault://join/<code>`
  (scheme registered via partial `Config/Info.plist` merged through
  INFOPLIST_FILE — kept OUTSIDE the synchronized folders, otherwise the
  build copies it as a resource too and fails with "Multiple commands
  produce Info.plist") lands in JoinVault prefilled via
  `session.pendingInviteCode`.
- **View pattern**: screen view holds `@State private var viewModel: VM?`,
  creates it in `.onAppear` with `deps` from environment, inner
  `*Content` struct takes `@Bindable var viewModel`.
- **Live sync**: pull-based. Fetch DTOs (PostgREST) → `SupabaseStore`
  reconciles into SwiftData (upsert by id + prune rows gone remotely) →
  views keep rendering the same SwiftData models. Refresh on launch, tab
  task, scenePhase→active, pull-to-refresh, and after mutations.

## Domain rules (precise)

- **dayKey** = `"yyyy-MM-dd"` in device timezone via en_US_POSIX formatter;
  lexicographic == chronological. 23:59 belongs to its day; 00:01 re-locks.
- **Gate**: unlocked today ⟺ deposit exists with (current user, this vault,
  today's dayKey). Gate applies to today only; past days always visible.
  Debug override `DebugSettings.simulateNotPostedToday` forces it shut.
  While locked, image bytes are deliberately never loaded.
- **Once and permanent (v2)**: one deposit per (vault, author, dayKey),
  and it can NEVER be edited, replaced, or deleted. Mock + live both throw
  `DepositError.alreadyDepositedToday` on a second attempt; the DB has no
  update/delete policies on deposits at all. Compose has a mandatory
  confirmation stage ("This is permanent — post it?").
- **Camera-only capture (v3)**: the main deposit flow accepts ONLY a live
  camera capture (`CameraPicker`, a `UIImagePickerController` bridge locked
  to `.camera`; `NSCameraUsageDescription` in `Config/Info.plist`). No
  library/file import in Compose. Simulator has no camera → Compose shows a
  "no camera" state. The profile-picture upload (below) is exempt and still
  uses `PhotosPicker`.
- **Daily reminders (v3)**: per-user local-notification reminders, fully
  backend-agnostic (`Support/DailyReminders.swift`: `ReminderSettings`
  persisted in UserDefaults, `DailyReminderScheduler` over
  `UNUserNotificationCenter`, `ReminderCoordinator` on `deps.reminders`).
  Opt-in toggle + time picker in Profile. Strategy: rolling 7-day window of
  dated non-repeating notifications (1 main + 2 capped follow-ups/day),
  fully rebuilt on each `reminders.refresh()` — called on launch
  (RootViewModel), foreground (VaultApp scenePhase), after a deposit
  (VaultHomeViewModel), and on settings change. Suppresses today once the
  user has uploaded in every vault; respects denied permission.
- **Recovery window (v2)**: when a day ends incomplete, the streak reads 0
  but `VaultEngine.recovery(...)` is non-nil until brokenDayStart+48h
  (== end of the following day). Home shows a live countdown; missing
  members backfill the broken day to restore the streak (recompute over
  full history does the restoration naturally). Window expiry == permanent
  reset (backfill becomes impossible).
- **Streak**: a day counts when every current member deposited OR spent a
  skip token (2 per member, `Membership.skipTokensRemaining`). Count
  consecutive counting days walking back from today if today is complete,
  else from yesterday (in-progress today never breaks a streak). First
  incomplete *ended* day stops the walk. **Subtle verified behavior**: break
  yesterday + complete today = streak of 1 (new chain starts immediately).
  Recomputed on launch and after every deposit; server RPC is canonical in
  live mode.
- **Backfill**: a *past* dayKey can receive a deposit while `now <
  dayStart + 48h` (practically: yesterday). Surfaced in Archive. No special
  streak repair, but full-history recompute naturally sees backfilled days.
- **Invite codes**: 6 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`. Captions:
  ≤80 chars (UI + `VaultEngine.sanitizedCaption` + DB check). Member cap: 8,
  enforced only server-side (`join_vault` RPC). Notification hour default 19.

## Auth (the newest subsystem)

- Protocol surface: `currentState()` → `.signedOut | .needsProfile(suggestedName:) | .signedIn(User)`;
  `requestCode(to: OTPDestination)` (email/phone); `verifyCode`;
  `signInWithApple(idToken:nonce:suggestedName:)`; `completeProfile`;
  `updateProfile`; `signOut`.
- Onboarding is a 4-step state machine in `OnboardingViewModel`:
  welcome cards → method (Apple button / email / phone segmented) → 6-digit
  code (`CodeEntryField`: hidden TextField + 6 boxes, `.oneTimeCode`
  autofill, auto-submit on 6th digit, resend w/ 60s cooldown) → profile
  (name + avatar ink). `AppSession.needsProfileSetup` resumes interrupted
  sign-ups at the profile step (both backends).
- **Live**: GoTrue REST — `POST /auth/v1/otp` (create_user: true),
  `POST /auth/v1/verify` (type "email"/"sms"), Apple via
  `POST /auth/v1/token?grant_type=id_token` with raw nonce (SHA-256 of it
  went into the `ASAuthorizationAppleIDRequest`; see
  `Support/AppleSignInNonce.swift`). Sessions in **Keychain**
  (`KeychainStore`), auto-refresh ~60s before expiry; failed refresh ⇒
  signed out. Apple shares full name only on FIRST authorization →
  prefilled into profile step.
- **Mock**: code is always `123456` (shown in UI in mock mode); identities
  map to local users via UserDefaults keys `vault.mock.identity.*`;
  explicit sign-out sets `vault.mock.signedOutExplicitly` so auto-sign-in
  doesn't undo it; first launch auto-signs-in seeded "You";
  `MockAuthService.resetForReseed()` is called by the seeder's regenerate.
- No identity linking yet (email X + phone Y = two accounts). Apple
  entitlement in `Vault/Vault.entitlements`, wired via
  `CODE_SIGN_ENTITLEMENTS` (requires paid Apple program to sign).

## Live backend facts

- `SupabaseClient` (`Services/Live/`): zero-dep URLSession client for
  GoTrue + PostgREST + Storage. JSON via convertFrom/ToSnakeCase — DTO
  property names must be snake-case-safe (`vaultId` not `vaultID`). Custom
  ISO-8601 date decoding (with/without fractional seconds). Errors surface
  as `ClientError.http(status:message:)`; PostgREST/GoTrue messages parsed
  from `message`/`msg`/`error_description`.
- PostgREST idioms used: `?col=eq.X`, `?id=in.(a,b,c)`
  (`Array<UUID>.postgrestInList`), `Prefer: return=representation`,
  upsert = POST + `on_conflict=` + `resolution=merge-duplicates`,
  PATCH for updates, RPC = POST `/rest/v1/rpc/<fn>`.
- Storage: private bucket `deposits`; upload POST w/ `x-upsert: true`;
  download via `/object/authenticated/...`. RLS gates by first path folder
  (vault UUID).
- Schema: 7 tables (profiles, vaults, memberships, deposits, reactions,
  comments, skips), SECURITY DEFINER helpers (`is_vault_member` etc. — the
  standard fix for RLS recursion), 4 RPCs (`create_vault`, `join_vault`,
  `spend_skip_token`, `recompute_streak`). Deposits insert policy clamps
  dayKey to a UTC-anchored ~48h window.
- Config: `BackendConfig.load()` reads bundled `Supabase.plist`
  (SUPABASE_URL / SUPABASE_ANON_KEY); placeholders ⇒ nil ⇒ mock mode. The
  plist is gitignored; example at `supabase/Supabase.example.plist`. Anon
  key is publishable; RLS is the security boundary.

## Mock world & debug

Seed (first launch, mock only; `Seeding/SeedDataService.swift`): vault
"The Crew" 🏔, code `CREW42`; users You (keeper) / Maya / Sam / Riley with
ink-ramp avatar hexes; 30 days history — misses at offsets −24 (Riley) and
−7 (Maya), skip-token day −14 (Sam, so he has 1 token left) recorded in the
in-memory `SkipLedger` (re-seeded each launch, drifts with real days —
known mock quirk); today seeded so others posted and You didn't ⇒ app opens
LOCKED with streak 6. ~100 placeholder JPEGs generated on-device
(`PlaceholderImageGenerator`, gradient + SF Symbol).
Profile → DEBUG (mock only): gate toggle, advance mock day
(`AppDateProvider.dayOffset`, persisted), regenerate seed (runs behind the
splash via `session.isReady = false` — keep that; it prevents onboarding
flash and views rendering mid-deletion).

## Design system

Adaptive "gallery print" (all in `Support/Theme.swift`): every Theme
constant is a dynamic UIColor — light = warm paper + ink actions; dark =
deep charcoal (never flat black) + paper-white actions. Labels on accent
fills use `Theme.onAccent`. Cards via `.cardSurface()` (hairline + soft
shadow) work in both modes. Appearance: follows the system by default,
with a System/Light/Dark picker in Profile (`AppearanceSettings`,
persisted, applied via `.preferredColorScheme` in VaultApp — no forced
scheme anymore). Identity colors: a curated `AvatarPalette` (6 solids + 2
"hex-hex" gradient tokens, v3 reduced from the larger v2 set), rendered by
`AvatarStyle.fill/base`; chrome stays neutral — members and photos carry
the color. `AvatarView` shows a user's `profilePhotoPaths.first` as the
profile picture when present (v3), else colored initials. Names/avatars are
tappable everywhere via `UserLink` → member profile (photo pager, bio,
shared vaults). Launch: `LaunchRevealView` vault-dial animation in
RootView (reduce-motion aware, waits for bootstrap + min dwell).
Signature interaction: lock→unlock spring reveal + `Haptics.unlock()`.
App icon generated by `tools/generate_icon.swift` (must stay 1024×1024
**opaque** — App Store rejects alpha; no SF Symbols in icons per license).

## Dev environment on THIS machine (important)

- **No Xcode installed** — Command Line Tools only (`xcodebuild` unusable;
  Swift 6.3 toolchain targeting macOS). You cannot build the app or run
  XCTest here. Verification recipes that DO work:
  1. **Parse everything**:
     `for f in $(find Vault VaultTests -name '*.swift'); do swiftc -parse "$f"; done`
  2. **Typecheck the whole non-UI stack** against the macOS SDK: copy
     models/engine/services/Live/viewmodels (not Views, not anything
     importing SwiftUI/UIKit/PhotosUI) to a temp dir, then
     `sed` out SwiftData syntax (`import SwiftData`, `@Model`,
     `@Relationship(...)` lines, `@Attribute(.unique) ` prefix), add
     `: PersistentModel` to the six model classes, and compile alongside a
     ~25-line SwiftData shim (PersistentModel/ModelContext/etc. stubs) plus
     stubs for `Haptics`, `AvatarPalette`, `PlaceholderImageGenerator`.
     This caught real bugs repeatedly — use it after any non-view change.
     (CLT lacks the SwiftDataMacros plugin; Observation macros ARE present.)
  3. **Engine logic harness**: compile `VaultEngine.swift` + a `main.swift`
     of assertions with `swiftc`, run it. Mirrors the XCTests.
- The pbxproj uses **Xcode 16 synchronized folders** (objectVersion 77):
  files dropped into `Vault/` / `VaultTests/` join the build automatically —
  never hand-edit file lists into the pbxproj. Build-setting edits are done
  by string replacement (both Debug and Release blocks!).
- Git: repo root is the PARENT directory (`~/Desktop/dev`), project lives in
  `dev/Vault/`. Don't commit unless asked.

## Gotchas learned the hard way

- `.kerning()` is a `Text`-only modifier — not TextField/View.
- `RoundedRectangle().fill(x).strokeBorder(y)` chaining requires the iOS 17
  ShapeView API — fine at our floor, don't lower the target.
- Avoid `count(where:)` (Swift 6 stdlib back-deploy ambiguity in 5 mode) —
  use `filter{}.count`.
- The app module and the `Vault` model class share a name — fine in-module;
  avoid `Vault.X` qualifications that could mean the module; tests must not
  reference the `Vault` type (they don't need to).
- Memberwise-init defaults: optional `var` stored properties get nil
  defaults (SE-0242) — `PrimaryButton(title:action:)` relies on it.
- JSONEncoder snake_case strategy mangles `ID` suffixes → DTOs use `Id`.
- Seeded streak math: today-incomplete is normal state after seeding; if the
  app is relaunched days later, the missed-gap behavior is realistic (streak
  resets) — not a bug.
- `LocalDepositImage` must reload when the path changes (remote sync can
  re-path a row). Don't "optimize" back to `guard image == nil`.
- User model carries `bio: String?` + `profilePhotoPaths: [String]` (≤3,
  "Media/avatars/<user_id>/…"); profiles table mirrors with `bio` +
  `photo_paths jsonb`. Storage bucket "deposits" has TWO path namespaces:
  "<vault_uuid>/…" (membership-gated) and "avatars/<user_id>/…" (read: any
  signed-in user; write: owner only) — policies guard the uuid cast with
  `try_uuid()`.
- Mermaid renders on GitHub; OVERVIEW.md depends on it.

## Verified vs not (be honest about this in any session)

Verified: all files `swiftc -parse` clean; full non-UI stack typechecks via
the shim recipe; engine rules executed against assertion harness (all
scenarios incl. midnight boundary, skip tokens, replacement, backfill
window, fresh-streak-after-break); icon is 1024 opaque RGB; pbxproj
hand-validated.
**Not verified**: SwiftUI view layer compilation (needs Xcode), any HTTP
against a real Supabase project (likely friction: `/verify` response shape,
Apple id_token grant, error pass-through), Apple sign-in end-to-end (needs
paid account + provider config), SMS (needs Twilio). DEPLOYMENT.md's last
section tracks this.

## Conventions

- Comments explain constraints/whys, not whats; `// TODO: BACKEND — <what>`
  marks every server-integration point (grep for it).
- Errors: services throw typed `LocalizedError` enums (`AuthError`,
  `VaultServiceError`); view models catch and expose `errorMessage: String?`.
- Keep README/OVERVIEW/DEPLOYMENT in sync with behavior changes; they are
  part of the deliverable, not an afterthought.
