// HuddlePals Plus, server side: checking Apple's signature on App Store data
// (functions/_shared/apple-jws.ts), deciding it's a Plus subscription of this
// app (functions/_shared/subscriptions.ts), and the verify-subscription and
// app-store-notifications handlers. Runs the functions' own TypeScript (Node
// strips the types) against test chains shaped like Apple's
// (app-store-chain.mjs), Apple's real root and intermediate, and the real
// apply_entitlement in PGlite; binding rules in depth are in
// entitlements.test.mjs.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createHash, X509Certificate, randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import {
  APPLE_ROOT_CA_G3, JwsError, isSignedBy, parseCertificate, verifyAppleJws,
} from '../functions/_shared/apple-jws.ts'
import {
  appStoreConfigFromEnv, applyEntitlementParams, entitlementFrom, InvalidTransaction,
} from '../functions/_shared/subscriptions.ts'
import { handleVerifySubscription } from '../functions/verify-subscription/handler.ts'
import { handleAppStoreNotification } from '../functions/app-store-notifications/handler.ts'
import { chain, ecKey, STORE_SIGNING_MARKER, WWDR_MARKER } from './app-store-chain.mjs'
import { freshDatabase, admin, service, signUp } from './harness.mjs'

const DAY = 86_400_000
const NOW = Date.now()
const USER = '6f9619ff-8b86-d011-b42d-00c04fc964ff'
const BUNDLE = 'com.huddlepals.ios'
const MONTHLY = 'com.huddlepals.ios.plus.monthly'
const ANNUAL = 'com.huddlepals.ios.plus.yearly'
const bytes = (base64) => new Uint8Array(Buffer.from(base64, 'base64'))

/** A StoreKit 2 transaction payload (JWSTransactionDecodedPayload) for a Plus purchase. */
const transaction = (overrides = {}) => ({
  transactionId: '2000000000000002',
  originalTransactionId: '2000000000000001',
  webOrderLineItemId: '2000000000000003',
  bundleId: BUNDLE,
  productId: MONTHLY,
  subscriptionGroupIdentifier: '21000000',
  purchaseDate: NOW - DAY,
  originalPurchaseDate: NOW - 40 * DAY,
  expiresDate: NOW + 29 * DAY,
  quantity: 1,
  type: 'Auto-Renewable Subscription',
  appAccountToken: USER.toUpperCase(),
  inAppOwnershipType: 'PURCHASED',
  signedDate: NOW,
  environment: 'Production',
  transactionReason: 'PURCHASE',
  ...overrides,
})

/** Its renewal info (JWSRenewalInfoDecodedPayload). */
const renewal = (overrides = {}) => ({
  originalTransactionId: '2000000000000001',
  autoRenewProductId: MONTHLY,
  productId: MONTHLY,
  autoRenewStatus: 1,
  signedDate: NOW,
  environment: 'Production',
  ...overrides,
})

const config = (signer, overrides = {}) => ({
  bundleId: BUNDLE, productIds: [MONTHLY, ANNUAL], rootCertificate: signer.rootCertificate, ...overrides,
})

describe("Apple's certificates", () => {
  it('the pinned root is Apple Root CA - G3', () => {
    const der = Buffer.from(APPLE_ROOT_CA_G3, 'base64')
    assert.equal(
      createHash('sha256').update(der).digest('hex'),
      '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179',
    )
    const parsed = new X509Certificate(der)
    assert.match(parsed.subject, /CN=Apple Root CA - G3/)
    assert.equal(parsed.ca, true)
  })

  it("reads Apple's real WWDR G6 intermediate and checks it against the root", async () => {
    const root = parseCertificate(bytes(APPLE_ROOT_CA_G3))
    const g6 = parseCertificate(new Uint8Array(readFileSync(new URL('./fixtures/apple/AppleWWDRCAG6.cer', import.meta.url))))
    assert.equal(g6.isCA, true)
    assert.ok(g6.extensions.has(WWDR_MARKER), "carries Apple's WWDR marker")
    assert.equal(await isSignedBy(g6, root), true)
    assert.equal(await isSignedBy(root, root), true, "the root's own signature (P-384, SHA-384)")
    assert.equal(await isSignedBy(root, g6), false)
    assert.equal(new Date(root.notAfter).toISOString(), '2039-04-30T18:19:06.000Z')
  })

  it("the test chains are real certificates (Node's own X.509 reader agrees)", () => {
    const signer = chain()
    const [leaf, intermediate, root] = [signer.leaf, signer.intermediate, signer.root].map((der) => new X509Certificate(der))
    assert.equal(intermediate.verify(root.publicKey), true)
    assert.equal(leaf.verify(intermediate.publicKey), true)
    assert.equal(leaf.checkIssued(intermediate), true)
    assert.equal(intermediate.ca, true)
    assert.equal(leaf.ca, false)
  })
})

describe('verifying a JWS', () => {
  const signer = chain()
  const options = { rootCertificate: signer.rootCertificate, now: NOW }

  it("returns the payload when Apple's chain and signature check out", async () => {
    assert.deepEqual(await verifyAppleJws(signer.sign({ hello: 'world' }), options), { hello: 'world' })
  })

  it('refuses one not chained to the pinned root', async () => {
    await assert.rejects(verifyAppleJws(signer.sign({}), { now: NOW }), /not Apple's root/, "a test chain against Apple's real root")
    const other = chain()
    await assert.rejects(verifyAppleJws(other.sign({}), options), /not Apple's root/)
  })

  it('refuses a forged intermediate or leaf presented with the real root', async () => {
    const forger = chain()
    // The forger's own intermediate and leaf (same names), the genuine root.
    const x5c = [forger.x5c[0], forger.x5c[1], signer.x5c[2]]
    await assert.rejects(verifyAppleJws(forger.sign({}, { header: { x5c } }), options), /bad certificate signature/)
    // The genuine intermediate, the forger's leaf.
    const leafOnly = [forger.x5c[0], signer.x5c[1], signer.x5c[2]]
    await assert.rejects(verifyAppleJws(forger.sign({}, { header: { x5c: leafOnly } }), options), /bad certificate signature/)
  })

  it('refuses a payload changed after signing, or signed by any other key', async () => {
    const [head, , signature] = signer.sign({ expiresDate: 1 }).split('.')
    const changed = Buffer.from(JSON.stringify({ expiresDate: 9_999_999_999_999 })).toString('base64url')
    await assert.rejects(verifyAppleJws(`${head}.${changed}.${signature}`, options), /bad signature/)
    await assert.rejects(verifyAppleJws(signer.sign({}, { key: ecKey().privateKey }), options), /bad signature/)
  })

  it('refuses certificates that have expired or are not yet valid', async () => {
    const expired = chain({ leaf: { notBefore: NOW - 400 * DAY, notAfter: NOW - DAY } })
    await assert.rejects(verifyAppleJws(expired.sign({}), { rootCertificate: expired.rootCertificate, now: NOW }), /leaf certificate not valid now/)
    const early = chain({ intermediate: { notBefore: NOW + DAY } })
    await assert.rejects(verifyAppleJws(early.sign({}), { rootCertificate: early.rootCertificate, now: NOW }), /intermediate certificate not valid now/)
  })

  it("refuses certificates without Apple's markers, or with the wrong roles", async () => {
    const cases = [
      [{ intermediate: { markers: [] } }, /not Apple's intermediate/],
      [{ intermediate: { ca: false } }, /not Apple's intermediate/],
      [{ leaf: { markers: [WWDR_MARKER] } }, /not an App Store signing certificate/],
      [{ leaf: { ca: true, markers: [STORE_SIGNING_MARKER] } }, /not an App Store signing certificate/],
      [{ leafCurve: 'P-384' }, /signing key is not P-256/],
    ]
    for (const [options, expected] of cases) {
      const bent = chain(options)
      await assert.rejects(verifyAppleJws(bent.sign({}), { rootCertificate: bent.rootCertificate, now: NOW }), expected, JSON.stringify(options))
    }
  })

  it('refuses anything that is not an ES256 JWS with a three-certificate chain', async () => {
    const malformed = [
      '', 'a.b', 'not.a.jws', signer.sign({}, { header: { alg: 'none' } }), signer.sign({}, { header: { alg: 'HS256' } }),
      signer.sign({}, { header: { x5c: signer.x5c.slice(0, 2) } }), signer.sign({}, { header: { x5c: undefined } }),
      signer.sign({}, { header: { x5c: ['!!', '!!', '!!'] } }), signer.sign({}, { header: { x5c: [signer.x5c[0], 'AAAA', signer.x5c[2]] } }),
    ]
    for (const jws of malformed) {
      await assert.rejects(verifyAppleJws(jws, options), JwsError, jws.slice(0, 40))
    }
  })
})

describe('what counts as a Plus subscription', () => {
  const signer = chain()

  it('maps a genuine purchase, with its renewal info, onto apply_entitlement', async () => {
    const update = await entitlementFrom(
      signer.sign(transaction()),
      signer.sign(renewal({ gracePeriodExpiresDate: NOW + 16 * DAY, autoRenewStatus: 0 })),
      config(signer),
      NOW,
    )
    assert.deepEqual(update, {
      originalTransactionId: '2000000000000001',
      transactionId: '2000000000000002',
      productId: MONTHLY,
      environment: 'Production',
      purchasedAt: new Date(NOW - DAY).toISOString(),
      expiresAt: new Date(NOW + 29 * DAY).toISOString(),
      revokedAt: null,
      transactionSignedAt: new Date(NOW).toISOString(),
      appAccountToken: USER,
      gracePeriodExpiresAt: new Date(NOW + 16 * DAY).toISOString(),
      willAutoRenew: false,
      renewalSignedAt: new Date(NOW).toISOString(),
    })
    assert.equal(applyEntitlementParams(USER, update).p_app_account_token, USER)
  })

  it('refuses genuine data that is not a Plus subscription of this app', async () => {
    const cases = [
      [transaction({ bundleId: 'com.example.other' }), null, 'wrong_bundle'],
      [transaction({ productId: 'com.huddlepals.ios.tip' }), null, 'unknown_product'],
      [transaction({ type: 'Non-Consumable' }), null, 'not_a_subscription'],
      [transaction({ environment: 'Xcode' }), null, 'unsupported_environment'],
      [transaction({ environment: 'LocalTesting' }), null, 'unsupported_environment'],
      [transaction({ inAppOwnershipType: 'FAMILY_SHARED' }), null, 'not_purchased'],
      [transaction({ expiresDate: undefined }), null, 'incomplete'],
      [transaction(), renewal({ originalTransactionId: '999' }), 'renewal_info_mismatch'],
      [transaction(), renewal({ environment: 'Sandbox' }), 'renewal_info_mismatch'],
    ]
    for (const [payload, info, reason] of cases) {
      await assert.rejects(
        entitlementFrom(signer.sign(payload), info && signer.sign(info), config(signer), NOW),
        (e) => e instanceof InvalidTransaction && e.message === reason,
        reason,
      )
    }
  })

  it('keeps refunds and expiry for the database to judge, and drops a malformed token', async () => {
    const update = await entitlementFrom(
      signer.sign(transaction({ revocationDate: NOW - 1000, expiresDate: NOW - DAY, appAccountToken: 'not-a-uuid' })),
      null, config(signer), NOW,
    )
    assert.equal(update.revokedAt, new Date(NOW - 1000).toISOString())
    assert.equal(update.expiresAt, new Date(NOW - DAY).toISOString())
    assert.equal(update.appAccountToken, null)
  })

  it('reads its configuration from the APPSTORE_* secrets', () => {
    assert.equal(appStoreConfigFromEnv(() => undefined), null)
    assert.equal(appStoreConfigFromEnv((n) => ({ APPSTORE_BUNDLE_ID: BUNDLE })[n]), null, 'no products')
    assert.deepEqual(
      appStoreConfigFromEnv((n) => ({ APPSTORE_BUNDLE_ID: BUNDLE, APPSTORE_PRODUCT_IDS: ` ${MONTHLY}, ${ANNUAL} ,` })[n]),
      { bundleId: BUNDLE, productIds: [MONTHLY, ANNUAL] },
    )
  })
})

describe('verify-subscription', () => {
  function setUp({ outcome = 'applied', signer = chain(), withConfig = true, failApply } = {}) {
    const applied = []
    const logs = []
    const services = {
      authenticate: async (token) => (token === 'valid-access-token' ? { id: USER } : null),
      config: withConfig ? config(signer) : null,
      applyEntitlement: async (userId, update) => {
        applied.push([userId, update])
        if (failApply) throw failApply
        return outcome
      },
      now: () => NOW,
      log: (event, detail) => logs.push(detail ? `${event} ${detail}` : event),
    }
    return { signer, services, applied, logs }
  }

  const request = (body, { token = 'valid-access-token', method = 'POST' } = {}) =>
    new Request('https://project.functions.test/verify-subscription', {
      method,
      headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' },
      body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
    })
  const answer = async (response) => [response.status, await response.json()]

  it("records a genuine purchase for the caller", async () => {
    const { signer, services, applied } = setUp()
    const body = { transaction: signer.sign(transaction()), renewal_info: signer.sign(renewal()) }
    assert.deepEqual(await answer(await handleVerifySubscription(request(body), services)), [200, { status: 'applied' }])
    assert.equal(applied.length, 1)
    assert.equal(applied[0][0], USER)
    assert.equal(applied[0][1].originalTransactionId, '2000000000000001')
    assert.equal(applied[0][1].willAutoRenew, true)
  })

  it('stale is fine too: the server already had something newer', async () => {
    const { signer, services } = setUp({ outcome: 'stale' })
    assert.deepEqual(await answer(await handleVerifySubscription(request({ transaction: signer.sign(transaction()) }), services)), [200, { status: 'stale' }])
  })

  it('a subscription another account holds: 409 subscription_in_use', async () => {
    const { signer, services } = setUp({ outcome: 'in_use' })
    assert.deepEqual(
      await answer(await handleVerifySubscription(request({ transaction: signer.sign(transaction()) }), services)),
      [409, { error: 'subscription_in_use' }],
    )
  })

  it('one with no appAccountToken binds only on Restore Purchases', async () => {
    const { signer, services, applied } = setUp()
    const unnamed = signer.sign(transaction({ appAccountToken: undefined }))
    assert.deepEqual(await answer(await handleVerifySubscription(request({ transaction: unnamed }), services)), [409, { error: 'needs_restore' }])
    assert.equal(applied.length, 0)
    assert.deepEqual(await answer(await handleVerifySubscription(request({ transaction: unnamed, restore: true }), services)), [200, { status: 'applied' }])
    assert.equal(applied[0][1].appAccountToken, null)
  })

  it('refuses forged and foreign transactions with 422, and never records them', async () => {
    const { signer, services, applied, logs } = setUp()
    const forger = chain()
    for (const jws of [
      forger.sign(transaction()),
      signer.sign(transaction({ bundleId: 'com.example.other' })),
      signer.sign(transaction({ environment: 'Xcode' })),
      signer.sign(transaction({ inAppOwnershipType: 'FAMILY_SHARED' })),
    ]) {
      assert.deepEqual(await answer(await handleVerifySubscription(request({ transaction: jws }), services)), [422, { error: 'invalid_transaction' }])
    }
    assert.equal(applied.length, 0)
    assert.deepEqual(logs, [
      "verify_invalid chain: not Apple's root", 'verify_invalid wrong_bundle', 'verify_invalid unsupported_environment', 'verify_invalid not_purchased',
    ])
  })

  it('needs a signed-in caller, a POST, a body, and the secrets', async () => {
    const { signer, services } = setUp()
    const body = { transaction: signer.sign(transaction()) }
    assert.equal((await handleVerifySubscription(request(body, { token: null }), services)).status, 401)
    assert.equal((await handleVerifySubscription(request(body, { token: 'expired' }), services)).status, 401)
    assert.equal((await handleVerifySubscription(request(body, { method: 'GET' }), services)).status, 405)
    for (const bad of ['not json', {}, { transaction: 42 }, { transaction: 'x'.repeat(20_000) }, { transaction: 'a.b.c', renewal_info: 7 }]) {
      assert.equal((await handleVerifySubscription(request(bad), services)).status, 400, JSON.stringify(bad).slice(0, 30))
    }
    const unconfigured = setUp({ withConfig: false })
    assert.deepEqual(await answer(await handleVerifySubscription(request(body), unconfigured.services)), [500, { error: 'not_configured' }])
  })

  it('a database failure is a 500, and the logs never hold the signed data', async () => {
    const { signer, services, logs } = setUp({ failApply: new Error('connection reset') })
    const jws = signer.sign(transaction())
    assert.deepEqual(await answer(await handleVerifySubscription(request({ transaction: jws }), services)), [500, { error: 'apply_failed' }])
    assert.ok(logs.every((line) => !line.includes(jws.split('.')[1])))
  })

  it('end to end with the real apply_entitlement: the purchase gives the caller Plus', async () => {
    const db = await freshDatabase()
    const uid = await signUp(db, 'Ada')
    const signer = chain()
    const services = {
      authenticate: async () => ({ id: uid }),
      config: config(signer),
      applyEntitlement: async (userId, update) => {
        const params = applyEntitlementParams(userId, update)
        const names = Object.keys(params)
        const [{ status }] = await service(
          db,
          `select apply_entitlement(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as status`,
          Object.values(params),
        )
        return status
      },
      now: () => NOW,
      log: () => {},
    }
    const jws = signer.sign(transaction({ appAccountToken: uid }))
    assert.equal((await handleVerifySubscription(request({ transaction: jws }), services)).status, 200)
    assert.deepEqual(await admin(db, 'select is_user_premium($1) p', [uid]), [{ p: true }])
    const other = await signUp(db, 'Ben')
    services.authenticate = async () => ({ id: other })
    assert.deepEqual(await answer(await handleVerifySubscription(request({ transaction: jws, restore: true }), services)), [409, { error: 'subscription_in_use' }])
    assert.deepEqual(await admin(db, 'select is_user_premium($1) p', [other]), [{ p: false }])
  })
})

describe('app-store-notifications', () => {
  function setUp({ outcome = 'applied', failApply, failRecord } = {}) {
    const signer = chain()
    const applied = []
    const recorded = []
    const logs = []
    const services = {
      config: config(signer),
      applyEntitlement: async (update) => {
        applied.push(update)
        if (failApply) throw failApply
        return outcome
      },
      recordNotification: async (record) => {
        if (failRecord) throw failRecord
        recorded.push(record)
      },
      now: () => NOW,
      log: (event, detail) => logs.push(detail ? `${event} ${detail}` : event),
    }
    return { signer, services, applied, recorded, logs }
  }

  /** A signed notification (ResponseBodyV2DecodedPayload) carrying `tx` and `info`. */
  const notification = (signer, { type = 'DID_RENEW', subtype, tx = transaction(), info = renewal(), data = {}, uuid = randomUUID() } = {}) =>
    signer.sign({
      notificationType: type,
      ...(subtype ? { subtype } : {}),
      notificationUUID: uuid,
      version: '2.0',
      signedDate: NOW,
      data: {
        bundleId: BUNDLE,
        environment: 'Production',
        ...(tx ? { signedTransactionInfo: signer.sign(tx) } : {}),
        ...(info ? { signedRenewalInfo: signer.sign(info) } : {}),
        ...data,
      },
    })

  const post = (body, method = 'POST') =>
    new Request('https://project.functions.test/app-store-notifications', {
      method, headers: { 'Content-Type': 'application/json' }, body: method === 'POST' ? JSON.stringify(body) : undefined,
    })
  const answer = async (response) => [response.status, await response.json()]

  it('applies what a renewal says, for whoever holds the subscription, and records it once handled', async () => {
    const { signer, services, applied, recorded } = setUp()
    const uuid = randomUUID()
    const signedPayload = notification(signer, { uuid, tx: transaction({ transactionId: '2000000000000009', expiresDate: NOW + 60 * DAY }) })
    assert.deepEqual(await answer(await handleAppStoreNotification(post({ signedPayload }), services)), [200, { status: 'applied' }])
    assert.equal(applied[0].transactionId, '2000000000000009')
    assert.equal(applied[0].expiresAt, new Date(NOW + 60 * DAY).toISOString())
    assert.deepEqual(recorded, [{
      uuid, type: 'DID_RENEW', subtype: null, originalTransactionId: '2000000000000001', signedAt: new Date(NOW).toISOString(),
    }])
  })

  it('carries a billing grace period and a refund through to the database', async () => {
    const { signer, services, applied } = setUp()
    await handleAppStoreNotification(post({
      signedPayload: notification(signer, {
        type: 'DID_FAIL_TO_RENEW', subtype: 'GRACE_PERIOD',
        tx: transaction({ expiresDate: NOW - 1000 }), info: renewal({ gracePeriodExpiresDate: NOW + 16 * DAY }),
      }),
    }), services)
    await handleAppStoreNotification(post({ signedPayload: notification(signer, { type: 'REFUND', tx: transaction({ revocationDate: NOW - 5000 }) }) }), services)
    assert.equal(applied[0].gracePeriodExpiresAt, new Date(NOW + 16 * DAY).toISOString())
    assert.equal(applied[1].revokedAt, new Date(NOW - 5000).toISOString())
  })

  it("records Apple's test notification, which carries no transaction", async () => {
    const { signer, services, applied, recorded } = setUp()
    const signedPayload = notification(signer, { type: 'TEST', tx: null, info: null })
    assert.deepEqual(await answer(await handleAppStoreNotification(post({ signedPayload }), services)), [200, { status: 'recorded' }])
    assert.equal(applied.length, 0)
    assert.equal(recorded[0].type, 'TEST')
  })

  it("acknowledges, without applying, genuine notifications that aren't ours to act on", async () => {
    const { signer, services, applied, recorded } = setUp()
    for (const signedPayload of [
      notification(signer, { data: { bundleId: 'com.example.other' } }),
      notification(signer, { tx: transaction({ productId: 'com.huddlepals.ios.tip' }) }),
      notification(signer, { tx: transaction({ inAppOwnershipType: 'FAMILY_SHARED' }) }),
    ]) {
      assert.deepEqual(await answer(await handleAppStoreNotification(post({ signedPayload }), services)), [200, { status: 'ignored' }])
    }
    assert.equal(applied.length, 0)
    assert.equal(recorded.length, 3)
  })

  it('a subscription nobody has claimed yet waits for the app', async () => {
    const { signer, services } = setUp({ outcome: 'unbound' })
    assert.deepEqual(await answer(await handleAppStoreNotification(post({ signedPayload: notification(signer) }), services)), [200, { status: 'unbound' }])
  })

  it('refuses a forged notification, and one wrapping a forged transaction', async () => {
    const { signer, services, applied, recorded } = setUp()
    const forger = chain()
    assert.deepEqual(await answer(await handleAppStoreNotification(post({ signedPayload: notification(forger) }), services)), [401, { error: 'invalid_signature' }])
    const wrapped = signer.sign({
      notificationType: 'DID_RENEW', notificationUUID: randomUUID(), signedDate: NOW,
      data: { bundleId: BUNDLE, environment: 'Production', signedTransactionInfo: forger.sign(transaction()) },
    })
    assert.deepEqual(await answer(await handleAppStoreNotification(post({ signedPayload: wrapped }), services)), [200, { status: 'ignored' }])
    assert.equal(applied.length, 0)
    assert.equal(recorded.length, 1, 'only the genuine outer notification')
  })

  it('a database failure is a 500, so Apple retries', async () => {
    const failing = setUp({ failApply: new Error('timeout') })
    assert.equal((await handleAppStoreNotification(post({ signedPayload: notification(failing.signer) }), failing.services)).status, 500)
    assert.equal(failing.recorded.length, 0, 'not recorded, so the retry is applied')
    const unrecorded = setUp({ failRecord: new Error('timeout') })
    assert.equal((await handleAppStoreNotification(post({ signedPayload: notification(unrecorded.signer) }), unrecorded.services)).status, 500)
  })

  it('needs a POST with a signedPayload, and the secrets', async () => {
    const { signer, services } = setUp()
    assert.equal((await handleAppStoreNotification(post({}, 'GET'), services)).status, 405)
    for (const bad of [{}, { signedPayload: 42 }, { signedPayload: 'x'.repeat(70_000) }]) {
      assert.equal((await handleAppStoreNotification(post(bad), services)).status, 400)
    }
    const incomplete = signer.sign({ notificationType: 'DID_RENEW', signedDate: NOW })
    assert.equal((await handleAppStoreNotification(post({ signedPayload: incomplete }), services)).status, 400, 'no notificationUUID')
    services.config = null
    assert.deepEqual(await answer(await handleAppStoreNotification(post({ signedPayload: notification(signer) }), services)), [500, { error: 'not_configured' }])
  })
})
