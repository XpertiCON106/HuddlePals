// profile_birthdates: each account's birthday, which only its owner can
// read or change, never under 13 (with a day's leeway for time zones), and
// gone with the account.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { freshDatabase, q, admin, affected, signUp, createHuddle, joinHuddle } from './harness.mjs'

const SAVE = `insert into profile_birthdates (user_id, birth_date) values ($1, $2)
              on conflict (user_id) do update set birth_date = excluded.birth_date`

/** The date `years` years and `days` days before the server's today. */
async function yearsAgo(db, years, days = 0) {
  const [{ d }] = await admin(db, `select to_char(current_date - make_interval(years => $1, days => $2), 'YYYY-MM-DD') as d`, [years, days])
  return d
}

describe('birthdays', () => {
  it('an account saves its birthday, changes it and reads it back; nobody else can, huddle or not', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)

    await q(db, A, SAVE, [A, '1995-06-14'])
    await q(db, A, SAVE, [A, '1994-02-01'])
    assert.deepEqual(await q(db, A, `select to_char(birth_date, 'YYYY-MM-DD') as d from profile_birthdates`), [{ d: '1994-02-01' }])
    assert.deepEqual(await q(db, B, 'select * from profile_birthdates'), [], 'not even someone in the same huddle')
    assert.deepEqual(await q(db, null, 'select * from profile_birthdates').catch(() => []), [], 'nor anyone signed out')
  })

  it('refuses one under 13, takes 13 today', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await assert.rejects(q(db, A, SAVE, [A, await yearsAgo(db, 12)]), /row-level security/)
    await assert.rejects(q(db, A, SAVE, [A, await yearsAgo(db, 13, -2)]), /row-level security/, 'two days short')
    await q(db, A, SAVE, [A, await yearsAgo(db, 13)])
    await assert.rejects(q(db, A, SAVE, [A, await yearsAgo(db, 10)]), /row-level security/, 'nor changed to under 13 later')
  })

  it("nobody writes someone else's", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    await q(db, A, SAVE, [A, '1995-06-14'])
    await assert.rejects(q(db, B, SAVE, [A, '1990-01-01']))
    assert.equal(await affected(db, B, `update profile_birthdates set birth_date = '1990-01-01' where user_id = $1`, [A]), 0)
    assert.equal(await affected(db, A, 'delete from profile_birthdates where user_id = $1', [A]).catch(() => 0), 0, 'and it is never deleted by hand')
    assert.deepEqual(await admin(db, `select to_char(birth_date, 'YYYY-MM-DD') as d from profile_birthdates`), [{ d: '1995-06-14' }])
  })

  it('goes with the account', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await q(db, A, SAVE, [A, '1995-06-14'])
    await admin(db, 'delete from auth.users where id = $1', [A]) // auth.admin.deleteUser
    assert.deepEqual(await admin(db, 'select * from profile_birthdates'), [])
  })
})
