// The free plan and HuddlePals+: how many huddles an account keeps and
// how many members a huddle takes (create_huddle, join_huddle,
// redeem_huddle_invite, huddle_join_rule). The keeper's plan decides: on the
// free plan 3 huddles of up to 4, and only the 3 they've kept longest take
// new members; with Plus 10 of up to 10. Nobody is ever removed: when a
// subscription ends, only new joins and new huddles are held back.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { randomBytes } from 'node:crypto'
import {
  freshDatabase, q, admin, serverToday, signUp, createHuddle, joinHuddle, deposit,
  grantPlus, endPlus, WRAPPED_KEY, PUBLIC_KEY,
} from './harness.mjs'

/** The message a refused call raised, or null if it went through. */
const refusal = (promise) => promise.then(() => null, (e) => e.message)

/** New accounts, each joining `huddle` (when given). */
async function members(db, count, huddle = null, prefix = 'M') {
  const ids = []
  for (let i = 0; i < count; i++) {
    const uid = await signUp(db, `${prefix}${i}-${randomBytes(3).toString('hex')}`)
    if (huddle) await joinHuddle(db, uid, huddle.invite_code)
    ids.push(uid)
  }
  return ids
}

const memberCount = async (db, h) =>
  Number((await admin(db, 'select count(*) n from memberships where huddle_id = $1', [h.id]))[0].n)

/** Someone new tries to join `h`; resolves to the refusal, or null once they're in. */
const tryJoin = async (db, h) => refusal(joinHuddle(db, await signUp(db, `J-${randomBytes(3).toString('hex')}`), h.invite_code))

/**
 * `count` huddles kept by `uid`, oldest first. PGlite's clock ticks in
 * milliseconds, so creates a moment apart could tie on keeper_since (the
 * huddle id then decides); real Postgres keeps microseconds.
 */
async function keep(db, uid, count) {
  const huddles = []
  for (let i = 0; i < count; i++) {
    if (i > 0) await new Promise((resolve) => setTimeout(resolve, 3))
    huddles.push(await createHuddle(db, uid, `H${i}`))
  }
  return huddles
}

/** What app builds from before Plus show for a join refusal (LiveHuddleService.joinHuddle). */
function oldBuildCopy(message) {
  if (message.includes('invite_code_not_found')) return 'No huddle found for that code.'
  if (message.includes('already_member')) return "You're already a member of this huddle."
  if (message.includes('huddle_full')) return 'This huddle already has 8 members — that\'s the limit.'
  if (message.includes('blocked')) return "You can't join this huddle."
  if (message.includes('too_many_attempts')) return 'Too many codes that didn\'t match.'
  return 'Something went wrong. Please try again.'
}

describe('creating huddles', () => {
  it('free plan: 3 kept, the 4th refused', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await keep(db, A, 3)
    assert.equal(await refusal(createHuddle(db, A)), 'huddle_limit_reached_free')
  })

  it('Plus: 10 kept, the 11th refused', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await grantPlus(db, A)
    await keep(db, A, 10)
    assert.equal(await refusal(createHuddle(db, A)), 'huddle_limit_reached_premium')
  })

  it('huddles inherited from a keeper who left count toward the cap', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const [inherited] = await keep(db, A, 1)
    await joinHuddle(db, B, inherited.invite_code)
    await keep(db, B, 2)
    await q(db, A, 'delete from memberships where user_id = $1', [A])
    assert.equal(await refusal(createHuddle(db, B)), 'huddle_limit_reached_free')
  })

  it('leaving a huddle makes room; only huddles you keep count', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const huddles = await keep(db, A, 3)
    const [other] = await keep(db, B, 1)
    await joinHuddle(db, A, other.invite_code)
    await joinHuddle(db, B, huddles[0].invite_code)
    assert.equal(await refusal(createHuddle(db, A)), 'huddle_limit_reached_free')
    await q(db, A, 'delete from memberships where user_id = $1 and huddle_id = $2', [A, huddles[0].id])
    assert.equal(await refusal(createHuddle(db, A)), null)
  })

  it('when Plus ends, every huddle stays; creating stops until fewer than 3 are kept', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const otid = await grantPlus(db, A)
    const huddles = await keep(db, A, 5)
    await endPlus(db, otid)
    assert.equal((await q(db, A, 'select id from huddles')).length, 5)
    assert.equal(await refusal(createHuddle(db, A)), 'huddle_limit_reached_free')
    for (const h of huddles.slice(0, 3)) {
      await members(db, 1, h)
      await q(db, A, 'delete from memberships where user_id = $1 and huddle_id = $2', [A, h.id])
    }
    assert.equal(await refusal(createHuddle(db, A)), null)
  })
})

describe('joining a huddle whose keeper is on the free plan', () => {
  it('takes 4 members, the keeper included, then refuses join_blocked_free_limit', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const [h] = await keep(db, A, 1)
    await members(db, 3, h)
    assert.equal(await memberCount(db, h), 4)
    assert.equal(await tryJoin(db, h), 'join_blocked_free_limit')
  })

  it("only the keeper's 3 longest-kept huddles take new members; the rest are paused, even nearly empty", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const otid = await grantPlus(db, A)
    const huddles = await keep(db, A, 10)
    await endPlus(db, otid)
    for (const h of huddles.slice(0, 3)) assert.equal(await tryJoin(db, h), null, 'first 3 take members')
    for (const h of huddles.slice(3)) assert.equal(await tryJoin(db, h), 'join_blocked_invites_paused')
  })

  it("an inherited huddle joins the back of the queue and never pauses the heir's own", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const [older] = await keep(db, A, 1) // created before any of Ben's
    await joinHuddle(db, B, older.invite_code)
    const own = await keep(db, B, 3)
    await q(db, A, 'delete from memberships where user_id = $1', [A])
    assert.deepEqual(await admin(db, `select user_id from memberships where huddle_id = $1 and role = 'keeper'`, [older.id]), [{ user_id: B }])
    for (const h of own) assert.equal(await tryJoin(db, h), null, "Ben's own huddles still take members")
    assert.equal(await tryJoin(db, older), 'join_blocked_invites_paused')
  })

  it('leaving an earlier huddle moves a paused one into the first 3', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const otid = await grantPlus(db, A)
    const huddles = await keep(db, A, 4)
    await endPlus(db, otid)
    assert.equal(await tryJoin(db, huddles[3]), 'join_blocked_invites_paused')
    await members(db, 1, huddles[0])
    await q(db, A, 'delete from memberships where user_id = $1 and huddle_id = $2', [A, huddles[0].id])
    assert.equal(await tryJoin(db, huddles[3]), null)
  })
})

describe('joining a huddle whose keeper has Plus', () => {
  it('takes 10 in every huddle they keep, then refuses join_blocked_max_members', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await grantPlus(db, A)
    const huddles = await keep(db, A, 5)
    await members(db, 9, huddles[4])
    assert.equal(await memberCount(db, huddles[4]), 10)
    assert.equal(await tryJoin(db, huddles[4]), 'join_blocked_max_members')
    assert.equal(await tryJoin(db, huddles[3]), null, 'no first-3 rule with Plus')
  })

  it("a member's Plus doesn't lift the huddle: the keeper's plan decides", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const [h] = await keep(db, A, 1)
    const [B] = await members(db, 3, h)
    await grantPlus(db, B)
    assert.equal(await tryJoin(db, h), 'join_blocked_free_limit')
  })

  it('a billing grace period still counts; running out and refunds do not', async () => {
    const db = await freshDatabase()
    const cases = [
      [{ expiresIn: '-1 day', graceIn: '3 days' }, null],
      [{ expiresIn: '-1 day' }, 'join_blocked_free_limit'],
      [{ expiresIn: '-10 days', graceIn: '-1 day' }, 'join_blocked_free_limit'],
      [{ expiresIn: '30 days', revoked: true }, 'join_blocked_free_limit'],
      // A grace date left from an earlier period never cuts a renewal short.
      [{ expiresIn: '30 days', graceIn: '-20 days' }, null],
    ]
    for (const [plus, expected] of cases) {
      const K = await signUp(db, `K-${randomBytes(3).toString('hex')}`)
      await grantPlus(db, K, plus)
      const [h] = await keep(db, K, 1)
      await members(db, 3, h)
      assert.equal(await tryJoin(db, h), expected, JSON.stringify(plus))
    }
  })

  it('when Plus ends nobody is removed; joins wait until it comes back', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const otid = await grantPlus(db, A)
    const [h] = await keep(db, A, 1)
    const joined = await members(db, 6, h)
    await endPlus(db, otid)
    assert.equal(await memberCount(db, h), 7)
    assert.equal(await tryJoin(db, h), 'join_blocked_free_limit')
    const today = await serverToday(db)
    for (const uid of [A, ...joined]) await deposit(db, uid, h.id, today)
    await grantPlus(db, A)
    assert.equal(await tryJoin(db, h), null)
  })
})

describe('huddles over the free limits, and keepers who leave', () => {
  it('a huddle that grew to 6 with Plus keeps everyone posting, reacting and commenting when it ends; only joins stop', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const otid = await grantPlus(db, A)
    const [h] = await keep(db, A, 1)
    const joined = await members(db, 5, h)
    await endPlus(db, otid)
    assert.equal(await tryJoin(db, h), 'join_blocked_free_limit')
    const today = await serverToday(db)
    const dep = await deposit(db, joined[0], h.id, today)
    await q(db, joined[1], `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [dep.id, joined[1]])
    await q(db, A, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'nice')`, [dep.id, A])
    assert.equal(await memberCount(db, h), 6)
  })

  it('a keeper of 5 huddles made with Plus keeps them all when it ends; the 4th and 5th pause', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const otid = await grantPlus(db, A)
    const huddles = await keep(db, A, 5)
    await endPlus(db, otid)
    assert.equal(await tryJoin(db, huddles[2]), null)
    assert.equal(await tryJoin(db, huddles[3]), 'join_blocked_invites_paused')
    assert.equal((await q(db, A, 'select id from huddles')).length, 5)
  })

  it('a Plus keeper leaving hands a 7-member huddle to a free member: everyone stays, joins stop', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await grantPlus(db, A)
    const [h] = await keep(db, A, 1)
    const joined = await members(db, 6, h)
    await q(db, A, 'delete from memberships where user_id = $1', [A])
    assert.deepEqual(await admin(db, `select user_id from memberships where huddle_id = $1 and role = 'keeper'`, [h.id]), [{ user_id: joined[0] }])
    assert.equal(await memberCount(db, h), 6)
    assert.equal(await tryJoin(db, h), 'join_blocked_free_limit')
  })

  it("a keeper deleting their account: the heir's plan decides from then on", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const [h] = await keep(db, A, 1)
    const [heir] = await members(db, 3, h)
    await admin(db, 'delete from auth.users where id = $1', [A])
    assert.equal(await memberCount(db, h), 3)
    assert.equal(await tryJoin(db, h), null, 'room again after the keeper left')
    assert.equal(await tryJoin(db, h), 'join_blocked_free_limit')
    await grantPlus(db, heir)
    assert.equal(await tryJoin(db, h), null)
  })

  it('a new keeper is keeper from the moment they take over', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const [h] = await keep(db, A, 1)
    const [B, C] = await members(db, 2, h)
    const [{ joined_at: joinedAt }] = await admin(db, 'select joined_at from memberships where user_id = $1', [B])
    await q(db, A, 'delete from memberships where user_id = $1', [A])
    const [{ keeper_since: since }] = await admin(db, 'select keeper_since from memberships where user_id = $1', [B])
    assert.ok(since > joinedAt)
    assert.deepEqual(await admin(db, 'select keeper_since from memberships where user_id = $1', [C]), [{ keeper_since: null }])
  })
})

describe('the 25-huddle limit', () => {
  it('nobody joins more than 25 huddles, counting those they keep', async () => {
    const db = await freshDatabase()
    const B = await signUp(db, 'Ben')
    await keep(db, B, 3)
    const others = []
    for (let i = 0; i < 23; i++) {
      const [owner] = await members(db, 1)
      others.push((await keep(db, owner, 1))[0])
    }
    for (const h of others.slice(0, 22)) await joinHuddle(db, B, h.invite_code)
    assert.equal(await refusal(joinHuddle(db, B, others[22].invite_code)), 'join_blocked_membership_limit')
  })
})

describe('both ways in, and old app builds', () => {
  const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
  /** A new-format invite for `h`, issued by its keeper `uid` (see invites.test.mjs). */
  async function invite(db, uid, h, letter) {
    await q(db, uid, 'insert into user_keys (user_id, public_key) values ($1, $2) on conflict do nothing', [uid, PUBLIC_KEY(letter)])
    await q(db, uid, 'select init_huddle_key($1, $2, $3, $4)', [h.id, WRAPPED_KEY, PUBLIC_KEY('E'), PUBLIC_KEY(letter)])
    const code = {
      lookup: Array.from(randomBytes(6), (b) => ALPHABET[b % ALPHABET.length]).join(''),
      proof: randomBytes(32).toString('base64'),
    }
    await q(db, uid, 'select create_huddle_invite($1, $2, $3, $4, $5, $6)', [
      h.id, code.lookup, code.proof, randomBytes(32).toString('base64'), randomBytes(60).toString('base64'), randomBytes(54).toString('base64'),
    ])
    return code
  }
  const redeem = async (db, code) =>
    refusal(q(db, await signUp(db, `R-${randomBytes(3).toString('hex')}`), 'select * from redeem_huddle_invite($1, $2, null)', [code.lookup, code.proof]))

  it('redeem_huddle_invite applies the same rules as join_huddle', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const otid = await grantPlus(db, A)
    const huddles = await keep(db, A, 4)
    await endPlus(db, otid)
    const first = await invite(db, A, huddles[0], 'A')
    const fourth = await invite(db, A, huddles[3], 'A')
    for (let i = 0; i < 3; i++) assert.equal(await redeem(db, first), null)
    assert.equal(await redeem(db, first), 'join_blocked_free_limit')
    assert.equal(await redeem(db, fourth), 'join_blocked_invites_paused')
  })

  it("a refusal isn't a wrong guess: no attempt is recorded", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const [h] = await keep(db, A, 1)
    await members(db, 3, h)
    const J = await signUp(db, 'Joe')
    for (let i = 0; i < 12; i++) assert.equal(await refusal(joinHuddle(db, J, h.invite_code)), 'join_blocked_free_limit')
    assert.deepEqual(await admin(db, 'select 1 from join_attempts where user_id = $1', [J]), [])
  })

  it('app builds from before Plus read every refusal as "You can\'t join this huddle."', async () => {
    const db = await freshDatabase()
    const free = await signUp(db, 'Free')
    const otid = await grantPlus(db, free)
    const freeHuddles = await keep(db, free, 4)
    await endPlus(db, otid)
    await members(db, 3, freeHuddles[0])
    const plus = await signUp(db, 'Plus')
    await grantPlus(db, plus)
    const [full] = await keep(db, plus, 1)
    await members(db, 9, full)
    const many = await signUp(db, 'Many')
    for (let i = 0; i < 25; i++) {
      const [owner] = await members(db, 1)
      await joinHuddle(db, many, (await keep(db, owner, 1))[0].invite_code)
    }
    const messages = [
      await tryJoin(db, freeHuddles[0]),
      await tryJoin(db, freeHuddles[3]),
      await tryJoin(db, full),
      await refusal(joinHuddle(db, many, freeHuddles[1].invite_code)),
    ]
    assert.deepEqual(messages, [
      'join_blocked_free_limit', 'join_blocked_invites_paused', 'join_blocked_max_members', 'join_blocked_membership_limit',
    ])
    for (const message of messages) assert.equal(oldBuildCopy(message), "You can't join this huddle.", message)
  })
})

describe('huddle_join_status', () => {
  it('tells members whether the huddle takes new members, and why not', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const otid = await grantPlus(db, A)
    const huddles = await keep(db, A, 4)
    const [B] = await members(db, 3, huddles[0])
    await endPlus(db, otid)
    const status = (h, uid = A) => q(db, uid, 'select * from huddle_join_status($1)', [h.id])
    assert.deepEqual(await status(huddles[0], B), [{ accepting: false, refusal: 'join_blocked_free_limit', member_count: 4, member_cap: 4 }])
    assert.deepEqual(await status(huddles[3]), [{ accepting: false, refusal: 'join_blocked_invites_paused', member_count: 1, member_cap: 4 }])
    await grantPlus(db, A)
    assert.deepEqual(await status(huddles[3]), [{ accepting: true, refusal: null, member_count: 1, member_cap: 10 }])
  })

  it('tells outsiders nothing, and nobody calls huddle_join_rule directly', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const D = await signUp(db, 'Dee')
    const [h] = await keep(db, A, 1)
    assert.deepEqual(await q(db, D, 'select * from huddle_join_status($1)', [h.id]), [])
    await assert.rejects(q(db, A, 'select * from huddle_join_rule($1)', [h.id]), /permission denied/)
  })
})

describe('concurrent creates and joins', () => {
  // PGlite runs one connection, so two transactions can't actually race
  // here. What makes them safe is that each RPC takes its row locks before
  // counting anything; this checks that the locks are there.
  it('lock before they count', async () => {
    const db = await freshDatabase()
    const source = async (name) => (await admin(db, 'select prosrc from pg_proc where proname = $1', [name]))[0].prosrc
    const create = await source('create_huddle')
    assert.ok(create.indexOf('from profiles where id = auth.uid() for update') < create.indexOf('select count(*) into v_kept'))
    for (const name of ['join_huddle', 'redeem_huddle_invite']) {
      const body = await source(name)
      const lock = body.indexOf('from huddles where id = ')
      assert.ok(lock > 0 && body.slice(lock).match(/^from huddles where id = \S+ for update/), `${name} locks the huddle`)
      assert.ok(body.indexOf('from profiles where id = auth.uid() for update') > 0, `${name} locks the joiner`)
      assert.ok(lock < body.indexOf('huddle_join_rule('), `${name} locks before counting`)
    }
  })
})
