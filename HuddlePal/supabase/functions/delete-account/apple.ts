// Sign in with Apple token revocation (App Review guideline 5.1.1(v)).
//
// The app re-authenticates with Apple when the user deletes their account and
// sends the fresh authorization code. It is exchanged at /auth/token for the
// app's tokens, and the refresh token is revoked at /auth/revoke, which
// removes HuddlePals from the user's "Sign in with Apple" list.
//
// Plain WebCrypto + fetch, no runtime-specific imports: the edge function runs
// it on Deno, and supabase/tests runs it on Node (delete-account.test.mjs).

const APPLE = "https://appleid.apple.com";
const TIMEOUT_MS = 10_000;

export interface AppleConfig {
  /** 10-character Team ID (Membership details in the developer account). */
  teamId: string;
  /** 10-character ID of the Sign in with Apple key. */
  keyId: string;
  /** The app's bundle ID: native authorization codes are issued to it. */
  clientId: string;
  /** The key's .p8 contents (PEM). Newlines may be escaped as \n. */
  privateKey: string;
}

/** The APPLE_* edge function secrets, or null if any is missing. */
export function appleConfigFromEnv(get: (name: string) => string | undefined): AppleConfig | null {
  const teamId = get("APPLE_TEAM_ID");
  const keyId = get("APPLE_KEY_ID");
  const clientId = get("APPLE_CLIENT_ID");
  const privateKey = get("APPLE_PRIVATE_KEY");
  if (!teamId || !keyId || !clientId || !privateKey) return null;
  return { teamId, keyId, clientId, privateKey };
}

/** A non-OK answer from Apple. Carries no token or code, so it's safe to log. */
export class AppleError extends Error {
  readonly step: "token" | "revoke";
  readonly status: number;
  /** Apple's `error` value (invalid_grant, invalid_client, ...), if any. */
  readonly code: string;

  constructor(step: "token" | "revoke", status: number, code: string) {
    super(`apple ${step} ${status}${code ? ` ${code}` : ""}`);
    this.step = step;
    this.status = status;
    this.code = code;
  }
}

/**
 * "revoked": the user's authorization for the app is gone.
 * "other_apple_id": the code belongs to a different Apple Account than the
 * one this user signed up with, so nothing was revoked.
 */
export type RevokeOutcome = "revoked" | "other_apple_id";

/**
 * Exchanges `code` for the app's tokens and revokes them. `appleUserIds` are
 * the Apple user ids linked to the account being deleted; a code issued to
 * anyone else is not revoked. Throws AppleError when Apple refuses a step.
 */
export async function revokeWithAuthorizationCode(
  code: string,
  config: AppleConfig,
  appleUserIds: string[],
  fetchFn: typeof fetch = fetch,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<RevokeOutcome> {
  const clientSecret = await makeClientSecret(config, nowSeconds);

  const tokenResponse = await post(fetchFn, "/auth/token", {
    client_id: config.clientId,
    client_secret: clientSecret,
    code,
    grant_type: "authorization_code",
  });
  if (!tokenResponse.ok) throw new AppleError("token", tokenResponse.status, await errorCode(tokenResponse));
  const tokens = await tokenResponse.json();

  const subject = subjectOf(tokens.id_token);
  if (subject && appleUserIds.length > 0 && !appleUserIds.includes(subject)) return "other_apple_id";

  const [token, hint] = typeof tokens.refresh_token === "string"
    ? [tokens.refresh_token, "refresh_token"]
    : [tokens.access_token, "access_token"];
  if (typeof token !== "string") throw new AppleError("token", tokenResponse.status, "no_token");

  const revokeResponse = await post(fetchFn, "/auth/revoke", {
    client_id: config.clientId,
    client_secret: clientSecret,
    token,
    token_type_hint: hint,
  });
  if (!revokeResponse.ok) throw new AppleError("revoke", revokeResponse.status, await errorCode(revokeResponse));
  return "revoked";
}

/**
 * The client secret Apple's REST API takes: an ES256 JWT signed with the
 * Sign in with Apple key. Valid for 5 minutes, long enough for both calls.
 */
export async function makeClientSecret(
  config: AppleConfig,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  const header = base64url(utf8(JSON.stringify({ alg: "ES256", kid: config.keyId })));
  const claims = base64url(utf8(JSON.stringify({
    iss: config.teamId,
    iat: nowSeconds,
    exp: nowSeconds + 300,
    aud: APPLE,
    sub: config.clientId,
  })));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(config.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  // WebCrypto's ECDSA signature is r || s, exactly what JWS ES256 expects.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    utf8(`${header}.${claims}`),
  );
  return `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
}

function post(fetchFn: typeof fetch, path: string, form: Record<string, string>): Promise<Response> {
  return fetchFn(`${APPLE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
}

async function errorCode(response: Response): Promise<string> {
  try {
    const body = await response.json();
    return typeof body?.error === "string" ? body.error : "";
  } catch {
    return "";
  }
}

/**
 * The `sub` claim of the ID token from /auth/token. It came straight from
 * Apple over TLS in answer to our own request, so it isn't re-verified.
 */
function subjectOf(idToken: unknown): string | null {
  if (typeof idToken !== "string") return null;
  try {
    const payload = idToken.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const sub = JSON.parse(atob(payload)).sub;
    return typeof sub === "string" ? sub : null;
  } catch {
    return null;
  }
}

function pemToBytes(pem: string): ArrayBuffer {
  const base64 = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function utf8(text: string) {
  return new TextEncoder().encode(text);
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
