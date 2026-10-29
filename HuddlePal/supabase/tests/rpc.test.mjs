// RPC behaviour, invites, streak math, key sharing, and account lifecycle.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  freshDatabase, q, affected, admin, serverToday, signUp, createHuddle, joinHuddle,
  deposit, service, WRAPPED_KEY, PUBLIC_KEY, randomUUID,
} from './harness.mjs'

const RESET_SQL = readFileSync(new URL('../scripts/reset_database.sql', import.meta.url), 'utf8')
const SCHEMA_SQL = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8')

describe('create_huddle', () => {
  it('requires a signed-in caller', async () => {
    const db = await freshDatabase()
    await assert.rejects(q(db, null, `select * from create_huddle('x', '🏔', null)`), /not authenticated/)
  })

  it('makes the caller keeper with a 6-char unambiguous invite code', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const h = await createHuddle(db, A, 'Family')
    assert.match(h.invite_code, /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$/)
    const [m] = await admin(db, 'select role, joined_day_key from memberships where huddle_id = $1', [h.id])
    assert.equal(m.role, 'keeper')
    assert.equal(m.joined_day_key, await serverToday(db))
  })

  it('validates the name and the emoji', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await assert.rejects(q(db, A, `select * from create_huddle('', '🏔', null)`), /check constraint/)
    await assert.rejects(q(db, A, `select * from create_huddle($1, '🏔', null)`, ['x'.repeat(61)]), /check constraint/)
    await assert.rejects(q(db, A, `select * from create_huddle('ok', $1, null)`, ['🏔'.repeat(500)]), /check constraint/)
  })

  it('stores the client’s join day only within ±1 day of the server', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const tomorrow = await serverToday(db, 1)
    const [h1] = await q(db, A, `select * from create_huddle('a', '🏔', $1)`, [tomorrow])
    const [h2] = await q(db, A, `select * from create_huddle('b', '🏔', '1999-01-01')`)
    const [h3] = await q(db, A, `select * from create_huddle('c', '🏔', '2026-13-45')`)
    const day = async (h) => (await admin(db, 'select joined_day_key d from memberships where huddle_id = $1', [h.id]))[0].d
    assert.equal(await day(h1), tomorrow)
    assert.equal(await day(h2), await serverToday(db))
    assert.equal(await day(h3), await serverToday(db))
  })
})

describe('join_huddle (invites)', () => {
  it('joins with a valid code, case- and whitespace-insensitive', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    const joined = await joinHuddle(db, B, `  ${h.invite_code.toLowerCase()} `)
    assert.equal(joined.id, h.id)
  })

  it('refuses anonymous callers, existing members and a full huddle', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const h = await createHuddle(db, A)
    await assert.rejects(q(db, null, `select * from join_huddle($1, null)`, [h.invite_code]), /not authenticated/)
    await assert.rejects(joinHuddle(db, A, h.invite_code), /already_member/)
    // Its keeper is on the free plan: 4 members.
    for (let i = 0; i < 3; i++) await joinHuddle(db, await signUp(db, `m${i}`), h.invite_code)
    await assert.rejects(joinHuddle(db, await signUp(db, 'fifth'), h.invite_code), /join_blocked_free_limit/)
  })

  it('an unknown code joins nothing', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await createHuddle(db, A)
    const B = await signUp(db, 'Ben')
    const result = await q(db, B, `select * from join_huddle('ZZZZZZ', null)`).catch((e) => e)
    // Either an empty result or the invite_code_not_found error; never a huddle.
    if (Array.isArray(result)) assert.deepEqual(result, [])
    else assert.match(String(result.message), /invite_code_not_found/)
    assert.deepEqual(await q(db, B, 'select * from memberships'), [])
  })

  it('stops guessing: after 10 wrong codes in an hour, even a right code is refused', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const h = await createHuddle(db, A)
    const attacker = await signUp(db, 'Mallory')
    for (let i = 0; i < 10; i++) {
      await q(db, attacker, `select * from join_huddle($1, null)`, [`WRONG${i}`]).catch(() => {})
    }
    await assert.rejects(joinHuddle(db, attacker, h.invite_code), /too_many_attempts/)
    assert.deepEqual(await admin(db, 'select 1 from memberships where user_id = $1', [attacker]), [])
    // Another user is unaffected.
    await joinHuddle(db, await signUp(db, 'Ben'), h.invite_code)
  })

  it('failed attempts older than an hour no longer count', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const h = await createHuddle(db, A)
    const B = await signUp(db, 'Ben')
    for (let i = 0; i < 10; i++) await q(db, B, `select * from join_huddle($1, null)`, [`WRONG${i}`]).catch(() => {})
    await admin(db, `update join_attempts set attempted_at = now() - interval '61 minutes'`)
    await joinHuddle(db, B, h.invite_code)
  })

  it('nobody can read or write the attempt log directly', async () => {
    const db = await freshDatabase()
    const B = await signUp(db, 'Ben')
    await q(db, B, `select * from join_huddle('NOPE00', null)`).catch(() => {})
    assert.deepEqual(await q(db, B, 'select * from join_attempts'), [])
    assert.equal(await affected(db, B, 'delete from join_attempts'), 0)
    await assert.rejects(q(db, B, `insert into join_attempts (user_id) values ($1)`, [randomUUID()]), /row-level security|permission denied|foreign key/)
  })
})

describe('streaks', () => {
  async function huddleWithTwo() {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    // Both joined five days ago, so the last four days wait on both.
    await admin(db, `update memberships set joined_day_key = to_char(now() - interval '5 days', 'YYYY-MM-DD')`)
    return { db, A, B, h }
  }
  const streak = (db, uid, h, day) => q(db, uid, 'select recompute_streak($1, $2) n', [h.id, day]).then((r) => r[0].n)

  it('counts complete days; an incomplete today never breaks the streak', async () => {
    const { db, A, B, h } = await huddleWithTwo()
    for (const off of [-2, -1]) {
      const d = await serverToday(db, off)
      await admin(db, `insert into deposits (huddle_id, author_id, storage_path, wrapped_photo_key, day_key) values ($1,$2,$6,$4,$3),($1,$5,$7,$4,$3)`, [h.id, A, d, WRAPPED_KEY, B, `${h.id}/${randomUUID()}.jpg`, `${h.id}/${randomUUID()}.jpg`])
    }
    assert.equal(await streak(db, A, h, await serverToday(db)), 2)
    const [row] = await admin(db, 'select streak_count, last_streak_day from huddles where id = $1', [h.id])
    assert.deepEqual(row, { streak_count: 2, last_streak_day: await serverToday(db, -1) })
  })

  it('a skip token covers a missing member', async () => {
    const { db, A, B, h } = await huddleWithTwo()
    const y = await serverToday(db, -1)
    await deposit(db, A, h.id, y)
    await q(db, B, 'select spend_skip_token($1, $2, $3)', [h.id, B, y])
    assert.equal(await streak(db, A, h, await serverToday(db)), 1)
  })

  it('a member who joined today is not waited on today', async () => {
    const { db, A, h } = await huddleWithTwo()
    const C = await signUp(db, 'Cy')
    await joinHuddle(db, C, h.invite_code)
    const B = (await admin(db, `select user_id from memberships where huddle_id = $1 and role = 'member' order by joined_at limit 1`, [h.id]))[0].user_id
    const t = await serverToday(db)
    await deposit(db, A, h.id, t)
    await deposit(db, B, h.id, t)
    assert.equal(await streak(db, A, h, t), 1)
  })

  it('only members may recompute, and only for a plausible today', async () => {
    const { db, A, h } = await huddleWithTwo()
    const D = await signUp(db, 'Dee')
    await assert.rejects(streak(db, D, h, await serverToday(db)), /not_a_member/)
    await assert.rejects(streak(db, A, h, '2000-01-01'), /invalid_day_key/)
    await assert.rejects(streak(db, A, h, await serverToday(db, 3)), /invalid_day_key/)
  })

  it('spend_skip_token always charges the caller, never the member named in p_user', async () => {
    const { db, A, B, h } = await huddleWithTwo()
    await q(db, B, 'select spend_skip_token($1, $2, $3)', [h.id, A, await serverToday(db)])
    const tokens = Object.fromEntries((await admin(db, 'select user_id, skip_tokens_remaining t from memberships')).map((r) => [r.user_id, r.t]))
    assert.equal(tokens[A], 2)
    assert.equal(tokens[B], 1)
    await q(db, B, 'select spend_skip_token($1, $2, $3)', [h.id, B, await serverToday(db, -1)])
    await assert.rejects(q(db, B, 'select spend_skip_token($1, $2, $3)', [h.id, B, await serverToday(db, -2)]), /no_tokens_remaining/)
    await assert.rejects(q(db, await signUp(db, 'Dee'), 'select spend_skip_token($1, $2, $3)', [h.id, A, await serverToday(db)]), /not_a_member/)
  })
})

describe('huddle key sharing', () => {
  async function keyed() {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const D = await signUp(db, 'Dee')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    for (const [u, c] of [[A, 'A'], [B, 'B'], [D, 'D']]) {
      await q(db, u, 'insert into user_keys (user_id, public_key) values ($1, $2)', [u, PUBLIC_KEY(c)])
    }
    return { db, A, B, D, h }
  }
  const init = (db, u, h, mine) => q(db, u, 'select init_huddle_key($1, $2, $3, $4) ok', [h.id, WRAPPED_KEY, PUBLIC_KEY('E'), mine]).then((r) => r[0].ok)
  const share = (db, u, h, to, theirs) => q(db, u, 'select share_huddle_key($1, $2, $3, $4, $5)', [h.id, to, WRAPPED_KEY, PUBLIC_KEY('F'), theirs])

  it('the first key is created once; later attempts are refused, never replaced', async () => {
    const { db, A, B, h } = await keyed()
    assert.equal(await init(db, A, h, PUBLIC_KEY('A')), true)
    assert.equal(await init(db, B, h, PUBLIC_KEY('B')), false)
    await assert.rejects(init(db, B, h, PUBLIC_KEY('Q')), /stale_public_key/)
  })

  it('outsiders can neither create, request nor share a huddle’s key', async () => {
    const { db, A, D, h } = await keyed()
    await assert.rejects(init(db, D, h, PUBLIC_KEY('D')), /not_a_member/)
    await init(db, A, h, PUBLIC_KEY('A'))
    assert.deepEqual(await q(db, D, 'select * from huddle_key_recipients($1)', [h.id]), [])
    await assert.rejects(share(db, D, h, A, PUBLIC_KEY('A')), /not_a_member/)
    await assert.rejects(share(db, A, h, D, PUBLIC_KEY('D')), /recipient_not_member/)
  })

  it('members waiting for the key are listed and served for their current public key only', async () => {
    const { db, A, B, h } = await keyed()
    await init(db, A, h, PUBLIC_KEY('A'))
    assert.deepEqual((await q(db, A, 'select user_id from huddle_key_recipients($1)', [h.id])).map((r) => r.user_id), [B])
    await assert.rejects(share(db, A, h, B, PUBLIC_KEY('Q')), /stale_public_key/)
    await assert.rejects(share(db, A, h, A, PUBLIC_KEY('A')), /cannot_share_with_self/)
    await share(db, A, h, B, PUBLIC_KEY('B'))
    assert.deepEqual(await q(db, A, 'select * from huddle_key_recipients($1)', [h.id]), [])
  })

  it('a member cannot overwrite a working copy someone else gave', async () => {
    const { db, A, B, h } = await keyed()
    const C = await signUp(db, 'Cy')
    await joinHuddle(db, C, h.invite_code)
    await q(db, C, 'insert into user_keys (user_id, public_key) values ($1, $2)', [C, PUBLIC_KEY('C')])
    await init(db, A, h, PUBLIC_KEY('A'))
    await share(db, A, h, C, PUBLIC_KEY('C'))
    await q(db, B, 'select share_huddle_key($1, $2, $3, $4, $5)', [h.id, C, 'B'.repeat(80), PUBLIC_KEY('G'), PUBLIC_KEY('C')])
    const [row] = await admin(db, 'select wrapped_key, wrapped_by from huddle_keys where user_id = $1', [C])
    assert.equal(row.wrapped_by, A)
    assert.equal(row.wrapped_key, WRAPPED_KEY)
  })

  it('leaving a huddle removes the leaver’s wrapped copy of its key', async () => {
    const { db, A, B, h } = await keyed()
    await init(db, A, h, PUBLIC_KEY('A'))
    await share(db, A, h, B, PUBLIC_KEY('B'))
    await affected(db, B, 'delete from memberships where user_id = $1 and huddle_id = $2', [B, h.id])
    assert.deepEqual(await q(db, B, 'select * from huddle_keys'), [])
  })
})

describe('keeper succession', () => {
  it("the keeper can't leave: deleting their own membership deletes nothing", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    assert.equal(await affected(db, A, 'delete from memberships where user_id = $1', [A]), 0)
    const roles = Object.fromEntries((await admin(db, 'select user_id, role from memberships')).map((r) => [r.user_id, r.role]))
    assert.deepEqual(roles, { [A]: 'keeper', [B]: 'member' })
  })

  it("when the keeper's account goes, the longest-standing member becomes keeper", async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const C = await signUp(db, 'Cy')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    await joinHuddle(db, C, h.invite_code)
    await admin(db, 'delete from auth.users where id = $1', [A])
    const roles = Object.fromEntries((await admin(db, 'select user_id, role from memberships')).map((r) => [r.user_id, r.role]))
    assert.deepEqual(roles, { [B]: 'keeper', [C]: 'member' })
    // The new keeper can manage the huddle.
    assert.equal(await affected(db, B, `update huddles set name = 'Ours now' where id = $1`, [h.id]), 1)
  })

  it('a member leaving does not change the keeper', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const C = await signUp(db, 'Cy')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    await joinHuddle(db, C, h.invite_code)
    await affected(db, B, 'delete from memberships where user_id = $1', [B])
    const roles = Object.fromEntries((await admin(db, 'select user_id, role from memberships')).map((r) => [r.user_id, r.role]))
    assert.deepEqual(roles, { [A]: 'keeper', [C]: 'member' })
  })
})

describe('account deletion (what the delete-account function triggers)', () => {
  it('removes the profile, birthday, memberships, keys, devices, reactions, Terms records; keeps photos, comments and reports', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    const dep = await deposit(db, B, h.id, await serverToday(db))
    await q(db, B, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'mine')`, [dep.id, B])
    await q(db, B, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [dep.id, B])
    await q(db, B, `insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [B, A])
    const photoKey = PUBLIC_KEY('K')
    await q(db, B, `insert into reports (reporter_id, deposit_id, photo_key) values ($1, $2, $3)`, [B, dep.id, photoKey])
    await q(db, B, 'insert into user_keys (user_id, public_key) values ($1, $2)', [B, PUBLIC_KEY('B')])
    await q(db, B, `insert into device_tokens (user_id, token, environment) values ($1, $2, 'production')`, [B, 'b'.repeat(64)])
    await q(db, B, `insert into terms_acceptances (user_id, version, accepted_at) values ($1, '2026-10-25', now())`, [B])
    await q(db, B, `select save_birthday('1995-06-14')`)

    await admin(db, 'delete from auth.users where id = $1', [B]) // auth.admin.deleteUser

    for (const table of ['profiles where id', 'memberships where user_id', 'reactions where user_id', 'blocks where blocker_id', 'reports where reporter_id', 'user_keys where user_id', 'huddle_keys where user_id', 'device_tokens where user_id', 'terms_acceptances where user_id', 'profile_birthdates where user_id']) {
      assert.deepEqual(await admin(db, `select 1 from ${table} = $1`, [B]), [], table)
    }
    // The report stays, with the photo and its key: only the reporter is gone.
    assert.deepEqual(
      await admin(db, 'select reporter_id, deposit_id, photo_key from reports'),
      [{ reporter_id: null, deposit_id: dep.id, photo_key: photoKey }],
    )
    const [d] = await admin(db, 'select author_id from deposits where id = $1', [dep.id])
    assert.equal(d.author_id, null)
    const [c] = await admin(db, 'select user_id, body from comments where deposit_id = $1', [dep.id])
    assert.deepEqual(c, { user_id: null, body: 'mine' })
    // The remaining member still sees the photo and comment.
    assert.equal((await q(db, A, 'select * from deposits')).length, 1)
    assert.equal((await q(db, A, 'select * from comments')).length, 1)
  })

  it('a report survives the reported person deleting their account too', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    const dep = await deposit(db, B, h.id, await serverToday(db))
    await q(db, A, `insert into reports (reporter_id, deposit_id, reported_user_id) values ($1, $2, $3)`, [A, dep.id, B])

    await admin(db, 'delete from auth.users where id = $1', [B])

    assert.deepEqual(
      await admin(db, 'select reporter_id, deposit_id, reported_user_id from reports'),
      [{ reporter_id: A, deposit_id: dep.id, reported_user_id: null }],
      'the photo itself stays too, so the report still points at it',
    )
  })

  it('a keeper deleting their account hands the huddle to the next member', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    await admin(db, 'delete from auth.users where id = $1', [A])
    assert.deepEqual(await admin(db, 'select user_id, role from memberships where huddle_id = $1', [h.id]), [{ user_id: B, role: 'keeper' }])
  })

  it('someone who deposited photos can be deleted once their objects are released; the photos stay (QA-20)', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    const dep = await deposit(db, B, h.id, await serverToday(db))
    // Ownership as the Storage API records it on upload.
    const own = `insert into storage.objects (bucket_id, name, owner, owner_id) values ('deposits', $1, $2, $3)`
    const othersPhoto = `${h.id}/${randomUUID()}.jpg`
    await admin(db, own, [dep.storage_path, B, B])
    await admin(db, own, [othersPhoto, A, A])

    await assert.rejects(admin(db, 'delete from auth.users where id = $1', [B]), /objects_owner_fkey/, 'owning an object blocks deleteUser')

    assert.deepEqual(await service(db, 'select release_storage_objects($1) as released', [B]), [{ released: 1 }])
    await admin(db, 'delete from auth.users where id = $1', [B]) // auth.admin.deleteUser
    const objects = await admin(db, 'select name, owner, owner_id from storage.objects order by name = $1 desc', [dep.storage_path])
    assert.deepEqual(objects, [
      { name: dep.storage_path, owner: null, owner_id: null },
      { name: othersPhoto, owner: A, owner_id: A },
    ], 'the photo stays, with no owner; nobody else’s ownership changes')
    assert.equal((await q(db, A, 'select * from deposits')).length, 1)
  })

  it('only the service role can release storage objects', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    for (const caller of [null, A, B]) {
      await assert.rejects(q(db, caller, 'select release_storage_objects($1)', [B]), /permission denied/, `caller ${caller}`)
    }
  })

  it('a deleted author’s Former-member rows never block that day for anyone else', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const h = await createHuddle(db, A)
    await joinHuddle(db, B, h.invite_code)
    const t = await serverToday(db)
    await deposit(db, B, h.id, t)
    await admin(db, 'delete from auth.users where id = $1', [B])
    await deposit(db, A, h.id, t)
  })
})

describe('schema lifecycle', () => {
  it('reset_database.sql wipes an existing database and schema.sql rebuilds it cleanly', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    await createHuddle(db, A)
    await db.exec(RESET_SQL)
    assert.deepEqual(await admin(db, `select tablename from pg_tables where schemaname = 'public'`), [])
    await db.exec(SCHEMA_SQL)
    const tables = (await admin(db, `select tablename from pg_tables where schemaname = 'public' order by 1`)).map((r) => r.tablename)
    assert.ok(tables.includes('deposits') && tables.includes('huddle_keys'))
    // auth.users survives the reset, as documented.
    assert.equal((await admin(db, 'select count(*)::int n from auth.users'))[0].n, 1)
  })

  it('every table in public has row level security enabled', async () => {
    const db = await freshDatabase()
    const rows = await admin(db, `select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                                  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity`)
    assert.deepEqual(rows, [])
  })

  it('every SECURITY DEFINER function pins its search_path', async () => {
    const db = await freshDatabase()
    const rows = await admin(db, `select proname from pg_proc where pronamespace = 'public'::regnamespace
                                  and prosecdef and not coalesce(array_to_string(proconfig, ',') like '%search_path%', false)`)
    assert.deepEqual(rows, [])
  })

  it('the hot paths have indexes', async () => {
    const db = await freshDatabase()
    const idx = (await admin(db, `select indexdef from pg_indexes where schemaname = 'public'`)).map((r) => r.indexdef).join('\n')
    for (const needle of ['deposits USING btree (huddle_id, day_key)', 'memberships USING btree (user_id)', 'reactions USING btree (deposit_id)', 'comments USING btree (deposit_id)']) {
      assert.ok(idx.includes(needle), needle)
    }
  })
})
