// The verify-subscription request, independent of the Supabase client so
// what each answer means is testable on its own
// (supabase/tests/app-store.test.mjs). index.ts wires the real services.

import { JwsError } from "../_shared/apple-jws.ts";
import {
  type AppStoreConfig,
  type ApplyOutcome,
  type EntitlementUpdate,
  entitlementFrom,
  InvalidTransaction,
} from "../_shared/subscriptions.ts";

export interface VerifySubscriptionServices {
  /** The caller, from their access token; null if it isn't valid. */
  authenticate(accessToken: string): Promise<{ id: string } | null>;
  /** The APPSTORE_* secrets; null when they aren't set. */
  config: AppStoreConfig | null;
  /** public.apply_entitlement for the caller. */
  applyEntitlement(userId: string, update: EntitlementUpdate): Promise<ApplyOutcome>;
  now(): number;
  /** Server-side log. Never handed a token or Apple's signed data. */
  log(event: string, detail?: string): void;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** Longest JWS accepted (Apple's are a few kilobytes, mostly the x5c chain). */
const MAX_JWS_LENGTH = 16_384;

/**
 * POST {"transaction": Transaction.jwsRepresentation, "renewal_info"?: the
 * subscription status's renewalInfo JWS, "restore"?: true}. Answers:
 * 200 {"status": "applied" | "stale"} (stale: the server already had
 * something newer; either way the app can finish the transaction),
 * 409 {"error": "subscription_in_use"} (another HuddlePals account holds it),
 * 409 {"error": "needs_restore"} (no appAccountToken, and the person didn't
 * tap Restore), 422 {"error": "invalid_transaction"}, 400, 401, 405, 500.
 */
export async function handleVerifySubscription(req: Request, services: VerifySubscriptionServices): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const accessToken = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const user = accessToken ? await services.authenticate(accessToken) : null;
  if (!user) return json({ error: "not_authenticated" }, 401);

  const config = services.config;
  if (!config) {
    services.log("verify_refused", "APPSTORE_* secrets not set");
    return json({ error: "not_configured" }, 500);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  const transaction = body?.transaction;
  const renewalInfo = body?.renewal_info ?? null;
  if (!isJws(transaction) || (renewalInfo !== null && !isJws(renewalInfo))) {
    return json({ error: "bad_request" }, 400);
  }

  let update: EntitlementUpdate;
  try {
    update = await entitlementFrom(transaction, renewalInfo as string | null, config, services.now());
  } catch (e) {
    if (e instanceof JwsError || e instanceof InvalidTransaction) {
      services.log("verify_invalid", e.message);
      return json({ error: "invalid_transaction" }, 422);
    }
    services.log("verify_failed", e instanceof Error ? `${e.name}: ${e.message}` : String(e));
    return json({ error: "verify_failed" }, 500);
  }

  // A subscription bought outside the app (resubscribed in Settings, an
  // offer code) carries no appAccountToken: it goes to whoever presents it
  // first, so only when the person asked for it with Restore Purchases. A
  // shared iPad can't quietly hand a parent's subscription to a child's
  // account.
  if (!update.appAccountToken && body.restore !== true) {
    return json({ error: "needs_restore" }, 409);
  }

  let outcome: ApplyOutcome;
  try {
    outcome = await services.applyEntitlement(user.id, update);
  } catch (e) {
    services.log("verify_apply_failed", e instanceof Error ? e.message : String(e));
    return json({ error: "apply_failed" }, 500);
  }
  services.log("verify_" + outcome, `${update.environment} ${update.productId}`);
  if (outcome === "in_use") return json({ error: "subscription_in_use" }, 409);
  // The caller's own account is gone (deleted while this ran).
  if (outcome === "unbound") return json({ error: "not_authenticated" }, 401);
  return json({ status: outcome }, 200);
}

function isJws(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= MAX_JWS_LENGTH;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
