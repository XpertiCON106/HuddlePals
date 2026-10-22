// Apple Push Notification service: token-based auth (an ES256 JWT signed
// with the APNs .p8 key) and one alert request per device. APNs speaks only
// HTTP/2; Deno's fetch negotiates it over TLS, so plain fetch is enough.
//
// Plain WebCrypto + fetch, no runtime-specific imports, like
// delete-account/apple.ts: the edge function runs it on Deno, and
// supabase/tests runs it on Node (send-push.test.mjs).

const HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;
const TIMEOUT_MS = 10_000;
/** How long APNs keeps trying a device that's offline. */
const EXPIRY_SECONDS = 24 * 60 * 60;

export type ApnsEnvironment = keyof typeof HOSTS;

export interface ApnsConfig {
  /** 10-character ID of the APNs key. */
  keyId: string;
  /** 10-character Team ID (Membership details in the developer account). */
  teamId: string;
  /** The key's .p8 contents (PEM). Newlines may be escaped as \n. */
  privateKey: string;
  /** The app's bundle ID, sent as apns-topic. */
  bundleId: string;
}

/** The APNS_* edge function secrets, or null if any is missing. */
export function apnsConfigFromEnv(get: (name: string) => string | undefined): ApnsConfig | null {
  const keyId = get("APNS_KEY_ID");
  const teamId = get("APNS_TEAM_ID");
  const privateKey = get("APNS_PRIVATE_KEY");
  const bundleId = get("APNS_BUNDLE_ID");
  if (!keyId || !teamId || !privateKey || !bundleId) return null;
  return { keyId, teamId, privateKey, bundleId };
}

/** The provider token APNs takes as `authorization: bearer …`. */
export async function makeProviderToken(
  config: ApnsConfig,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  const header = base64url(utf8(JSON.stringify({ alg: "ES256", kid: config.keyId })));
  const claims = base64url(utf8(JSON.stringify({ iss: config.teamId, iat: nowSeconds })));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(config.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  // WebCrypto's ECDSA signature is r || s, exactly what JWS ES256 expects.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(`${header}.${claims}`));
  return `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
}

/**
 * Reuses one provider token for 50 minutes. APNs refuses a token older than
 * an hour, and answers 429 TooManyProviderTokenUpdates to a sender that mints
 * new ones more often than every 20 minutes.
 */
export class ProviderTokenCache {
  static readonly lifetimeSeconds = 50 * 60;
  private readonly config: ApnsConfig;
  private token: string | null = null;
  private issuedAt = 0;

  constructor(config: ApnsConfig) {
    this.config = config;
  }

  async get(nowSeconds = Math.floor(Date.now() / 1000)): Promise<string> {
    if (!this.token || nowSeconds - this.issuedAt >= ProviderTokenCache.lifetimeSeconds) {
      this.token = await makeProviderToken(this.config, nowSeconds);
      this.issuedAt = nowSeconds;
    }
    return this.token;
  }
}

export interface Alert {
  title: string;
  body: string;
  /** Opened when the notification is tapped; also groups a huddle's alerts. */
  huddleId: string;
}

/**
 * "sent"; "invalid_token" when APNs says the token is no good any more
 * (410 Unregistered, 400 BadDeviceToken), so it should be deleted; "failed"
 * for anything else (logged, token kept).
 */
export type SendOutcome =
  | { status: "sent" }
  | { status: "invalid_token"; reason: string }
  | { status: "failed"; httpStatus: number; reason: string };

export async function sendAlert(
  fetchFn: typeof fetch,
  config: ApnsConfig,
  providerToken: string,
  deviceToken: string,
  environment: ApnsEnvironment,
  alert: Alert,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<SendOutcome> {
  let response: Response;
  try {
    response = await fetchFn(`${HOSTS[environment]}/3/device/${deviceToken}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${providerToken}`,
        "apns-topic": config.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(nowSeconds + EXPIRY_SECONDS),
        "content-type": "application/json",
      },
      body: JSON.stringify({
        aps: {
          alert: { title: alert.title, body: alert.body },
          sound: "default",
          "thread-id": alert.huddleId,
        },
        huddle_id: alert.huddleId,
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (e) {
    return { status: "failed", httpStatus: 0, reason: e instanceof Error ? e.name : "network" };
  }
  if (response.ok) return { status: "sent" };
  const reason = await errorReason(response);
  if (response.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered") {
    return { status: "invalid_token", reason: reason || "Unregistered" };
  }
  return { status: "failed", httpStatus: response.status, reason };
}

async function errorReason(response: Response): Promise<string> {
  try {
    const body = await response.json();
    return typeof body?.reason === "string" ? body.reason : "";
  } catch {
    return "";
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
