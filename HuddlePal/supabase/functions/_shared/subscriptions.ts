// What a verified App Store transaction (and its renewal info) means for
// HuddlePals+, once it passes our own checks: this app, a Plus product,
// a subscription bought by this Apple Account (Family Sharing is off), in
// production or the sandbox (App Review and TestFlight buy there; a local
// StoreKit test signs with a certificate Apple's root never issued, so it
// fails before this). Shared by verify-subscription and app-store-notifications.

import { verifyAppleJws } from "./apple-jws.ts";

export interface AppStoreConfig {
  /** APPSTORE_BUNDLE_ID: com.huddlepals.ios. */
  bundleId: string;
  /** APPSTORE_PRODUCT_IDS, comma-separated: the Plus subscriptions. */
  productIds: string[];
  /** Apple Root CA - G3 unless a test passes its own (base64 DER). */
  rootCertificate?: string;
}

/** The APPSTORE_* edge function secrets, or null if any is missing. */
export function appStoreConfigFromEnv(get: (name: string) => string | undefined): AppStoreConfig | null {
  const bundleId = get("APPSTORE_BUNDLE_ID")?.trim();
  const productIds = (get("APPSTORE_PRODUCT_IDS") ?? "").split(",").map((id) => id.trim()).filter(Boolean);
  if (!bundleId || productIds.length === 0) return null;
  return { bundleId, productIds };
}

/** Signed by Apple, but not a Plus subscription of this app. Safe to log. */
export class InvalidTransaction extends Error {}

/** apply_entitlement's arguments, from Apple's signed data. Times are ISO 8601. */
export interface EntitlementUpdate {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  environment: "Production" | "Sandbox";
  purchasedAt: string | null;
  expiresAt: string;
  revokedAt: string | null;
  transactionSignedAt: string;
  /** The account the app named at purchase (lowercase uuid), if any. */
  appAccountToken: string | null;
  gracePeriodExpiresAt: string | null;
  willAutoRenew: boolean | null;
  renewalSignedAt: string | null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Checks Apple's signature on a transaction (and on its renewal info, when
 * given), then that it's ours. Throws JwsError for a bad signature and
 * InvalidTransaction for genuine data that isn't a Plus subscription.
 */
export async function entitlementFrom(
  signedTransaction: string,
  signedRenewalInfo: string | null,
  config: AppStoreConfig,
  now = Date.now(),
): Promise<EntitlementUpdate> {
  const options = { rootCertificate: config.rootCertificate, now };
  const transaction = await verifyAppleJws(signedTransaction, options);
  if (transaction.bundleId !== config.bundleId) throw new InvalidTransaction("wrong_bundle");
  const productId = transaction.productId;
  if (typeof productId !== "string" || !config.productIds.includes(productId)) {
    throw new InvalidTransaction("unknown_product");
  }
  if (transaction.type !== "Auto-Renewable Subscription") throw new InvalidTransaction("not_a_subscription");
  const environment = transaction.environment;
  if (environment !== "Production" && environment !== "Sandbox") {
    throw new InvalidTransaction("unsupported_environment");
  }
  if (transaction.inAppOwnershipType !== "PURCHASED") throw new InvalidTransaction("not_purchased");
  const originalTransactionId = text(transaction.originalTransactionId);
  const transactionId = text(transaction.transactionId);
  const expiresAt = time(transaction.expiresDate);
  const transactionSignedAt = time(transaction.signedDate);
  if (!originalTransactionId || !transactionId || !expiresAt || !transactionSignedAt) {
    throw new InvalidTransaction("incomplete");
  }
  const token = transaction.appAccountToken;

  const update: EntitlementUpdate = {
    originalTransactionId,
    transactionId,
    productId,
    environment,
    purchasedAt: time(transaction.purchaseDate),
    expiresAt,
    revokedAt: time(transaction.revocationDate),
    transactionSignedAt,
    appAccountToken: typeof token === "string" && UUID.test(token) ? token.toLowerCase() : null,
    gracePeriodExpiresAt: null,
    willAutoRenew: null,
    renewalSignedAt: null,
  };
  if (signedRenewalInfo === null) return update;

  const renewal = await verifyAppleJws(signedRenewalInfo, options);
  if (renewal.originalTransactionId !== originalTransactionId || renewal.environment !== environment) {
    throw new InvalidTransaction("renewal_info_mismatch");
  }
  const renewalSignedAt = time(renewal.signedDate);
  if (!renewalSignedAt) throw new InvalidTransaction("incomplete");
  return {
    ...update,
    gracePeriodExpiresAt: time(renewal.gracePeriodExpiresDate),
    willAutoRenew: renewal.autoRenewStatus === 1 ? true : renewal.autoRenewStatus === 0 ? false : null,
    renewalSignedAt,
  };
}

/** What apply_entitlement answered (see schema.sql). */
export type ApplyOutcome = "applied" | "stale" | "in_use" | "unbound";

/** apply_entitlement's named parameters. */
export function applyEntitlementParams(userId: string | null, update: EntitlementUpdate) {
  return {
    p_user: userId,
    p_original_transaction_id: update.originalTransactionId,
    p_transaction_id: update.transactionId,
    p_product_id: update.productId,
    p_environment: update.environment,
    p_purchased_at: update.purchasedAt,
    p_expires_at: update.expiresAt,
    p_revoked_at: update.revokedAt,
    p_transaction_signed_at: update.transactionSignedAt,
    p_app_account_token: update.appAccountToken,
    p_grace_period_expires_at: update.gracePeriodExpiresAt,
    p_will_auto_renew: update.willAutoRenew,
    p_renewal_signed_at: update.renewalSignedAt,
  };
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 && value.length <= 64 ? value : null;
}

/** Apple's dates are milliseconds since 1970. */
function time(value: unknown): string | null {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? new Date(value).toISOString() : null;
}
