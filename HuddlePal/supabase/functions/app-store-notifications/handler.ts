// The App Store Server Notifications V2 request, independent of the Supabase
// client so what each notification does is testable on its own
// (supabase/tests/app-store.test.mjs). index.ts wires the real services.

import { JwsError, verifyAppleJws } from "../_shared/apple-jws.ts";
import {
  type AppStoreConfig,
  type ApplyOutcome,
  type EntitlementUpdate,
  entitlementFrom,
  InvalidTransaction,
} from "../_shared/subscriptions.ts";

export interface NotificationRecord {
  uuid: string;
  type: string;
  subtype: string | null;
  originalTransactionId: string | null;
  /** ISO 8601. */
  signedAt: string;
}

export interface AppStoreNotificationServices {
  /** The APPSTORE_* secrets; null when they aren't set. */
  config: AppStoreConfig | null;
  /** public.apply_entitlement with no caller: Apple is telling us. */
  applyEntitlement(update: EntitlementUpdate): Promise<ApplyOutcome>;
  /** public.record_app_store_notification. */
  recordNotification(record: NotificationRecord): Promise<void>;
  now(): number;
  /** Server-side log. Never handed Apple's signed data. */
  log(event: string, detail?: string): void;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** Longest signedPayload accepted: it nests the transaction and renewal JWS. */
const MAX_PAYLOAD_LENGTH = 65_536;

/**
 * POST {"signedPayload": "<JWS>"} from Apple. Every notification about a
 * subscription (renewals, expiry, a grace period, billing retries, refunds,
 * revocations, plan changes) carries the latest transaction and renewal info,
 * so each one is handled the same way: apply what they say. apply_entitlement
 * ignores anything older than what it has, so retries and notifications
 * arriving out of order are harmless. Answers 200 once handled (Apple stops
 * retrying), also for one that isn't ours to act on; 401 for a signature that
 * doesn't check out; 500 when the database fails, so Apple tries again.
 */
export async function handleAppStoreNotification(req: Request, services: AppStoreNotificationServices): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const config = services.config;
  if (!config) {
    services.log("notification_refused", "APPSTORE_* secrets not set");
    return json({ error: "not_configured" }, 500);
  }

  let signedPayload: unknown;
  try {
    signedPayload = (await req.json())?.signedPayload;
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (typeof signedPayload !== "string" || signedPayload.length > MAX_PAYLOAD_LENGTH) {
    return json({ error: "bad_request" }, 400);
  }

  const now = services.now();
  let notification: Record<string, unknown>;
  try {
    notification = await verifyAppleJws(signedPayload, { rootCertificate: config.rootCertificate, now });
  } catch (e) {
    services.log("notification_invalid", e instanceof JwsError ? e.message : String(e));
    return json({ error: "invalid_signature" }, 401);
  }

  const type = notification.notificationType;
  const uuid = notification.notificationUUID;
  const signedDate = notification.signedDate;
  if (typeof type !== "string" || typeof uuid !== "string" || !UUID.test(uuid) || typeof signedDate !== "number") {
    services.log("notification_invalid", "incomplete");
    return json({ error: "bad_request" }, 400);
  }
  const subtype = typeof notification.subtype === "string" ? notification.subtype : null;
  const data = (notification.data ?? null) as Record<string, unknown> | null;

  let outcome: ApplyOutcome | "ignored" | "recorded" = "recorded";
  let originalTransactionId: string | null = null;
  if (data && data.bundleId !== config.bundleId) {
    // Genuine, but for another app: a misconfigured URL in App Store Connect.
    services.log("notification_ignored", `${type} wrong_bundle`);
    outcome = "ignored";
  } else if (data && typeof data.signedTransactionInfo === "string") {
    let update: EntitlementUpdate | null = null;
    try {
      update = await entitlementFrom(
        data.signedTransactionInfo,
        typeof data.signedRenewalInfo === "string" ? data.signedRenewalInfo : null,
        config,
        now,
      );
    } catch (e) {
      if (!(e instanceof JwsError || e instanceof InvalidTransaction)) {
        services.log("notification_failed", e instanceof Error ? `${e.name}: ${e.message}` : String(e));
        return json({ error: "verify_failed" }, 500);
      }
      services.log("notification_ignored", `${type} ${e.message}`);
      outcome = "ignored";
    }
    if (update) {
      originalTransactionId = update.originalTransactionId;
      try {
        outcome = await services.applyEntitlement(update);
      } catch (e) {
        services.log("notification_apply_failed", e instanceof Error ? e.message : String(e));
        return json({ error: "apply_failed" }, 500);
      }
    }
  }

  try {
    await services.recordNotification({
      uuid: uuid.toLowerCase(),
      type,
      subtype,
      originalTransactionId,
      signedAt: new Date(signedDate).toISOString(),
    });
  } catch (e) {
    services.log("notification_record_failed", e instanceof Error ? e.message : String(e));
    return json({ error: "record_failed" }, 500);
  }
  services.log("notification_" + outcome, subtype ? `${type} ${subtype}` : type);
  return json({ status: outcome }, 200);
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
