// HuddlePals Plus on the server: user_entitlements, written only through
// apply_entitlement (service role: the verify-subscription and
// app-store-notifications edge functions, once Apple's signature checks out)
// and read by the app only through my_entitlement(). One Apple subscription
// entitles one HuddlePals account, and Plus is judged by the server's clock.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  freshDatabase, q, admin, service, signUp, createHuddle, grantPlus, randomUUID,
} from './harness.mjs'

const DENIED = /permission denied/
const MONTHLY = 'com.huddlepals.ios.plus.monthly'
const DAY = 86_400_000
const iso = (offsetMs = 0) => new Date(Date.now() + offsetMs).toISOString()

/** apply_entitlement as the edge functions call it; resolves to its outcome. */
async function apply(db, user, {
  otid = '1000', tx = otid, env = 'Production', expires = iso(30 * DAY), revoked = null, signed = iso(),
  token = null, grace = null, autoRenew = null, renewalSigned = null,
} = {}) {
  const [{ status }] = await service(
    db,
    'select apply_entitlement($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) as status',
    [user, otid, tx, MONTHLY, env, iso(-DAY), expires, revoked, signed, token, grace, autoRenew, renewalSigned],
  )
  return status
}

const premium = async (db, uid) => (await admin(db, 'select is_user_premium($1) p', [uid]))[0].p
const owner = async (db, otid) =>
  (await admin(db, 'select user_id from user_entitlements where original_transaction_id = $1', [otid]))[0]?.user_id ?? null

describe('who can touch subscriptions', () => {
  it('the app can neither read nor write user_entitlements or the notification log', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await grantPlus(db, A)
    for (const table of ['user_entitlements', 'app_store_notifications']) {
      for (const uid of [A, null]) {
        await assert.rejects(q(db, uid, `select * from ${table}`), DENIED, `${table} read`)
        await assert.rejects(q(db, uid, `delete from ${table}`), DENIED, `${table} delete`)
      }
    }
    await assert.rejects(
      q(db, A, `insert into user_entitlements (original_transaction_id, user_id, product_id, transaction_id, environment, expires_at, transaction_signed_at)
                values ('1', $1, 'p', '1', 'Production', now() + interval '1 year', now())`, [A]),
      DENIED,
    )
    await assert.rejects(q(db, A, `update user_entitlements set expires_at = now() + interval '1 year'`), DENIED)
  })

  it("nobody can ask about someone else's plan, or write one through a function", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    await grantPlus(db, B)
    for (const uid of [A, null]) {
      await assert.rejects(q(db, uid, 'select is_user_premium($1)', [B]), DENIED)
      await assert.rejects(
        q(db, uid, 'select apply_entitlement($1, $2, $2, $3, $4, now(), now() + interval \'1 year\', null, now(), null)', [A, '9', MONTHLY, 'Production']),
        DENIED,
      )
      await assert.rejects(q(db, uid, 'select record_app_store_notification($1, $2, null, null, now())', [randomUUID(), 'TEST']), DENIED)
    }
    assert.deepEqual(await q(db, A, 'select caller_is_premium() p'), [{ p: false }])
    assert.deepEqual(await q(db, B, 'select caller_is_premium() p'), [{ p: true }])
  })
})

describe('is_user_premium', () => {
  it('Plus lasts until expiry, through a billing grace period, and ends at once on a refund', async () => {
    const db = await freshDatabase()
    const cases = [
      [{}, true],
      [{ expiresIn: '-1 minute' }, false],
      [{ expiresIn: '-1 day', graceIn: '2 days' }, true],
      [{ expiresIn: '-3 days', graceIn: '-1 day' }, false],
      [{ revoked: true }, false],
      [{ expiresIn: '30 days', graceIn: '-20 days' }, true],
    ]
    for (const [plus, expected] of cases) {
      const uid = await signUp(db, 'U')
      await grantPlus(db, uid, plus)
      assert.equal(await premium(db, uid), expected, JSON.stringify(plus))
    }
  })

  it('any one active subscription is enough, and sandbox ones count (App Review buys there)', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await grantPlus(db, A, { expiresIn: '-1 day' })
    assert.equal(await premium(db, A), false)
    assert.equal(await apply(db, A, { otid: '2000', env: 'Sandbox' }), 'applied')
    assert.equal(await premium(db, A), true)
  })

  it('accepts only Production and Sandbox, never a local StoreKit test', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await assert.rejects(apply(db, A, { env: 'Xcode' }), /check constraint/)
  })
})

describe('one subscription, one account', () => {
  it('goes to the first account to present it, with or without its appAccountToken', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    assert.equal(await apply(db, A, { otid: '1', token: A }), 'applied')
    assert.equal(await apply(db, B, { otid: '2' }), 'applied', 'resubscribed in Settings: no token')
    assert.equal(await owner(db, '1'), A)
    assert.equal(await owner(db, '2'), B)
  })

  it("stays with that account: another account restoring it gets in_use, and nothing changes", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    await apply(db, A, { token: A })
    assert.equal(await apply(db, B, { token: A, expires: iso(365 * DAY), signed: iso(1000) }), 'in_use')
    assert.equal(await apply(db, B, { signed: iso(2000) }), 'in_use')
    assert.equal(await owner(db, '1000'), A)
    assert.equal(await premium(db, B), false)
  })

  it('bought by another account that still exists: theirs, even before they present it', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    assert.equal(await apply(db, B, { token: A }), 'in_use')
    assert.equal(await owner(db, '1000'), null)
  })

  it('once its account is deleted, the next account to present it may have it', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await apply(db, A, { token: A })
    await admin(db, 'delete from auth.users where id = $1', [A])
    assert.deepEqual(await admin(db, 'select * from user_entitlements'), [], 'goes with the account')
    const A2 = await signUp(db, 'Ada again')
    assert.equal(await apply(db, A2, { token: A }), 'applied')
    assert.equal(await owner(db, '1000'), A2)
    assert.equal(await premium(db, A2), true)
  })

  it("a notification updates the holder's row, binds by appAccountToken, and otherwise waits for the app", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    assert.equal(await apply(db, null, { otid: '1' }), 'unbound', 'no token, nobody holds it yet')
    assert.equal(await apply(db, null, { otid: '2', token: randomUUID() }), 'unbound', 'token of no account')
    assert.equal(await apply(db, null, { otid: '3', token: A }), 'applied')
    assert.equal(await owner(db, '3'), A)
    await apply(db, B, { otid: '4' })
    assert.equal(await apply(db, null, { otid: '4', expires: iso(-DAY), signed: iso(1000) }), 'applied')
    assert.equal(await premium(db, B), false)
  })
})

describe('applying what Apple says, in the order Apple signed it', () => {
  it('a renewal extends Plus; anything Apple signed earlier changes nothing', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const first = { tx: '1000', expires: iso(DAY), signed: iso(-60_000) }
    await apply(db, A, first)
    assert.equal(await apply(db, null, { tx: '1001', expires: iso(31 * DAY), signed: iso() }), 'applied')
    assert.equal(await apply(db, A, first), 'stale', 'the app sent its cached first transaction')
    const [row] = await admin(db, 'select transaction_id, expires_at > now() + interval \'30 days\' as renewed from user_entitlements')
    assert.deepEqual(row, { transaction_id: '1001', renewed: true })
  })

  it('a refund ends Plus; a reversed refund brings it back', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await apply(db, A, { signed: iso(-2000) })
    await apply(db, null, { revoked: iso(-1000), signed: iso(-1000) })
    assert.equal(await premium(db, A), false)
    await apply(db, null, { signed: iso() })
    assert.equal(await premium(db, A), true)
  })

  it('renewal info (grace period, auto-renew) has its own order', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const transaction = { expires: iso(-DAY), signed: iso(-5000) }
    await apply(db, A, transaction)
    assert.equal(await premium(db, A), false)
    // Billing failed; Apple grants a grace period.
    assert.equal(await apply(db, null, { ...transaction, grace: iso(5 * DAY), autoRenew: true, renewalSigned: iso(-3000) }), 'applied')
    assert.equal(await premium(db, A), true)
    // An older renewal info arriving late changes nothing.
    assert.equal(await apply(db, null, { ...transaction, grace: null, autoRenew: false, renewalSigned: iso(-4000) }), 'stale')
    const [row] = await admin(db, 'select will_auto_renew, grace_period_expires_at is not null as grace from user_entitlements')
    assert.deepEqual(row, { will_auto_renew: true, grace: true })
  })
})

describe('my_entitlement', () => {
  it("is the caller's own plan, by the server's clock", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await createHuddle(db, A)
    await createHuddle(db, A)
    let [mine] = await q(db, A, 'select * from my_entitlement()')
    assert.equal(mine.is_premium, false)
    assert.equal(mine.premium_until, null)
    assert.ok(Math.abs(mine.server_now - Date.now()) < 60_000)
    assert.equal(mine.kept_huddles, 2)
    assert.equal(mine.huddle_limit, 3)
    assert.equal('free_limits_start' in mine, false, 'no limits switch')

    await grantPlus(db, A, { expiresIn: '-1 day', graceIn: '3 days' })
    ;[mine] = await q(db, A, 'select * from my_entitlement()')
    assert.equal(mine.is_premium, true)
    assert.ok(mine.premium_until > mine.server_now, 'until the grace period ends')
    assert.equal(mine.huddle_limit, 10)
  })

  it('answers nobody who is signed out', async () => {
    const db = await freshDatabase()
    assert.deepEqual(await q(db, null, 'select * from my_entitlement()'), [])
  })
})

describe('the notification log', () => {
  it('records each notification once and forgets those older than 90 days', async () => {
    const db = await freshDatabase()
    const record = async (uuid) => (await service(db, 'select record_app_store_notification($1, $2, null, $3, now()) ok', [uuid, 'DID_RENEW', '1000']))[0].ok
    const old = randomUUID()
    assert.equal(await record(old), true)
    assert.equal(await record(old), false, 'a retry')
    await admin(db, `update app_store_notifications set received_at = now() - interval '91 days'`)
    await record(randomUUID())
    assert.deepEqual(await admin(db, 'select 1 from app_store_notifications where notification_uuid = $1', [old]), [])
  })
})
