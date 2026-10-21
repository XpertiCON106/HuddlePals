# QA Report: `polish` branch (HuddlePals)

_QA sweep run 2026-10-21 on `polish` (branched from `main` at a06d8a7). This file is not committed; every fix is its own commit on `polish`, none pushed._

> **Name check.** You called the app "Vault". The code is **HuddlePals** (renamed in 25d7ba7 / b1af561). Glossary: group = **huddle**, check-in = **deposit**, group owner = **keeper**. Where your brief and the code disagree, the code wins (see "Brief vs. code" below).

## Executive summary

**Verdict: yes, with caveats.** The `polish` app build is ready for TestFlight once the six database migrations are applied. **Apply migration 001 to production now**, independent of any app release: the profile-photo leak it closes (QA-01) is live today.

| | Before | After |
|---|---|---|
| iOS tests (unit + UI) | 78 / 78 (unit only) | **152 / 152** (128 unit + 24 UI); UI suite green 3 runs in a row |
| Database / RLS / RPC tests | none | **69 / 69** on fresh `schema.sql` and on deployed schema + migrations |
| App line coverage | 20.9% | **74.9%** |
| Findings | — | **33**: 2 Critical, 3 High, 15 Medium, 13 Low. **30 fixed**, 3 open (QA-19 Low, QA-20 Medium, QA-21 Medium) |

## Progress (working checklist)

- [x] Phase 0: recon, inventory, local environment
- [x] Phase 1: baseline (builds, tests, analyzer, audits)
- [x] Phase 2: test sweep (backend/RLS, live layer, iOS, UI journeys, security, a11y)
- [x] Phase 3: fixes (QA-01 … QA-34)
- [x] Phase 4: retest from clean: Debug/Release/analyze/strict on 53fd496; unit+UI ×1 and UI ×2 more (no flakes); device matrix SE3 / Pro Max / iPad mini / 17 Pro
- [x] Phase 4b: final confirmation on the final commit **c0d313a**: `scripts/test-all.sh` (credentials check + DB 69/69 ×2 + iOS 152/152), UI suite 2 more runs (24/24 each, 3 in a row), clean Release build (0 warnings)
- [x] Phase 5: report

---

## 1. Environment and commands

| What | Detail |
|---|---|
| Machine | macOS 26.6.2, 32 GB, Xcode 26.1.1 (17B100), iOS 26.1 simulator runtime, Node 24.8 |
| Not available | Docker, Supabase CLI, Postgres, Deno, SwiftLint. No local Supabase stack could be started |
| Production safety | `HuddlePal/HuddlePal/Supabase.plist` (untracked, gitignored) is a **live hosted project config**. Every build in this sweep passed `EXCLUDED_SOURCE_FILE_NAMES=Supabase.plist`, and each app bundle was checked to contain no `Supabase.plist`. No request was ever made to production. |
| Simulators | Dedicated, created for this run: **QA-SE3** (iPhone SE 3, smallest), **QA-17Pro**, **QA-17ProMax** (largest), **QA-iPadMini**. The already-booted iPhone 17 Pro (which may hold your real sign-in) was never touched. |
| Database | Real Postgres via **PGlite 0.5.8** (in-process, dev-only npm dependency) with a stub of the Supabase pieces `schema.sql` relies on (`supabase/tests/supabase-stub.sql`). |

**One command for everything** (added, see QA-28):
```
HuddlePal/scripts/test-all.sh            # credentials-ignored check + DB suite (2 modes) + unit + UI tests
```
Pieces:
```
cd HuddlePal/supabase/tests && npm ci && npm test     # DB/RLS/RPC suite: fresh schema.sql AND deployed schema + migrations
cd HuddlePal && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project HuddlePal.xcodeproj -scheme HuddlePal \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -enableCodeCoverage YES \
  EXCLUDED_SOURCE_FILE_NAMES=Supabase.plist              # unit + UI tests, never the live config
```

TBD sections below are filled after the final retest.

## Findings log (IDs fixed; commits reference them)

| ID | Sev | Area | Finding | Status / commit |
|---|---|---|---|---|
| QA-01 | **Critical** | Storage RLS | Profile photos (`avatars/…`) readable **and listable** by anyone with the public anon key, and by any signed-in stranger | fixed 99e82e9 (+ migration 001) |
| QA-02 | **High** | Invites | Unlimited invite-code guessing (6 chars, never expire); a successful guess gets the huddle key auto-shared → whole photo archive | fixed 536b706 (+ migration 002) |
| QA-03 | — | — | (ID unused) | — |
| QA-04 | Medium | Huddles | Keeper leaves / deletes account → huddle has no keeper forever | fixed dc12158 (+ migration 003, repairs existing) |
| QA-05 | Low | Keys | Leaver keeps their wrapped huddle-key copy server-side | fixed 4abf413 (+ migration 004) |
| QA-06 | Low | Schema | Huddle emoji and profile `photo_paths` unbounded server-side | fixed a5ce063 (+ migration 005) |
| QA-07 | **Critical** | iOS crash | Recovery banner `Date()...deadline` traps once the deadline passes with the banner on screen (next-morning reopen) | fixed c4bf538 |
| QA-08 | **High** | Sync | Huddle history unpaginated: PostgREST 1000-row cap silently truncates, then local prune deletes real history; `in.()` URLs grow unbounded (414) | fixed d08380c |
| QA-09 | **High** | Time | Day keys formatted in the user's calendar (Buddhist → 2569-…): every check-in refused for those users; reminders would misfire | fixed f461439 |
| QA-10 | Medium | Privacy | Sign-out/deletion left synced rows, plaintext avatar cache, HTTP cache, pending invite, blocked list; reminders kept firing | fixed 5559f6a |
| QA-11 | Medium | Permissions | Camera denied/restricted: black system screen loop, no Settings path; restricted shown as "no camera" | fixed d1c182a |
| QA-12 | Medium | Auth | Offline launch with valid session looked signed out | fixed a88b64f |
| QA-13 | Medium | Auth | Server-ended session left the app "signed in" but broken; 429/408 on refresh signed people out | fixed c7b5a78 |
| QA-14 | Medium | Compose | Cancel/swipe during upload still posted (no unlock/streak); double tap uploaded twice | fixed 835f348 |
| QA-15 | Medium | Archive | Backfilling yesterday from Archive didn't recompute the streak | fixed 19e7021 |
| QA-16 | Low | Deep link | Invite link while signed out never opened Join; ignored when Join open; 7–8 char codes dead-ended | fixed 10c1fae |
| QA-17 | Medium | Input | Client limits ≠ server (names 60/40, comment 500 unlimited; emoji counted as characters not code points) → generic errors after upload | fixed 2268d70 |
| QA-18 | Medium | UX | Home/Archive: no loading or error state; failures looked like "Nobody has posted yet" | fixed 0143219 |
| QA-19 | Low | Stability | Sync prune can delete SwiftData models still on screen: **not reproduced** (probe: reads after delete+save return cached values) | open, recommendation |
| QA-20 | Medium | Compliance | Apple token revocation on account deletion can never run (no authorization code is ever obtained) | open, needs Apple secrets + design |
| QA-21 | Medium | A11y | No Dynamic Type: ~130 fixed font sizes | open, recommendation |
| QA-22 | Low | Security | Deposit `storage_path` / photo paths unchecked: cross-huddle reference, `../` traversal into members' app sandbox | fixed 3bd621b (+ migration 006) |
| QA-23 | Low | Sync | Reactions/blocks upsert used merge-duplicates → DO UPDATE refused by RLS on duplicates | fixed 49efa92 |
| QA-24 | Low | DEBUG | "Regenerate seed data" failed over existing data (batch delete) | fixed b5c720a |
| QA-25 | Low | Copy | Every 403 shown as "session expired" | fixed 7985e10 |
| QA-26 | Low | Settings | Non-keeper hour picker silently did nothing server-side but looked saved | fixed 13be8ea + 99af9f4 |
| QA-27 | Medium | A11y | Apple's audit on 13 screens: unlabelled photos/locked cards/thumbnails, raw SF Symbol names read aloud, secondary text ≈4.2:1 (< 4.5 AA), Terms "Decline" hit area = the word only, colour swatches invisible to VoiceOver, unlock reveal ignored Reduce Motion | fixed 66e4d6f |
| QA-28 | Low | Repo hygiene | Credential ignore rule covered one exact path only; no single test command | fixed b2adc17 |
| QA-29 | Low | Docs | OVERVIEW said email/SMS sign-in is live (flag is off) | fixed 5b6fb52 |
| QA-30 | Medium | Dev safety | ⌘U with the live plist present launched the test host **against production** (startup sync writes) | fixed 3be310d |
| QA-31 | Medium | UX | Locked Home: "Add today's memory" hidden under the iOS 26 floating tab bar | fixed 1dd2ba4 |
| QA-32 | Low | DEBUG | Seeded demo photos had an unpainted white wedge | fixed ce5bd21 |
| QA-33 | Medium | UX | Profile: after editing the (multi-line) bio the keyboard could not be dismissed and covered the tab bar | fixed 9b70501 |
| QA-34 | Low | UX | Shelf row status truncated on small phones ("3 waiting fo…", iPhone SE) | fixed 5d24437 |

Process notes (honesty): 13be8ea was committed with a test that did not compile (my test runner exited 0 on a failed build); corrected in 99af9f4, runner fixed, no history rewritten. One probe command targeted `~/Library/Application Support/default.store*` for cleanup; the glob matched nothing and nothing was deleted; later probes used scratch paths only.

## 2. Inventory and coverage

Legend: ✅ tested (automated unless noted) · 👀 tested by hand/visual · ⛔ untested (reason given)

### Screens (iOS, SwiftUI)
| Screen / state | Coverage |
|---|---|
| Launch reveal (hug mark) | 👀 every UI run; Reduce Motion path untested (no reliable simulator switch from XCUITest) |
| Terms gate: scroll-to-end, Agree, Decline | ✅ TermsAgreementTests (unit) + UI `testFirstLaunch…`, `testDecliningTheTermsGoesNowhere` |
| Welcome cards → sign-in method → profile step | ✅ UI journeys 1/2/7/8 (mock "Continue with Apple") |
| Email/SMS code entry | ✅ unit (AuthInputTests); ⛔ UI: hidden by `FeatureFlags.emailAndPhoneSignInEnabled = false` |
| Huddles shelf: list / empty / loading / error | ✅ UI + CriticalFlowTests; error banner on shelf already existed |
| Home: loading, error, first-to-deposit, locked, unlocked, recovery banner | ✅ LoadStateTests, HuddleEngineTests (recovery), UI (locked/unlocked, CTA layout QA-31) |
| Compose: capture, no camera, denied, restricted, confirm, double-tap, cancel-while-saving | ✅ ComposeTests + UI (fake camera, denied); ⛔ real camera (Simulator has none; mocked capture path used) |
| Archive: loading, error, empty, months, backfill banner | ✅ LoadStateTests, ComposeTests (backfill), UI journey 4 |
| Deposit detail: reactions, comments, report, block | ✅ unit (live service tests for reactions/blocks), UI audit screen; report flow 👀 |
| Create / Join huddle (+ errors) | ✅ CriticalFlowTests, TextLimitTests, UI journey 2 + wrong code |
| Huddle settings: members, streak, hour (keeper only), invite, leave | ✅ CriticalFlowTests (QA-26), UI journey 5 |
| Profile: photos, name/bio draft+confirm, reminders, appearance, sign out, delete, DEBUG | ✅ ProfileConfirmationTests, UI journeys 6/7/8 |
| Member profile (UserProfileView), Terms reader | 👀 reachable via names; no dedicated test |

### View models / services with logic
All view models (Root, Onboarding, HuddleList, HuddleHome, Compose, Archive, DepositDetail, Create/Join/Settings, Profile, UserProfile), HuddleEngine, all Mock services, all Live services (Auth, Huddle, Deposit, Media, Moderation, PhotoKeyring, SupabaseClient, SupabaseStore), DailyReminders, TextLimits, ImageDownscaler. ✅ except: `LivePhotoKeyring` key sharing between two real devices ⛔ (needs a live backend), `UserProfileViewModel` (trivial, 👀).

### Backend (Supabase) — every object
| Object | Allowed + denied tests |
|---|---|
| Tables: profiles, huddles, memberships, deposits, reactions, comments, skips, reports, blocks, user_keys, huddle_keys, join_attempts (new) | ✅ `supabase/tests/rls.test.mjs` (anon, outsider, member, keeper, leaver) |
| Storage `deposits` bucket: `<huddle>/…` and `avatars/<user>/…` read / insert / update / delete | ✅ rls.test.mjs (storage section) |
| RPCs: create_huddle, join_huddle, spend_skip_token, recompute_streak, init_huddle_key, huddle_key_recipients, share_huddle_key; helpers; trigger handle_membership_removed (new) | ✅ rpc.test.mjs |
| Account deletion cascade (what `delete-account` triggers) | ✅ rpc.test.mjs; ⛔ the edge function itself (no Deno / Supabase runtime; reviewed only) |
| Schema from scratch, reset script, migrations 001–006 on the deployed schema, parity, idempotency | ✅ migrations.test.mjs (+ whole suite run in both modes) |
| Indexes on hot paths, RLS on every table, SECURITY DEFINER search_path | ✅ rpc.test.mjs "schema lifecycle" |

### Scheduled jobs, notifications, links, permissions, integrations
| Item | Coverage |
|---|---|
| Server-side scheduled jobs | none exist (no cron / pg_cron / edge schedule in repo) |
| Push notifications (APNs), "new check-in" notifications | **do not exist**: only local daily reminders. ⛔ nothing to test |
| Local reminders: schedule, follow-ups, suppression, signed-out cancel, calendar | ✅ SignOutTests (spy), HuddleEngineTests (trigger calendar); permission allow/deny ✅ UI |
| Deep link `huddlepal://join/<code>` (logged out / in / already open / malformed) | ✅ InviteLinkTests + UI; universal links: none configured |
| Permissions: camera (granted/denied/restricted), notifications (allow/deny), photo library | ✅ (camera via mocked states); photo library uses PhotosPicker, which needs no permission |
| Third parties | App: none (zero dependencies). Backend: Supabase (GoTrue, PostgREST, Storage, Edge Functions); edge fn imports supabase-js@2, djwt@3.0.2 |
| Web pieces (landing, invite pages, AASA) | ⛔ none in this repo (huddlepals.com lives elsewhere) |

### Brief vs. code (where your description and the code differ: the code wins)
- **Name**: "Vault" → the app is **HuddlePals**.
- **"Remove a member"**: there is no keeper "remove member" feature. Members can only **leave**. Leaving was tested: access to the huddle, its member list, past check-ins, comments and photo objects ends immediately (rls.test.mjs "leaving a huddle").
- **"New-check-in notifications" / push / APNs**: none exist. The only notifications are **local daily reminders**. Nothing server-side sends anything.
- **"Edit / delete / re-post a check-in"**: by design, check-ins are **permanent**: no edit, no delete, no re-post (no UPDATE/DELETE policies; verified).
- **Account deletion "removes or anonymizes photos"**: it **anonymizes** them ("Former member", `author_id → null`). Photos stay in the huddle by design (Model B, disclosed in PRIVACY.md). Verified.
- **Invites "expire / can be revoked"**: invite codes **never expire and can't be rotated or revoked** (see Needs your decision).
- **Daily rule "enforced server-side"**: yes, `unique (huddle_id, author_id, day_key)` plus an RLS day window. "Today" is the **device's** local day; the server accepts today-2 … today+1 (UTC) to cover every time zone.
- **EXIF/GPS**: stripped. Every upload is re-rendered by `ImageDownscaler` (ImagePipelineTests proves GPS, EXIF and TIFF are gone for JPEG, HEIC and PNG).
- **Web pieces / universal links**: none in the repo.
- **Production data**: `DEVELOPMENT.md` says a real Supabase project is "being exercised by hand"; you said your family uses it. Treated as production throughout.

---

## 3. Needs deployment (backend changes made in code and verified locally, not deployed)

Production runs `schema.sql` as of **b1af561** (assumption: that commit says "start the backend fresh" and `schema.sql` hasn't changed since; a frozen copy is in `supabase/tests/fixtures/deployed-schema-b1af561.sql`). `schema.sql` now contains all fixes for fresh databases. For the **existing** database, run these in order in the Supabase SQL editor. Each is idempotent and wrapped in a transaction:

| # | File | What it does | Data migration |
|---|---|---|---|
| 1 | `supabase/migrations/001_qa01_avatar_read_policy.sql` | Profile photos readable only by co-members (QA-01) | none |
| 2 | `002_qa02_invite_guess_limit.sql` | `join_attempts` table + 10 wrong codes/hour/user (QA-02) | none |
| 3 | `003_qa04_keeper_succession.sql` | Trigger: longest-standing member becomes keeper (QA-04) | **promotes a keeper in huddles that already lost theirs** |
| 4 | `004_qa05_drop_key_copy_on_leave.sql` | Leaving deletes your huddle-key copy (QA-05) | **deletes key copies held by people who already left** |
| 5 | `005_qa06_bound_emoji_and_photo_paths.sql` | Emoji ≤16 code points, photo_paths array ≤3 (QA-06) | `NOT VALID`: existing rows not rechecked |
| 6 | `006_qa22_deposit_storage_path_shape.sql` | Deposit path must be `<its huddle>/<uuid>.jpg` (QA-22) | `NOT VALID`: existing rows not rechecked |

Verified locally: the whole DB suite passes on (a) fresh `schema.sql` and (b) deployed schema + migrations, and a parity test proves (a) and (b) produce the same columns, constraints, indexes, policies, functions, triggers and grants. Each migration also re-applies cleanly.

**Compatibility:** all six are safe with the app version already in people's hands. The old app already treats an empty `join_huddle` result as "code not found", already writes `<huddle>/<UUID>.jpg` paths, and only reads co-members' avatars. Ship the migrations first, then the app build.

**App build:** every client fix needs a new TestFlight/App Store build (not done; you deploy).

**Not changed (still needs your deploy decision):** the `delete-account` edge function (see QA-20 and the edge-function notes below).

---

## 4. Needs your decision (product calls; nothing changed)

1. **Who gets the photo key.** Members' apps automatically share the huddle key with **anyone who joins**, which also opens every past photo. QA-02 makes guessing a code impractical, but a leaked or forwarded code still works forever. Options: a keeper approves new members before keys are shared; invite codes that expire and can be re-generated ("rotate code" in Settings); a "who joined" notice to the keeper. *My recommendation: rotate plus expiry first (small), approval later.*
2. **The reciprocity gate is client-side only.** RLS lets any member read today's rows (captions, wrapped keys) before posting; only the app hides them. Enforcing it server-side means a `can_see_today()` check in the deposits/storage policies, which also changes backfill and streak reads. It's a fairness mechanic, not a privacy one (members only), so I didn't change it.
3. **"Today" is the device's day.** Members in different time zones can disagree at day edges; the server accepts today-2 … today+1 (UTC) so every zone works, which also lets a modified client backfill 2 days or post "tomorrow". A per-huddle home time zone fixes both.
4. **Skip tokens can't be spent** anywhere in the UI (`spendSkipToken` is never called), yet Settings and the docs describe them. Ship a "use a skip" action, or hide the copy.
5. **Device-wide settings.** Terms acceptance and reminder preferences belong to the device, not the account, so a second account on a shared iPad inherits them. Fine for a family app; say so if not.
6. **Email OTP server-side.** The app hides email/SMS sign-in, but the Supabase project probably still accepts `POST /auth/v1/otp` for email (default on). If it shouldn't, disable the provider in the dashboard.
7. **iPad.** The app is Universal; it renders on iPad mini (screenshots), but layouts are phone-first. Keep Universal (needs iPad screenshots for review) or go iPhone-only.
8. **Housekeeping you own:** a dangling git object in `.git` contains a copy of the production `Supabase.plist` (URL + publishable anon key; never committed or pushed). Remove with `git reflog expire --expire-unreachable=now --all && git gc --prune=now` if you share `.git` copies. I didn't run it (irreversible, your repo).

## 5. Couldn't test, and why

| Area | Why | What was done instead |
|---|---|---|
| A real Supabase stack (GoTrue, PostgREST, Storage API, Realtime) | No Docker / Supabase CLI here; production is off-limits | SQL, RLS and storage policies on real Postgres (PGlite) with Supabase-equivalent roles/`auth.uid()`/`storage.foldername`. The HTTP layer is tested against an in-process stub that reproduces PostgREST's row cap, error bodies, `Prefer` semantics, offline failures |
| `delete-account` edge function | No Deno / edge runtime | Code review; cascade behaviour it triggers is tested in SQL. Open risks: Apple revocation never runs (QA-20); `auth.admin.deleteUser` may fail if the user owns Storage objects (unverified; test once in a staging project) |
| Sign in with Apple (real sheet), email/SMS delivery, APNs | Need Apple/Twilio accounts and a live backend | Mock flows in UI tests; request/response handling unit-tested |
| Real camera capture | Simulator has no camera | Mocked capture path (`-ui-testing-fake-camera`) and mocked permission states |
| Multi-device E2EE key sharing | Needs two real accounts on a backend | Crypto unit-tested (existing PhotoEncryptionTests); SQL of init/share/recipients tested |
| Network conditioning on device (slow/flaky) | Mock backend makes no requests | Offline/timeout/5xx/429 paths unit-tested via the HTTP stub |
| Reduce Motion | No reliable switch from XCUITest | Code path reviewed: launch reveal already honoured it; unlock reveal now does (QA-27) |
| Web pieces, AASA, Lighthouse/axe | No web code in this repo | n/a |
| SwiftLint / ESLint / `tsc` | None configured in the repo | Static analyzer + strict-concurrency diagnostics instead |

---

## 6. Ways forward

### 6.1 What a user costs you today (from the code)
- A deposit is a ~1440 px JPEG at quality 0.8 → **~300–500 KB** (ciphertext adds 28 bytes). One per member per huddle per day, kept **forever**.
- A typical member (≈1.5 huddles × 4 members) adds **~18 MB/month** of storage and downloads **~55 MB/month** of others' photos (each photo once, then cached; sign-out now clears that cache, so re-downloads happen after sign-in).
- **The biggest variable cost is not photos.** Home and Archive re-download the huddle's *entire* deposit/reaction/comment history on every open, foreground and pull (QA-08 made it complete, not smaller). A year-old 4-person huddle is ~1,500 rows ≈ 0.5 MB of JSON per open; at ~5 opens/day that's ~75 MB/month per user, more than the photos. Incremental sync (Improvement 1) removes almost all of it.
- At Supabase Pro rates (base **$25/mo** with 100 GB storage, 250 GB egress, 100k MAU; overage ~$0.021/GB-month storage, $0.09/GB egress) that's roughly **$0.01–0.03 per active user per month** in year one, rising slowly as archives grow. **Any paid plan clears cost by a wide margin**; pricing is about value and trust, not cost recovery.

### 6.2 Monetization (ranked; start with #1)
Comparables: FamilyAlbum Premium Family $5.99/mo or $59/yr (Pro $10.99/$109; Premium One $2.99/mo) · Tinybeans+ $7.99/mo or $74.99/yr (Legacy $4.49/$39.99) · 1 Second Everyday Pro $9.99/mo or $49.99/yr · Locket Gold ≈ $3–5/mo (sources disagree) · BeReal: ad-supported, no clear paid tier.
App Store rules (check before launch): the **Small Business Program** charges **15%** (under $1M/yr) on subscriptions from day one. In the **US, external purchase links** have carried **no Apple commission since the April 2025 Epic ruling**, but Apple proposed a 15% rate (5% for small businesses) in Aug 2026, pending the court. **Physical goods** (prints) are outside IAP entirely.

| # | Model | Free vs. paid | Price | What to build | Trust |
|---|---|---|---|---|---|
| **1** | **Huddle Plus**: one family subscription per huddle, bought by any member (the "grandparent gift") | Free forever: the daily ritual, E2EE, full archive viewing, up to 8 members, 2 huddles. Plus: yearly/monthly **archive export** (decrypted on device), **full-resolution originals**, "On this day" and **year-in-review** reels, unlimited huddles, custom streak rescue (extra skip tokens) | **$3.99/mo or $29.99/yr per huddle** (under FamilyAlbum's $59 because it covers a small group and the core stays free) | StoreKit 2 subscriptions; App Store Server Notifications → edge function → `huddles.plan`; RLS gates on paid features (e.g., huddle count); paywall copy | **High** if the rule is "your photos are never paywalled", since viewing and export of basics stay free |
| 2 | **Printed yearbook** | 365-day huddle book, auto-laid-out, opt-in | **$34–49** per book (vendor cost ~$15–25) | On-device PDF layout (photos are E2EE, so the server can't render them); consented upload to a print vendor (Lulu/Prodigi); Apple Pay / Stripe checkout (physical goods → no IAP) | High, if it's explicit opt-in and the copy says the printer sees that book only |
| 3 | **Keeper's family plan** (multi-huddle bundle) | Plus across every huddle you keep | $59.99/yr | Variant of #1 | High |
| 4 | **Originals vault** (storage tier) | Keep originals and Live Photos; free tier stays 1440 px | $1.99/mo | Second upload path, larger bucket limits | Medium: the storage pitch is weak when the free archive is already permanent |
| 5 | Ads / data | — | — | — | **Don't.** Contradicts E2EE, "no tracking" in the privacy manifest and the product's whole promise |

**Where I'd start:** #1 with an annual-first paywall shown at a natural moment (the 30-day streak, the first "On this day"), then #2 before the holidays. Both need nothing that weakens E2EE.

### 6.3 Technical and product improvements (top 8)
| # | Improvement | Why (from the code) | Effort |
|---|---|---|---|
| 1 | **Incremental sync** (cursor on `created_at`/`id`, plus deletions via a small tombstone or membership check) | Every open re-downloads the full history; the biggest cost and slowness driver (6.1) | M |
| 2 | **CI** running `scripts/test-all.sh` on a macOS runner (or Xcode Cloud) for every PR | 152 unit/UI tests and 69 DB tests (×2 schema modes) now exist; nothing runs them automatically | S |
| 3 | **Crash + error reporting** (MetricKit, or Sentry with PII scrubbing; edge-function logs) | No crash reporting is configured at all; release-readiness gap | S |
| 4 | **A staging Supabase project** and live integration tests (PostgREST, Storage, `delete-account`, Apple sign-in) | The HTTP layer is only stub-tested; the edge function has never run | M |
| 5 | **Invite hardening**: expiring/rotatable codes, keeper approval before key sharing (decision 4.1) | One forwarded code = permanent access to every photo | M |
| 6 | **Dynamic Type + accessibility pass** (QA-21, QA-27 remainder) | ~130 fixed sizes; large-text users get small text | M |
| 7 | **ID-based navigation routes** (QA-19) | Routes hold SwiftData models; a multi-device leave could leave a stale model on screen | S |
| 8 | **Apple token revocation done right** (QA-20) | App Review 5.1.1(v) expects revocation; today it can't run | M |

### 6.4 Features (ranked by impact ÷ effort)
| # | Feature | User benefit | Drives | Effort |
|---|---|---|---|---|
| 1 | **"Everyone's in but you" push** (APNs + edge fn on deposit insert) | The nudge that actually matters, from the group not the app | Retention | M |
| 2 | **On this day / year in review** | The permanent archive pays off emotionally | Retention, delight, Plus upsell | S–M |
| 3 | **Use a skip token** button (it's documented and modelled, not reachable) | Keeps streaks alive on a bad day | Retention | S |
| 4 | **Keeper tools**: rotate code, approve joiners, hand over keeper, rename | Control over who's in a private family space | Trust & safety | S–M |
| 5 | **Invite links that work without the app** (universal link → App Store → Join prefilled) | Grandparents join from a text message | Growth | M |
| 6 | **Home-screen widget**: who has posted today (already planned in README) | Glanceable streak pressure | Retention | M |
| 7 | **Printed yearbook** (6.2 #2) | A real object for the family shelf | Revenue | M–L |
| 8 | **Export my archive** (on-device decrypt → zip) | Data ownership; GDPR portability | Trust, Plus | M |
| 9 | **Reactions/comments notifications** (opt-in) | Conversation around the photo | Retention | M |
| 10 | **Monthly collage / time-lapse** of a huddle | Shareable delight | Growth, delight | M |
| 11 | **Special-day prompts** (birthdays, holidays) without breaking once-a-day | Ritual around family moments | Delight | S |
| 12 | **Android / web viewer** for family members without iPhones | Whole-family coverage (E2EE needs a key-holding client) | Platform reach | L |

---

## 7. Baseline vs. after

| Check | Baseline (before any change) | After (final retest) |
|---|---|---|
| Debug build (clean) | ✅ success, 0 Swift warnings (2 benign `appintentsmetadataprocessor` notes) | ✅ success, 0 Swift warnings (same benign notes) |
| Release build (clean) | ✅ success, 0 warnings | ✅ success, 0 warnings; no `Supabase.plist` in the bundle |
| Static analyzer (`xcodebuild analyze`) | ✅ 0 issues | ✅ 0 issues |
| Strict concurrency (diagnostic build, `SWIFT_STRICT_CONCURRENCY=complete`) | 20 unique Swift 6 warnings (not errors in Swift 5 mode) | 20, the same set (none new): Haptics main-actor calls, non-Sendable service existentials, static ISO8601 formatters, SwiftData `#Predicate` key paths. Swift 6 migration item, not a polish fix |
| iOS unit tests | 78 / 78 passed, 0 skipped | **128 / 128** passed, 0 skipped |
| UI tests | none existed | **24 / 24** passed in each of 3 consecutive runs (no flakes) |
| Device matrix (9 UI tests: first launch, CTA layout, posting, two-account join, XXXL text, dark mode, 13-screen accessibility audit) | — | iPhone SE 3 **9/9** · iPhone 17 Pro **9/9** · iPhone 17 Pro Max **9/9** · iPad mini **9/9** |
| DB / RLS / RPC tests | none existed (first run of the new suite: 53 / 62 passed, the 9 failures = QA-01/02/04/05/06) | **69 / 69** on fresh `schema.sql` **and** 69 / 69 on deployed schema + migrations (clean `npm ci`) |
| App code coverage (line) | 20.9% (2549 / 12209) | **74.9%** (9678 / 12920), final commit |
| Linters / formatters | none configured | none configured |
| Dependencies | App: 0 third-party. Edge fn: supabase-js@2 (floating major, resolves to 2.118.0; 0 advisories), djwt@3.0.2 (latest) | + dev-only `@electric-sql/pglite@0.5.8` (tests only; 0 vulnerabilities, no transitive deps) |
| Secrets (gitleaks 8.30.1 over all history + working tree; custom regex over every object) | 0 real secrets (1 false positive). Dangling unreferenced blob = copy of prod plist (publishable anon key) | unchanged (see 4.8) |

---

## 8. Security, privacy and release readiness (summary of what was checked)

**Verified OK (no change needed):**
- Session tokens in the Keychain (`…AfterFirstUnlockThisDeviceOnly`), never UserDefaults. E2EE identity key in iCloud Keychain (by design). Refresh is single-flight.
- HTTPS only (non-https config rejected); no ATS exceptions. Entitlements: Sign in with Apple only.
- No `print`/logging outside `#if DEBUG`; DEBUG menu and mock code compiled out of Release; the Release build refuses to build without a live config.
- No server/admin keys in the repo, its history, or the app bundle (anon key is publishable by design; service-role key exists only as an edge-function secret).
- Privacy manifest matches collected data (email/phone slightly over-declared while that sign-in is off; FileTimestamp reason declared but unused; both harmless). `NSCameraUsageDescription` present and specific. PhotosPicker needs no library permission.
- UGC requirements: report + block present; in-app account deletion present; Terms gate with zero-tolerance terms present. Privacy policy text exists (PRIVACY.md): **replace the bracketed operator placeholders and host it** before review.
- Photos: E2EE (AES-GCM per photo, X25519 key wrapping); EXIF/GPS stripped; storage paths per-huddle, non-guessable UUIDs; bucket listing gated by membership (and, after QA-01, avatars by co-membership).
- Rate limiting: GoTrue limits OTP and refresh; **invite guessing now limited (QA-02)**; uploads limited only by bucket size and membership (a member could still upload junk; acceptable at this scale).

**Fixed:** QA-01, 02, 05, 06, 10, 13, 22, 28, 30 (see findings log).

**Open (recommendation):**
- QA-20: Apple token revocation on deletion can't run (no authorization code). Re-authenticate with Apple at deletion, send `authorizationCode`, exchange and revoke in the edge function.
- Edge function: returns `delErr.message` to the client (internal detail); CORS `*` unnecessary for a native client; floating `supabase-js@2` import (pin an exact, aged version in a `deno.json` + lockfile); no re-authentication before irreversible deletion; verify `deleteUser` succeeds for a user who owns Storage objects (avatars are deleted first, but deposit objects stay).
- `tools/decrypt_reported_photo`: the README example passes the key on argv (shell history); prefer `-` (stdin). Output written 0644 without overwrite protection.
- Custom URL scheme `huddlepal://` can be claimed by another app (invite codes in links). Prefer universal links.
- Crash reporting: none configured.
- Version/build: `MARKETING_VERSION 1.0`, `CURRENT_PROJECT_VERSION 2`; icon 1024 opaque single-size (fine for Xcode 26); display name "HuddlePals".


---

## 9. Accessibility audit (performAccessibilityAudit) — what's accepted and why

`AccessibilityAuditTests` audits 13 screens (Terms, welcome, profile step, shelf, Home locked/unlocked, deposit detail, archive, huddle settings, profile, create, join, compose). Every issue is attached to the result bundle; the test **fails on any issue outside these rules**, each checked by hand against the screenshots:
1. **Dynamic Type** (QA-21, open): fixed point sizes everywhere. Needs a design pass, not a polish fix.
2. **Contrast on disabled controls** (e.g. Agree before the Terms are read): WCAG 1.4.3 exempts inactive UI.
3. **Colour-emoji glyphs** (huddle emoji): contrast/clipping are measured on the glyph box; screenshots show them whole.
4. **Content under the translucent tab bar / comment bar / nav bar**: the audit measures against the overlay; the same text passes higher up the screen. Scrolled clear, it's legible.
5. **System keyboard** elements (not app UI).
6. **Hit-region on static text** (not a control).
7. **Issues with no element**, and Apple's **"nearly passed"** contrast warnings: recorded, not failed.
8. **Avatar initials** (1–2 letters, white on the member's colour): decorative; the name is always next to them.

## 10. Performance (simulator, Debug build; indicative only)

| Metric | Result |
|---|---|
| Launch to first responsive frame (`XCTApplicationLaunchMetric`, 5 runs) | **1.19 s** avg (RSD 0.7%) |
| Archive scroll, 30-day seeded history (`scrollDecelerationMetric`) | 2.43 s per fling sequence (RSD 0.01%) |
| Memory while scrolling the archive | peak ≈ 325 MB physical (simulator); growth during the scroll test ≈ 0.25 MB. Thumbnails are ImageIO-downsampled (a9966e0), so no per-tile 10 MB decodes |
| Backend at seeded volume | All hot paths indexed (test). The cost driver is the full-history re-download on every Home/Archive open (see 6.1); `recompute_streak` walks day by day with an indexed lookup per day: fine for years of history |

---

## 11. Commits on `polish` (none pushed)

- `4a5a465` test(supabase): add local database, RLS and RPC test suite
- `99e82e9` fix(storage): stop exposing profile photos to anyone with the anon key [QA-01]
- `536b706` fix(invites): limit wrong invite-code guesses to 10 per user per hour [QA-02]
- `c4bf538` fix(home): stop the streak-recovery countdown crashing after midnight [QA-07]
- `d08380c` fix(sync): page huddle history and chunk id filters so sync stays complete [QA-08]
- `f461439` fix(time): build day keys in the Gregorian calendar, whatever the user picked [QA-09]
- `dc12158` fix(huddles): hand the keeper role on when the keeper leaves or deletes their account [QA-04]
- `4abf413` fix(keys): remove a member's huddle-key copy when they leave [QA-05]
- `a5ce063` fix(schema): bound the huddle emoji and profile photo_paths server-side [QA-06]
- `5559f6a` fix(privacy): forget the account's local data on sign-out and deletion [QA-10]
- `835f348` fix(compose): keep the sheet up and post once while a photo uploads [QA-14]
- `d1c182a` fix(compose): explain a refused or restricted camera and link to Settings [QA-11]
- `a88b64f` fix(auth): keep a stored session signed in when launching offline [QA-12]
- `c7b5a78` fix(auth): return to sign-in when the server ends the session; keep it on 429 [QA-13]
- `19e7021` fix(archive): recompute the streak after backfilling yesterday [QA-15]
- `2268d70` fix(input): apply the server's text limits in the app, counting code points [QA-17]
- `0143219` fix(home): show loading and refresh-failed states instead of an empty day [QA-18]
- `10c1fae` fix(invites): open Join after sign-in for a link tapped while signed out [QA-16]
- `3bd621b` fix(storage): pin deposit photo paths to their huddle and keep cache paths inside Media [QA-22]
- `49efa92` fix(sync): re-adding a reaction or block is a no-op, not an error [QA-23]
- `b5c720a` fix(debug): make 'Regenerate seed data' work over an existing world [QA-24]
- `7985e10` fix(errors): stop calling access refusals an expired session [QA-25]
- `13be8ea` fix(settings): only the keeper can change the huddle's reminder hour [QA-26]
- `99af9f4` test(settings): fix the QA-26 keeper test so it compiles and signs in [QA-26]
- `b2adc17` chore(security): ignore credentials anywhere in the repo; add one test command [QA-28]
- `3be310d` fix(tests): never run the test host against the live backend [QA-30]
- `c18bb43` test(ui): add a HuddlePalUITests target with launch hooks for the journeys
- `1dd2ba4` fix(home): pin the deposit button above the floating tab bar [QA-31]
- `ce5bd21` fix(seed): paint the demo photos edge to edge [QA-32]
- `5b6fb52` docs: say sign-in is Apple-only today; email and SMS are behind a flag [QA-29]
- `4d0a7e0` test(photos): prove uploads carry no GPS/EXIF and are downscaled
- `d90f83b` test(ui): end-to-end journeys, unhappy paths, environment matrix, performance
- `66e4d6f` fix(a11y): label photos and avatars, honour Reduce Motion, fix contrast and targets [QA-27]
- `53fd496` chore(project): take Xcode's normalised scheme (parallelizable NO is the default)
- `2ed7f98` chore(tests): run the suite on a test-only simulator by default
- `76031c6` test(ui): make the tab-bar checks work where iPad puts the tab bar on top
- `9b70501` fix(profile): let the keyboard go away after editing the bio [QA-33]
- `5d24437` fix(shelf): let a huddle's status line wrap instead of truncating [QA-34]
- `f5aee96` test(ui): open tabs on iPad too, where the tabs sit in a top bar
- `c0d313a` fix(tests): don't clobber PATH in test-all.sh's ignore check [QA-28]
