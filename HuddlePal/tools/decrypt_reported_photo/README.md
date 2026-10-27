# decrypt_reported_photo

HuddlePals photos and videos are end-to-end encrypted, so the Supabase
dashboard only ever shows ciphertext. When a member reports a deposit, their
device attaches that deposit's key to the report (`reports.photo_key`). This
script turns the reported deposit's Storage objects back into a JPEG (a
photo, or a video's poster) or an MP4 (a video's clip) for review. The key
opens that deposit only: not the huddle key, and no other photo or video.

## Steps

1. Find the report and the deposit's storage paths (Dashboard → SQL Editor):

   ```sql
   select r.created_at, r.reason, r.photo_key, d.media_type, d.storage_path, d.video_path, r.deposit_id
   from public.reports r
   left join public.deposits d on d.id = r.deposit_id
   order by r.created_at desc;
   ```

   A `null` `photo_key` means the reporter's device couldn't open the deposit
   either (it hadn't received the huddle key yet), so it can't be decrypted.
   Act on the caption, the author, or the reporter's reason.

   A video (`media_type = 'video'`) has two files under the same key: its
   poster at `storage_path` (`<file>.jpg`) and its clip at `video_path`
   (`<file>.mp4`, same name). Review the clip: the poster is only its first
   frame.

2. Download each object: Dashboard → Storage → `deposits` → open the
   `<huddle_id>` folder → select `<file>.jpg` or `<file>.mp4` → Download. The
   file is ciphertext whatever its name ends in.

3. Decrypt it (macOS; CryptoKit ships with the OS, nothing to install):

   ```bash
   swift tools/decrypt_reported_photo/decrypt_reported_photo.swift ~/Downloads/<file>.mp4 '<photo_key>' reported.mp4
   ```

   The output is named for what's inside, `.jpg` or `.mp4`, whatever name you
   give it, and the script says when it changed the name. To keep the key out
   of your shell history, pass `-` and paste the key on stdin. A wrong key, or
   a file from another deposit, fails with `authenticationFailure` and writes
   nothing.

Delete the decrypted files once the review is done.

## Format

Each object is CryptoKit's `AES.GCM.SealedBox.combined`, which is a 12-byte
nonce, then the ciphertext, then a 16-byte tag. It uses AES-256-GCM with no
associated data. The key is the 32 raw bytes in `reports.photo_key`,
base64-encoded. A video's poster and clip are sealed separately with that one
key, each with its own nonce. Any AES-GCM implementation can open them.
