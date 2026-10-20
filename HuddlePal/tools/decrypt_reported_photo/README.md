# decrypt_reported_photo

HuddlePal photos are end-to-end encrypted, so the Supabase dashboard only ever
shows ciphertext. When a member reports a photo, their device attaches that
one photo's key to the report (`reports.photo_key`). This script turns the
reported photo's Storage object back into a JPEG for review. The key opens
that photo only: not the huddle key, and no other photo.

## Steps

1. Find the report and the photo's storage path (Dashboard → SQL Editor):

   ```sql
   select r.created_at, r.reason, r.photo_key, d.storage_path, r.deposit_id
   from public.reports r
   left join public.deposits d on d.id = r.deposit_id
   order by r.created_at desc;
   ```

   A `null` `photo_key` means the reporter's device couldn't open the photo
   either (it hadn't received the huddle key yet), so the photo can't be
   decrypted. Act on the caption, the author, or the reporter's reason.

2. Download the object: Dashboard → Storage → `deposits` → open the
   `<huddle_id>` folder → select `<file>.jpg` → Download. The file is
   ciphertext even though its name ends in `.jpg`.

3. Decrypt it (macOS; CryptoKit ships with the OS, nothing to install):

   ```bash
   swift tools/decrypt_reported_photo/decrypt_reported_photo.swift ~/Downloads/<file>.jpg '<photo_key>' reported.jpg
   ```

   To keep the key out of your shell history, pass `-` and paste the key on
   stdin. A wrong key, or a file from another photo, fails with
   `authenticationFailure` and writes nothing.

Delete `reported.jpg` once the review is done.

## Format

The object is CryptoKit's `AES.GCM.SealedBox.combined`, which is a 12-byte
nonce, then the ciphertext, then a 16-byte tag. It uses AES-256-GCM with no
associated data. The key is the 32 raw bytes in `reports.photo_key`,
base64-encoded. Any AES-GCM implementation can open it.
