# HuddlePal — Deployment Readiness Report

_Audit date: 2026-07-03 · Branch: `release-readiness` · Auditor: automated pre-submission audit (Claude Code)_

Toolchain used for verification: **Xcode 26.1.1 (17B100), iOS 26.1 SDK** — satisfies Apple's
current submission floor (since **April 28, 2026** uploads must be built with Xcode 26 / iOS 26 SDK,
per [Apple's upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)).

**Proof of green:** Release build succeeds (`xcodebuild -configuration Release`, zero warnings) and
the full test suite passes — 20/20 (16 `HuddleEngineTests` + 4 new `CriticalFlowTests`). A clean
install of the Debug build was launched on an iPhone 17 Pro simulator and lands correctly on the
seeded Huddles shelf with no crash.

---

## 1. Verdict

**Not submittable today — but only for account-side reasons, not code.** Every code-side item found
was fixed on this branch. What remains is work only a human with the Apple/Supabase accounts can do:

| # | 🚫 Blocker (ranked) | Why |
|---|---|---|
| 1 | **No live backend exists yet.** No Supabase project has been created; `Supabase.plist` is absent; per `DEPLOYMENT.md` the live layer has *never made a real request*. | The Release build now (deliberately) refuses to build without live config. Create the Supabase project, run `schema.sql`, deploy the `delete-account` edge function, create the private `deposits` bucket with size/MIME limits, then bundle the plist. Budget time to shake out wire-format surprises — the live client is untested against a real project. |
| 2 | **Bundle identifier is `com.vaultphotos.app`.** | A "-test" suffix in a production bundle ID looks like a leftover device-testing workaround. Decide the final ID (docs assume `com.vaultphotos.app`), set it in Build Settings, create the matching App Store Connect record, and update the **Client IDs** list in Supabase's Apple provider to match. I did not change it — bundle ID choice is yours. |
| 3 | **Sign in with Apple capability must be registered on the App ID.** | The entitlement is now in the project (fixed here), but with automatic signing Xcode must register the capability against *your* team/App ID — requires the paid developer account. |
| 4 | **Account deletion path must actually work before review.** | Guideline 5.1.1(v) is a hard rejection. The in-app flow and edge function exist, but the function has never been deployed/run. Deploy it and delete a test account end-to-end before submitting. |

Once those four are done (plus the App Store Connect paperwork in §3), this build is submittable.

---

## 2. Change log (everything fixed on this branch)

### Phase 1 — Build integrity
- ✅ **Baseline verified before any change:** Release build clean (0 errors / 0 warnings), 16/16 tests green.
- ✅ **DEBUG demo tools compiled out of Release** (`b001769`) — the Profile DEBUG section (force
  gate shut, advance mock day, regenerate seed data) was only runtime-gated on backend mode; a
  Release binary built without `Supabase.plist` would have shipped a visible DEBUG menu.
  Now `#if DEBUG` in [ProfileView.swift](HuddlePal/HuddlePal/Views/Profile/ProfileView.swift) and
  [ProfileViewModel.swift](HuddlePal/HuddlePal/ViewModels/ProfileViewModel.swift).
- ✅ **Release builds fail without live backend config** (`680db0e`) — new Release-only build phase
  in [project.pbxproj](HuddlePal/HuddlePal.xcodeproj/project.pbxproj) errors with instructions when
  `HuddlePal/Supabase.plist` is missing or still contains placeholders, so the seeded mock world can
  never be archived by accident. Verified in all three directions (Release w/o plist → fails with
  message; Release with plist → succeeds; Debug w/o plist → succeeds).
  [DEPLOYMENT.md](HuddlePal/DEPLOYMENT.md) updated to document this.
- ✅ Versioning confirmed sane: `CFBundleShortVersionString` 1.0, `CFBundleVersion` 1, iOS 17.0 target.
- ✅ Clean-install first launch verified on simulator (mock world, locked state, no crash).

### Phase 2 — App Store compliance
- ✅ **Missing Sign in with Apple entitlement added** (`5a2779a`) —
  [HuddlePal.entitlements](HuddlePal/HuddlePal/HuddlePal.entitlements) was an **empty dict** while the app offers
  SIWA + email/phone login. Without it the live ASAuthorization flow fails on device, and offering
  email/phone login without SIWA violates Guideline 4.8.
- ✅ **Privacy manifest completed** (`07c4c28`) —
  [PrivacyInfo.xcprivacy](HuddlePal/HuddlePal/PrivacyInfo.xcprivacy) declared Photos/Name/UserID but not
  **email address, phone number** (OTP sign-in) or **other user content** (captions, comments,
  bios). All added: linked, non-tracking, app-functionality. `plutil -lint` clean; verified present
  in the built bundle.
- ✅ Verified (no change needed): `NSCameraUsageDescription` present and specific; `PhotosPicker`
  needs no photo-library permission (out-of-process picker); no ATS exceptions;
  `ITSAppUsesNonExemptEncryption = NO` (standard HTTPS + CryptoKit hashing only — exempt); no
  private APIs (system frameworks only); no background modes; no tracking → no ATT; 1024×1024 icon
  **without alpha**; generated launch screen; UGC safeguards (report + block + moderation tables)
  present per Guideline 1.2; in-app account deletion present per 5.1.1(v); no payments/IAP surface.

### Phase 3 — Security
- ✅ **Secrets sweep clean** — no keys/tokens/passwords in the working tree; full git-history scan
  (including a vestigial React/FastAPI project from May 2026) found only placeholder values
  (`SECRET_KEY=your-secret-key-here`). **Nothing needs rotation.**
- ✅ Session tokens in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never
  UserDefaults; all traffic HTTPS (enforced in `BackendConfig` — non-https config is rejected);
  the only `print` statements are `#if DEBUG` inside mock services; no hidden dev backdoors reachable
  in Release (after the Phase 1 fixes).
- ✅ Reviewed `schema.sql` RLS + storage policies and the `delete-account` edge function — sound
  (deposit immutability enforced server-side; skip-token/streak RPCs auth-clamped; reports readable
  only by the operator).

### Phase 4 — Stability
- ✅ **`SupabaseClient` hardened** (`a27644c`,
  [SupabaseClient.swift](HuddlePal/HuddlePal/Services/Live/SupabaseClient.swift)): converted to an **actor**
  (its `session` was unsynchronized shared mutable state across concurrent refresh flows);
  **single-flight token refresh** (GoTrue refresh tokens are single-use — parallel refreshes could
  invalidate the session and sign the user out); **transient refresh failures no longer wipe the
  Keychain session** (offline at launch previously forced a re-login); three force-unwrapped URL
  constructions replaced with thrown errors.
- ✅ **Archive no longer blanks on a failed refresh** (`dc50df5`) — a transient error collapsed a
  full archive to the "starts today" empty state; it now keeps last-known content like Home does.
- ✅ Audited every view model: all user-initiated network paths surface errors and stop spinners
  (`defer { isWorking = false }` pattern throughout); no force casts; the one remaining `try!`
  ([AppDependencies.swift:186](HuddlePal/HuddlePal/App/AppDependencies.swift:186)) is a documented
  last-resort fallback creating an *in-memory* store, which cannot realistically fail — left as is.

### Phase 5 — Performance & size
- ✅ **Thumbnail decodes downsampled** (`a9966e0`,
  [DepositCards.swift](HuddlePal/HuddlePal/Components/DepositCards.swift)) — archive tiles (110pt) and
  profile strips decoded full 1440px bitmaps (~10 MB RAM each); now ImageIO thumbnail decode capped
  at the tile's @3x pixel size. Full-bleed contexts unchanged.
- ✅ Launch path is light (async bootstrap behind the reveal animation; no synchronous network).
- ✅ Size: app bundle ≈ **6 MB** before thinning (only asset is the 568 KB icon; zero dependencies).
  Expect a store download of a few MB. Nothing bloats it.
- ℹ️ The on-device media cache grows with the archive by design (deposits are permanent); server
  storage growth is mitigated by upload downscaling (~1440px/0.8 JPEG).

### Phase 6 — Tests
- ✅ **New smoke tests for critical flows**
  ([CriticalFlowTests.swift](HuddlePal/HuddlePalTests/CriticalFlowTests.swift)): bootstrap auto-sign-in +
  both seeded huddles locked; deposit → gate unlocks; second same-day deposit refused
  (once-and-permanent); create → join (case-insensitive code) → duplicate-join and bad-code
  refusals; sign-out round trip. **Final run: 20/20 green; final Release build: clean.**

### Phase 7 — Dependencies
- ✅ **Zero third-party dependencies** in the app (imports are all Apple frameworks; the Supabase
  client is hand-rolled over URLSession). No lockfiles needed; build is reproducible by construction;
  no license exposure (the repo's own LICENSE is proprietary — fine for the App Store since you are
  the copyright holder).
- ℹ️ The server-side edge function imports `@supabase/supabase-js@2` (major-pinned) and
  `djwt@v3.0.2` (exact) from CDNs at deploy time. Consider pinning supabase-js to an exact version
  when you deploy.

### Phase 8 — Accessibility (quick pass)
- ✅ **Labels + tap target** (`5f504ae`): VoiceOver labels for every icon-only control (archive /
  settings toolbar, add-huddle menu, both more-options menus, send-comment, retake-photo,
  remove-photo, state-aware reaction labels); remove-photo tap target enlarged to ~44pt.
- Logged as P3 (not fixed): the app uses fixed point sizes throughout, so **Dynamic Type is
  effectively ignored** — layouts won't break (they don't scale), but large-text users get small
  text. A `.dynamicTypeSize` adoption pass is a post-launch improvement.

### Housekeeping
- ✅ Untracked `xcuserdata`, `*.xcuserstate`, `.DS_Store` from git; added root `.gitignore` (`800b57f`).

---

## 3. Human-only checklist (derived from this codebase)

**Accounts & signing**
- [ ] Apple Developer Program enrollment ($99/yr); Xcode → Signing & Capabilities → select Team
      (project currently carries team `BCK77N7264` — confirm it's yours).
- [ ] Decide the final bundle ID (🚫 #2 above) and create the App Store Connect app record with it.
- [ ] Let automatic signing register the **Sign in with Apple** capability on the App ID.

**Backend (follow [DEPLOYMENT.md](HuddlePal/DEPLOYMENT.md) — it's accurate and ordered)**
- [ ] Create the Supabase project; run `supabase/schema.sql`; create **private** `deposits` bucket
      with ~5 MB file limit and `image/jpeg, image/heic` MIME allowlist.
- [ ] Enable Auth providers: Email (edit Magic Link template to send `{{ .Token }}`), Apple (add
      your bundle ID to Client IDs), Phone only if you configure Twilio — otherwise consider hiding
      expectations around SMS in your release notes.
- [ ] Configure custom SMTP before inviting real users (built-in mailer is a few emails/hour).
- [ ] Deploy `delete-account` (`supabase functions deploy delete-account`) and set
      `APPLE_TEAM_ID / APPLE_KEY_ID / APPLE_SERVICE_ID / APPLE_PRIVATE_KEY` secrets; **test a real
      account deletion end-to-end** (🚫 #4).
- [ ] Set up `reports`-table monitoring (dashboard query or webhook → email) — App Review expects
      UGC reports acted on within 24h.
- [ ] Copy `supabase/Supabase.example.plist` → `HuddlePal/HuddlePal/Supabase.plist` with real values on the
      machine you archive from (gitignored; Release build fails without it — by design).

**App Store Connect record**
- [ ] Category: Photo & Video (or Social Networking); age rating questionnaire — with UGC,
      expect 12+ ("Infrequent/Mild User-Generated Content") unless you argue otherwise.
- [ ] **Privacy nutrition labels** — copy these (derived from the code + privacy manifest):
      - *Contact Info*: Email Address, Phone Number — app functionality, linked to identity, no tracking
      - *User Content*: Photos or Videos; Other User Content (captions, comments, bio) — app functionality, linked, no tracking
      - *Identifiers*: User ID — app functionality, linked, no tracking
      - *Name*: display name — app functionality, linked, no tracking
      - Data used for tracking: **none**. Third-party data collection: **none** (Supabase is your
        processor, not an SDK in the binary).
- [ ] Support URL + **privacy policy URL** — host [PRIVACY.md](HuddlePal/PRIVACY.md) somewhere public;
      its content already matches what the app collects (verified). Replace the bracketed
      operator-name placeholders before publishing.
- [ ] Review notes: **provide a demo login** (an email address on a mailbox App Review can't read
      won't work — either set up a test account with a code you can relay, or note that Sign in
      with Apple works with any reviewer Apple ID and onboarding is self-serve). Explain the
      reciprocity gate ("today's photos stay blurred until the reviewer deposits one") so it isn't
      mistaken for broken functionality — and note deposits are camera-only.
- [ ] Screenshots for 6.9" and 6.5" iPhone (and iPad 13" **if you keep iPad support** — see below).
- [ ] Export compliance: answer "None of the algorithms mentioned" / standard encryption exempt —
      consistent with `ITSAppUsesNonExemptEncryption = NO` already in the project.
- [ ] Content rights: all UGC; you hold rights to the app's own assets (icon is generated in-repo).

**Decisions to make (⚠️ flagged, not changed)**
- [ ] **Device family** is currently Universal (iPhone + iPad). The UI renders on iPad but is
      designed for iPhone. Recommendation: set `TARGETED_DEVICE_FAMILY = 1` (iPhone-only, still
      installable on iPad in compatibility mode) for the MVP — it removes the iPad screenshot
      requirement and review surface. Keeping Universal is fine too; then test on an iPad first.
- [ ] **Timezone caveat** (documented in DEPLOYMENT.md): dayKey is device-local and the server
      trusts the client's "today" within ±1 day. Same-timezone groups: fine. Split-timezone groups
      can see edge-of-day disagreements. Acceptable for launch; a huddle "home timezone" is the fix.
- [ ] Terms of Service / EULA: Apple's standard EULA applies by default; UGC apps benefit from an
      in-app link to terms with a zero-tolerance policy. PRIVACY.md covers reporting/blocking;
      consider adding a short terms page next to the privacy policy.

---

## 4. TestFlight plan (shortest sensible pass)

1. **Internal (you + 1 friend, 1–2 days):**
   - Two-phone smoke test from DEPLOYMENT.md Phase 4: onboard via email code on A, via Apple on B;
     create huddle on A, join by code on B; deposit on A (blurred on B), deposit on B (unlock
     animation both sides); react + comment both ways; archive on both.
   - Kill/relaunch both apps (session restore); airplane-mode launch (must show sign-in/error, not
     hang, and must **not** log you out — fixed on this branch).
   - Set the daily reminder, accept the permission prompt, verify a notification fires and is
     suppressed after depositing.
   - **Delete account** on B; verify B's photos remain as "Former member" on A, and B can re-onboard.
2. **Internal group (the real 2–8 person huddle, 3–5 days):** exercise the streak across real
   midnights, one skip token, one deliberate miss → recovery-window backfill before the countdown
   expires. Watch Supabase logs + `reports` table.
3. Only then (optional) external TestFlight — requires beta review; with a working demo account
   that review doubles as a dry run for App Review proper.

---

## 5. Commits on `release-readiness`

| Commit | Change |
|---|---|
| `800b57f` | chore: stop tracking user-state and .DS_Store files |
| `5a2779a` | fix: add missing Sign in with Apple entitlement |
| `b001769` | fix: compile DEBUG demo tools out of Release builds |
| `680db0e` | build: fail Release builds that lack live backend config |
| `07c4c28` | fix: declare email, phone, and user-content collection in privacy manifest |
| `a27644c` | fix: harden SupabaseClient session handling for concurrent use |
| `dc50df5` | fix: keep last-known archive on a failed refresh |
| `a9966e0` | perf: downsample thumbnail decodes in archive and profile strips |
| `5f504ae` | a11y: label icon-only controls and enlarge the remove-photo target |
| `8a269d0` | test: add smoke tests for launch, deposit gate, and create/join flows |
| *(this)* | docs: deployment readiness report + runbook note |
