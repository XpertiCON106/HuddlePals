# Vault — Go-Live Runbook

Everything code-side is already in this repo. This file is the ordered
checklist of the account-side steps only you can do. Total hands-on time:
roughly an afternoon, most of it waiting on Apple.

The app picks its backend at launch: if `Vault/Vault/Supabase.plist` exists
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
     "Your Vault code is {{ .Token }}. It expires in one hour." — so users
     receive a 6-digit code instead of a link. The built-in mailer is
     rate-limited to a few emails per hour: fine for your own testing, but
     configure custom SMTP (*Settings → Auth → SMTP*) before inviting the
     group.
   - **Phone** (optional, costs money): *Sign In / Up → Phone* → enable,
     then connect an SMS provider — Twilio is the documented path (Account
     SID, Auth Token, Messaging Service SID). Until this is configured, the
     app's Phone tab will return the provider's error; Apple + email work
     without it.
   - **Apple**: *Sign In / Up → Apple* → enable, and add your app's bundle
     id (default `com.vaultapp.Vault`) to **Client IDs**. The native iOS
     flow needs no secret key.
3. **Storage** → *New bucket* → name `deposits`, **Private** (not public).
   (Profile photos live in the same bucket under `avatars/…` — the schema's
   storage policies cover both namespaces; no second bucket needed.)
   **Then set the bucket's limits** (bucket → settings): **file size limit
   ~5 MB** and **allowed MIME types** `image/jpeg, image/heic`. Without this,
   a malicious client can upload unbounded data and run up your bill.
4. **SQL Editor** → *New query* → paste the entire contents of
   [`supabase/schema.sql`](supabase/schema.sql) → Run. This creates the nine
   tables (profiles, vaults, memberships, deposits, reactions, comments,
   skips, **reports, blocks**), every RLS policy + column grant, the storage
   policies, and four RPCs (`create_vault`, `join_vault`, `spend_skip_token`,
   `recompute_streak`). The security hardening (skip-token auth, crypto
   invite codes, streak-tamper protection) is baked in.
5. **Deploy the account-deletion edge function** (required for App Review —
   see "Account deletion" below): `supabase functions deploy delete-account`.
   It revokes the user's Apple token, deletes their avatars, and deletes the
   auth user (deposits stay as "Former member"). If you keep Sign in with
   Apple, set the Apple secrets so revocation works:
   `supabase secrets set APPLE_TEAM_ID=… APPLE_KEY_ID=… APPLE_SERVICE_ID=<bundle id> APPLE_PRIVATE_KEY="$(cat AuthKey_XXX.p8)"`.
6. **Settings → API**: copy the **Project URL** and the **anon public key**.
7. **Set up report monitoring**: the `reports` table fills when users flag
   content — watch it (a saved dashboard query, or a Database Webhook to
   email/Slack) and act within 24 h, as App Review requires.

## Phase 2 — Point the app at it (~5 minutes)

1. Copy `supabase/Supabase.example.plist` → `Vault/Vault/Supabase.plist`.
2. Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
   (`Supabase.plist` is gitignored; the anon key is publishable by design —
   RLS is the security boundary.)
3. Run on a simulator. You should see onboarding (no "The Crew", no DEBUG
   section in Profile) → sign in with an email code (or Apple) → pick a
   name and color → "No vault yet" → create a vault → a server-generated
   invite code. Sign out from Profile, sign back in with the same email:
   you land straight back in your vault — no profile step the second time.

## Phase 3 — Apple Developer + TestFlight (~1–2 hours + review wait)

1. Enroll at [developer.apple.com](https://developer.apple.com/programs/)
   ($99/year). Approval is usually same-day.
2. In Xcode, select the **Vault** target → *Signing & Capabilities* →
   choose your **Team**. Change the bundle id from `com.vaultapp.Vault` to
   something you own (e.g. `com.yourname.vault`) in *Build Settings* if
   Xcode reports a collision. The **Sign in with Apple** entitlement is
   already in the project (`Vault.entitlements`); with automatic signing,
   Xcode registers the capability on your App ID — this requires the paid
   program, and if you change the bundle id, update the Client IDs list in
   Supabase's Apple provider to match.
3. [App Store Connect](https://appstoreconnect.apple.com) → *My Apps* →
   **+** → New App → platform iOS, the same bundle id, a name, primary
   language. (The 1024px icon, privacy manifest, and the
   `ITSAppUsesNonExemptEncryption = NO` export-compliance flag are already
   in the project.)
4. Xcode: select **Any iOS Device (arm64)** → *Product → Archive* →
   *Distribute App → App Store Connect → Upload*.
5. App Store Connect → your app → **TestFlight** tab:
   - **Internal Testing**: create a group, add up to 100 testers by their
     Apple-account emails. Available within minutes of the build finishing
     processing. **This is your friends-and-family test. Stop here.**
   - External Testing (later, optional): needs a short beta review.
6. Testers install via the TestFlight app from the invite email.

## Phase 4 — Two-phone smoke test (~10 minutes)

1. Phone A: onboard with an email code (or Apple) → Create a Vault →
   share the invite code.
2. Phone B: onboard with a different account → Join a Vault with that code.
3. Phone A: deposit a photo. Phone B: pull-to-refresh on Today → A's
   deposit shows **blurred**; B's vault is LOCKED.
4. Phone B: deposit → unlock animation → both photos visible; streak shows
   1 the next day (server-computed, so both phones agree).
5. React + comment from both sides; check Archive on both.
6. Vault Settings → set the reminder hour → accept the notification
   permission prompt → a daily local reminder is now scheduled.

---

> Already ran an earlier `schema.sql`? The bottom of the file carries a
> commented idempotent migration block (profile columns, deposit
> immutability, rebuilt storage policies) — run that instead of the file.

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
  pull-to-refresh. No realtime push yet (Supabase Realtime is the upgrade);
  no APNs ("everyone has deposited!") yet — the daily reminder is local.
- **Timezones.** dayKey is the *device's* calendar day, and the server
  trusts the client's "today" for streaks (RLS only clamps deposits to a
  48h window). Same-timezone groups: no issue. Split-timezone groups can
  see edge-of-day disagreements — a vault "home timezone" is the fix.
- **Account deletion (Model B).** "Delete account" in Profile removes the
  account, login, name, and avatars and revokes the Apple token, but
  **deposited photos stay in shared vaults as "Former member"** — the
  archive is permanent (disclose this in your privacy policy; see
  [PRIVACY.md](PRIVACY.md)). Deletion runs through the `delete-account` edge
  function, which holds the `service_role` key — never put that key in the
  app.
- **Permanent storage grows forever.** Deposits are never deleted, so
  storage cost only rises. Images are now downscaled before upload
  (~1440px deposits, ~512px avatars) to keep that growth ~10× slower —
  budget Supabase Pro for backups + headroom.
- **Streak source of truth** is the `recompute_streak` RPC (server-side).
  The local `VaultEngine` math stays as the mock/test implementation —
  keep the two in sync if you change the rules.

## What I could not verify from this machine

The live layer is written against Supabase's stable REST APIs (GoTrue,
PostgREST, Storage) and fully type-checks, but **no request has been made
against a real project** — this machine has no Xcode and no Supabase
account. Budget the first 30 minutes of Phase 2 for shaking out wire-format
surprises (most likely spots: the OTP `/verify` response shape, the Apple
`id_token` grant, and PostgREST error-message pass-through in
`SupabaseClient.check`).
