// Supabase Edge Function: delete-account
//
// Permanently deletes the calling user's account (Model B):
//   1. (If Sign in with Apple) revoke the user's Apple token — required by
//      App Review guideline 5.1.1(v) for any app offering Sign in with Apple.
//   2. Delete the user's avatar Storage objects (PII).
//   3. Delete the auth user. FKs then cascade: profile is removed, and so
//      are the user's E2EE keys (user_keys, huddle_keys); deposits/comments
//      keep their rows with a null author ("Former member") — the huddle's
//      archive stays permanent, and stays readable to members, who hold
//      their own copies of the huddle key.
//
// Deploy:  supabase functions deploy delete-account
// Secrets (supabase secrets set ...): SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//   are injected automatically. For Apple revocation set:
//     APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_SERVICE_ID (your bundle id),
//     APPLE_PRIVATE_KEY (the .p8 contents, newlines as \n).
//   If those are unset, deletion still completes; revocation is skipped.
//
// NOTE: not yet run against a live project — test in the dashboard before
// relying on it. The iOS app calls this via POST /functions/v1/delete-account
// with the user's bearer token.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { create, getNumericDate } from "https://deno.land/x/djwt@v3.0.2/mod.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const authHeader = req.headers.get("Authorization") ?? "";

  // Identify the caller from their JWT (anon client bound to the bearer).
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await asUser.auth.getUser();
  if (userErr || !userData.user) return json({ error: "not_authenticated" }, 401);
  const userId = userData.user.id;

  // Admin client (service role) for the privileged operations.
  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 1. Best-effort Apple token revocation.
  try {
    await revokeAppleIfLinked(admin, userData.user);
  } catch (e) {
    console.error("apple_revoke_failed", String(e)); // non-fatal
  }

  // 2. Delete the user's avatar objects (deposit photos are kept on purpose).
  try {
    const prefix = `avatars/${userId}`;
    const { data: files } = await admin.storage.from("deposits").list(prefix);
    if (files && files.length) {
      await admin.storage
        .from("deposits")
        .remove(files.map((f) => `${prefix}/${f.name}`));
    }
  } catch (e) {
    console.error("avatar_cleanup_failed", String(e)); // non-fatal
  }

  // 3. Delete the auth user — cascades remove the profile/memberships and
  //    the user's user_keys/huddle_keys rows; deposits + comments are
  //    repointed to null author by the FK SET NULL.
  const { error: delErr } = await admin.auth.admin.deleteUser(userId);
  if (delErr) return json({ error: "delete_failed", detail: delErr.message }, 500);

  return json({ ok: true }, 200);
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

// Revokes the user's Sign in with Apple token if their account is linked to
// Apple. Requires the Apple credentials below; skips cleanly if unset.
async function revokeAppleIfLinked(admin: ReturnType<typeof createClient>, user: any) {
  const linkedApple = (user.identities ?? []).some((i: any) => i.provider === "apple");
  if (!linkedApple) return;

  const teamId = Deno.env.get("APPLE_TEAM_ID");
  const keyId = Deno.env.get("APPLE_KEY_ID");
  const serviceId = Deno.env.get("APPLE_SERVICE_ID"); // your app's bundle id
  const privateKeyPem = Deno.env.get("APPLE_PRIVATE_KEY")?.replace(/\\n/g, "\n");
  if (!teamId || !keyId || !serviceId || !privateKeyPem) {
    console.warn("apple_revoke_skipped: missing APPLE_* secrets");
    return;
  }

  // The provider refresh/access token GoTrue stored at sign-in. Availability
  // depends on your GoTrue config; revocation is best-effort if absent.
  const appleIdentity = (user.identities ?? []).find((i: any) => i.provider === "apple");
  const token =
    appleIdentity?.identity_data?.refresh_token ??
    appleIdentity?.identity_data?.access_token;
  if (!token) {
    console.warn("apple_revoke_skipped: no stored Apple token");
    return;
  }

  const clientSecret = await makeAppleClientSecret(teamId, keyId, serviceId, privateKeyPem);
  const body = new URLSearchParams({
    client_id: serviceId,
    client_secret: clientSecret,
    token,
    token_type_hint: appleIdentity?.identity_data?.refresh_token ? "refresh_token" : "access_token",
  });
  const res = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) throw new Error(`apple revoke status ${res.status}`);
}

// Builds the ES256 client secret JWT Apple requires for the revoke call.
async function makeAppleClientSecret(
  teamId: string,
  keyId: string,
  serviceId: string,
  privateKeyPem: string,
): Promise<string> {
  const pkcs8 = pemToArrayBuffer(privateKeyPem);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return await create(
    { alg: "ES256", kid: keyId },
    {
      iss: teamId,
      iat: getNumericDate(0),
      exp: getNumericDate(60 * 5),
      aud: "https://appleid.apple.com",
      sub: serviceId,
    },
    key,
  );
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
}
