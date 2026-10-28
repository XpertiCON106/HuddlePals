// The delete-account request, independent of the Supabase client so the
// order of the steps and what each failure means are testable on their own
// (supabase/tests/delete-account.test.mjs). index.ts wires the real services.

import { type AppleConfig, AppleError, revokeWithAuthorizationCode } from "./apple.ts";

/** The parts of a GoTrue user this function reads. */
export interface AuthUser {
  id: string;
  identities?: {
    provider: string;
    id?: string;
    provider_id?: string;
    identity_data?: { sub?: unknown };
  }[];
}

export interface DeleteAccountServices {
  /** The caller, from their access token; null if it isn't valid. */
  authenticate(accessToken: string): Promise<AuthUser | null>;
  /** The APPLE_* secrets; null when they aren't set. */
  apple: AppleConfig | null;
  fetch: typeof fetch;
  /** Deletes the user's registered devices, so no notification reaches them. */
  removeDeviceTokens(userId: string): Promise<void>;
  /** Deletes the user's profile photos (avatars/<user id>/...). */
  removeAvatars(userId: string): Promise<void>;
  /**
   * Deletes every huddle in which this user is the only member, and that
   * huddle's Storage files, keeping a reported deposit's files. Huddles
   * that still have other members are left alone.
   */
  removeSoleHuddles(userId: string): Promise<void>;
  /** Leaves the user's remaining Storage objects (deposit photos) unowned. */
  releaseStorageObjects(userId: string): Promise<void>;
  /** auth.admin.deleteUser. Throws on failure. */
  deleteUser(userId: string): Promise<void>;
  /** Server-side log. Never handed a token, code, or secret. */
  log(event: string, detail?: string): void;
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** Longest authorization code accepted (Apple's are well under 100 chars). */
const MAX_CODE_LENGTH = 512;

export async function handleDeleteAccount(req: Request, services: DeleteAccountServices): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const accessToken = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const user = accessToken ? await services.authenticate(accessToken) : null;
  if (!user) return json({ error: "not_authenticated" }, 401);

  // 1. Revoke the app's Apple tokens. Best effort: deletion must go ahead
  //    even if Apple can't be reached, so a failure is only logged.
  try {
    services.log(await revokeApple(user, await authorizationCode(req), services));
  } catch (e) {
    services.log("apple_revoke_failed", e instanceof AppleError ? e.message : errorName(e));
  }

  // 2. Forget the user's devices: no more notifications. (deleteUser's
  //    cascade removes them too; this stops them even if it fails.)
  try {
    await services.removeDeviceTokens(user.id);
  } catch (e) {
    services.log("device_token_cleanup_failed", errorName(e));
  }

  // 3. Delete the profile photos. Deposit photos in a huddle that still
  //    has other members stay on purpose: that archive is permanent.
  try {
    await services.removeAvatars(user.id);
  } catch (e) {
    services.log("avatar_cleanup_failed", errorName(e));
  }

  // 4. Delete huddles this person is the only member of, including their
  //    files. A reported deposit's files are kept. Best effort: a failure
  //    is logged and the account deletion goes on.
  try {
    await services.removeSoleHuddles(user.id);
  } catch (e) {
    services.log("sole_huddle_cleanup_failed", errorName(e));
  }

  // 5. Release the deposit photos the user uploaded. Where storage.objects
  //    .owner still references auth.users, deleteUser fails for anyone who
  //    owns an object.
  try {
    await services.releaseStorageObjects(user.id);
  } catch (e) {
    services.log("storage_release_failed", errorName(e));
  }

  // 6. Delete the auth user. FKs cascade the profile, memberships, device
  //    tokens and the user's E2EE keys. In a huddle that still has other
  //    members, deposits and comments keep their rows with a null author
  //    ("Former member").
  try {
    await services.deleteUser(user.id);
  } catch (e) {
    services.log("delete_failed", e instanceof Error ? e.message : String(e));
    return json({ error: "delete_failed" }, 500);
  }
  return json({ ok: true }, 200);
}

async function revokeApple(user: AuthUser, code: string | null, services: DeleteAccountServices): Promise<string> {
  const apple = (user.identities ?? []).filter((identity) => identity.provider === "apple");
  if (apple.length === 0) return "apple_revoke_skipped: not an Apple account";
  if (!services.apple) return "apple_revoke_skipped: APPLE_* secrets not set";
  if (!code) return "apple_revoke_skipped: no authorization code";

  const appleUserIds = apple
    .flatMap((identity) => [identity.id, identity.provider_id, identity.identity_data?.sub])
    .filter((id): id is string => typeof id === "string" && id.length > 0);
  const outcome = await revokeWithAuthorizationCode(code, services.apple, appleUserIds, services.fetch);
  return outcome === "revoked" ? "apple_revoked" : "apple_revoke_skipped: code is for another Apple Account";
}

/** `authorization_code` from the JSON body; older app versions send none. */
async function authorizationCode(req: Request): Promise<string | null> {
  try {
    const code = (await req.json())?.authorization_code;
    return typeof code === "string" && code.length > 0 && code.length <= MAX_CODE_LENGTH ? code : null;
  } catch {
    return null;
  }
}

/** Enough to tell failures apart without echoing request data. */
function errorName(e: unknown): string {
  return e instanceof Error ? `${e.name}: ${e.message}` : String(e);
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
