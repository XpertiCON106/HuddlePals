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
   ("Backend setup and deploys").
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
   contents). [DEVELOPMENT.md](DEVELOPMENT.md) → "Backend setup and
   deploys" has the key setup and the exact commands.
6. **Settings → API**: copy the **Project URL** and the **anon public key**.
7. **Set up report monitoring**: the `reports` table fills when users flag
   content — watch it (a saved dashboard query, or a Database Webhook to
   email/Slack) and act within 24 h, as App Review requires. Photos are
   end-to-end encrypted, so the dashboard can't show them: a report carries
   that one photo's key (`reports.photo_key`), and
   [`tools/decrypt_reported_photo`](tools/decrypt_reported_photo/README.md)
   turns the downloaded Storage object back into a JPEG. A report stays when
   its reporter (or the reported person) deletes their account, so what you
   report to NCMEC stays reviewable for the year the law requires.
   To take a reported photo down, use the SQL editor, never a manual delete:
   - Child sexual abuse material: report it to NCMEC first, then
     `select remove_reported_photo('<deposit id>', true, 'CyberTip #…');`.
     The photo leaves the huddle; its file stays in Storage, and
     `preserved_photos` keeps what finds and opens it for a year.
   - A removal the law doesn't ask you to keep (an adult's intimate image,
     which must go within 48 hours, or a copyright notice):
     `select remove_reported_photo('<deposit id>', false);`, then delete the
     file it returns under Storage → `deposits`.
   - Yearly: `select * from expired_preserved_photos();` lists what's past
     its keep-until date. Delete each file in Storage, then its row.
   - Videos work the same way, with two files under the one key: the poster
     at `storage_path` (`<file>.jpg`, what these return) and the clip at
     `video_path` (the same name ending in `.mp4`). Review the clip, and when
     deleting, delete both.

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
   https://huddlepals.com/privacy, the URLs the Terms cite. Keep Apple's
   **standard EULA** as the app's License Agreement (don't upload a custom
   one): the Terms apply alongside it and already include Apple's required
   minimum terms (Section 15).
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
     > to 4 people who know each other, or 10 with HuddlePals+). Sign in with Apple is the only
     > sign-in. To try it: agree to the Terms, sign in, create a huddle and
     > take today's photo. Other members' photos for today unlock once you
     > post yours. To see a group with other members, join with invite
     > code <CODE>. Content safeguards (guideline 1.2): everyone agrees to
     > the Terms (zero tolerance for objectionable content) before signing
     > in; any photo (••• menu), comment (touch and hold) or profile (•••
     > menu) can be reported; members can be blocked; we review reports
     > within 24 hours. Photos and videos are end-to-end encrypted; a
     > report sends us that one post's key so we can review it. HuddlePals
     > Plus (auto-renewable, monthly or yearly) is in Profile → Plan and
     > behind Video when posting; Restore Purchases is in both places. Account deletion: Profile
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

## Phase 5 — HuddlePals+ and video drops

The Plus build needs migration 013, two new edge functions, the
subscriptions in App Store Connect, and the website's changes before App
Review. The free plan's limits apply as soon as migration 013 runs.

**Order:** App Store Connect → migration 013 → secrets and functions →
TestFlight build → checks on a device → website → App Review → release.

### 5.1 App Store Connect (needed before anything can be bought, even in TestFlight)

1. **Agreements first.** Business → Agreements: accept the **Paid Apps**
   agreement and complete the tax forms and banking. Until it's active,
   StoreKit returns no products and the paywall says "HuddlePals+ isn't
   available right now".
2. **Subscription group.** Your app → Monetization → Subscriptions → **+**
   a group named **HuddlePals+**, with a display-name localization
   (e.g. "HuddlePals+").
3. **Two subscriptions** in it, both at **the same level** (a switch
   between them then takes effect at the next renewal):

   | Reference name | Product ID | Duration |
   |---|---|---|
   | HuddlePals+ Monthly | `com.huddlepals.ios.plus.monthly` | 1 month |
   | HuddlePals+ Yearly | `com.huddlepals.ios.plus.yearly` | 1 year |

   The IDs must match exactly: the app (`PlusCatalog`) and the
   `APPSTORE_PRODUCT_IDS` secret use them. For each, set your price (the
   paywall shows whatever App Store Connect returns, in local currency; the
   test store's $2.99 and $24.99 are only for the tests), a localization
   (display name and a short description, e.g. "Videos, bigger huddles,
   your whole archive"), and a **review screenshot** of the paywall
   (Profile → Get HuddlePals+, on a TestFlight build).
4. **Free trial.** Each subscription → Subscription Prices → Introductory
   Offers → **Free, 1 week**, all territories. Eligible people then see
   "Try it free for 1 week".
5. **Billing Grace Period: on** (Subscriptions → Billing Grace Period; 16
   days is a reasonable length). Plus continues while Apple retries a
   failed renewal; the server already honours it.
6. **Family Sharing: leave it off.** It's off by default and can't be
   turned off once on; Terms §3.9(g) says Plus isn't shared.
7. **App Store Server Notifications.** App Information → App Store Server
   Notifications: set both the **Production** and the **Sandbox** Server URL
   to `https://<project-ref>.supabase.co/functions/v1/app-store-notifications`,
   **Version 2**.
8. **Sandbox testers** (Users and Access → Sandbox → Test Accounts) only for
   testing outside TestFlight. TestFlight builds buy in the sandbox with each
   tester's own Apple Account, free, and renew on a fast clock.
9. **App Privacy** (App Privacy → Edit): add **Purchases → Purchase
   History** and **User Content → Audio Data**, both linked to the user, for
   App Functionality, not used for tracking. "Photos or Videos" is already
   declared. This matches `PrivacyInfo.xcprivacy`.
10. **Terms of Use.** Keep Apple's standard EULA (Phase 3 step 3).
    Guideline 3.1.2 also wants the Terms of Use linked in the metadata, so
    end the App Store description with:

    > Terms of Use: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
    > Privacy Policy: https://huddlepals.com/privacy

    The paywall links the same Terms of Use, plus huddlepals.com/terms and
    /privacy.

### 5.2 Supabase (additive: nothing existing changes)

1. **Storage limits.** Storage → `deposits` → settings: a file size limit
   of at least **5 MB**, and allowed MIME types including
   `application/octet-stream`, as Phase 1 step 3 set them. A clip is at most
   4 MB before encryption, and posters and clips upload as encrypted
   `application/octet-stream`.
2. **Migration 013.** SQL Editor → paste
   [`supabase/migrations/013_plus_and_video.sql`](supabase/migrations/013_plus_and_video.sql)
   → Run (safe to re-run). From then on, without Plus: 3 huddles kept,
   4 members a huddle (and only in the keeper's 3 longest-kept huddles), 25
   huddles joined, and an archive of the last 30 days. Nobody is removed and
   nothing is deleted. Builds from before Plus explain any refusal as "You
   can't join this huddle."
3. **Secrets** (DEVELOPMENT.md → "Backend setup and deploys"):

   ```bash
   supabase secrets set --project-ref <project-ref> APPSTORE_BUNDLE_ID=com.huddlepals.ios APPSTORE_PRODUCT_IDS=com.huddlepals.ios.plus.monthly,com.huddlepals.ios.plus.yearly
   ```

4. **Functions**, from `HuddlePal/`, after 013 (`send-push` now asks the
   database whether a post is a video, so it needs redeploying too):

   ```bash
   supabase functions deploy verify-subscription --project-ref <project-ref>
   ```

   ```bash
   supabase functions deploy app-store-notifications --no-verify-jwt --project-ref <project-ref>
   ```

   ```bash
   supabase functions deploy send-push --no-verify-jwt --project-ref <project-ref>
   ```

### 5.3 TestFlight and checks on a device

1. Bump the version or build number, archive the Plus build and upload it
   as in Phase 3. Everyone who updates sees the revised Terms (version
   2026-10-28) and agrees once more.
2. On a phone with the TestFlight build:
   - **Buy.** Profile → Get HuddlePals+ → Try it free for 1 week →
     Apple's sheet. The paywall says "You have HuddlePals+" and closes;
     Profile shows "Current period ends …". In SQL,
     `select product_id, environment, expires_at from user_entitlements;`
     shows one `Sandbox` row.
   - **Apple's notifications arrive.**
     `select notification_type, subtype, received_at from app_store_notifications order by received_at desc limit 5;`
     shows `SUBSCRIBED`. If nothing arrives, check the URLs in 5.1 step 7
     and Edge Functions → `app-store-notifications` → Logs.
   - **Renewal.** After a sandbox renewal, `expires_at` has moved on and a
     `DID_RENEW` row has arrived.
   - **Cancel.** Profile → Manage subscription → cancel. Plus lasts until
     the period ends; then Profile says Free plan, Compose shows
     "Video · Plus", and videos already posted still play.
   - **Restore elsewhere.** Signed in to another HuddlePals account on the
     same phone, Restore Purchases says it's "already linked to another
     HuddlePals account".
   - **Video.** Record one (the microphone prompt comes with the first;
     Don't Allow gives a silent clip) and post it. On the second phone it
     loops muted in the feed and plays with sound in detail, and its push
     says "posted a video".
   - **Report a video** from the second phone, then decrypt its clip with
     [`tools/decrypt_reported_photo`](tools/decrypt_reported_photo/README.md)
     (it writes `.mp4`).
   - **Delete a test account that has Plus.** The confirmation warns that
     Apple keeps billing; afterwards its `user_entitlements` row is gone and
     the subscription still shows in Settings until it's cancelled.

### 5.4 App Review and release

1. Publish **the website changes** (the Grok instructions: Support's Plus
   questions, the member counts, the revised Terms and Privacy Policy) and
   have the live pages checked against the repo.
2. On the version page, add **both subscriptions** under In-App Purchases
   and Subscriptions (the first ones must go to review with an app
   version), use the App Review notes from Phase 3 step 7 (they cover
   Plus), and submit.
3. Release, then watch support mail and reports for a few days.

### Undoing it

- **Selling Plus:** App Store Connect → each subscription → Remove from
  Sale. Subscribers keep Plus until their period ends.
- **Migration 013** has no down migration.

### Still open

- A lawyer's review of the subscription terms against state automatic-
  renewal laws (California's, as amended in 2025, and others), and of
  §3.9(h)'s notice before Plus loses features.

## Phase 6 — Deleting huddles

A huddle's keeper can delete it: everyone is removed and every photo and
video in it is deleted from Storage, except a reported one, which is kept
for review as `remove_reported_photo` keeps one.

1. **Migration 014.** SQL Editor → paste
   [`supabase/migrations/014_delete_huddle.sql`](supabase/migrations/014_delete_huddle.sql)
   → Run (safe to re-run).
2. **Functions**, from `HuddlePal/`: deploy the new one, and redeploy
   `send-push` so members hear "… deleted the huddle.":

   ```bash
   supabase functions deploy delete-huddle --project-ref <project-ref>
   ```

   ```bash
   supabase functions deploy send-push --no-verify-jwt --project-ref <project-ref>
   ```

3. **Website**: the revised Terms (§3.2, §3.11, §4.2, §4.5; version
   2026-10-28, so everyone agrees again) and Privacy Policy, and the
   Support question "How do I delete a huddle?".
4. **Check on two phones** with the new build: the keeper opens a test
   huddle → Settings → Delete huddle → confirm. The other phone gets "…
   deleted the huddle." and the huddle leaves its shelf. In SQL,
   `select * from huddle_deletions order by deleted_at desc limit 1;` shows
   it, and Storage → `deposits` has no folder named after the huddle's id.
   A reported photo in it would still be in `preserved_photos`.

## Phase 7 — Invite links that open the app

Invites are now `https://huddlepals.com/join#<code>` links. Messages shows
them as a card with the huddle's emoji and name, and they open HuddlePals
straight to Join. That needs two things outside the app:

1. **The website** serves `/.well-known/apple-app-site-association` (JSON,
   no redirect) naming the app, and a `/join` page for people without the
   app (the Grok instructions have both, word for word). Check it:

   ```bash
   curl -sI https://huddlepals.com/.well-known/apple-app-site-association
   ```

   It should answer `200` with `content-type: application/json`.
2. **Associated Domains** on the App ID: the app's entitlements now list
   `applinks:huddlepals.com`. With automatic signing, Xcode adds the
   capability to the App ID on the next archive (Signing & Capabilities
   then shows Associated Domains with no error).

Then, on a phone with the new build: share an invite into Messages (a card,
not a bare link), and tap it on another phone with HuddlePals installed
(Join opens with the code). Apple caches the association file, so a phone
can take up to a day to pick up a change to it; deleting and reinstalling
the app makes it check again.

## Phase 8 — Keepers stay, and calmer Terms

A huddle's keeper can no longer leave it, only delete it. The Terms lose the
all-caps Section 13 notice at the top (Section 13 itself is unchanged).

1. **Migration 015.** SQL Editor → paste
   [`supabase/migrations/015_keeper_cannot_leave.sql`](supabase/migrations/015_keeper_cannot_leave.sql)
   → Run (safe to re-run). Run it with the build that hides Leave from
   keepers: older builds still offer it, and once 015 runs, a keeper who
   taps it stays in place.
2. **Website**: the Terms page without the notice, version 2026-10-29 (the
   app asks everyone to agree once more). The Grok instructions have it.
3. **Check on a phone** with the new build: as a keeper, Huddle Settings
   shows Delete huddle and no Leave; as a member, Leave. Profile → Delete
   account opens its page, and Delete my account works only once DELETE is
   typed.

## Phase 9 — Birthdays

New profiles ask for a birthday (only its owner can see it; under 13 can't
continue), and accounts from before are asked for theirs once.

1. **Migration 016.** SQL Editor → paste
   [`supabase/migrations/016_birthdays.sql`](supabase/migrations/016_birthdays.sql)
   → Run (safe to re-run). Run it before shipping the build: without the
   table, that build can't finish a new profile.
2. **Website**: the Privacy Policy with the birthday (the Grok instructions
   have it, word for word).
3. **App Store Connect → App Privacy**: add the birthday as collected data
   (Other Data, linked to the user, for App Functionality, not used for
   tracking).
4. **Check on a phone** with the new build: a new account's profile step
   needs a birthday; one under 13 stops with Sign out. An existing account
   is asked once, full screen, then Profile shows it.

## Phase 10 — Live updates

An open huddle updates as soon as someone posts, comments or reacts, over
Supabase Realtime. Until this runs, the app refreshes an open huddle every
half minute instead, so it can go before or after the build ships.

1. **Migration 017.** SQL Editor → paste
   [`supabase/migrations/017_live_updates.sql`](supabase/migrations/017_live_updates.sql)
   → Run (safe to re-run). It adds `deposits`, `comments` and `reactions`
   to the `supabase_realtime` publication. Realtime checks each change
   against the tables' RLS with the listener's own token, so nobody hears
   about a row they can't read.
2. **Check it ran**: Database → Publications → `supabase_realtime` lists
   the three tables (Realtime is on for every project by default).
3. **Check on two phones** in one huddle: a post, a comment or a reaction
   on one shows on the other within a second or two, with the huddle open
   and no pull to refresh.

## Phase 11 — A last member's huddles go with their account

When the last member of a huddle deletes their account, the huddle goes
too: every photo, video, caption, comment and reaction in it, and its files
in Storage, except a reported one, which is kept for review as
`delete_huddle` keeps one. Nobody else was in it, so nobody is notified.
Deleting a huddle's files now also works whichever way its folder is
spelled: the app names it with an uppercase id, Postgres prints ids in
lowercase, and both functions clear both.

1. **Migration 018.** SQL Editor → paste
   [`supabase/migrations/018_delete_sole_huddles.sql`](supabase/migrations/018_delete_sole_huddles.sql)
   → Run (safe to re-run). Run it first: until it exists, the new
   `delete-account` logs `sole_huddle_cleanup_failed` and leaves such a
   huddle in place (the account is still deleted).
2. **Functions**, from `HuddlePal/`: redeploy both:

   ```bash
   supabase functions deploy delete-account --project-ref <project-ref>
   ```

   ```bash
   supabase functions deploy delete-huddle --project-ref <project-ref>
   ```

3. **Website**: the revised Terms (§3.2, §4.2, §4.5; version 2026-10-30,
   so the next build asks everyone to agree again), the Privacy Policy, and
   the Support answer "How do I delete my account?".
4. **Check on a phone**: sign in with a test account that is the only
   member of a test huddle with a photo in it, then Profile → Delete
   account. In SQL,
   `select id from huddles where id = '<huddle-id>';` returns nothing, and
   Storage → `deposits` has no folder named after the huddle's id, in
   either case.

## Phase 12 — Website analytics

Migration 020 adds tables and functions for basic website analytics (page
visits, sessions, events) used by the huddlepals.com dashboard at
`https://huddlepals.com/admin`, with automatic cleanup of old data. The
website code is in the HuddlePals.com repository; the app is untouched. Do the steps in this order: a push to the website's
`main` deploys it straight away (Cloudflare Workers Builds).

1. **Migration 020.** SQL Editor → paste
   [`supabase/migrations/020_website_analytics.sql`](supabase/migrations/020_website_analytics.sql)
   → Run (safe to re-run). It only adds the five `analytics_` tables and
   their functions. Check: Table Editor lists them, each with RLS on and
   no policies.
2. **The admin account.** Authentication → Users → Add user → Create new
   user: email `<admin-email>`, a long password from a password manager,
   **Auto Confirm User** on. Copy the new user's id (`<admin-user-id>`).
   Nothing about the admin goes in SQL or in the code; the Worker checks
   both values from its secrets.
   - Email sign-in has to be enabled (Authentication → Sign In / Providers
     → Email) for the password to work. Leave "Allow new users to sign up"
     on: Sign in with Apple needs it. Other email accounts may then exist,
     but the dashboard and every `/api/admin/*` call refuse anyone who isn't
     the admin.
3. **Redirect URL** for "Forgot password": Authentication → URL
   Configuration → Redirect URLs → add `https://huddlepals.com/admin`. The
   recovery link opens the dashboard's set-password screen.
4. **Worker secrets** (Cloudflare → Workers & Pages → `huddlepals` →
   Settings → Variables and Secrets, type *Secret*; or
   `npx wrangler secret put <NAME>` in the website repo):
   - `SUPABASE_SERVICE_ROLE_KEY` — Supabase → Project Settings → API keys →
     service role. It lives only here; the browser only ever gets the anon
     key.
   - `ADMIN_EMAIL` — `<admin-email>`
   - `ADMIN_USER_ID` — `<admin-user-id>`

   Set them before pushing: visit recording and the dashboard need them
   from the first request (`wrangler.jsonc` lists them as required).
5. **Push the website's `main`.** Workers Builds runs `npm run build` and
   `npx wrangler deploy`. That deploy also applies `workers_dev: false` and
   `preview_urls: false` (the site is served only on huddlepals.com) and
   adds the daily cron (`17 4 * * *`) that cleans up old analytics data.
6. **Check it live**:
   - `https://huddlepals.com/api/health` answers `{"ok":true}`.
   - `/`, `/privacy`, `/terms`, `/support`, `/join` and
     `/.well-known/apple-app-site-association` look and answer as before
     (the association file still as `application/json`).
   - Open a public page in a private window, then
     `select path, visited_at from analytics_visits order by visited_at desc limit 5;`
     shows it.
   - `https://huddlepals.com/admin` answers with `X-Robots-Tag: noindex, nofollow`;
     sign in as the admin and the dashboard shows that visit. Signing in
     with any other account shows "Not the admin account".
   - "Forgot password?" on the sign-in page sends a link that opens "Set a
     new password".

Undoing it: revert the website commit and push (the site goes back to
static assets only), then `drop table` the five `analytics_` tables and
`drop function` the `analytics_` functions if you want the data gone.

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
  [PRIVACY.md](PRIVACY.md)). A huddle with no other member left is deleted
  with the account (Phase 11). Deletion runs through the `delete-account` edge
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
  it) gets a new one and sees locked photos until another member checks
  their new key code and shares each huddle key.
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
  joining a full huddle should say why, the free plan's 4 or Plus's 10,
  not a generic error);
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
