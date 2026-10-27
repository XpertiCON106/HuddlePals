// Supabase Edge Function: app-store-notifications
//
// Apple's App Store Server Notifications V2 endpoint (App Store Connect →
// the app → App Information → App Store Server Notifications, for both the
// production and the sandbox URL). Renewals, expiry, billing grace periods
// and retries, refunds and revocations reach the server this way even when
// nobody opens the app. Each notification is checked against Apple's
// certificate chain (../_shared/apple-jws.ts), then the subscription state it
// carries is recorded with public.apply_entitlement (migration 013), and its
// arrival with public.record_app_store_notification.
//
// Deploy with JWT verification off (Apple sends no Supabase token; Apple's
// signature is the check):
//   supabase functions deploy app-store-notifications --no-verify-jwt --project-ref <ref>
//
// Secrets: the same APPSTORE_BUNDLE_ID and APPSTORE_PRODUCT_IDS as
// verify-subscription. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected
// automatically.
//
// The logic lives in handler.ts and ../_shared, tested on Node by
// supabase/tests/app-store.test.mjs; this file only wires Supabase in.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.117.2";
import { appStoreConfigFromEnv, applyEntitlementParams, type ApplyOutcome } from "../_shared/subscriptions.ts";
import { handleAppStoreNotification } from "./handler.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

Deno.serve((req) =>
  handleAppStoreNotification(req, {
    config: appStoreConfigFromEnv((name) => Deno.env.get(name)),
    async applyEntitlement(update) {
      const { data, error } = await admin.rpc("apply_entitlement", applyEntitlementParams(null, update));
      if (error) throw new Error(error.message);
      return data as ApplyOutcome;
    },
    async recordNotification(record) {
      const { error } = await admin.rpc("record_app_store_notification", {
        p_uuid: record.uuid,
        p_type: record.type,
        p_subtype: record.subtype,
        p_original_transaction_id: record.originalTransactionId,
        p_signed_at: record.signedAt,
      });
      if (error) throw new Error(error.message);
    },
    now: () => Date.now(),
    log: (event, detail) => console.log(detail ? `${event} ${detail}` : event),
  })
);
