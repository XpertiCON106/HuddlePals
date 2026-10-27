// Supabase Edge Function: delete-huddle
//
// Deletes a huddle for its keeper. The app sends {"huddle_id": "..."} with
// the keeper's access token:
//   1. public.delete_huddle (migration 014) checks they keep it, keeps any
//      reported deposit in preserved_photos, tells everyone else who was in
//      it (send-push, 'huddle_deleted'), and deletes the huddle; its
//      memberships, deposits, reactions, comments, skips, keys and invite
//      go with it.
//   2. Every file in Storage under "<huddle id>/" is deleted, except a
//      reported deposit's poster and clip.
//
// Secrets: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY only (injected
// automatically). Deploy with JWT verification on (the default):
//   supabase functions deploy delete-huddle --project-ref <project-ref>
//
// The logic lives in handler.ts, tested on Node by
// supabase/tests/delete-huddle.test.mjs; this file only wires Supabase in.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.117.2";
import { handleDeleteHuddle } from "./handler.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);
const bucket = () => admin.storage.from("deposits");

Deno.serve((req) =>
  handleDeleteHuddle(req, {
    async authenticate(accessToken) {
      const { data, error } = await admin.auth.getUser(accessToken);
      return error || !data.user ? null : data.user.id;
    },
    async deleteRows(huddleId, userId) {
      const { data, error } = await admin.rpc("delete_huddle", { p_huddle: huddleId, p_user: userId });
      if (error) throw new Error(error.message);
      return (data as string[] | null) ?? [];
    },
    async listFiles(huddleId) {
      const paths: string[] = [];
      for (let offset = 0;; offset += 1000) {
        const { data, error } = await bucket().list(huddleId, { limit: 1000, offset });
        if (error) throw error;
        // Folders come back with no id; a huddle's folder has only files.
        for (const file of data ?? []) if (file.id) paths.push(`${huddleId}/${file.name}`);
        if (!data || data.length < 1000) return paths;
      }
    },
    async removeFiles(paths) {
      const { error } = await bucket().remove(paths);
      if (error) throw error;
    },
    log: (event, detail) => console.log(detail ? `${event} ${detail}` : event),
  })
);
