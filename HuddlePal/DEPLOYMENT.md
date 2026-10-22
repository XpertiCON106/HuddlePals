# HuddlePals — Go-Live Runbook

Everything code-side is already in this repo. This file is the ordered
checklist of the account-side steps only you can do. Total hands-on time:
roughly an afternoon, most of it waiting on Apple.

The app picks its backend at launch: if `HuddlePal/HuddlePal/Supabase.plist` exists
with real values, it runs **live** against Supabase; otherwise it runs the
seeded **mock** world. No code changes to switch.

> **Release builds require the plist.** A build-phase guard fails any
> Release build (including Archive) when `Supabase.plist` is missing or
> still holds placeholder values, so the mock world can never reach
> TestFlight or the App Store by accident. Debug builds are unaffected.

---

## Phase 1 — Supabase (~30 minutes, free tier)

1. Create a project at [supabase.com](https://supabase.com) (any region near
   your group; note the database password somewhere safe).
2. **Auth providers** (Dashboard → Authentication):
   - **Email** (on by default): under *Emails → Templates*, edit the
     **Magic Link** template so its body contains `{{ .Token }}` — e.g.
     "Your HuddlePals code is {{ .Token }}. It expires in one hour." — so users
     receive a code instead of a link. Then check **Email OTP Length**
     (Authentication → Email): the app expects 6 digits unless you set
     `EMAIL_OTP_LENGTH` in `Supabase.plist` to the same number — otherwise
     the code won't fit the boxes. The built-in mailer is
     rate-limited to a few emails per hour: fine for your own testing, but
     configure custom SMTP (*Settings → Auth → SMTP*) before inviting the
     group.
   - **Phone** (optional, costs money): *Sign In / Up → Phone* → enable,
     then connect an SMS provider — Twilio is the documented path (Account
     SID, Auth Token, Messaging Service SID). Until this is configured, the
     app's Phone tab will return the provider's error; Apple + email work
     without it.
   - **Apple**: *Sign In / Up → Apple* → enable, and add your app's bundle
     id (`com.huddlepals.ios`) to **Client IDs**. The native iOS
     flow needs no secret key.
3. **Storage** → *New bucket* → name `deposits`, **Private** (not public).
   (Profile photos live in the same bucket under `avatars/…` — the schema's
   storage policies cover both namespaces; no second bucket needed.)
   **Then set the bucket's limits** (bucket → settings): **file size limit
   ~5 MB** and **allowed MIME types** `image/jpeg, application/octet-stream`
   (profile photos are JPEGs; huddle photos are end-to-end encrypted
   ciphertext). Without this, a malicious client can upload unbounded data
   and run up your bill.
4. **SQL Editor** → *New query* → paste the entire contents of
   [`supabase/schema.sql`](supabase/schema.sql) → Run. This creates the
   tables (profiles, huddles, memberships, deposits, reactions, comments,
   skips, **reports, blocks, user_keys, huddle_keys, huddle_invite_keys,
   device_tokens**), every RLS policy + column grant, the storage policies,
   the RPCs (`create_huddle`, `join_huddle`, `spend_skip_token`,
   `recompute_streak`, the end-to-end encryption functions
   `init_huddle_key`, `huddle_key_recipients`, `share_huddle_key`, the
   invite functions `redeem_huddle_invite`, `huddle_invite`,
   `create_huddle_invite`, `reset_huddle_invite`, `save_own_huddle_key`, and
   their helpers), and the push triggers. The security hardening (skip-token
   auth, crypto invite codes, streak-tamper protection), join-day streaks,
   encrypted photos and instant join are baked in. Push notifications need
   the APNs key, secrets and `send-push` function from DEVELOPMENT.md
   ("Push notifications (APNs)").
   The file only builds a fresh database. If the project already ran an
   older copy, start over: run `supabase/scripts/reset_database.sql`
   (destructive — it drops every app table, function, and storage policy,
   and keeps `auth.users`), empty the `deposits` bucket in the Storage
   dashboard, then run `schema.sql`.
5. **Deploy the account-deletion edge function** (required for App Review —
   see "Account deletion" below): `supabase functions deploy delete-account`.
   It trades the Apple authorization code the app sends for the user's Apple
   tokens and revokes them, deletes their avatars, releases their deposit
   photos, and deletes the auth user (deposits stay as "Former member"; the
   user's encryption keys cascade away with the account). Set the four
   Apple secrets so revocation works: `APPLE_TEAM_ID`, `APPLE_KEY_ID`,
   `APPLE_CLIENT_ID=com.huddlepals.ios` and `APPLE_PRIVATE_KEY` (the `.p8`
   contents). [DEVELOPMENT.md](DEVELOPMENT.md) → "Account deletion and
   Apple token revocation" has the key setup and the exact commands.
6. **Settings → API**: copy the **Project URL** and the **anon public key**.
7. **Set up report monitoring**: the `reports` table fills when users flag
   content — watch it (a saved dashboard query, or a Database Webhook to
   email/Slack) and act within 24 h, as App Review requires. Photos are
   end-to-end encrypted, so the dashboard can't show them: a report carries
   that one photo's key (`reports.photo_key`), and
   [`tools/decrypt_reported_photo`](tools/decrypt_reported_photo/README.md)
   turns the downloaded Storage object back into a JPEG.

## Phase 2 — Point the app at it (~5 minutes)

1. Copy `supabase/Supabase.example.plist` → `HuddlePal/HuddlePal/Supabase.plist`.
2. Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY`. If your project's email
   or SMS codes aren't 6 digits, also set `EMAIL_OTP_LENGTH` /
   `SMS_OTP_LENGTH` to match (both optional, default 6).
   (`Supabase.plist` is gitignored; the anon key is publishable by design —
   RLS is the security boundary.)
3. Run on a simulator. You should see onboarding (no "The Crew", no DEBUG
   section in Profile) → sign in with an email code (or Apple) → pick a
   name and color → "No huddle yet" → create a huddle → a server-generated
   invite code. Sign out from Profile, sign back in with the same email:
   you land straight back in your huddle — no profile step the second time.

## Phase 3 — Apple Developer + TestFlight (~1–2 hours + review wait)

1. Enroll at [developer.apple.com](https://developer.apple.com/programs/)
   ($99/year). Approval is usually same-day.
2. In Xcode, select the **HuddlePal** target → *Signing & Capabilities* →
   choose your **Team**. The bundle id is `com.huddlepals.ios`; change it in
   *Build Settings* only if Xcode reports a collision. The **Sign in with Apple** entitlement is
   already in the project (`HuddlePal.entitlements`); with automatic signing,
   Xcode registers the capability on your App ID — this requires the paid
   program, and if you change the bundle id, update the Client IDs list in
   Supabase's Apple provider to match.
3. [App Store Connect](https://appstoreconnect.apple.com) → *My Apps* →
   **+** → New App → platform iOS, the same bundle id, a name, primary
   language. (The 1024px icon, privacy manifest, and the
   `ITSAppUsesNonExemptEncryption = NO` export-compliance flag are already
   in the project. The photo end-to-end encryption uses only Apple's
   CryptoKit, i.e. encryption within the operating system — keep the flag
   unless you add your own or bundled crypto; see "Export compliance"
   below.) Users must agree to the Terms of Service in-app before they
   can sign in (`HuddlePal/Legal/TermsOfService.md`). Publish that same
   text at https://huddlepals.com/terms and PRIVACY.md at
   https://huddlepals.com/privacy, the URLs the Terms cite. Then paste
   the Terms into the app record's **License Agreement** field (App
   Information), replacing Apple's standard EULA; they already include
   Apple's required minimum terms (Section 14).
4. Xcode: select **Any iOS Device (arm64)** → *Product → Archive* →
   *Distribute App → App Store Connect → Upload*.
5. App Store Connect → your app → **TestFlight** tab:
   - **Internal Testing**: create a group, add up to 100 testers by their
     Apple-account emails. Available within minutes of the build finishing
     processing. **This is your friends-and-family test. Stop here.**
   - External Testing (later, optional): needs a short beta review.
6. Testers install via the TestFlight app from the invite email.
7. **Submit for App Review** (the version page in App Store Connect):
   - **Privacy Policy URL** `https://huddlepals.com/privacy` (publish the
     current PRIVACY.md there first) and **Support URL**
     `https://huddlepals.com/support`. The app links both from
     Profile → About, with the contact address in `Support/AppLinks.swift`;
     keep the website's contact address the same.
   - **App Privacy** answers matching `PrivacyInfo.xcprivacy`; **age
     rating** with "user-generated content" answered yes; **screenshots**
     for iPhone and for 13-inch iPad (the app is Universal).
   - **Account deletion** must work on the live backend: migrations
     001–007, the Apple secrets and the `delete-account` function
     (DEVELOPMENT.md), then delete a test account on the TestFlight build.
   - **App Review notes.** Sign in with Apple is the only sign-in, so no
     demo account is needed. Reviewers can't see the core loop alone, so
     consider a demo huddle where a test account posts daily, and paste
     something like this:

     > HuddlePals is a private, invite-only photo app for small groups (up
     > to 8 people who know each other). Sign in with Apple is the only
     > sign-in. To try it: agree to the Terms, sign in, create a huddle and
     > take today's photo. Other members' photos for today unlock once you
     > post yours. To see a group with other members, join with invite
     > code <CODE>. Content safeguards (guideline 1.2): everyone agrees to
     > the Terms (zero tolerance for objectionable content) before signing
     > in; any photo (••• menu), comment (touch and hold) or profile (•••
     > menu) can be reported; members can be blocked; we review reports
     > within 24 hours. Photos are end-to-end encrypted; a report sends us
     > that one photo's key so we can review it. Account deletion: Profile
     > → Delete account (Apple confirms, then the account is deleted and
     > its Sign in with Apple token revoked).

## Phase 4 — Two-phone smoke test (~10 minutes)

1. Phone A: onboard with an email code (or Apple) → Create a Huddle →
   share the invite code.
2. Phone B: onboard with a different account → Join a Huddle with that code.
3. Phone A: deposit a photo (with notifications set up, B gets "… posted
   a photo"). Phone B: pull-to-refresh on Today → A's deposit shows
   **blurred**; B's huddle is LOCKED. B never needed A's app to be open:
   the invite code carried the huddle key.
4. Phone B: deposit → unlock animation → both photos visible; streak
   shows 1 the next day (server-computed, so both phones agree).
   Dashboard → Storage → `deposits` → the huddle's folder: the files don't
   open as images (ciphertext).
5. React + comment from both sides; check Archive on both.
6. Profile → turn on **Daily reminder** and pick a time → accept the
   notification permission prompt → reminders are scheduled (today's go
   quiet once you've posted in every huddle). The hour in Huddle Settings is
   only the huddle's stored preference; it doesn't schedule anything.
7. Phone A: open B's photo → "•••" → Report. In the SQL Editor the new
   `reports` row has a `photo_key`; download the object and decrypt it with
   `tools/decrypt_reported_photo`.
8. Phone B: Profile → **Delete account**. Phone A: pull-to-refresh → B's
   photos and comments are still there as "Former member" (still
   decryptable — A holds the huddle key), and the photo's "•••" menu still
   offers Report.

---

> Already ran an earlier `schema.sql`? There are no upgrade migrations —
> start over with [`supabase/scripts/reset_database.sql`](supabase/scripts/reset_database.sql)
> as in Phase 1 step 4, and make sure the `deposits` bucket allows
> `application/octet-stream` (keep `image/jpeg`); without it, posting a
> photo fails.

## Caveats you accepted by shipping this MVP

- **Accounts are durable.** Sign in with Apple, email codes, and SMS codes
  all resolve to the same Supabase user for the same identity — sign out
  and back in freely. One sharp edge: Apple shares the user's name only on
  the *first* authorization (the app prefills it into the profile step);
  to see that again you must revoke the app under Settings → Apple ID →
  Sign-In & Security. Also note: signing in with email X and separately
  with phone Y creates two different accounts — identity *linking* is a
  later upgrade.
- **OTP limits.** GoTrue allows one code request per destination per 60
  seconds (the app's resend button respects this), codes expire after an
  hour by default, and the built-in mailer caps at a few emails per hour
  until you configure SMTP.
- **Refresh model.** Deposits from others appear on app-foreground and
  pull-to-refresh (Supabase Realtime is the upgrade). Activity push
  notifications (new photos, comments and reactions on yours, new members)
  arrive through APNs once DEVELOPMENT.md's push setup is done; the daily
  reminder is local.
- **Timezones.** dayKey is the *device's* calendar day, and the server
  trusts the client's "today" for streaks (RLS only clamps deposits to a
  48h window). Same-timezone groups: no issue. Split-timezone groups can
  see edge-of-day disagreements — a huddle "home timezone" is the fix.
- **Account deletion (Model B).** "Delete account" in Profile removes the
  account, login, name, and avatars and revokes the Apple tokens (Apple
  confirms the person first), but
  **deposited photos stay in shared huddles as "Former member"** — the
  archive is permanent (disclose this in your privacy policy; see
  [PRIVACY.md](PRIVACY.md)). Deletion runs through the `delete-account` edge
  function, which holds the `service_role` key — never put that key in the
  app.
- **Permanent storage grows forever.** Deposits are never deleted, so
  storage cost only rises. Images are now downscaled before upload
  (~1440px deposits, ~512px avatars) to keep that growth ~10× slower —
  budget Supabase Pro for backups + headroom.
- **End-to-end encrypted photos.** Neither you nor Supabase can view
  deposited photos; you can view a reported one with the key its report
  carries. The keys live on members' devices: each user's identity key is
  in their iCloud Keychain. New members get the huddle key from their
  invite code, so they see every photo at once. A member who loses their
  identity key (new phone with iCloud Keychain off, or a reinstall without
  it) gets a new one and sees locked photos until another member's app
  re-shares each huddle key.
  If *nobody* left in a huddle still holds its key, its photos are
  unrecoverable — by design, no one else can open them. Using one account
  on two devices needs iCloud Keychain on; without it, the device that
  launched most recently is the one that can decrypt. Leaving a huddle
  doesn't rotate its key (Storage RLS stops a former member downloading
  new photos), and they may still hold the invite code: the keeper can make
  a new one in Huddle Settings. Captions, comments,
  reactions, profiles, and avatars are not encrypted.
- **Streak source of truth** is the `recompute_streak` RPC (server-side).
  The local `HuddleEngine` math stays as the mock/test implementation —
  keep the two in sync if you change the rules.

## What tests can't verify

The app builds and its XCTest suite passes in Xcode, and the live layer is
being exercised by hand against the real project (fixes so far: lowercase
avatar paths, the reports select policy, `extensions.gen_random_bytes`).
Nothing over HTTP is covered by tests, so give these a deliberate pass on
a device before TestFlight:

- the OTP `/verify` response shape and the Apple `id_token` grant;
- PostgREST error-message pass-through in `SupabaseClient.check` (e.g.
  joining a full huddle should say "8 members", not a generic error);
- **posting a photo** — uploads are insert-only (no `x-upsert`), so the
  storage INSERT policy alone must allow it;
- the huddle list's single `deposits?select=huddle_id,author_id&day_key=eq.…`
  read (lock icons and "N waiting for you" on the shelf);
- the `delete-account` edge function end-to-end, then step 7 of Phase 4;
- the **join-day streak SQL** (`client_day_key`, `huddle_day_complete`, the
  new `create_huddle` / `join_huddle` signatures, `recompute_streak`) has
  never been executed against Postgres. After running its migration,
  create a huddle, join it from a second account, and check the streak
  doesn't drop.
- the **end-to-end encryption SQL and key sharing** (`user_keys`,
  `huddle_keys`, `init_huddle_key`, `huddle_key_recipients`,
  `share_huddle_key`) passed a Postgres parser but has never run against a
  database; the crypto itself is unit-tested. Run Phase 4 steps 1–4 and 7
  after applying the migration, and check `select * from huddle_keys` shows
  one row per member for the huddle.

## Export compliance

App Store Connect asks about encryption on every build unless
`ITSAppUsesNonExemptEncryption` is set (it is, to `NO`, in the build
settings). HuddlePals' encryption is HTTPS (URLSession) plus Apple's CryptoKit
for the photo end-to-end encryption: standard algorithms (AES-GCM, X25519,
HKDF-SHA256) used through the operating system, with no proprietary or
bundled crypto. Apple treats encryption "within Apple's operating system"
as exempt from documentation uploads, so the flag stays `NO`; if the form
is ever shown, the matching answer to "What type of encryption algorithms
does your app implement?" is **None of the algorithms mentioned above**.
If you add a third-party crypto library or your own algorithm, revisit
this — that would require `YES` and export documentation. (Not legal
advice; Apple's "Complying with encryption export regulations" page is
the reference.)
