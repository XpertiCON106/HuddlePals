// Instant join: new-format invite codes, whose secret opens a sealed copy of
// the huddle key. What the server must guarantee: only someone presenting the
// code's proof gets the sealed key (and joins); it stores the lookup and the
// proof's hash, never the secret; nobody reads the sealed copies directly;
// resetting a code revokes it; and the old secret-less codes retire.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createHash, randomBytes } from 'node:crypto'
import {
  freshDatabase, q, admin, signUp, createHuddle, joinHuddle, affected, WRAPPED_KEY, PUBLIC_KEY,
} from './harness.mjs'

const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
const RLS_DENIED = /row-level security|permission denied/

/** What an app sends for a fresh code: everything but the secret itself. */
function newInvite() {
  return {
    lookup: Array.from(randomBytes(6), (b) => ALPHABET[b % ALPHABET.length]).join(''),
    proof: randomBytes(32).toString('base64'),
    salt: randomBytes(32).toString('base64'),
    sealedKey: randomBytes(60).toString('base64'),
    sealedSecret: randomBytes(54).toString('base64'),
  }
}
const args = (h, i) => [h.id, i.lookup, i.proof, i.salt, i.sealedKey, i.sealedSecret]
const sha256Hex = (base64) => createHash('sha256').update(Buffer.from(base64, 'base64')).digest('hex')

const createInvite = (db, uid, h, i) =>
  q(db, uid, 'select create_huddle_invite($1, $2, $3, $4, $5, $6) ok', args(h, i)).then((r) => r[0].ok)
const resetInvite = (db, uid, h, i) => q(db, uid, 'select reset_huddle_invite($1, $2, $3, $4, $5, $6)', args(h, i))
const redeem = (db, uid, lookup, proof) =>
  q(db, uid, 'select * from redeem_huddle_invite($1, $2, null)', [lookup, proof])
const publishKey = (db, uid, c) =>
  q(db, uid, 'insert into user_keys (user_id, public_key) values ($1, $2)', [uid, PUBLIC_KEY(c)])
const saveOwn = (db, uid, h, mine, wrapped = WRAPPED_KEY) =>
  q(db, uid, 'select save_own_huddle_key($1, $2, $3, $4) ok', [h.id, wrapped, PUBLIC_KEY('E'), mine]).then((r) => r[0].ok)

/** Ada creates a huddle and its key, as the app does right after create_huddle. */
async function keyedHuddle() {
  const db = await freshDatabase()
  const A = await signUp(db, 'Ada')
  const h = await createHuddle(db, A, 'Family')
  await publishKey(db, A, 'A')
  await q(db, A, 'select init_huddle_key($1, $2, $3, $4)', [h.id, WRAPPED_KEY, PUBLIC_KEY('E'), PUBLIC_KEY('A')])
  return { db, A, h }
}

/** …and issues a new-format invite. */
async function invitedHuddle() {
  const world = await keyedHuddle()
  const invite = newInvite()
  assert.equal(await createInvite(world.db, world.A, world.h, invite), true)
  return { ...world, invite }
}

describe('issuing an invite', () => {
  it('a new huddle starts on an old-style code', async () => {
    const { db, h } = await keyedHuddle()
    const [row] = await admin(db, 'select invite_code, legacy_invite from huddles where id = $1', [h.id])
    assert.match(row.invite_code, /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$/)
    assert.equal(row.legacy_invite, true)
  })

  it('stores the lookup and the proof’s hash; never the proof, never the secret', async () => {
    const { db, h, invite } = await invitedHuddle()
    const [huddle] = await admin(db, 'select invite_code, legacy_invite from huddles where id = $1', [h.id])
    assert.deepEqual(huddle, { invite_code: invite.lookup, legacy_invite: false })
    const [row] = await admin(db, 'select * from huddle_invite_keys where huddle_id = $1', [h.id])
    assert.equal(row.proof_hash, sha256Hex(invite.proof))
    assert.equal(row.salt, invite.salt)
    assert.equal(row.sealed_key, invite.sealedKey)
    assert.equal(row.sealed_secret, invite.sealedSecret)
    const everything = JSON.stringify(await admin(db, 'select * from huddle_invite_keys')) + JSON.stringify(await admin(db, 'select * from huddles'))
    assert.ok(!everything.includes(invite.proof), 'the proof itself is not stored')
  })

  it('only a member holding a working copy of the key may issue one, and only one', async () => {
    const { db, A, h } = await keyedHuddle()
    const B = await signUp(db, 'Ben')
    await joinHuddle(db, B, (await admin(db, 'select invite_code from huddles where id = $1', [h.id]))[0].invite_code)
    const D = await signUp(db, 'Dee')
    await assert.rejects(createInvite(db, D, h, newInvite()), /not_a_member/)
    await assert.rejects(createInvite(db, B, h, newInvite()), /no_huddle_key/, 'B never received the key')
    assert.equal(await createInvite(db, A, h, newInvite()), true)
    assert.equal(await createInvite(db, A, h, newInvite()), false, 'another member’s app got there first')
    assert.equal((await admin(db, 'select count(*)::int n from huddle_invite_keys'))[0].n, 1)
  })

  it('refuses a malformed invite, and a lookup another huddle already uses', async () => {
    const { db, A, h } = await keyedHuddle()
    await assert.rejects(createInvite(db, A, h, { ...newInvite(), lookup: 'ABC10O' }), /invalid_invite/)
    await assert.rejects(createInvite(db, A, h, { ...newInvite(), lookup: null }), /invalid_invite/)
    await assert.rejects(createInvite(db, A, h, { ...newInvite(), proof: 'not base64' }), /invalid_invite/)
    await assert.rejects(createInvite(db, A, h, { ...newInvite(), sealedKey: 'short' }), /check constraint/)
    const other = await createHuddle(db, A, 'Friends')
    const [{ invite_code: taken }] = await admin(db, 'select invite_code from huddles where id = $1', [other.id])
    await assert.rejects(createInvite(db, A, h, { ...newInvite(), lookup: taken }), /invite_code_taken/)
  })

  it('members read the sealed secret through huddle_invite; nobody reads or writes the table directly', async () => {
    const { db, A, h, invite } = await invitedHuddle()
    const B = await signUp(db, 'Ben')
    const D = await signUp(db, 'Dee')
    await redeem(db, B, invite.lookup, invite.proof)
    for (const uid of [A, B]) {
      assert.deepEqual(await q(db, uid, 'select * from huddle_invite($1)', [h.id]), [
        { lookup: invite.lookup, legacy: false, sealed_secret: invite.sealedSecret },
      ])
    }
    assert.deepEqual(await q(db, D, 'select * from huddle_invite($1)', [h.id]), [], 'outsiders learn nothing')
    for (const uid of [A, B, D, null]) {
      await assert.rejects(q(db, uid, 'select * from huddle_invite_keys'), RLS_DENIED)
      await assert.rejects(q(db, uid, 'delete from huddle_invite_keys'), RLS_DENIED)
      await assert.rejects(q(db, uid, `update huddle_invite_keys set sealed_key = $1`, ['A'.repeat(80)]), RLS_DENIED)
    }
    await assert.rejects(
      q(db, A, 'insert into huddle_invite_keys (huddle_id, proof_hash, salt, sealed_key, sealed_secret) values ($1, $2, $3, $4, $5)',
        [h.id, sha256Hex(invite.proof), invite.salt, invite.sealedKey, invite.sealedSecret]),
      RLS_DENIED,
    )
  })

  it('a huddle still on its old code reports it, so members’ apps upgrade it', async () => {
    const { db, A, h } = await keyedHuddle()
    const [row] = await q(db, A, 'select * from huddle_invite($1)', [h.id])
    assert.equal(row.legacy, true)
    assert.equal(row.sealed_secret, null)
  })
})

describe('redeeming an invite', () => {
  it('joins and hands over the sealed key, with no other member involved', async () => {
    const { db, h, invite } = await invitedHuddle()
    const B = await signUp(db, 'Ben')
    const rows = await redeem(db, B, ` ${invite.lookup.toLowerCase()} `, invite.proof)
    assert.deepEqual(rows, [{ joined_huddle_id: h.id, invite_salt: invite.salt, invite_sealed_key: invite.sealedKey }])
    assert.equal((await q(db, B, 'select * from memberships where user_id = $1', [B])).length, 1)
    // B's app opens the key and stores its own copy: access no longer depends on the invite.
    await publishKey(db, B, 'B')
    assert.equal(await saveOwn(db, B, h, PUBLIC_KEY('B')), true)
    assert.equal((await q(db, B, 'select * from huddle_keys')).length, 1)
    assert.deepEqual(await q(db, B, 'select user_id from huddle_key_recipients($1)', [h.id]), [], 'B waits on nobody')
  })

  it('a wrong secret joins nothing and counts as a miss', async () => {
    const { db, invite } = await invitedHuddle()
    const B = await signUp(db, 'Ben')
    assert.deepEqual(await redeem(db, B, invite.lookup, newInvite().proof), [])
    assert.deepEqual(await redeem(db, B, newInvite().lookup, invite.proof), [], 'the proof only counts with its own lookup')
    assert.deepEqual(await redeem(db, B, invite.lookup, 'garbage'), [])
    assert.deepEqual(await q(db, B, 'select * from memberships'), [])
    assert.equal((await admin(db, 'select count(*)::int n from join_attempts where user_id = $1', [B]))[0].n, 3)
  })

  it('shares the guess limit with old codes: 10 misses an hour, then even the right code is refused', async () => {
    const { db, invite } = await invitedHuddle()
    const M = await signUp(db, 'Mallory')
    for (let i = 0; i < 6; i++) await redeem(db, M, invite.lookup, newInvite().proof)
    for (let i = 0; i < 4; i++) await q(db, M, 'select * from join_huddle($1, null)', [`WRONG${i}`])
    await assert.rejects(redeem(db, M, invite.lookup, invite.proof), /too_many_attempts/)
    assert.deepEqual(await admin(db, 'select 1 from memberships where user_id = $1', [M]), [])
  })

  it('refuses existing members, a full huddle, and someone a member has blocked — without counting a miss', async () => {
    const { db, A, h, invite } = await invitedHuddle()
    await assert.rejects(redeem(db, A, invite.lookup, invite.proof), /already_member/)

    const D = await signUp(db, 'Dee')
    await q(db, A, 'insert into blocks (blocker_id, blocked_id) values ($1, $2)', [A, D])
    await assert.rejects(redeem(db, D, invite.lookup, invite.proof), /blocked/)
    assert.deepEqual(await admin(db, 'select 1 from memberships where user_id = $1', [D]), [])

    for (let i = 0; i < 7; i++) await redeem(db, await signUp(db, `m${i}`), invite.lookup, invite.proof)
    const ninth = await signUp(db, 'ninth')
    await assert.rejects(redeem(db, ninth, invite.lookup, invite.proof), /huddle_full/)
    assert.equal((await admin(db, 'select count(*)::int n from join_attempts'))[0].n, 0)
  })

  it('requires a signed-in caller', async () => {
    const { db, invite } = await invitedHuddle()
    await assert.rejects(redeem(db, null, invite.lookup, invite.proof), /not authenticated/)
  })
})

describe('old codes', () => {
  it('keep working for old app builds until the huddle gets a new-format invite, then never again', async () => {
    const { db, A, h } = await keyedHuddle()
    const [{ invite_code: oldCode }] = await admin(db, 'select invite_code from huddles where id = $1', [h.id])
    const B = await signUp(db, 'Ben')
    assert.equal((await joinHuddle(db, B, oldCode)).id, h.id, 'old builds still join before the upgrade')

    const invite = newInvite()
    await createInvite(db, A, h, invite)
    const C = await signUp(db, 'Cy')
    assert.equal(await joinHuddle(db, C, oldCode), undefined, 'the old code is retired')
    assert.equal(await joinHuddle(db, C, invite.lookup), undefined, 'the lookup alone is no code')
    assert.deepEqual(await admin(db, 'select 1 from memberships where user_id = $1', [C]), [])
  })
})

describe('resetting an invite', () => {
  it('is for the keeper only', async () => {
    const { db, h, invite } = await invitedHuddle()
    const B = await signUp(db, 'Ben')
    await redeem(db, B, invite.lookup, invite.proof)
    await publishKey(db, B, 'B')
    await saveOwn(db, B, h, PUBLIC_KEY('B'))
    await assert.rejects(resetInvite(db, B, h, newInvite()), /not_keeper/)
  })

  it('revokes the old code and deletes its sealed copy; the new code works', async () => {
    const { db, A, h, invite } = await invitedHuddle()
    const fresh = newInvite()
    await resetInvite(db, A, h, fresh)
    const rows = await admin(db, 'select proof_hash, sealed_key from huddle_invite_keys where huddle_id = $1', [h.id])
    assert.deepEqual(rows, [{ proof_hash: sha256Hex(fresh.proof), sealed_key: fresh.sealedKey }], 'only the new sealed copy is left')

    const B = await signUp(db, 'Ben')
    assert.deepEqual(await redeem(db, B, invite.lookup, invite.proof), [], 'the revoked code fails')
    assert.equal((await redeem(db, B, fresh.lookup, fresh.proof))[0].joined_huddle_id, h.id)
  })
})

describe('own copies after joining', () => {
  it('members only, for their current public key, and never over a working copy', async () => {
    const { db, A, h, invite } = await invitedHuddle()
    const B = await signUp(db, 'Ben')
    const D = await signUp(db, 'Dee')
    await publishKey(db, B, 'B')
    await publishKey(db, D, 'D')
    await assert.rejects(saveOwn(db, D, h, PUBLIC_KEY('D')), /not_a_member/)
    await redeem(db, B, invite.lookup, invite.proof)
    await assert.rejects(saveOwn(db, B, h, PUBLIC_KEY('Q')), /stale_public_key/)
    assert.equal(await saveOwn(db, B, h, PUBLIC_KEY('B')), true)
    assert.equal(await saveOwn(db, B, h, PUBLIC_KEY('B'), 'B'.repeat(80)), false)
    assert.equal((await q(db, B, 'select wrapped_key from huddle_keys'))[0].wrapped_key, WRAPPED_KEY)
    assert.equal(await saveOwn(db, A, h, PUBLIC_KEY('A'), 'B'.repeat(80)), false, 'the creator’s copy stays too')
  })
})

describe('key rotation', () => {
  it('a new huddle key drops the invite sealing the old one; a fresh invite then carries the new key', async () => {
    const { db, A, h, invite } = await invitedHuddle()
    // Cy joined with the invite but his own copy never reached the server;
    // then Ada, the only member holding the key, left.
    const C = await signUp(db, 'Cy')
    await redeem(db, C, invite.lookup, invite.proof)
    await publishKey(db, C, 'C')
    await affected(db, A, 'delete from memberships where user_id = $1', [A])

    // Nobody left holds the key, so Cy's app makes a new one…
    const [{ ok }] = await q(db, C, 'select init_huddle_key($1, $2, $3, $4) ok', [h.id, 'N'.repeat(80), PUBLIC_KEY('E'), PUBLIC_KEY('C')])
    assert.equal(ok, true)
    // …and the invite that sealed the old key is gone with it.
    assert.deepEqual(await admin(db, 'select 1 from huddle_invite_keys'), [])
    assert.deepEqual(await q(db, C, 'select legacy, sealed_secret from huddle_invite($1)', [h.id]), [{ legacy: false, sealed_secret: null }])
    const B = await signUp(db, 'Ben')
    assert.deepEqual(await redeem(db, B, invite.lookup, invite.proof), [], 'the old code no longer hands out a key')

    // Cy's app issues a fresh invite, sealed with the new key.
    const fresh = newInvite()
    assert.equal(await createInvite(db, C, h, fresh), true)
    assert.equal((await redeem(db, B, fresh.lookup, fresh.proof))[0].invite_sealed_key, fresh.sealedKey)
  })

  it('while any member still holds the key, it isn’t replaced and the invite stays', async () => {
    const { db, A, h, invite } = await invitedHuddle()
    const B = await signUp(db, 'Ben')
    await redeem(db, B, invite.lookup, invite.proof)
    await publishKey(db, B, 'B')
    const [{ ok }] = await q(db, B, 'select init_huddle_key($1, $2, $3, $4) ok', [h.id, 'N'.repeat(80), PUBLIC_KEY('E'), PUBLIC_KEY('B')])
    assert.equal(ok, false)
    assert.equal((await admin(db, 'select count(*)::int n from huddle_invite_keys where huddle_id = $1', [h.id]))[0].n, 1)
    assert.ok(A)
  })
})
