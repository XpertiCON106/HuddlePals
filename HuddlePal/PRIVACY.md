# HuddlePal — Privacy Policy

_Last updated: 2026-10-19_

> Operator: **HuddlePals**
> Contact: **hello@huddlepals.com**

## What HuddlePal is

HuddlePal is a private, invite-only photo-sharing app for small groups. Each
member deposits one photo per day into a shared "huddle." Photos are
end-to-end encrypted and can be viewed only by the members of that huddle.

## What we collect

| Data | Why | Linked to you |
|---|---|---|
| **Email address or phone number** | To sign you in (one-time verification codes) and identify your account | Yes |
| **Apple account identifier** (if you use Sign in with Apple) | To sign you in | Yes |
| **Display name** | Shown to other members of your huddles | Yes |
| **Profile photos** (up to 3) and **bio** | Shown on your profile to people you share a huddle with | Yes |
| **Deposited photos and captions** | The core function — shared with your huddle's members. Photos are end-to-end encrypted; captions are not | Yes |
| **Encryption public key** | Lets your huddle's members share the huddle's photo key with your device. Your private key stays on your devices (iCloud Keychain) | Yes |
| **Reactions and comments** | The core function | Yes |

We do **not** use third-party advertising or tracking, we do **not** sell your
data, and we do **not** collect location, contacts, or device-tracking
identifiers.

## How your data is stored and protected

Your data is stored with our backend provider, **Supabase** (managed
PostgreSQL and object storage). Access is restricted by per-row security
rules so that a huddle's content is visible only to that huddle's members. All
network traffic uses HTTPS. Sign-in tokens are stored in the iOS Keychain on
your device.

**Deposited photos are end-to-end encrypted.** Each photo is encrypted on
your device before upload, and only the devices of that huddle's members hold
the keys to decrypt it. Supabase stores only the encrypted file, and **we
(the operator) cannot view your photos** — with one exception: when someone
**reports** a photo, their device sends that one photo's key with the report
so we can review it. That key opens only the reported photo, never the rest
of the huddle. Your encryption key is kept in your iCloud Keychain; if you lose
it, another member of each huddle restores your access automatically, and if
no one can, those photos cannot be recovered — not even by us.

Not end-to-end encrypted: captions, comments, reactions, your display name,
bio, and profile photos, and information such as who is in which huddle and
when photos were posted. These are protected by the access rules above and
are visible to us as the operator.

## Permanence of deposited content

HuddlePal is built around a promise: **a photo deposited into a huddle is
permanent.** It becomes part of that group's shared archive and **cannot be
edited or deleted**, even by the person who posted it. Please only deposit
photos you are comfortable making a permanent part of your group's record.

## Your choices and account deletion

You can **delete your account at any time** from **Profile → Delete account**.
When you do:

- Your account, login, display name, bio, profile photos, and encryption
  keys are **permanently removed**, and you are signed out.
- If you used Sign in with Apple, we revoke your Apple sign-in token.
- **Photos you already deposited remain in your shared huddles**, shown as
  "Former member" rather than under your name. This is required to keep the
  group's shared archive intact for the other members — consistent with the
  permanence described above.

If you want a deposited photo removed from a huddle entirely (beyond the
"Former member" de-identification above), contact us at the email above and
we will review the request.

## Reporting and blocking

You can **report** a photo and **block** another member from within the app
(via the "•••" menu on a photo or a member's profile). Blocking hides that
person's photos and comments from you. We review reports and act on
objectionable content. Because photos are end-to-end encrypted, reporting a
photo shares that photo's decryption key with us so we can see it; we use it
only to review the report.

## Children

HuddlePal is not directed to children under 13 (or the minimum age in your
country). Do not use the app if you are under that age.

## Legal basis and your rights

Depending on where you live, you may have rights to access, correct, or
delete your personal data. The in-app **Delete account** flow covers
deletion; for any other request, contact us at the email above. We will
respond within a reasonable period.

## Changes

We may update this policy; material changes will be reflected by the "Last
updated" date above.

## Contact

**HuddlePals** — **hello@huddlepals.com**
