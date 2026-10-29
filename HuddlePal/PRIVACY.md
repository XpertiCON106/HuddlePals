# HuddlePals — Privacy Policy

_Last updated: 2026-10-30_

> Operator: **HuddlePals**
> Contact: **hello@huddlepals.com**

## What HuddlePals is

HuddlePals is a private, invite-only photo-sharing app for small groups. Each
member deposits one photo per day into a shared "huddle" or, with HuddlePals
Plus, a video of up to 6 seconds. Photos and videos are end-to-end encrypted
so that only the members of that huddle can view them, within the limits
described under "How your data is stored and protected."

## What we collect

| Data | Why | Linked to you |
|---|---|---|
| **Apple account identifier**, and any email address Apple shares at sign-in (it may be a private relay address) | To sign you in with Sign in with Apple, the only way to sign in. If Apple shares your name, we use it only to pre-fill your display name, which you can change | Yes |
| **Display name** | Shown to other members of your huddles | Yes |
| **Profile photos** (up to 3) and **bio** | Shown on your profile to people you share a huddle with | Yes |
| **Birthday** | Asked when you make your profile, to make sure everyone using HuddlePals is 13 or older. Only you can see it: it isn't shown to anyone else | Yes |
| **Deposited photos, videos and captions** | The core function — shared with your huddle's members. Photos and videos are end-to-end encrypted, including a video's sound and the still image made from its first frame; captions are not. A video records sound only if you allow HuddlePals to use the microphone | Yes |
| **Encryption public key** | Lets your huddle's members share the huddle's photo key with your device. Your private key stays on your devices (iCloud Keychain) | Yes |
| **Reactions and comments** | The core function | Yes |
| **Push notification token** (only if you allow notifications) | To notify your device about activity in your huddles: new photos, comments and reactions on your photos, and new members | Yes |
| **Terms agreement record**: which version of the Terms of Service you agreed to, when, and the app version | To show that you agreed to the Terms | Yes |
| **Subscription records** (only if you get HuddlePals+): the plan (monthly or yearly), Apple's transaction IDs, when it was bought and when it renews or ends, any billing grace period, refund or revocation, whether it will renew, and whether it was a test purchase | To give you Plus and keep it in step with Apple, and so that one subscription unlocks only one account. Apple handles payment: we never receive your card or billing details | Yes |

We do **not** use third-party advertising or tracking, we do **not** sell your
data, and we do **not** collect location, contacts, or device-tracking
identifiers.

## How your data is stored and protected

Your data is stored with our backend provider, **Supabase** (managed
PostgreSQL and object storage). Access is restricted by per-row security
rules so that a huddle's content is visible only to that huddle's members. All
network traffic uses HTTPS. Sign-in tokens are stored in the iOS Keychain on
your device.

**Deposited photos and videos are end-to-end encrypted.** Each photo and
video is encrypted on your device before upload, and the keys that decrypt a
huddle's photos and videos are held on its members' devices, not by us.
Supabase stores only the encrypted files. We don't hold your keys, and
HuddlePals is designed so that we (the operator) can't view your photos or
videos, with one exception: when someone **reports** a photo or video, their
device sends that one deposit's key with the report so we can review it.
That key opens only the reported deposit (for a video, the clip and its
still image), never the rest of the huddle. Your device keeps only encrypted
copies: a new recording stays in a protected temporary file only until it's
encrypted, and a video is decrypted into memory to play.

Our servers keep track of who belongs to each huddle and pass members'
public keys between devices. So that no one who controls those servers,
including us, can slip in a key of their own, a member's app shares a
huddle's key with someone who didn't join through an invite, or whose key
has changed, only after a member checks that person's **key code**. The
code is in Profile, and the two of them compare it in person or on a call.
End-to-end encryption therefore depends on members checking key codes with
the right person, as Section 3.3 of our
[Terms of Service](https://huddlepals.com/terms) explains. A huddle's invite
code carries what a new member needs to decrypt its photos, without our
servers ever seeing it, so share the code only with people you'd invite; the
huddle's keeper can replace it at any time. Your encryption key is kept in
your iCloud Keychain; if you lose it, another member of each huddle can
restore your access after checking your new key code, and if no one can,
those photos cannot be recovered — not even by us.

**Notifications** are delivered through Apple's push notification service.
They name the huddle and the member who posted, commented, reacted or
joined, and never include photos, videos, captions or comment text. You can
turn them off in Profile → Notifications or in iOS Settings; signing out or
turning them off removes your device's token.

Not end-to-end encrypted: captions, comments, reactions, your display name,
bio, and profile photos, and information such as who is in which huddle,
when deposits were posted, whether each is a photo or a video and how long a
video is, and whether you have HuddlePals+. These are protected by the
access rules above and are visible to us as the operator.

## HuddlePals+ purchases

HuddlePals+ is sold through Apple's App Store, and Apple handles the
payment: we never receive your payment card or billing details. When you
buy, renew or restore Plus, your device sends us the signed record of the
purchase that Apple gave it, and Apple's servers tell us about renewals,
billing problems, refunds and cancellations. We check Apple's signature on
each, then keep the subscription records listed above for as long as your
account exists. The app tags each purchase with your HuddlePals account ID,
so that the subscription goes to the account that bought it and can't
unlock another; Apple receives that ID, a random code that means nothing
outside HuddlePals, with the purchase. We also note which messages from Apple arrived and when, and
delete those notes after 90 days. Apple keeps its own records of your
purchases under Apple's privacy policy.

## Permanence of deposited content

HuddlePals is built around a promise: **a photo or video deposited into a
huddle is permanent.** It becomes part of that group's shared archive and
**cannot be edited or deleted**, even by the person who posted it. Please
only deposit photos and videos you are comfortable making a permanent part
of your group's record. On the free plan, the archive shows the most recent
30 days; older deposits are kept, not deleted, and open again with
HuddlePals+.

The one exception: a huddle's **keeper can delete the whole huddle**. That
removes every member and permanently deletes every photo, video, caption,
comment and reaction in it from our servers, for everyone, including what
other members posted; each member's app removes its copies the next time it
opens. We still keep a photo or video someone reported, as described under
"Reporting and blocking," and copies may remain in our backups for a limited
time. To tell the members, we keep the deleted huddle's name and who was in
it for a week.

## Your choices and account deletion

You can **delete your account at any time** from **Profile → Delete account**.
When you do:

- Your account, login, display name, bio, birthday, profile photos, push
  notification tokens, encryption keys, Terms agreement records, and
  subscription records are **permanently removed**, and you are signed out.
- We ask Apple to revoke the app's access to your Apple Account.
- **Photos and videos you already deposited remain in your shared huddles**,
  shown as "Former member" rather than under your name. This is required to
  keep the group's shared archive intact for the other members — consistent
  with the permanence described above. A huddle you keep passes to another
  member; to delete it and everything in it instead, delete the huddle first
  (its settings → Delete huddle). A huddle with no other member left is
  deleted with your account, along with everything in it; we still keep a
  photo or video someone reported, as described under "Reporting and
  blocking."
- **Deleting your account doesn't cancel HuddlePals+.** Apple keeps
  billing until you cancel it in Settings → your name → Subscriptions, so
  cancel it there first.

If you want a deposited photo or video removed from a huddle entirely
(beyond the "Former member" de-identification above), contact us at the
email above and we will review the request.

## Reporting and blocking

You can **report** a photo or video and **block** another member from
within the app (via the "•••" menu on a photo or video, or on a member's
profile). Blocking hides that person's photos, videos and comments from you.
We review reports and act on objectionable content. Because photos and
videos are end-to-end encrypted, reporting one shares that deposit's
decryption key with us so we can see it; we use it
only to review the report and to meet our legal obligations, such as
reporting child sexual abuse material to NCMEC. Reports stay on file even if
the person who filed one, or the person reported, deletes their account,
because the law can require us to keep reported material.

## Children

HuddlePals is not directed to children under 13 (or the minimum age in your
country). Do not use the app if you are under that age. We ask for your
birthday when you make your profile; if it shows you're under 13, you can't
make one.

## Legal basis and your rights

Depending on where you live, you may have rights to access, correct, or
delete your personal data. The in-app **Delete account** flow covers
deletion; for any other request, contact us at the email above. We will
respond within a reasonable period.

## Changes

We may update this policy; material changes will be reflected by the "Last
updated" date above.

## Contact

**HuddlePals** — **hello@huddlepals.com** · [huddlepals.com/support](https://huddlepals.com/support)
