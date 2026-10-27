// Supabase Edge Function: verify-subscription
//
// The app sends a StoreKit 2 transaction (Transaction.jwsRepresentation, and
// the subscription's renewal info when it has it) after a purchase, a
// restore, a renewal it sees through Transaction.updates, and on launch. This
// checks Apple's signature on it (../_shared/apple-jws.ts: the certificate
// chain up to the pinned Apple Root CA - G3), checks it's a HuddlePals+
// subscription (../_shared/subscriptions.ts), and records it for the caller
// with public.apply_entitlement (migration 013), which keeps each Apple
// subscription with one HuddlePals account. Postgres then enforces Plus
// (video posts, huddle and member caps) by the server's clock.
//
// Deploy with JWT verification on (the default): the caller's access token
// says whose subscription it is.
//   supabase functions deploy verify-subscription --project-ref <ref>
//
// Secrets: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected
// automatically. Set APPSTORE_BUNDLE_ID (com.huddlepals.ios) and
// APPSTORE_PRODUCT_IDS (the Plus product ids, comma-separated). Apple's root
// certificate is in the code, so there's no Apple key to set.
//
// The logic lives in handler.ts and ../_shared, tested on Node by
// supabase/tests/app-store.test.mjs; this file only wires Supabase in.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.117.2";
import { appStoreConfigFromEnv, applyEntitlementParams, type ApplyOutcome } from "../_shared/subscriptions.ts";
import { handleVerifySubscription } from "./handler.ts";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

Deno.serve((req) =>
  handleVerifySubscription(req, {
    async authenticate(accessToken) {
      const { data, error } = await admin.auth.getUser(accessToken);
      return error || !data.user ? null : data.user;
    },
    config: appStoreConfigFromEnv((name) => Deno.env.get(name)),
    async applyEntitlement(userId, update) {
      const { data, error } = await admin.rpc("apply_entitlement", applyEntitlementParams(userId, update));
      if (error) throw new Error(error.message);
      return data as ApplyOutcome;
    },
    now: () => Date.now(),
    log: (event, detail) => console.log(detail ? `${event} ${detail}` : event),
  })
);
