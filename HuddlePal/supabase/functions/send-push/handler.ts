// The send-push request, independent of the Supabase client so who is told
// what, and what each APNs answer means, are testable on their own
// (supabase/tests/send-push.test.mjs). index.ts wires the real services.

import { type Alert, type ApnsConfig, type ApnsEnvironment, sendAlert } from "./apns.ts";

export type PushKind = "deposit" | "comment" | "reaction" | "join" | "huddle_deleted";
/** What the event's deposit is (public.push_media_type); null for a join. */
export type MediaType = "photo" | "video";
const KINDS: readonly string[] = ["deposit", "comment", "reaction", "join", "huddle_deleted"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** One row of public.push_targets: a device to notify, and what to say. */
export interface PushTarget {
  user_id: string;
  token: string;
  environment: ApnsEnvironment;
  huddle_id: string;
  huddle_name: string;
  huddle_emoji: string;
  actor_name: string | null;
  /** A reaction's emoji. */
  detail: string | null;
}

export interface SendPushServices {
  /** PUSH_WEBHOOK_SECRET, which the database triggers send as x-push-secret. */
  webhookSecret: string | null;
  /** The APNS_* secrets; null when they aren't set. */
  apns: ApnsConfig | null;
  /** A current provider token (cached; see ProviderTokenCache). */
  providerToken(): Promise<string>;
  /** public.push_targets(kind, id). */
  targets(kind: PushKind, id: string): Promise<PushTarget[]>;
  /** public.push_media_type(kind, id). */
  mediaType(kind: PushKind, id: string): Promise<MediaType | null>;
  /** Deletes device tokens APNs reported as no longer valid. */
  removeTokens(tokens: string[]): Promise<void>;
  fetch: typeof fetch;
  /** Server-side log. Never handed a token or a secret. */
  log(event: string, detail?: string): void;
}

/**
 * The notification's words. Huddle names, display names and reaction emoji
 * aren't end-to-end encrypted, so they can be shown; captions and comment
 * text are never sent (they never reach this function), and photos and
 * videos are only ever ciphertext on the server.
 */
export function alertFor(kind: PushKind, target: PushTarget, mediaType: MediaType | null = "photo"): Alert {
  const who = target.actor_name?.trim() || "Someone";
  const title = `${target.huddle_emoji} ${target.huddle_name}`.trim();
  const what = mediaType === "video" ? "video" : "photo";
  const body = {
    deposit: `${who} posted a ${what}.`,
    comment: `${who} commented on your ${what}.`,
    reaction: target.detail ? `${who} reacted ${target.detail} to your ${what}.` : `${who} reacted to your ${what}.`,
    join: `${who} joined the huddle.`,
    huddle_deleted: `${who} deleted the huddle.`,
  }[kind];
  return { title, body, huddleId: target.huddle_id };
}

export async function handleSendPush(req: Request, services: SendPushServices): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!services.webhookSecret) {
    services.log("push_refused", "PUSH_WEBHOOK_SECRET not set");
    return json({ error: "not_configured" }, 500);
  }
  if (!sameSecret(req.headers.get("x-push-secret") ?? "", services.webhookSecret)) {
    return json({ error: "not_authorized" }, 401);
  }

  let kind: unknown, id: unknown;
  try {
    ({ kind, id } = await req.json());
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  if (typeof kind !== "string" || !KINDS.includes(kind) || typeof id !== "string" || !UUID.test(id)) {
    return json({ error: "bad_request" }, 400);
  }

  const apns = services.apns;
  if (!apns) {
    services.log("push_skipped", "APNS_* secrets not set");
    return json({ sent: 0, failed: 0, removed: 0 }, 200);
  }

  let targets: PushTarget[];
  try {
    targets = await services.targets(kind as PushKind, id);
  } catch (e) {
    services.log("push_targets_failed", e instanceof Error ? e.message : String(e));
    return json({ error: "targets_failed" }, 500);
  }
  if (targets.length === 0) return json({ sent: 0, failed: 0, removed: 0 }, 200);

  // Before migration 013 (or if the lookup fails) every deposit is a photo.
  let mediaType: MediaType | null = "photo";
  if (kind !== "join" && kind !== "huddle_deleted") {
    try {
      mediaType = (await services.mediaType(kind as PushKind, id)) ?? "photo";
    } catch (e) {
      services.log("push_media_type_failed", e instanceof Error ? e.message : String(e));
    }
  }

  const providerToken = await services.providerToken();
  const outcomes = await Promise.all(targets.map((target) =>
    sendAlert(
      services.fetch,
      apns,
      providerToken,
      target.token,
      target.environment,
      alertFor(kind as PushKind, target, mediaType),
    )
  ));

  const invalid: string[] = [];
  let sent = 0, failed = 0;
  outcomes.forEach((outcome, i) => {
    if (outcome.status === "sent") sent++;
    else if (outcome.status === "invalid_token") invalid.push(targets[i].token);
    else {
      failed++;
      services.log("push_failed", `${kind} ${outcome.httpStatus} ${outcome.reason}`.trim());
    }
  });
  const removed = [...new Set(invalid)];
  if (removed.length > 0) {
    try {
      await services.removeTokens(removed);
    } catch (e) {
      services.log("token_cleanup_failed", e instanceof Error ? e.message : String(e));
    }
  }
  services.log("push_sent", `${kind} sent=${sent} failed=${failed} removed=${removed.length}`);
  return json({ sent, failed, removed: removed.length }, 200);
}

/** Constant-time comparison, so the secret can't be guessed byte by byte. */
function sameSecret(given: string, expected: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let difference = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) difference |= (a[i] ?? 0) ^ b[i];
  return difference === 0;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
