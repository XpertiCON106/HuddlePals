// Supabase Edge Function: send-push
//
// Sends HuddlePals' activity notifications through APNs. Called only by the
// database: AFTER INSERT triggers on deposits, comments, reactions and
// memberships (public.notify_push, migration 009), and delete_huddle
// (migration 014), POST {"kind": "deposit" | "comment" | "reaction" | "join"
// | "huddle_deleted", "id": "<row id>"} through pg_net with the shared secret
// in x-push-secret. The function asks
// public.push_targets who to notify (never the person who acted, never across
// a block) and public.push_media_type whether it's about a photo or a video
// (migration 013), sends one alert per device, and deletes tokens APNs
// reports as invalid (410 Unregistered, 400 BadDeviceToken).
//
// Deploy with JWT verification off (the trigger sends no user token; the
// shared secret is the check):
//   supabase functions deploy send-push --no-verify-jwt --project-ref <ref>
//
// Secrets: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected
// automatically. Set PUSH_WEBHOOK_SECRET (the same value as the Vault secret
// push_webhook_secret), and APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (the
// .p8 contents) and APNS_BUNDLE_ID (com.huddlepals.ios). Without the APNS_*
// secrets nothing is sent. DEVELOPMENT.md ("Backend setup and deploys") has
// the key setup and every command.
//
// The logic lives in handler.ts and apns.ts, tested on Node by
// supabase/tests/send-push.test.mjs; this file only wires Supabase in.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.117.2";
import { apnsConfigFromEnv, ProviderTokenCache } from "./apns.ts";
import { handleSendPush, type PushTarget } from "./handler.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

const apns = apnsConfigFromEnv((name) => Deno.env.get(name));
// Module scope: a warm instance reuses its provider token across requests.
const providerTokens = apns ? new ProviderTokenCache(apns) : null;

Deno.serve((req) =>
  handleSendPush(req, {
    webhookSecret: Deno.env.get("PUSH_WEBHOOK_SECRET") ?? null,
    apns,
    providerToken: () => providerTokens!.get(),
    async targets(kind, id) {
      const { data, error } = await admin.rpc("push_targets", { p_kind: kind, p_id: id });
      if (error) throw new Error(error.message);
      return (data ?? []) as PushTarget[];
    },
    async mediaType(kind, id) {
      const { data, error } = await admin.rpc("push_media_type", { p_kind: kind, p_id: id });
      if (error) throw new Error(error.message);
      return data === "video" ? "video" : data === "photo" ? "photo" : null;
    },
    async removeTokens(tokens) {
      const { error } = await admin.from("device_tokens").delete().in("token", tokens);
      if (error) throw new Error(error.message);
    },
    fetch,
    log: (event, detail) => console.log(detail ? `${event} ${detail}` : event),
  })
);
