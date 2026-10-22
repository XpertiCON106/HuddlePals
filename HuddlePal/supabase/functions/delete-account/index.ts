// Supabase Edge Function: delete-account
//
// Permanently deletes the calling user's account (Model B):
//   1. Revokes the app's Sign in with Apple tokens (App Review guideline
//      5.1.1(v)). The app re-authenticates with Apple when the user confirms
//      deletion and sends {"authorization_code": "..."}; the code is
//      exchanged at Apple's /auth/token and the refresh token revoked at
//      /auth/revoke. Best effort: if Apple refuses or can't be reached, the
//      failure is logged and the deletion still completes.
//   2. Deletes the user's registered devices (device_tokens), so no push
//      notification reaches them.
//   3. Deletes the user's avatar Storage objects (PII).
//   4. Releases ownership of the deposit photos they uploaded
//      (public.release_storage_objects, migration 007), so deleteUser isn't
//      blocked by storage.objects.owner → auth.users.
//   5. Deletes the auth user. FKs then cascade: profile is removed, and so
//      are the user's E2EE keys (user_keys, huddle_keys); deposits/comments
//      keep their rows with a null author ("Former member") — the huddle's
//      archive stays permanent, and stays readable to members, who hold
//      their own copies of the huddle key.
//
// Secrets: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected
// automatically. Apple revocation needs APPLE_TEAM_ID, APPLE_KEY_ID,
// APPLE_CLIENT_ID (the bundle ID) and APPLE_PRIVATE_KEY (the .p8 contents);
// without them deletion still completes and revocation is skipped.
// DEVELOPMENT.md ("Account deletion and Apple token revocation") has the
// key setup, the `supabase secrets set` command and the deploy command.
//
// The logic lives in handler.ts and apple.ts, tested on Node by
// supabase/tests/delete-account.test.mjs; this file only wires Supabase in.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.117.2";
import { appleConfigFromEnv } from "./apple.ts";
import { handleDeleteAccount } from "./handler.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

Deno.serve((req) =>
  handleDeleteAccount(req, {
    async authenticate(accessToken) {
      const { data, error } = await admin.auth.getUser(accessToken);
      return error || !data.user ? null : data.user;
    },
    apple: appleConfigFromEnv((name) => Deno.env.get(name)),
    fetch,
    async removeDeviceTokens(userId) {
      const { error } = await admin.from("device_tokens").delete().eq("user_id", userId);
      if (error) throw new Error(error.message);
    },
    async removeAvatars(userId) {
      const prefix = `avatars/${userId}`;
      const bucket = admin.storage.from("deposits");
      const { data: files, error } = await bucket.list(prefix, { limit: 1000 });
      if (error) throw error;
      if (files && files.length) {
        const { error: removeError } = await bucket.remove(files.map((f) => `${prefix}/${f.name}`));
        if (removeError) throw removeError;
      }
    },
    async releaseStorageObjects(userId) {
      const { error } = await admin.rpc("release_storage_objects", { p_user_id: userId });
      if (error) throw new Error(error.message);
    },
    async deleteUser(userId) {
      const { error } = await admin.auth.admin.deleteUser(userId);
      if (error) throw error;
    },
    log: (event, detail) => console.log(detail ? `${event} ${detail}` : event),
  })
);
