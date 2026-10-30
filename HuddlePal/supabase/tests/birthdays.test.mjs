// Birthdays activate core app access, remain owner-private, and cannot be
// changed after activation. Both schema installation paths run these cases.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  freshDatabase, q, admin, affected, as, authUser, signUp, createHuddle,
  joinHuddle, deposit, serverToday, storeObject, WRAPPED_KEY, PUBLIC_KEY,
} from './harness.mjs'

const SAVE = 'select save_birthday($1::date)'
const ACTIVATE = "select * from complete_profile($1, 'E5484D', $2::date)"
const DENIED = /row-level security|permission denied/

async function yearsAgo(db, years, days = 0) {
  const [{ d }] = await admin(db,
    `select to_char((now() at time zone 'UTC')::date - make_interval(years => $1, days => $2), 'YYYY-MM-DD') as d`,
    [years, days])
  return d
}

async function legacyAccount(db, name) {
  const id = await authUser(db, name)
  await admin(db, 'insert into profiles (id, display_name) values ($1, $2)', [id, name])
  return id
}

describe('birthday activation', () => {
  it('creates the profile and birthday atomically and safely retries the same activation', async () => {
    const db = await freshDatabase()
    const A = await authUser(db, 'Ada')
    const first = await q(db, A, ACTIVATE, ['Ada', '1995-06-14'])
    assert.equal(first[0].id, A)
    assert.equal(first[0].display_name, 'Ada')
    assert.equal((await q(db, A, ACTIVATE, ['Another name', '1995-06-14']))[0].display_name, 'Ada')
    assert.deepEqual(await q(db, A, 'select caller_is_age_eligible() as eligible'), [{ eligible: true }])
    assert.equal((await admin(db, 'select * from profiles')).length, 1)
    assert.equal((await admin(db, 'select * from profile_birthdates')).length, 1)
  })

  it('refuses underage, missing or invalid birthdays without retaining a partial profile', async () => {
    const db = await freshDatabase()
    const A = await authUser(db, 'Ada')
    await assert.rejects(q(db, A, ACTIVATE, ['Ada', await yearsAgo(db, 12)]), /under_minimum_age/)
    await assert.rejects(q(db, A, ACTIVATE, ['Ada', await yearsAgo(db, 13, -1)]), /under_minimum_age/, 'no one-day grace')
    await assert.rejects(q(db, A, ACTIVATE, ['Ada', null]), /invalid_birthday/)
    await assert.rejects(q(db, A, ACTIVATE, ['Ada', '1899-12-31']), /invalid_birthday/)
    assert.deepEqual(await admin(db, 'select * from profiles'), [])
    assert.deepEqual(await admin(db, 'select * from profile_birthdates'), [])
  })

  it('accepts the thirteenth birthday by UTC date, even if the database session timezone differs', async () => {
    const db = await freshDatabase()
    const A = await authUser(db, 'Ada')
    const tomorrow = await yearsAgo(db, 13, -1)
    await assert.rejects(as(db, A, async tx => {
      await tx.exec("set local time zone 'Pacific/Kiritimati'")
      return tx.query(ACTIVATE, ['Ada', tomorrow])
    }), /under_minimum_age/)
    await q(db, A, ACTIVATE, ['Ada', await yearsAgo(db, 13)])
    assert.equal((await q(db, A, 'select caller_is_age_eligible() as eligible'))[0].eligible, true)
  })

  it('denies direct profile, birthday, avatar and identity-key writes before activation', async () => {
    const db = await freshDatabase()
    const A = await authUser(db, 'Ada')
    await assert.rejects(q(db, A, "insert into profiles (id, display_name) values ($1, 'Ada')", [A]), DENIED)
    await assert.rejects(q(db, A, "insert into profile_birthdates (user_id, birth_date) values ($1, '1995-06-14')", [A]), DENIED)
    await assert.rejects(q(db, A, 'insert into user_keys (user_id, public_key) values ($1, $2)', [A, PUBLIC_KEY()]), DENIED)
    await assert.rejects(q(db, A, "insert into storage.objects (bucket_id, name) values ('deposits', $1)", [`avatars/${A}/a.jpg`]), DENIED)
    await assert.rejects(q(db, A, SAVE, ['1995-06-14']), /profile_required/)
    await assert.rejects(q(db, null, ACTIVATE, ['Anon', '1995-06-14']), /permission denied|not authenticated/)
    await assert.rejects(q(db, null, SAVE, ['1995-06-14']), /permission denied|not authenticated/)
  })

  it('lets a legacy account read only its own profile and supply an eligible birthday', async () => {
    const db = await freshDatabase()
    const A = await legacyAccount(db, 'Ada')
    const B = await signUp(db, 'Ben')
    assert.deepEqual(await q(db, A, 'select id from profiles'), [{ id: A }])
    assert.deepEqual(await q(db, A, 'select * from profile_birthdates'), [])
    assert.equal(await affected(db, A, "update profiles set display_name = 'Edited' where id = $1", [A]), 0)
    await assert.rejects(createHuddle(db, A), /age_confirmation_required/)
    await assert.rejects(q(db, A, SAVE, [await yearsAgo(db, 12)]), /under_minimum_age/)
    await q(db, A, SAVE, ['1995-06-14'])
    await q(db, A, SAVE, ['1995-06-14'])
    await createHuddle(db, A)
    assert.equal(await affected(db, A, "update profiles set bio = 'hi' where id = $1", [A]), 1)
    assert.deepEqual(await q(db, B, 'select * from profile_birthdates where user_id = $1', [A]), [], 'only the owner sees the birthday')
  })

  it('birthdays are immutable, including through direct table access and activation retries', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    await assert.rejects(q(db, A, SAVE, ['1994-02-01']), /birthday_immutable/)
    await assert.rejects(q(db, A, ACTIVATE, ['Ada', '1994-02-01']), /birthday_immutable/)
    await assert.rejects(q(db, A, "update profile_birthdates set birth_date = '1994-02-01'"), DENIED)
    await assert.rejects(q(db, A, 'delete from profile_birthdates'), DENIED)
    await assert.rejects(q(db, B, "insert into profile_birthdates (user_id, birth_date) values ($1, '1990-01-01')", [A]), DENIED)
    assert.deepEqual(await q(db, A, "select to_char(birth_date, 'YYYY-MM-DD') as d from profile_birthdates"), [{ d: '1995-06-14' }])
    assert.deepEqual(await q(db, B, 'select * from profile_birthdates where user_id = $1', [A]), [])
    assert.deepEqual(await q(db, null, 'select * from profile_birthdates').catch(() => []), [])
  })

  it('missing age approval blocks existing shared rows, every client RPC and Storage access', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    const today = await serverToday(db)
    const dep = await deposit(db, A, h.id, today)
    for (const [u, c] of [[A, 'A'], [B, 'B']]) {
      await q(db, u, 'insert into user_keys (user_id, public_key) values ($1, $2)', [u, PUBLIC_KEY(c)])
    }
    await q(db, A, 'select init_huddle_key($1, $2, $3, $4)', [h.id, WRAPPED_KEY, PUBLIC_KEY('E'), PUBLIC_KEY('A')])
    await q(db, A, 'select share_huddle_key($1, $2, $3, $4, $5)', [h.id, B, WRAPPED_KEY, PUBLIC_KEY('F'), PUBLIC_KEY('B')])
    await q(db, B, "insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '❤️')", [dep.id, B])
    await q(db, B, "insert into comments (deposit_id, user_id, body) values ($1, $2, 'hi')", [dep.id, B])
    await q(db, B, 'select spend_skip_token($1, $2, $3)', [h.id, B, today])
    await q(db, B, 'insert into reports (reporter_id, deposit_id) values ($1, $2)', [B, dep.id])
    await q(db, B, 'insert into blocks (blocker_id, blocked_id) values ($1, $2)', [B, A])
    await q(db, B, "insert into device_tokens (user_id, token, environment) values ($1, $2, 'sandbox')", [B, 'b'.repeat(64)])
    await q(db, B, "insert into terms_acceptances (user_id, version, accepted_at) values ($1, '2026-10-30', now())", [B])
    await storeObject(db, `${h.id}/photo.jpg`)
    await storeObject(db, `avatars/${B}/profile.jpg`)
    await admin(db, 'delete from profile_birthdates where user_id = $1', [B])
    for (const table of ['huddles', 'memberships', 'deposits', 'reactions', 'comments', 'skips', 'reports', 'blocks', 'user_keys', 'huddle_keys', 'device_tokens', 'terms_acceptances', 'storage.objects']) {
      assert.deepEqual(await q(db, B, `select * from ${table}`), [], table)
    }
    assert.deepEqual(await q(db, B, 'select id from profiles'), [{ id: B }])
    assert.deepEqual(await q(db, B, 'select * from my_entitlement()'), [])
    assert.deepEqual(await q(db, B, 'select * from huddle_join_status($1)', [h.id]), [])
    assert.deepEqual(await q(db, B, 'select * from huddle_key_recipients($1)', [h.id]), [])
    assert.deepEqual(await q(db, B, 'select * from huddle_invite($1)', [h.id]), [])
    assert.deepEqual(await q(db, B, 'select holds_huddle_key($1) as holds', [h.id]), [{ holds: false }])
    await assert.rejects(createHuddle(db, B), /age_confirmation_required/)
    await assert.rejects(joinHuddle(db, B, h.invite_code), /age_confirmation_required/)
    await assert.rejects(q(db, B, "select * from redeem_huddle_invite('AAAAAA', $1, null)", [PUBLIC_KEY()]), /age_confirmation_required/)
    await assert.rejects(q(db, B, 'select recompute_streak($1, $2)', [h.id, today]), /not_a_member/)
    await assert.rejects(q(db, B, 'select spend_skip_token($1, $2, $3)', [h.id, B, today]), /not_a_member/)
    await assert.rejects(q(db, B, 'select init_huddle_key($1, $2, $3, $4)', [h.id, WRAPPED_KEY, PUBLIC_KEY('E'), PUBLIC_KEY('B')]), /not_a_member/)
    await assert.rejects(q(db, B, 'select save_own_huddle_key($1, $2, $3, $4)', [h.id, WRAPPED_KEY, PUBLIC_KEY('E'), PUBLIC_KEY('B')]), /not_a_member/)
    await assert.rejects(q(db, B, 'select share_huddle_key($1, $2, $3, $4, $5)', [h.id, A, WRAPPED_KEY, PUBLIC_KEY('F'), PUBLIC_KEY('A')]), /not_a_member/)
    await assert.rejects(q(db, B, 'select create_huddle_invite($1, $2, $3, $4, $5, $6)', [h.id, 'AAAAAA', PUBLIC_KEY(), PUBLIC_KEY(), WRAPPED_KEY, 'A'.repeat(72)]), /not_a_member/)
    await assert.rejects(q(db, B, 'select reset_huddle_invite($1, $2, $3, $4, $5, $6)', [h.id, 'AAAAAA', PUBLIC_KEY(), PUBLIC_KEY(), WRAPPED_KEY, 'A'.repeat(72)]), /not_keeper/)
    await assert.rejects(deposit(db, B, h.id, today), DENIED)
    await assert.rejects(q(db, B, 'insert into user_keys (user_id, public_key) values ($1, $2)', [B, PUBLIC_KEY()]), DENIED)
    await assert.rejects(q(db, B, "insert into storage.objects (bucket_id, name) values ('deposits', $1)", [`avatars/${B}/new.jpg`]), DENIED)
    await q(db, B, SAVE, ['1995-06-14'])
    assert.equal((await q(db, B, 'select * from deposits')).length, 1, 'approval restores access without losing history')
    assert.equal((await q(db, B, 'select * from storage.objects')).length, 2)
  })

  it('an invalid pre-existing birthday grants no eligibility, and account deletion still works', async () => {
    const db = await freshDatabase()
    const A = await legacyAccount(db, 'Ada')
    await admin(db, 'insert into profile_birthdates (user_id, birth_date) values ($1, $2)', [A, await yearsAgo(db, 12)])
    assert.deepEqual(await q(db, A, 'select caller_is_age_eligible() as eligible'), [{ eligible: false }])
    await assert.rejects(createHuddle(db, A), /age_confirmation_required/)
    await admin(db, 'delete from auth.users where id = $1', [A])
    assert.deepEqual(await admin(db, 'select * from profile_birthdates'), [])
    assert.deepEqual(await admin(db, 'select * from profiles'), [])
  })
})
