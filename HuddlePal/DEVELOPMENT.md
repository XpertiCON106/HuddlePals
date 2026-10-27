# HuddlePals — developer reference

What you need to work on the app safely. [OVERVIEW.md](OVERVIEW.md) has the
long narrative and diagrams, [README.md](README.md) the quick start,
[DEPLOYMENT.md](DEPLOYMENT.md) the go-live runbook, and
[supabase/schema.sql](supabase/schema.sql) the whole backend. Keep all four
in sync when behaviour changes.

## At a glance

- **The app**: private daily photo sharing for small groups ("huddles"):
  up to 4 people on the free plan, 10 when the keeper has HuddlePals Plus.
  One photo per member per day (or, with Plus, a video of up to 6 seconds);
  others' stay blurred until you post yours (the gate); the streak belongs
  to the group; deposits are permanent.
- **Build**: version 1.0, bundle id `com.huddlepals.ios`, iOS 17.0+,
  Swift 5 language mode, SwiftUI + SwiftData, **no third-party
  dependencies**. Built with Xcode 26.1.1.
- **Two backends, one app**: a seeded offline **mock** world and a **live**
  Supabase backend behind the same service protocols. The app goes live
  when a filled-in `HuddlePal/HuddlePal/Supabase.plist` is bundled (it's
  git-ignored; example in `supabase/Supabase.example.plist`).
- **Careful**: the `Supabase.plist` on this machine points at
  **production**, which holds a family's real data. Never run tests or
  demos against it; every test build excludes it (below).
- **Sign-in**: Apple only (`FeatureFlags.emailAndPhoneSignInEnabled` is
  `false`; the email/phone code stays, hidden).

## Rules you must not break

1. **No third-party dependencies.** Apple frameworks and `URLSession` only,
   unless the owner says otherwise.
2. **Views never call services.** Only `@Observable @MainActor` view models
   do. (One exception: `LocalDepositImage` loads image bytes for display.)
3. **`HuddleEngine` stays pure**: no SwiftData, UIKit or wall clock;
   calendar and `now` are injected, and it works on `DepositSnapshot`
   values.
4. **Mock and live mean the same thing.** A protocol change updates both
   and every call site.
5. **Observation only** (`@Observable`): no `ObservableObject`, no Combine.
6. **A business rule lives in three places**: `HuddleEngine`,
   `supabase/schema.sql` (the server is canonical for streaks in live
   mode), and the tests.
7. **Images are stored by Documents-relative path** (`Media/<storage
   path>`); a huddle photo is `<huddle_id>/<uuid>.jpg`. In live mode huddle
   photos are ciphertext, in Storage and in the cache; never upload one
   through `saveImageData`, which is for profile photos only.
8. **No API newer than iOS 17.0**, and nothing Swift 5 mode doesn't allow.

## Architecture

```
Views → ViewModels (one per screen) → service protocols → Mock | Live
              ↘ HuddleEngine (pure rules)
Mock: SwiftData + Documents/Media      Live: Supabase, with the same store as a cache
```

- **Composition root**: `App/AppDependencies.swift`. `makeMock()` and
  `makeLive(config:)` are the only wirings, built once in
  `HuddlePalApp.init` and passed through the environment. It holds the
  model container, engine, clock (`AppDateProvider`), `AppSession`, debug
  and appearance settings, Terms acceptance, the services, the seeder,
  `reminders` and `push`.
- **`AppSession`**: `currentUser`, `blockedUserIDs`, `pendingInviteCode`
  (from a `huddlepal://join/…` link), `pendingHuddleID` (from a tapped
  notification), `needsProfileSetup`, `isReady`, and `photoKeysVersion`
  (the one field a service writes: the keyring bumps it so locked photos
  retry).
- **Services**:

  | Protocol | Mock | Live |
  |---|---|---|
  | `AuthServiceProtocol` | code `123456`; first launch signs in "You" | GoTrue: Apple id_token + nonce; session in the Keychain |
  | `HuddleServiceProtocol` | SwiftData; skips in memory | `create_huddle`, `redeem_huddle_invite`, invite show/reset, skips, `recompute_streak` |
  | `DepositServiceProtocol` | insert-only | deposits, reactions, comments; full sync when a huddle opens |
  | `MediaServiceProtocol` | files in `Documents/Media` | Storage plus the same cache; encrypts huddle photos |
  | `ModerationServiceProtocol` | blocks in UserDefaults | `reports`, `blocks` |
  | `PushTokenServiceProtocol` | remembered in memory | `device_tokens` (used only inside `deps.push`) |
  | `TermsRecordServiceProtocol` | not used (no recorder) | `terms_acceptances` (used only inside `deps.termsRecorder`) |

  Live also has `LivePhotoKeyring` (identity key, huddle keys, invites),
  shared by the live services and deliberately not a protocol: the mock has
  nothing to hide photos from.
- **Navigation**: two tabs, Huddles and Profile. Huddles is one
  `NavigationStack` (`router.huddlesPath` of typed `Route`s): shelf → huddle
  home → archive / photo / settings / member profile. Home, Archive and
  Compose view models take their huddle in `init`.
- **View pattern**: the screen holds `@State var viewModel: VM?`, creates it
  in `.onAppear` with `deps`, and an inner `…Content` view takes
  `@Bindable var viewModel`.
- **Live sync is pull-based**: PostgREST rows → `SupabaseStore` upserts
  them into SwiftData and prunes rows gone remotely → views render the same
  models as in mock mode. It refreshes on launch, foreground,
  pull-to-refresh and after changes. The shelf stays light (huddle rows,
  one "who posted today" query, a streak recompute at most once per huddle
  per day); full history syncs only when a huddle opens. Don't add a full
  per-huddle sync to the shelf: it runs on every foreground.

## Domain rules

- **Day key**: `yyyy-MM-dd` in the device's time zone (Gregorian,
  `en_US_POSIX`), so string order is date order. 23:59 belongs to its day.
- **Gate**: today is unlocked once you've posted in that huddle today. Only
  today is gated. Locked photos are never even loaded.
- **Once and permanent**: one photo per member per huddle per day, never
  edited or deleted (`DepositError.alreadyDepositedToday`; the database has
  no update or delete policy on deposits). Compose asks "This is permanent —
  post it?".
- **Camera only** for daily photos (`CameraPicker`) and videos
  (`VideoCaptureView`); profile photos use `PhotosPicker`. The Simulator has
  no camera, so Compose says so (`-ui-testing-fake-camera` stands in for
  both: a test photo, or a generated 2-second clip).
- **Video drops** (Plus): one a day instead of a photo, never both. The
  recorder (`VideoRecorder`) feeds AVAssetWriter straight from the camera:
  720p H.264 at ~2 Mbps, AAC mono (silent if the microphone is off), no
  metadata, cut at exactly 6.0 s by the frames' timestamps. It records into
  `CaptureFiles` (tmp, complete file protection, swept at launch), the only
  plaintext video that ever touches disk; `ClipPreparer` reads it into memory,
  makes the poster from the first frame, and deletes the file. The poster,
  then the clip, then the row go up; if Plus has ended meanwhile Storage or
  RLS refuses it (`DepositError.videoNeedsPlus`), nothing is posted, and
  Compose keeps the clip and offers a photo instead. Playback is from memory
  (`InMemoryClipLoader`, an AVAssetResourceLoader delegate): the cache only
  ever holds ciphertext. Muted and looping in the feed (tap to unmute, ambient
  audio so music keeps playing), with sound in detail.
- **Streak**: a day counts when every member it waits on posted or spent a
  skip token (2 each). A day waits only on members who joined before it, so
  joining never breaks a streak, and a new huddle's first countable day is
  the next one. Counting walks back from today (if complete) or yesterday;
  the first incomplete finished day stops it. Breaking yesterday and
  completing today gives 1.
- **Backfill and recovery**: yesterday can still take a photo (until 48 h
  after its start). A broken streak shows a countdown until then; if the
  missing members backfill in time, the recompute restores it.
- **Limits**: captions ≤ 80, comments ≤ 500, names ≤ 40 (huddles 60), bios
  ≤ 160, 3 profile photos. Members per huddle 4 on the free plan and 10 with
  Plus, huddles kept 3 and 10, huddles joined 25; before the free limits
  start, 8 members (10 with Plus) and nothing else (`HuddleLimits.swift`;
  all enforced by the server). Lengths count code points, as Postgres does
  (`TextLimits.swift`).
- **Downscaling** before upload: photos ≤ 1440 px, avatars ≤ 512 px, JPEG
  0.8. Storage only grows, so keep it.
- **Former member**: deleting an account keeps its photos and comments
  (null author, shown as "Former member"), and members who left look the
  same. Those DTO fields must stay optional.
- **Moderation**: report a photo, comment or profile, and block a member.
  Blocking only hides content for the blocker; the gate and streak use the
  unfiltered data. Someone a member has blocked can't join their huddle.
- **Profile edits** stay a draft until **Save Changes** is confirmed;
  leaving with unsaved changes asks first, and nothing is queued.

## Encryption and invites (live)

The operator must not be able to see photos (`Services/Live/PhotoCrypto.swift`,
`InviteCrypto.swift`, `LivePhotoKeyring.swift`; CryptoKit only).

- **Identity key**: each user's Curve25519 key. The private half lives in
  the iCloud Keychain (`com.huddlepals.ios.identity`, synchronizable;
  deleted only with the account, never on sign-out); the public half is in
  `user_keys`.
- **Huddle key**: one random 256-bit key per huddle, stored per member in
  `huddle_keys`, wrapped to that member's identity key (ephemeral X25519 →
  HKDF-SHA256 → AES-GCM). A huddle key is shared, never replaced.
- **Photo key**: one per photo. The JPEG is AES-GCM sealed with it (that box
  is the Storage object, `application/octet-stream`); the photo key, sealed
  with the huddle key, is `deposits.wrapped_photo_key`. A report discloses
  only that photo's key (`tools/decrypt_reported_photo`). A video has one
  photo key for two objects (`PhotoCrypto.sealVideo`): its poster JPEG at
  `storage_path` and its MP4 at `video_path`, each with its own nonce, so the
  one disclosed key opens both.
- **Invite codes** (`Support/InviteCode.swift`): 32 characters of
  `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, shown as eight groups of four. The
  first 6 are a lookup, the only part the server stores
  (`huddles.invite_code`); the other 26 are a secret (≈129 bits). From the
  secret, HKDF-SHA256 gives a **proof** (the server keeps its SHA-256) and,
  with a random salt, a **wrapping key** that seals the huddle key into
  `huddle_invite_keys`. The secret itself is kept sealed with the huddle
  key, so members' apps can show the code.
- **Joining**: `redeem_huddle_invite(lookup, proof)` checks the code (10
  misses an hour), membership, the cap and blocks, and returns the sealed
  key. The app opens it, then stores its own wrapped copy
  (`save_own_huddle_key`, retried by every sync). Nobody else needs to be
  online.
- **Issuing**: the creator's app right after creating the key, and any
  member's app that opens a huddle still on an old 6-character code (which
  retires it). The keeper's **New invite code** revokes the old one. If a
  huddle ever gets a new key (only when nobody left holds the old one), its
  invite is dropped and the next member to open it issues a new one.
- **Fallback, after a key-code check**: on foreground and huddle open,
  members' apps find anyone without a working copy (`huddle_key_recipients`):
  people who joined with an old code, or who lost their identity key. The
  server names them and their public key, so the app shares the huddle key
  (`share_huddle_key`) only with a key some member has checked by comparing
  key codes (`KeyCode`, 30 digits from the account and its public key; each
  user's own is in Profile). Anyone else shows under **Waiting for the huddle
  key** in the huddle's settings, with a banner on its home screen, until a
  member checks them. Checked keys live in the Keychain (`VerifiedKeychain`,
  synced like the identity key), so a re-share to the same key needs no new
  check; a changed key does. This is what stops the server, or anyone with
  its database, from slipping in a key of its own.
- **Not encrypted**: captions, comments, reactions, huddle names, profiles,
  avatars and all metadata. Mock mode stores photos as they are.

## Auth

- **Terms first**: the full Terms (`Legal/TermsOfService.md`) with Agree,
  enabled only after scrolling to the end. The gate is device-local
  (`TermsAcceptance`); once someone is signed in, `TermsRecorder` records
  the agreement in `terms_acceptances` (account, version, when Agree was
  tapped, app build; the server stamps `recorded_at`). The first account
  signed in after Agree claims it; another account on the same device sees
  the Terms again. Live only. A material change to the Terms must bump
  `TermsOfService.version` (a test compares it with "Last updated"), and
  the same text belongs at huddlepals.com/terms.
- **Onboarding**: Terms → welcome cards → Sign in with Apple → profile
  (name + colour). `needsProfileSetup` resumes an unfinished sign-up.
- **Live**: Apple's id_token goes to `/auth/v1/token?grant_type=id_token`
  with the raw nonce (`Support/AppleSignInNonce.swift`). The session lives
  in the Keychain (`…ThisDeviceOnly`) and refreshes about 60 s before
  expiry; a refused refresh signs out, but being offline doesn't. Apple
  sends the name only on the first authorization.

## Notifications

- **Daily reminders** are local (`Support/DailyReminders.swift`,
  `deps.reminders`): opt-in in Profile, a rolling 7-day window (one main
  nudge plus up to two follow-ups a day), rebuilt on launch, foreground,
  after posting and on settings change, and silent today once you've posted
  everywhere.
- **Activity pushes** come from the server (`Support/PushNotifications.swift`,
  `deps.push`): a new photo (every other member), a comment or reaction on
  your photo (you), someone joining (the members already there). Never the
  actor, never across a block, never captions or comment text.
  - The app asks for permission after the first create or join, never at
    launch; when allowed, it registers on launch, foreground and sign-in,
    and upserts the token with its `sandbox` or `production` environment
    (read from the provisioning profile) into `device_tokens`.
  - Profile → Notifications → **Huddle activity** turns it off for the
    device. Sign-out removes the device's token first; account deletion
    removes all of the user's tokens. A tap opens the huddle (`huddle_id`).
  - Server side: AFTER INSERT triggers on deposits, comments, reactions and
    memberships (`notify_push`) send `{kind, id}` through `pg_net` to the
    `send-push` function, with a shared secret from Vault; they do nothing
    without the Vault secrets and never block an insert.
    `push_targets(kind, id)` picks recipients. `send-push` signs an ES256
    provider token (reused 50 minutes), sends one alert per device to the
    token's APNs host, and deletes tokens APNs calls invalid.
- The hour in Huddle Settings is only the huddle's stored preference; it
  schedules nothing.

## Account deletion

Profile → **Delete account** → confirm → Apple's sheet gives a fresh
authorization code (`SystemAppleReauthenticator`). Closing the sheet
deletes nothing; if Apple can't confirm, the app offers **Delete account
anyway**. The `delete-account` function then revokes the app's Apple tokens
(App Review 5.1.1(v)), deletes device tokens and avatars, releases the
user's photos (`release_storage_objects`), and calls
`auth.admin.deleteUser`. An Apple failure is logged and deletion goes on;
codes, tokens and keys are never logged.

## Backend

- **`SupabaseClient`** (`Services/Live/`) is a small URLSession client for
  GoTrue, PostgREST and Storage. JSON uses snake_case conversion, so DTO
  names use `Id`, never `ID`. Raw server messages stay inside
  `ClientError.http` for services to map; users see generic text.
- **Storage**: one private bucket, `deposits` (5 MB; `image/jpeg` and
  `application/octet-stream`). `<huddle_id>/…` is for members only;
  `avatars/<user_id>/…` is readable by the owner and their co-members,
  writable by the owner. Uploads are plain inserts: **never send
  `x-upsert`** (permanence, and huddle paths have no update policy).
- **Schema**: `schema.sql` builds a fresh database; `supabase/migrations/`
  (001–012, idempotent, run in order) upgrades the deployed one;
  `supabase/scripts/reset_database.sql` wipes an old database for a fresh
  start. Writes that need rules RLS can't express go through SECURITY
  DEFINER functions (key sharing, invites, joins, skips, streaks).
  `huddle_invite_keys` and `join_attempts` have no policies at all, so only
  those functions touch them.
- **Edge functions**: `delete-account` and `send-push`. Each splits into
  `index.ts` (wiring), `handler.ts` (logic) and a client file (`apple.ts`,
  `apns.ts`), so Node can test the logic. `verify-subscription` and
  `app-store-notifications` (HuddlePals Plus) split the same way and share
  `_shared/apple-jws.ts` (Apple's certificate chain, checked with WebCrypto
  against the pinned Apple Root CA - G3) and `_shared/subscriptions.ts`.
- **Plus and the free plan** (migration 013): Postgres enforces them, by
  the server's clock. `user_entitlements` is written only by
  `apply_entitlement` (service role, after Apple's signature checks out) and
  one Apple subscription entitles one account. `huddle_join_rule` decides
  joins from the keeper's plan; `create_huddle` caps huddles kept; posting a
  video (and uploading a `.mp4`) takes Plus. None of the free limits apply
  until `app_limits.free_limits_start` is set; Plus (10 members, videos)
  works from the start.
- **Plus in the app** (`PlusServiceProtocol`, `deps.plus`): the server's
  word, from `my_entitlement()`, judged by the server's clock
  (`PlanStatus.clockOffset`), cached per account for offline launches.
  `LivePlusService` buys with StoreKit 2 (`appAccountToken` = the user's id),
  sends every transaction to `verify-subscription` and finishes it only once
  the server has it, listens to `Transaction.updates` from launch, and on
  launch, sign-in and foreground sends any subscription of this account the
  server hasn't recorded. A subscription naming another account, or none, is
  sent only on Restore Purchases. `MockPlusService` buys by flipping
  `MockPlanLedger`. `HuddlePalTests/StoreKit/HuddlePalsPlus.storekit` is a
  local App Store for the tests (`SKTestSession`); selected as a scheme's
  StoreKit configuration it sells locally signed transactions, which the
  real server refuses, so it's no use against Supabase.
- **Where the free plan shows** (only once the free limits are on, and
  never with Plus): every gate opens `PaywallView` for its `PaywallContext`
  (price, period, trial, renewal terms, Terms of Use / Terms / Privacy links,
  Restore Purchases, as guideline 3.1.2 asks), which closes itself once Plus
  is on. Archive days past the last 30 show who posted, locked, and never
  load their media (`ArchiveGate`, which takes "today" as the latest of the
  phone's day, the server's and the newest deposit's, so setting the clock
  back opens nothing; the server doesn't hold these back). Compose shows
  "Video · Plus"; Create Huddle says when 3 (or 10) are kept, from
  `my_entitlement()` or the server's refusal; Huddle Settings asks
  `huddle_join_status` and explains a full or paused invite instead of
  showing a code that would fail. Profile's Plan section shows the plan,
  Manage subscription (live) and Restore Purchases, and deleting the account
  warns that Apple's billing goes on until it's cancelled.

## Backend setup and deploys

Secrets (`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected
automatically):

| Secret | Where | For |
|---|---|---|
| `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_ID` (= `com.huddlepals.ios`), `APPLE_PRIVATE_KEY` | function secrets | `delete-account` (without them, deletion works but skips revocation) |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` (= `com.huddlepals.ios`), `APNS_PRIVATE_KEY` | function secrets | `send-push` |
| `PUSH_WEBHOOK_SECRET` (e.g. `openssl rand -hex 32`) | function secrets | `send-push` checks the triggers' `x-push-secret` |
| `push_function_url`, `push_webhook_secret` (same value) | Vault | the push triggers |
| `APPSTORE_BUNDLE_ID` (= `com.huddlepals.ios`), `APPSTORE_PRODUCT_IDS` (the Plus product ids, comma-separated) | function secrets | `verify-subscription` and `app-store-notifications` (Apple's root certificate is in the code, so no Apple key is needed) |

**Apple keys** ([developer.apple.com](https://developer.apple.com/account) →
Certificates, Identifiers & Profiles):

1. Identifiers → `com.huddlepals.ios` → turn on **Push Notifications**.
2. Keys → **+** → **Sign in with Apple** → Configure → App ID
   `com.huddlepals.ios` → Register; download the `.p8` and note the Key ID.
3. Keys → **+** → **Apple Push Notifications service (APNs)**, Sandbox &
   Production → Register; download the `.p8` and note the Key ID.
4. The Team ID is under Account → Membership details. Each `.p8` downloads
   only once: keep it in a password manager, never in the repo.
5. In Xcode, Signing & Capabilities should list Sign in with Apple and Push
   Notifications with no profile errors; both entitlements are already in
   `HuddlePal/HuddlePal.entitlements`.

**Set the secrets** (Supabase CLI logged in; the `.p8` may keep real
newlines or use `\n`):

```bash
supabase secrets set --project-ref <project-ref> APPLE_TEAM_ID=<TEAM_ID> APPLE_KEY_ID=<SIWA_KEY_ID> APPLE_CLIENT_ID=com.huddlepals.ios APNS_TEAM_ID=<TEAM_ID> APNS_KEY_ID=<APNS_KEY_ID> APNS_BUNDLE_ID=com.huddlepals.ios PUSH_WEBHOOK_SECRET=<webhook-secret>
```

```bash
supabase secrets set --project-ref <project-ref> APPLE_PRIVATE_KEY="$(cat /path/to/AuthKey_<SIWA_KEY_ID>.p8)" APNS_PRIVATE_KEY="$(cat /path/to/AuthKey_<APNS_KEY_ID>.p8)"
```

HuddlePals Plus (the product ids as created in App Store Connect):

```bash
supabase secrets set --project-ref <project-ref> APPSTORE_BUNDLE_ID=com.huddlepals.ios APPSTORE_PRODUCT_IDS=com.huddlepals.ios.plus.monthly,com.huddlepals.ios.plus.annual
```

In the SQL editor (change one later with `vault.update_secret`):

```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/send-push', 'push_function_url');
select vault.create_secret('<webhook-secret>', 'push_webhook_secret');
```

**Deploy**, database first:

1. Run the migrations not yet applied, in order, in the SQL editor (a fresh
   project runs `schema.sql` instead). 009 enables `pg_net`; if the project
   refuses, enable it under Database → Extensions and run 009 again.
2. From `HuddlePal/`:

   ```bash
   supabase functions deploy delete-account --project-ref <project-ref>
   ```

   ```bash
   supabase functions deploy send-push --no-verify-jwt --project-ref <project-ref>
   ```

   ```bash
   supabase functions deploy verify-subscription --project-ref <project-ref>
   ```

   ```bash
   supabase functions deploy app-store-notifications --no-verify-jwt --project-ref <project-ref>
   ```

   `send-push` runs without JWT verification because the database sends no
   user token; the shared secret is the check. `app-store-notifications`
   runs without it because Apple sends none; Apple's signature is the check.
   Its URL, `https://<project-ref>.supabase.co/functions/v1/app-store-notifications`,
   goes in App Store Connect as the App Store Server Notifications V2 URL,
   for production and for the sandbox.

## Building and testing (this machine)

Commands run from the repo root.

- `xcode-select` points at the Command Line Tools, so prefix Xcode commands
  with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Always build tests with `EXCLUDED_SOURCE_FILE_NAMES=Supabase.plist` so
  nothing bundles the production config. `scripts/test-all.sh` does.
- UI tests wipe the app's data on their simulator, so use the QA ones
  (`QA-17Pro`, `QA-17ProMax`, `QA-SE3`, `QA-iPadPro13`, `QA-iPadMini`). The
  script's default simulator, "HuddlePals Tests", doesn't exist here.
- Everything (credentials-ignored check, database suite in both modes, unit
  and UI tests):

  ```bash
  SIMULATOR=QA-17Pro HuddlePal/scripts/test-all.sh
  ```

- Database and edge-function tests only (Node 22.18+; Postgres runs in
  process via PGlite, once on `schema.sql` and once on the deployed schema
  plus the migrations, which must end up identical):

  ```bash
  cd HuddlePal/supabase/tests && npm ci && npm test
  ```

- Unit tests only (parallel clones sometimes fail to launch here, so run
  them serially):

  ```bash
  cd HuddlePal && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project HuddlePal.xcodeproj -scheme HuddlePal -destination "platform=iOS Simulator,name=QA-17Pro" -only-testing:HuddlePalTests -parallel-testing-enabled NO EXCLUDED_SOURCE_FILE_NAMES=Supabase.plist
  ```

- **Covered**: engine rules, mock flows, store reconciliation, live
  services over stubbed HTTP (`StubURLProtocol`), encryption and invite
  joins against an in-process fake server, push coordination, accessibility
  audits; schema, RLS, functions and triggers in PGlite; edge-function
  logic on Node.
- **Not covered**: a real Supabase project's responses, Apple's servers and
  sheets, APNs delivery, real `pg_net`/Vault (stubbed), and key sharing
  between two real devices. Check those on devices: delete a test account
  (logs show `apple_revoked`; the app leaves Settings › Sign in with Apple;
  its photos show "Former member"), join with an invite while nobody else
  is online, and see each push arrive, open its huddle, and stop when
  turned off.
- **Project file**: Xcode 16 synchronized folders, so new files in
  `HuddlePal/`, `HuddlePalTests/` or `HuddlePalUITests/` join the build by
  themselves; never hand-edit file lists. `Config/Info.plist` (URL scheme,
  camera text) stays outside those folders, or the build copies it twice.
  Build-setting edits go in both Debug and Release.
- Debug builds without `Supabase.plist` run the mock; Release builds refuse
  to build without one.

## Mock world and debug

The first mock launch seeds "The Crew" 🏔 (code
`SeedDataService.crewInviteCode`) with You (keeper), Maya, Sam and Riley,
plus "Sunday Dinners" 🍝; 45 days of history (past the free plan's 30-day
archive window), a couple of misses and a skip, Maya's post yesterday as a
2-second video (`PlaceholderVideoGenerator`), and a today where everyone but
You has posted, so the app opens locked. The Crew has 4 members: full on the
free plan. Who has Plus and whether the free limits are on live in
`MockPlanLedger` (off by default, as on the server); the mock huddle service
refuses what the server would. Profile → DEBUG (mock only): force the gate
shut, turn the free plan's limits on, simulate Plus (or Plus that ends in a
minute), simulate a subscription already linked to another account, advance
the mock day, regenerate the seed (behind the splash, `session.isReady =
false`; keep that). UI tests start with the free limits on
(`-ui-testing-free-limits`) or with Plus (`-ui-testing-plus`); the rest of
the launch switches are listed in `Support/UITestHooks.swift`.

## Design

All in `Support/Theme.swift`: dynamic colours for light ("gallery print":
warm paper, ink actions) and dark (charcoal, never pure black), with
`Theme.onAccent` for labels on accent fills and `.cardSurface()` for cards.
Appearance follows the system unless set in Profile. Identity colours come
from `AvatarPalette` (6 solids, 2 gradients); chrome stays neutral. Names
and avatars open the member's profile (`UserLink`). The app icon
(`tools/generate_icon.swift`) must stay a 1024 px opaque PNG with no SF
Symbols.

## Gotchas

- `.kerning()` works only on `Text`.
- Avoid `count(where:)` in Swift 5 mode; use `filter{}.count`.
- The module is `HuddlePal` and the model is `Huddle`; don't confuse them
  in tests.
- Snake-case encoding turns `userID` into `user_id`, which decodes back
  only to `userId`. That once signed everyone out on every launch. Use `Id`.
- A DTO field for a nullable column must be optional, or one null fails the
  whole response.
- `LocalDepositImage` must reload when its path changes, and for huddle
  photos its task id includes `photoKeysVersion` so a locked photo retries.
  Don't "optimise" either away.
- Wire formats are pinned by check constraints: public keys and invite
  proofs/salts are 44-character base64, wrapped and sealed keys 80,
  sealed secrets 72. HKDF info uses lowercase UUIDs (Postgres prints them
  lowercase; Swift doesn't).
- A SwiftUI `TextField`'s tap target is its text height; padding doesn't
  count, so keep the font at least 18 pt where the audit checks it.
- OVERVIEW.md uses Mermaid, which GitHub renders.

## Open issues

- **QA-21: no Dynamic Type** (medium). About 130 fixed font sizes ignore
  the person's text-size setting; it needs a type scale built on text
  styles. `AccessibilityAuditTests` accepts Dynamic Type issues until then
  (`knownOpen`); remove `.dynamicType` from that list when it's done.
- **QA-19: a screen can hold a huddle that sync just removed** (low). Routes
  carry SwiftData models and the store prunes rows gone remotely (say,
  after leaving on another device). Never reproduced. The fix is ID-based
  routes that look the model up and pop if it's gone.
- **Terms screen contrast**: `AccessibilityAuditTests.testOnboardingScreens`
  fails on the all-caps arbitration paragraph of the Terms. Every other UI
  test passes.

## Conventions

- Comments explain why, not what. `// TODO: BACKEND — …` marks the
  remaining server-integration notes.
- Services throw typed `LocalizedError`s (`AuthError`,
  `HuddleServiceError`, …); view models show `errorMessage`.
- Commits: author XpertiCON106, plain messages with no co-author lines.
