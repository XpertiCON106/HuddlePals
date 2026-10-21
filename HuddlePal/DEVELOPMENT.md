# HuddlePals — developer reference

This file gets a new contributor productive immediately. Read it fully, then
consult [OVERVIEW.md](OVERVIEW.md) for the deep narrative (diagrams of every
flow), [README.md](README.md) for quick start, [DEPLOYMENT.md](DEPLOYMENT.md)
for the go-live runbook, and [supabase/schema.sql](supabase/schema.sql) for
the entire backend. Those four docs are accurate and maintained — when you
change behavior, update them.

## What this is

**HuddlePals** — a private, daily photo-sharing iOS app for groups of 2–8. One
photo per member per day; today's photos from others stay blurred until you
deposit your own (the "reciprocity gate"); streaks belong to the group.
SwiftUI, iOS 17.0+, Xcode 16 project, **zero third-party dependencies**.
Dual-backend: a seeded offline **mock** world and a **live** Supabase backend
behind identical service protocols — the app picks at launch based on whether
`HuddlePal/HuddlePal/Supabase.plist` exists with real values.

**Project status (as of 2026-10-19):** v1.0 (build 1), bundle id
`com.huddlepals.ios`, heading to TestFlight from the `test-flight` branch.
Builds and passes its XCTests in Xcode 26.1.1. A real Supabase project now
exists and is being exercised by hand; fixes from that so far include
lowercase avatar paths, the reports select policy, and the
`extensions.gen_random_bytes` qualifier. The live layer is still the least
battle-tested part — see "Verified vs not" below.

## Hard constraints — never violate

1. **Zero third-party dependencies.** Apple frameworks + raw URLSession only.
   Do not add SPM packages (not even supabase-swift) without explicit owner
   approval.
2. **Views never touch services.** Views render view-model state and forward
   taps. Only `@Observable @MainActor` view models call services. (Sanctioned
   exception: `LocalDepositImage` resolves image bytes via
   `deps.mediaService` as a display concern.)
3. **`HuddleEngine` stays pure.** No SwiftData, no UIKit, no `Date()`/wall
   clock — calendar and `now` are always injected. It operates on
   `DepositSnapshot` values, never models.
4. **Mock and live implement the same protocols with the same semantics.**
   Any protocol change must update both, plus call sites.
5. **Observation framework only** (`@Observable`) — no ObservableObject, no
   Combine.
6. **Business-rule changes must be mirrored in three places**: `HuddleEngine`
   (client), `supabase/schema.sql` (constraints + `recompute_streak` RPC),
   and `HuddlePalTests`. The server is the streak source of truth in live mode.
7. **Images are referenced by Documents-relative paths** (sandbox absolute
   paths change between launches). Cache path = `Media/<storage path>`;
   storage object path = `<huddle_id>/<uuid>.jpg`. In live mode a huddle
   photo's bytes — in Storage *and* in the cache — are ciphertext (see
   "End-to-end encrypted photos"); never upload one through the plaintext
   `saveImageData`, which is for profile photos only.
8. Swift 5 language mode (`SWIFT_VERSION = 5.0`), deployment target iOS 17.0.
   Don't use APIs newer than iOS 17.0 or stdlib additions newer than Swift 5
   mode allows.

## Architecture (one minute)

```
Views (9 screens) → ViewModels (one per screen) → Service protocols → {Mock | Live}
                          ↘ HuddleEngine (pure rules)
Mock → SwiftData + Documents/Media          Live → Supabase + same local store as cache
```

- **Composition root**: `HuddlePal/App/AppDependencies.swift`. `makeMock()` /
  `makeLive(config:)` are the only two wirings; built once in
  `HuddlePalApp.init`, injected via `.environment(...)`. Holds: ModelContainer,
  `HuddleEngine`, `AppDateProvider` (injectable clock w/ debug `dayOffset`),
  `AppSession` (currentUser, blockedUserIDs, pendingInviteCode,
  needsProfileSetup, isReady), `DebugSettings`, `AppearanceSettings`, the
  five services, the seeder, `reminders` (ReminderCoordinator), and `isLive`.
- **Services (protocol → mock / live)**: `AuthServiceProtocol`,
  `HuddleServiceProtocol`, `DepositServiceProtocol`, `MediaServiceProtocol`,
  `ModerationServiceProtocol` (report/block, UGC safeguards).
  All `@MainActor` except Media. Live mode adds `LivePhotoKeyring` (E2EE
  keys), shared by the live services and deliberately NOT a protocol: the
  mock has no server to hide photos from, so it has nothing to mirror. Notifications are NOT a service: the
  single notification path is the backend-agnostic per-user
  `ReminderCoordinator` (`Support/DailyReminders.swift`, on `deps.reminders`).
  The old per-huddle `NotificationService` was removed once the per-user
  reminder superseded it — Huddle Settings' hour picker now only stores the
  huddle's `notificationHour`, it doesn't schedule anything.
- **Navigation (v2, multi-huddle)**: two tabs — Huddles / Profile. The Huddles
  tab is one `NavigationStack` (`router.huddlesPath`): HuddleListView →
  huddleHome(Huddle) → archive/detail/settings/userProfile. Home, Archive,
  and Compose view models are huddle-scoped (huddle passed in init);
  `AppSession.activeHuddle` no longer exists. Deep link `huddlepal://join/<code>`
  (scheme registered via partial `Config/Info.plist` merged through
  INFOPLIST_FILE — kept OUTSIDE the synchronized folders, otherwise the
  build copies it as a resource too and fails with "Multiple commands
  produce Info.plist") lands in JoinHuddle prefilled via
  `session.pendingInviteCode`.
- **View pattern**: screen view holds `@State private var viewModel: VM?`,
  creates it in `.onAppear` with `deps` from environment, inner
  `*Content` struct takes `@Bindable var viewModel`.
- **Live sync**: pull-based. Fetch DTOs (PostgREST) → `SupabaseStore`
  reconciles into SwiftData (upsert by id + prune rows gone remotely) →
  views keep rendering the same SwiftData models. Refresh on launch, tab
  task, scenePhase→active, pull-to-refresh, and after mutations.
  The **huddle list is deliberately light**: huddle rows + one
  `depositorIDs(in:dayKey:)` read for all huddles, and a streak recompute
  at most once per huddle per dayKey (`HuddleListViewModel`). Full history
  (deposits + reactions + comments + any uncached profiles) syncs only in
  `deposits(in:)`, i.e. when Home/Archive opens. Don't put a per-huddle
  full sync back into the list — it runs on every foreground.

## Domain rules (precise)

- **dayKey** = `"yyyy-MM-dd"` in device timezone via en_US_POSIX formatter;
  lexicographic == chronological. 23:59 belongs to its day; 00:01 re-locks.
- **Gate**: unlocked today ⟺ deposit exists with (current user, this huddle,
  today's dayKey). Gate applies to today only; past days always visible.
  Debug override `DebugSettings.simulateNotPostedToday` forces it shut.
  While locked, image bytes are deliberately never loaded.
- **Once and permanent (v2)**: one deposit per (huddle, author, dayKey),
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
  (RootViewModel), foreground (HuddlePalApp scenePhase), after a deposit
  (HuddleHomeViewModel), and on settings change. Suppresses today once the
  user has uploaded in every huddle; respects denied permission.
- **Account deletion — Model B (v4)**:
  `AuthServiceProtocol.deleteAccount(appleAuthorizationCode:)`, after Apple
  confirms the person (`AppleReauthenticating`). Live = the
  `supabase/functions/delete-account` edge function (revokes the app's Apple
  tokens, deletes avatar objects, releases the user's deposit photos,
  `auth.admin.deleteUser`); see "Account deletion and Apple token
  revocation" below. Deposited photos
  are PERMANENT and stay as "Former member" — this is why `deposits.author_id`
  / `comments.user_id` are nullable + `ON DELETE SET NULL`. Client side the
  matching DTO fields are optional, and `SupabaseStore` keeps any row whose
  author can't be resolved with a nil author/user (rendered "Former
  member") — that also covers members who *left*, whose profiles RLS hides.
  Former-member photos stay reportable (not blockable). Required by App Store
  5.1.1(v); reconciles with the permanence promise (account deletes, content
  stays). UI: Profile → Delete account (confirmation states the deal).
- **End-to-end encrypted photos (v5, live only)**: the operator must not
  be able to view deposits. `Services/Live/PhotoCrypto.swift` (CryptoKit
  only): per-user Curve25519 identity key (private half in the Keychain,
  `IdentityKeychain`, service `com.huddlepals.ios.identity`,
  synchronizable + AfterFirstUnlock, one item per user; deleted only on
  account deletion, never sign-out; public half in `user_keys`) → per-huddle
  256-bit huddle key, stored per member in `huddle_keys` wrapped to their
  identity key (ephemeral X25519 → HKDF-SHA256 with huddle + recipient ids →
  AES-GCM) → per-photo key: the JPEG is AES-GCM sealed with it (the
  `combined` box is the Storage object, uploaded as
  `application/octet-stream`, ≤ 5 MB checked on the ciphertext) and the
  photo key is sealed with the huddle key into
  `deposits.wrapped_photo_key` (`enc_version` 1). `LivePhotoKeyring` holds
  unwrapped huddle keys in memory only and `sync(huddleIDs:)` runs on huddle
  create, huddle open (`deposits(in:)`, awaited), and every huddle-list
  refresh (foreground; a detached Task): unwrap own copies → for a huddle
  with no copy at all, `init_huddle_key` (refuses once any current member
  holds one — a key is shared, never replaced) → `huddle_key_recipients` +
  `share_huddle_key` for members with no copy or a stale one (wrapped for a
  public key they've since replaced). Identity: created on first sign-in
  on a device; if the server holds a different public key (lost key, or
  another device without iCloud Keychain), this device publishes its own
  and members re-share. Display: `LocalDepositImage(deposit:)` →
  `loadDepositPhoto` (cache-only huddle key, no network) → nil shows the
  locked placeholder "Waiting for a huddle member to share access", retried
  whenever the keyring bumps `session.photoKeysVersion`. Reports attach that
  one photo's key (`reports.photo_key`); operators decrypt with
  `tools/decrypt_reported_photo`. Mock mode stores photos as-is
  (`wrappedPhotoKey` nil). NOT encrypted: captions, comments, reactions,
  profiles, avatars, all metadata.
- **Moderation — report/block (v4, UGC req. 1.2)**: `ModerationServiceProtocol`
  (+ Mock/Live). `reports` + `blocks` tables. Blocked ids live in
  `session.blockedUserIDs` (loaded at sign-in/launch; mutated by block
  actions). Filtering is PRESENTATIONAL only — HuddleHome/Archive/DepositDetail
  hide blocked authors' deposits/comments, but the gate/streak math uses the
  UNFILTERED set (blocking never changes membership or streaks; that's why
  HuddleHomeViewModel keeps `todayDepositorIDs` separate). UI: "•••" menu on
  DepositDetail (report + block) and UserProfileView (block/unblock).
- **Image downscaling (v4)**: `Support/ImageDownscaler.swift` — deposits
  ≤1440px, avatars ≤512px, JPEG 0.8, applied in ComposeViewModel +
  ProfileViewModel before upload. Critical because storage is permanent and
  only grows. Don't remove it.
- **Confirmed profile drafts**: `ProfileViewModel` owns an immutable
  normalized original snapshot plus a separate working draft for name, bio,
  avatar color, and ordered profile photos. New photos are downscaled and
  fingerprinted in memory but are not uploaded until the native **Confirm
  Changes** alert is accepted. A failed save retains the draft (and any
  staged upload path for retry); a successful full profile update alone
  advances the original snapshot. Leaving the Profile tab, signing out,
  deleting the account, or following a deep link is intercepted while dirty
  before navigation state changes. No destination is queued: Keep Editing
  preserves the draft, while Discard restores the saved snapshot and stays
  on Profile; leaving afterward requires a new navigation attempt.
- **Backend security hardening (v4, in schema.sql — must be re-run on live)**:
  `spend_skip_token` acts on `auth.uid()` only (was an IDOR); invite codes use
  `gen_random_bytes` (pgcrypto); a column grant + `recompute_streak` p_today
  clamp stop streak forgery; update policies have `WITH CHECK`. App side:
  Keychain is `…ThisDeviceOnly`; `BackendConfig` requires https;
  `ClientError.http.errorDescription` is generic (raw `message` kept for
  service mapping); the mock OTP `print` is `#if DEBUG`.
- **Recovery window (v2)**: when a day ends incomplete, the streak reads 0
  but `HuddleEngine.recovery(...)` is non-nil until brokenDayStart+48h
  (== end of the following day). Home shows a live countdown; missing
  members backfill the broken day to restore the streak (recompute over
  full history does the restoration naturally). Window expiry == permanent
  reset (backfill becomes impossible).
- **Streak**: a day counts when every member it *waits on* deposited OR
  spent a skip token (2 per member, `Membership.skipTokensRemaining`).
  A day waits on current members whose join day is strictly earlier
  (`HuddleEngine.requiredMembers`): the join day is free, so joining never
  breaks a streak (it used to reset it to 0). A day that waits on nobody
  never counts — a new huddle's first counting day is the day after
  creation. Join days: `Membership.joinedDayKey` (device-local, sent as
  `p_day_key` to `create_huddle`/`join_huddle`, stored as
  `memberships.joined_day_key`); `Huddle.memberJoinDayKeys(using:)` feeds the
  engine and falls back to `joinedAt` for older rows. Count
  consecutive counting days walking back from today if today is complete,
  else from yesterday (in-progress today never breaks a streak). First
  incomplete *ended* day stops the walk. **Subtle verified behavior**: break
  yesterday + complete today = streak of 1 (new chain starts immediately).
  Recomputed when a deposit lands and once per huddle per day from the huddle
  list; server RPC (`recompute_streak` → `huddle_day_complete`) is canonical
  in live mode.
- **Backfill**: a *past* dayKey can receive a deposit while `now <
  dayStart + 48h` (practically: yesterday). Surfaced in Archive. No special
  streak repair, but full-history recompute naturally sees backfilled days.
- **Invite codes**: 6 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`. Captions:
  ≤80 chars (UI + `HuddleEngine.sanitizedCaption` + DB check). Member cap: 8,
  enforced only server-side (`join_huddle` RPC). Notification hour default 19.

## Auth (the newest subsystem)

- **Currently Apple-only.** `FeatureFlags.emailAndPhoneSignInEnabled`
  (`HuddlePal/FeatureFlags.swift`) is `false`: the email/phone UI is hidden but
  all its code remains; set it to `true` to restore all three methods.
- Protocol surface: `currentState()` → `.signedOut | .needsProfile(suggestedName:) | .signedIn(User)`;
  `requestCode(to: OTPDestination)` (email/phone); `verifyCode`;
  `signInWithApple(idToken:nonce:suggestedName:)`; `completeProfile`;
  `updateProfile`; `signOut`.
- **Terms of Service gate (v6)**: the first screen anyone sees is the full
  Terms (`Legal/TermsOfService.md`, bundled, rendered by
  `TermsDocumentView`) with Agree / Decline. Agree stays disabled until the
  reader scrolls to the end (an end marker measured inside the ScrollView,
  so the text is a plain VStack, not lazy; required again each time the
  Terms are shown). Agree records the version
  (`TermsOfService.version`, the Terms' effective date) and a wall-clock
  timestamp in UserDefaults (`TermsAcceptance` on `deps.terms`). Decline
  returns to the first welcome card, and "Get started" brings the Terms back,
  so nothing past the welcome cards opens without Agree. RootView also
  withholds `MainTabView` from a restored session until the current version
  is accepted. Any material edit to the Terms must bump
  `TermsOfService.version` (a test checks it against "Last updated") so
  everyone agrees again; host the same text at huddlepals.com/terms.
  Profile → About → Terms of Service shows it read-only, with the agreement
  date. Acceptance is device-local, not yet recorded on the server.
- Onboarding is a 5-step state machine in `OnboardingViewModel`: Terms →
  welcome cards → method (Apple button / email / phone segmented; phone
  defaults to +1 — `AuthValidation.normalizedPhone` / `formattedPhoneInput`,
  "+…" for other countries) → verification code (`CodeEntryField`: hidden
  TextField + `length` boxes from `AuthServiceProtocol.codeLength(for:)` —
  live reads `EMAIL_OTP_LENGTH` / `SMS_OTP_LENGTH` from `Supabase.plist`,
  default 6, and they must match the Supabase project; `.oneTimeCode`
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
  map to local users via UserDefaults keys `huddlepal.mock.identity.*`;
  explicit sign-out sets `huddlepal.mock.signedOutExplicitly` so auto-sign-in
  doesn't undo it; first launch auto-signs-in seeded "You";
  `MockAuthService.resetForReseed()` is called by the seeder's regenerate.
- No identity linking yet (email X + phone Y = two accounts). Apple
  entitlement in `HuddlePal/HuddlePal.entitlements`, wired via
  `CODE_SIGN_ENTITLEMENTS` (requires paid Apple program to sign).

## Live backend facts

- `SupabaseClient` (`Services/Live/`): zero-dep URLSession client for
  GoTrue + PostgREST + Storage. JSON via convertFrom/ToSnakeCase — DTO
  property names must be snake-case-safe (`huddleId` not `huddleID`). Custom
  ISO-8601 date decoding (with/without fractional seconds). Errors surface
  as `ClientError.http(status:message:)`; PostgREST/GoTrue messages parsed
  from `message`/`msg`/`error_description`.
- PostgREST idioms used: `?col=eq.X`, `?id=in.(a,b,c)`
  (`Array<UUID>.postgrestInList`), `Prefer: return=representation`,
  upsert = POST + `on_conflict=` + `resolution=merge-duplicates`,
  PATCH for updates, RPC = POST `/rest/v1/rpc/<fn>`.
- Storage: private bucket `deposits` (5 MB; MIME types `image/jpeg` for
  avatars + `application/octet-stream` for encrypted huddle photos); upload is a plain insert POST —
  **never send `x-upsert`**: every path is a fresh UUID, an upsert needs an
  UPDATE policy that huddle paths don't (and mustn't) have, and overwriting
  a photo would break permanence. Download via `/object/authenticated/...`.
  RLS gates by first path folder (huddle UUID, or `avatars/<user_id>`).
- Schema: 11 tables (profiles, huddles, memberships, deposits, reactions,
  comments, skips, reports, blocks, user_keys, huddle_keys), SECURITY DEFINER helpers (`is_huddle_member` etc. — the
  standard fix for RLS recursion), 7 RPCs (`create_huddle`, `join_huddle`,
  `spend_skip_token`, `recompute_streak`, `init_huddle_key`,
  `huddle_key_recipients`, `share_huddle_key`). `huddle_keys` has a
  select-own policy only; its writers are the two key RPCs (an upsert of a
  row you can't SELECT fails under RLS). `schema.sql` builds a fresh
  database; `supabase/migrations/` (001–007, see its README) upgrades the
  one already deployed, and `supabase/scripts/reset_database.sql` wipes an
  older database so `schema.sql` can run fresh. Deposits insert policy clamps
  dayKey to a UTC-anchored ~48h window.
- Config: `BackendConfig.load()` reads bundled `Supabase.plist`
  (SUPABASE_URL / SUPABASE_ANON_KEY); placeholders ⇒ nil ⇒ mock mode. The
  plist is gitignored; example at `supabase/Supabase.example.plist`. Anon
  key is publishable; RLS is the security boundary.

## Account deletion and Apple token revocation

App Review guideline 5.1.1(v): deleting an account that signed in with
Apple must revoke the app's Apple tokens. How it runs (QA-20):

1. Profile → **Delete account** → confirm. The app then shows Apple's own
   sheet (`SystemAppleReauthenticator`, Face ID or passcode) for a fresh
   authorization code. Closing the sheet deletes nothing. If Apple can't
   confirm (no Apple Account on the device, Apple unreachable), the app
   offers **Delete account anyway** without a code, because deletion must
   stay possible (Apple TN3194), and says where to remove HuddlePals from
   Sign in with Apple by hand. Mock mode uses `MockAppleReauthenticator`.
2. `LiveAuthService.deleteAccount(appleAuthorizationCode:)` POSTs
   `{"authorization_code": "…"}` to `functions/v1/delete-account`.
3. The edge function (`supabase/functions/delete-account/`: `index.ts`
   wires Supabase in, `handler.ts` runs the steps, `apple.ts` talks to
   Apple):
   - signs a client secret (ES256 JWT, 5 minutes) with the Sign in with
     Apple key;
   - exchanges the code at `https://appleid.apple.com/auth/token`;
   - checks the ID token's `sub` is this user's Apple ID;
   - revokes the refresh token at `https://appleid.apple.com/auth/revoke`;
   - deletes `avatars/<user id>/…`;
   - calls `release_storage_objects` (migration 007), so the user's deposit
     photos stop pointing at them and can't block the deletion;
   - calls `auth.admin.deleteUser`.

   An Apple failure is logged (`apple_revoke_failed …`) and the deletion
   still completes. Codes, tokens and the key are never logged, and the
   app never sees Supabase's error detail.

### One-time setup: the Sign in with Apple key

1. [developer.apple.com](https://developer.apple.com/account) →
   Certificates, Identifiers & Profiles → **Keys** → **+**.
2. Give it a name (e.g. "HuddlePals token revocation"), tick **Sign in with
   Apple**, click **Configure**, pick the primary App ID
   `com.huddlepals.ios`, then **Save** → **Continue** → **Register**.
3. **Download** `AuthKey_<KEY_ID>.p8`. Apple offers the download once, so
   keep it in a password manager. It never goes in the repo. The
   10-character **Key ID** is shown on the key's page.
4. The 10-character **Team ID** is under Account → **Membership details**.

### Set the secrets

They live only in Supabase's edge function secrets. `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` are injected automatically. With the Supabase
CLI logged in (`supabase login`), set the four Apple secrets:

```bash
supabase secrets set --project-ref <project-ref> APPLE_TEAM_ID=<TEAM_ID> APPLE_KEY_ID=<KEY_ID> APPLE_CLIENT_ID=com.huddlepals.ios
```

```bash
supabase secrets set --project-ref <project-ref> APPLE_PRIVATE_KEY="$(cat /path/to/AuthKey_<KEY_ID>.p8)"
```

```bash
supabase secrets list --project-ref <project-ref>
```

- `APPLE_CLIENT_ID` is the **bundle ID**: the codes come from the native
  app, so Apple issued them to it. A Services ID is only for web sign-in.
- The key may keep its real newlines or use `\n` escapes; both work.
- Dashboard alternative: Edge Functions → **Secrets**.
- Without these secrets, deletion still works but logs
  `apple_revoke_skipped: APPLE_* secrets not set`.

### Deploy

1. **Database first.** On the existing project, run
   `supabase/migrations/007_qa20_release_storage_objects.sql` in the SQL
   editor. A fresh project gets it from `schema.sql`. Without it, the
   release step logs `storage_release_failed`. Then, on Storage versions
   that still have `objects_owner_fkey`, `deleteUser` fails for anyone who
   ever posted.
2. **Then the function.** From `HuddlePal/`:

   ```bash
   supabase functions deploy delete-account --project-ref <project-ref>
   ```

   This uploads `index.ts` together with `handler.ts` and `apple.ts`. Leave
   JWT verification on (the default), since the function acts only for the
   caller's own access token.

### Check it once on a device (TestFlight)

1. Sign in with Apple using a test Apple Account, then deposit a photo in a
   huddle shared with a second account.
2. Profile → Delete account → confirm → Face ID.
3. Supabase → Edge Functions → `delete-account` → Logs should show
   `apple_revoked` and no `…_failed` lines.
4. On the phone, HuddlePals should be gone from Settings › your name ›
   Sign-In & Security › Sign in with Apple.
5. The user should be gone from Authentication → Users, and the second
   account still sees the photo as "Former member".

### Tests

`cd supabase/tests && npm test` runs these checks (Node 22.18+ runs the
function's TypeScript directly; nothing reaches Apple or Supabase):

- `delete-account.test.mjs`:
  - the client secret, with its signature verified against the key's
    public half;
  - the exact `/auth/token` and `/auth/revoke` requests;
  - deletion going ahead when Apple refuses or can't be reached;
  - nothing secret in the logs;
  - a failed `deleteUser` returning a 500 with no detail.
- `rpc.test.mjs`: `release_storage_objects` can only be run by the service
  role, it unblocks `deleteUser` under `objects_owner_fkey`, and the
  photos stay.

On the app side:

- `ProfileConfirmationTests`: the Apple step, cancelling it, and the
  fallback.
- `LiveServiceTests`: the request body.
- `UnhappyPathTests.testDeletingWhenAppleCantConfirmStillWorks`: the
  fallback dialog.

Apple's real servers and sheet are not covered; do the device check above.

## Mock world & debug

Seed (first launch, mock only; `Seeding/SeedDataService.swift`): huddle
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
persisted, applied via `.preferredColorScheme` in HuddlePalApp — no forced
scheme anymore). Identity colors: a curated `AvatarPalette` (6 solids + 2
"hex-hex" gradient tokens, v3 reduced from the larger v2 set), rendered by
`AvatarStyle.fill/base`; chrome stays neutral — members and photos carry
the color. `AvatarView` shows a user's `profilePhotoPaths.first` as the
profile picture when present (v3), else colored initials. Names/avatars are
tappable everywhere via `UserLink` → member profile (photo pager, bio,
shared huddles). Launch: `LaunchRevealView` hug-mark animation in
RootView (reduce-motion aware, waits for bootstrap + min dwell).
Signature interaction: lock→unlock spring reveal + `Haptics.unlock()`.
App icon generated by `tools/generate_icon.swift` (must stay 1024×1024
**opaque** — App Store rejects alpha; no SF Symbols in icons per license).

## Dev environment on THIS machine (important)

- **Xcode 26.1.1** is installed at `/Applications/Xcode.app`, but
  `xcode-select` still points at the Command Line Tools, so a bare
  `xcodebuild` fails. Prefix commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (or switch it
  once yourself with `sudo xcode-select -s /Applications/Xcode.app`).
  Full test run (database suite + unit + UI tests): `scripts/test-all.sh`.
  It passes `EXCLUDED_SOURCE_FILE_NAMES=Supabase.plist` so no test build
  bundles the live config; do the same for any hand-run `xcodebuild`.
- Debug builds without `Supabase.plist` run the mock world; Release builds
  refuse to build without a real one (build-phase guard in the pbxproj).
- The pbxproj uses **Xcode 16 synchronized folders** (objectVersion 70):
  files dropped into `HuddlePal/` / `HuddlePalTests/` join the build automatically —
  never hand-edit file lists into the pbxproj. Build-setting edits are done
  by string replacement (both Debug and Release blocks!).
- Git: repo root is `~/Desktop/dev/HuddlePals`; the Xcode project lives in its
  `HuddlePal/` subfolder, so app sources are `HuddlePal/HuddlePal/…`.

## Gotchas learned the hard way

- `.kerning()` is a `Text`-only modifier — not TextField/View.
- `RoundedRectangle().fill(x).strokeBorder(y)` chaining requires the iOS 17
  ShapeView API — fine at our floor, don't lower the target.
- Avoid `count(where:)` (Swift 6 stdlib back-deploy ambiguity in 5 mode) —
  use `filter{}.count`.
- The app module is `HuddlePal` and the SwiftData model is `Huddle`.
  `@testable import HuddlePal` loads the module; `Huddle.memberJoinDayKeys`
  is the model.
- Memberwise-init defaults: optional `var` stored properties get nil
  defaults (SE-0242) — `PrimaryButton(title:action:)` relies on it.
- JSONEncoder snake_case strategy mangles `ID` suffixes → DTOs use `Id`.
  Anything that round-trips (encoded *and* decoded by us) is the dangerous
  case: `SupabaseClient.Session.userID` encoded as "user_id", never decoded
  back, and silently signed everyone out on every relaunch. It's `userId`
  now, with a round-trip test in `AuthInputTests`.
- A DTO field for a column the DB can null (`deposits.author_id`,
  `comments.user_id`) must be optional: one null in a non-optional field
  fails decoding of the *whole* response, not just that row.
- Seeded streak math: today-incomplete is normal state after seeding; if the
  app is relaunched days later, the missed-gap behavior is realistic (streak
  resets) — not a bug.
- `LocalDepositImage` must reload when the path changes (remote sync can
  re-path a row). Don't "optimize" back to `guard image == nil`. For huddle
  photos (`init(deposit:)`) a failed load is NOT final: the task id
  includes `session.photoKeysVersion`, so a locked photo retries when a key
  arrives. `photoKeysVersion` is the one `AppSession` field a service
  (`LivePhotoKeyring`) writes.
- E2EE wire formats are pinned by DB check constraints: public keys are
  44-char base64 (32 raw bytes), wrapped keys 80-char base64 (60-byte
  AES-GCM combined box). HKDF info uses lowercased UUIDs (Postgres prints
  them lowercase, Swift uppercase).
- User model carries `bio: String?` + `profilePhotoPaths: [String]` (≤3,
  "Media/avatars/<user_id>/…"); profiles table mirrors with `bio` +
  `photo_paths jsonb`. Storage bucket "deposits" has TWO path namespaces:
  "<huddle_uuid>/…" (membership-gated) and "avatars/<user_id>/…" (read: any
  signed-in user; write: owner only) — policies guard the uuid cast with
  `try_uuid()`.
- Mermaid renders on GitHub; OVERVIEW.md depends on it.

## Verified vs not

Verified: the app builds in Xcode 26.1.1 and the full XCTest suite passes
on the iPhone 17 Pro simulator (engine rules, critical mock flows,
`SupabaseStore` reconciliation incl. Former member, profile editor,
E2EE crypto + identity Keychain); icon
is 1024 opaque RGB.
**Not verified by tests**: anything over HTTP. The live layer is being
exercised by hand against the real project, but these still deserve a
deliberate pass: OTP `/verify` response shape, Apple id_token grant, the
`delete-account` edge function end-to-end, a Former-member photo after
deleting a test account, posting a photo (insert-only uploads), the
huddle list's `select=huddle_id,author_id` read, and the join-day streak
SQL (never executed against Postgres — no local database here). Likewise
the end-to-end encryption SQL in `schema.sql` and
`supabase/scripts/reset_database.sql` have not been run against Postgres
here; the CryptoKit layer is unit-tested
(`PhotoEncryptionTests`), the key sharing between two real accounts is
not. Apple sign-in needs the paid
account + provider config; SMS needs Twilio. DEPLOYMENT.md's last section
tracks this.

## Conventions

- Comments explain constraints/whys, not whats; `// TODO: BACKEND — <what>`
  marks every server-integration point (grep for it).
- Errors: services throw typed `LocalizedError` enums (`AuthError`,
  `HuddleServiceError`); view models catch and expose `errorMessage: String?`.
- Keep README/OVERVIEW/DEPLOYMENT in sync with behavior changes; they are
  part of the deliverable, not an afterthought.
