// Row Level Security and storage-policy tests: for every rule, the allowed
// case and the denied case. The privacy promise under test: a huddle's rows
// and photos are visible only to that huddle's current members.

import { describe, it, before } from 'node:test'
import assert from 'node:assert/strict'
import {
  freshDatabase, q, affected, admin, serverToday, signUp, createHuddle, joinHuddle,
  deposit, storeObject, WRAPPED_KEY, PUBLIC_KEY, randomUUID,
} from './harness.mjs'

const RLS_DENIED = /row-level security|permission denied/

/**
 * A: keeper of H1, member of H2. B: member of H1. C: keeper of H2.
 * D: signed in, in no huddle. null: anonymous (anon key only).
 */
async function world() {
  const db = await freshDatabase()
  const A = await signUp(db, 'Ada')
  const B = await signUp(db, 'Ben')
  const C = await signUp(db, 'Cy')
  const D = await signUp(db, 'Dee')
  const H1 = await createHuddle(db, A, 'Family')
  await joinHuddle(db, B, H1.invite_code)
  const H2 = await createHuddle(db, C, 'Friends')
  await joinHuddle(db, A, H2.invite_code)
  const today = await serverToday(db)
  const depB = await deposit(db, B, H1.id, today, { caption: 'B in H1' })
  const depC = await deposit(db, C, H2.id, today, { caption: 'C in H2' })
  for (const [uid, c] of [[A, 'A'], [B, 'B'], [C, 'C']]) {
    await q(db, uid, `insert into user_keys (user_id, public_key) values ($1, $2)`, [uid, PUBLIC_KEY(c)])
  }
  await storeObject(db, `${H1.id}/photo-b.jpg`)
  await storeObject(db, `${H2.id}/photo-c.jpg`)
  await storeObject(db, `avatars/${A}/a.jpg`)
  await storeObject(db, `avatars/${C}/c.jpg`)
  return { db, A, B, C, D, H1, H2, today, depB, depC }
}

const ids = (rows, key = 'id') => rows.map((r) => r[key]).sort()

describe('profiles', () => {
  let w
  before(async () => { w = await world() })

  it('members read co-members; non-members and anon read nothing of others', async () => {
    const { db, A, B, C, D } = w
    assert.deepEqual(ids(await q(db, A, 'select id from profiles')), [A, B, C].sort())
    assert.deepEqual(ids(await q(db, B, 'select id from profiles')), [A, B].sort(), 'B shares no huddle with C')
    assert.deepEqual(ids(await q(db, D, 'select id from profiles')), [D])
    assert.deepEqual(await q(db, null, 'select id from profiles'), [])
  })

  it('a user edits only their own profile', async () => {
    const { db, A, B } = w
    assert.equal(await affected(db, B, `update profiles set display_name = 'hacked' where id = $1`, [A]), 0)
    assert.equal((await admin(db, 'select display_name from profiles where id = $1', [A]))[0].display_name, 'Ada')
    assert.equal(await affected(db, B, `update profiles set bio = 'hi' where id = $1`, [B]), 1)
    await assert.rejects(
      q(db, B, `insert into profiles (id, display_name) values ($1, 'x')`, [randomUUID()]),
      RLS_DENIED,
    )
  })

  it('a profile holds at most 3 photo paths, as a list (QA-06)', async () => {
    const { db, B } = w
    const paths = (n) => JSON.stringify(Array.from({ length: n }, (_, i) => `Media/avatars/${B}/${i}.jpg`))
    assert.equal(await affected(db, B, `update profiles set photo_paths = $1::jsonb where id = $2`, [paths(3), B]), 1)
    await assert.rejects(q(db, B, `update profiles set photo_paths = $1::jsonb where id = $2`, [paths(4), B]), /check constraint/)
    await assert.rejects(q(db, B, `update profiles set photo_paths = '{"a":1}'::jsonb where id = $1`, [B]), /check constraint/)
  })

  it('a user cannot move their own profile to another id', async () => {
    const { db, B, D } = w
    await assert.rejects(q(db, B, `update profiles set id = $1 where id = $2`, [D, B]), /row-level security|violates|duplicate/)
  })
})

describe('huddles', () => {
  it('only members read a huddle; outsiders and anon see nothing', async () => {
    const { db, A, B, C, D, H1, H2 } = await world()
    assert.deepEqual(ids(await q(db, A, 'select id from huddles')), [H1.id, H2.id].sort())
    assert.deepEqual(ids(await q(db, B, 'select id from huddles')), [H1.id])
    assert.deepEqual(ids(await q(db, C, 'select id from huddles')), [H2.id])
    assert.deepEqual(await q(db, D, 'select id from huddles'), [])
    assert.deepEqual(await q(db, null, 'select id from huddles'), [])
  })

  it('the keeper renames; a member cannot; nobody writes streak or invite code directly', async () => {
    const { db, A, B, H1 } = await world()
    assert.equal(await affected(db, B, `update huddles set name = 'mine' where id = $1`, [H1.id]), 0)
    assert.equal(await affected(db, A, `update huddles set name = 'Fam' where id = $1`, [H1.id]), 1)
    await assert.rejects(q(db, A, `update huddles set streak_count = 999 where id = $1`, [H1.id]), RLS_DENIED)
    await assert.rejects(q(db, A, `update huddles set invite_code = 'AAAAAA' where id = $1`, [H1.id]), RLS_DENIED)
    await assert.rejects(q(db, A, `update huddles set emoji = $1 where id = $2`, ['🏔'.repeat(500), H1.id]), /check constraint/, 'QA-06')
  })

  it('huddles cannot be inserted or deleted directly', async () => {
    const { db, A, H1 } = await world()
    await assert.rejects(q(db, A, `insert into huddles (name, invite_code) values ('x', 'ZZZZZZ')`), RLS_DENIED)
    assert.equal(await affected(db, A, `delete from huddles where id = $1`, [H1.id]), 0)
  })
})

describe('memberships', () => {
  it('co-members read the member list; outsiders do not', async () => {
    const { db, B, C, D, H1 } = await world()
    assert.equal((await q(db, B, 'select * from memberships where huddle_id = $1', [H1.id])).length, 2)
    assert.equal((await q(db, C, 'select * from memberships where huddle_id = $1', [H1.id])).length, 0)
    assert.equal((await q(db, D, 'select * from memberships where huddle_id = $1', [H1.id])).length, 0)
    assert.equal((await q(db, null, 'select * from memberships')).length, 0)
  })

  it('nobody inserts a membership directly (joining goes through join_huddle)', async () => {
    const { db, B, D, H1, H2 } = await world()
    await assert.rejects(q(db, B, `insert into memberships (user_id, huddle_id) values ($1, $2)`, [B, H2.id]), RLS_DENIED)
    await assert.rejects(q(db, D, `insert into memberships (user_id, huddle_id) values ($1, $2)`, [D, H1.id]), RLS_DENIED)
  })

  it('a member cannot change their role or skip tokens', async () => {
    const { db, B, H1 } = await world()
    assert.equal(await affected(db, B, `update memberships set role = 'keeper', skip_tokens_remaining = 99 where user_id = $1`, [B]), 0)
    const [m] = await admin(db, 'select role, skip_tokens_remaining from memberships where user_id = $1 and huddle_id = $2', [B, H1.id])
    assert.deepEqual(m, { role: 'member', skip_tokens_remaining: 2 })
  })

  it('a member can remove only themselves', async () => {
    const { db, A, B, H1 } = await world()
    assert.equal(await affected(db, B, 'delete from memberships where user_id = $1', [A]), 0)
    assert.equal(await affected(db, B, 'delete from memberships where user_id = $1 and huddle_id = $2', [B, H1.id]), 1)
  })
})

describe('deposits (check-ins)', () => {
  it('only members read deposits, including captions', async () => {
    const { db, A, B, C, D, depB, depC } = await world()
    assert.deepEqual(ids(await q(db, A, 'select id from deposits')), [depB.id, depC.id].sort())
    assert.deepEqual(ids(await q(db, B, 'select id from deposits')), [depB.id])
    assert.deepEqual(ids(await q(db, C, 'select id from deposits')), [depC.id])
    assert.deepEqual(await q(db, D, 'select id from deposits'), [])
    assert.deepEqual(await q(db, null, 'select id from deposits'), [])
  })

  it('a member posts only as themselves, only into their own huddles', async () => {
    const { db, A, B, D, H1, H2, today } = await world()
    await assert.rejects(deposit(db, B, H2.id, today), RLS_DENIED, 'B is not in H2')
    await assert.rejects(deposit(db, D, H1.id, today), RLS_DENIED, 'D is in no huddle')
    await assert.rejects(
      q(db, B, `insert into deposits (huddle_id, author_id, storage_path, wrapped_photo_key, day_key)
                values ($1, $2, 'x/y.jpg', $3, $4)`, [H1.id, A, WRAPPED_KEY, today]),
      RLS_DENIED,
      'B cannot post as A',
    )
  })

  it('one check-in per member per huddle per day, enforced by the database', async () => {
    const { db, B, H1, today } = await world()
    await assert.rejects(deposit(db, B, H1.id, today), /duplicate key|deposits_huddle_id_author_id_day_key_key/)
  })

  it('the same member may check in to each of their huddles on the same day', async () => {
    const { db, A, H1, H2, today } = await world()
    await deposit(db, A, H1.id, today)
    await deposit(db, A, H2.id, today)
  })

  it('check-ins are permanent: no edits, no deletes, even by the author', async () => {
    const { db, B, depB } = await world()
    assert.equal(await affected(db, B, `update deposits set caption = 'edited' where id = $1`, [depB.id]), 0)
    assert.equal(await affected(db, B, 'delete from deposits where id = $1', [depB.id]), 0)
    const [row] = await admin(db, 'select caption from deposits where id = $1', [depB.id])
    assert.equal(row.caption, 'B in H1')
  })

  it('the day window: yesterday-or-earlier backfill and tomorrow for UTC+14, nothing further', async () => {
    const { db, A, H1 } = await world()
    // Server-UTC anchored: [today-2, today+1] covers every real timezone's
    // "today" and "yesterday" (UTC-12 … UTC+14).
    await deposit(db, A, H1.id, await serverToday(db, -2))
    await deposit(db, A, H1.id, await serverToday(db, 1))
    await assert.rejects(deposit(db, A, H1.id, await serverToday(db, -3)), RLS_DENIED)
    await assert.rejects(deposit(db, A, H1.id, await serverToday(db, 2)), RLS_DENIED)
  })

  it('rejects malformed day keys, oversized captions and unencrypted rows', async () => {
    const { db, A, H1, today } = await world()
    await assert.rejects(deposit(db, A, H1.id, '2026/10/21'), /check constraint|row-level security/)
    await assert.rejects(deposit(db, A, H1.id, today, { caption: 'x'.repeat(81) }), /check constraint/)
    await assert.rejects(
      q(db, A, `insert into deposits (huddle_id, author_id, storage_path, wrapped_photo_key, day_key)
                values ($1, $2, 'p', 'not-a-key', $3)`, [H1.id, A, today]),
      /check constraint/,
    )
  })
})

describe('leaving a huddle', () => {
  it('a member who leaves immediately loses the huddle, its members, its past check-ins and photos', async () => {
    const { db, A, B, H1, depB } = await world()
    await deposit(db, A, H1.id, await serverToday(db, -1))
    assert.equal(await affected(db, B, 'delete from memberships where user_id = $1 and huddle_id = $2', [B, H1.id]), 1)

    assert.deepEqual(await q(db, B, 'select id from huddles where id = $1', [H1.id]), [])
    assert.deepEqual(await q(db, B, 'select id from memberships where huddle_id = $1', [H1.id]), [])
    assert.deepEqual(await q(db, B, 'select id from deposits where huddle_id = $1', [H1.id]), [], 'past check-ins included')
    assert.deepEqual(await q(db, B, 'select id from comments'), [])
    assert.deepEqual(await q(db, B, `select name from storage.objects where name like $1`, [`${H1.id}/%`]), [])
    assert.deepEqual(await q(db, B, 'select id from profiles where id = $1', [A]), [], 'no longer shares a huddle with A')
    // Their own photo stays in the huddle for everyone else.
    assert.deepEqual(ids(await q(db, A, 'select id from deposits where author_id = $1', [B])), [depB.id])
  })

  it('a member who left cannot post, react, or comment there any more', async () => {
    const { db, B, H1, depB, today } = await world()
    await affected(db, B, 'delete from memberships where user_id = $1 and huddle_id = $2', [B, H1.id])
    await assert.rejects(deposit(db, B, H1.id, await serverToday(db, 1)), RLS_DENIED)
    await assert.rejects(q(db, B, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '❤️')`, [depB.id, B]), RLS_DENIED)
    await assert.rejects(q(db, B, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'hi')`, [depB.id, B]), RLS_DENIED)
    void today
  })
})

describe('reactions and comments', () => {
  it('members react and comment; outsiders cannot see or write', async () => {
    const { db, A, B, C, D, depB } = await world()
    await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [depB.id, A])
    await q(db, A, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'love it')`, [depB.id, A])
    assert.equal((await q(db, B, 'select * from reactions')).length, 1)
    assert.equal((await q(db, B, 'select * from comments')).length, 1)
    for (const outsider of [C, D, null]) {
      assert.deepEqual(await q(db, outsider, 'select * from reactions'), [])
      assert.deepEqual(await q(db, outsider, 'select * from comments'), [])
    }
    await assert.rejects(q(db, D, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'x')`, [depB.id, D]), RLS_DENIED)
    await assert.rejects(q(db, C, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [depB.id, C]), RLS_DENIED)
  })

  it('nobody writes as someone else or removes someone else’s reaction or comment', async () => {
    const { db, A, B, depB } = await world()
    await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [depB.id, A])
    await q(db, A, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'mine')`, [depB.id, A])
    await assert.rejects(q(db, B, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'as A')`, [depB.id, A]), RLS_DENIED)
    assert.equal(await affected(db, B, 'delete from reactions where user_id = $1', [A]), 0)
    assert.equal(await affected(db, B, 'delete from comments where user_id = $1', [A]), 0)
    assert.equal(await affected(db, B, `update comments set body = 'edited'`), 0, 'comments have no update policy')
  })

  it('enforces comment length and reaction uniqueness', async () => {
    const { db, A, depB } = await world()
    await assert.rejects(q(db, A, `insert into comments (deposit_id, user_id, body) values ($1, $2, $3)`, [depB.id, A, 'x'.repeat(501)]), /check constraint/)
    await assert.rejects(q(db, A, `insert into comments (deposit_id, user_id, body) values ($1, $2, '')`, [depB.id, A]), /check constraint/)
    await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [depB.id, A])
    await assert.rejects(q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [depB.id, A]), /duplicate key/)
  })
})

describe('storage: huddle photos', () => {
  it('only members list or download a huddle’s photo objects', async () => {
    const { db, A, B, C, D, H1, H2 } = await world()
    const inH1 = `select name from storage.objects where name like '${H1.id}/%'`
    assert.equal((await q(db, A, inH1)).length, 1)
    assert.equal((await q(db, B, inH1)).length, 1)
    for (const outsider of [C, D, null]) assert.deepEqual(await q(db, outsider, inH1), [])
    assert.deepEqual(ids(await q(db, B, `select name from storage.objects where name not like 'avatars/%'`), 'name'), [`${H1.id}/photo-b.jpg`])
    void H2
  })

  it('only members upload into a huddle folder, and nobody overwrites a huddle photo', async () => {
    const { db, B, D, H1, H2 } = await world()
    await q(db, B, `insert into storage.objects (bucket_id, name) values ('deposits', $1)`, [`${H1.id}/new.jpg`])
    await assert.rejects(q(db, B, `insert into storage.objects (bucket_id, name) values ('deposits', $1)`, [`${H2.id}/x.jpg`]), RLS_DENIED)
    await assert.rejects(q(db, D, `insert into storage.objects (bucket_id, name) values ('deposits', $1)`, [`${H1.id}/x.jpg`]), RLS_DENIED)
    await assert.rejects(q(db, null, `insert into storage.objects (bucket_id, name) values ('deposits', $1)`, [`${H1.id}/x.jpg`]), RLS_DENIED)
    assert.equal(await affected(db, B, `update storage.objects set name = name || '.bak' where name like $1`, [`${H1.id}/%`]), 0)
    assert.equal(await affected(db, B, `delete from storage.objects where name like $1`, [`${H1.id}/%`]), 0)
  })

  it('a non-uuid top folder never matches a huddle (no cast errors)', async () => {
    const { db, B } = await world()
    await assert.rejects(q(db, B, `insert into storage.objects (bucket_id, name) values ('deposits', 'misc/x.jpg')`), RLS_DENIED)
  })
})

describe('storage: profile photos (avatars)', () => {
  it('anonymous callers cannot list or download anyone’s profile photos', async () => {
    const { db } = await world()
    assert.deepEqual(await q(db, null, `select name from storage.objects where name like 'avatars/%'`), [])
  })

  it('a signed-in user sees only the profile photos of people they share a huddle with', async () => {
    const { db, A, B, C, D } = await world()
    const avatars = `select name from storage.objects where name like 'avatars/%'`
    assert.deepEqual(ids(await q(db, A, avatars), 'name'), [`avatars/${A}/a.jpg`, `avatars/${C}/c.jpg`].sort())
    assert.deepEqual(ids(await q(db, B, avatars), 'name'), [`avatars/${A}/a.jpg`], 'B shares H1 with A only')
    assert.deepEqual(await q(db, D, avatars), [], 'D shares no huddle with anyone')
  })

  it('a user writes only into their own avatars folder', async () => {
    const { db, A, B } = await world()
    await q(db, B, `insert into storage.objects (bucket_id, name) values ('deposits', $1)`, [`avatars/${B}/b.jpg`])
    await assert.rejects(q(db, B, `insert into storage.objects (bucket_id, name) values ('deposits', $1)`, [`avatars/${A}/evil.jpg`]), RLS_DENIED)
    assert.equal(await affected(db, B, `update storage.objects set name = $1 where name = $2`, [`avatars/${A}/x.jpg`, `avatars/${A}/a.jpg`]), 0)
  })
})

describe('encryption keys', () => {
  it('public keys: own + co-members only; nobody edits another user’s key', async () => {
    const { db, A, B, C, D } = await world()
    assert.deepEqual(ids(await q(db, B, 'select user_id from user_keys'), 'user_id'), [A, B].sort())
    assert.deepEqual(await q(db, D, 'select user_id from user_keys'), [])
    assert.deepEqual(await q(db, null, 'select user_id from user_keys'), [])
    assert.equal(await affected(db, B, `update user_keys set public_key = $1 where user_id = $2`, [PUBLIC_KEY('Z'), A]), 0)
    await assert.rejects(q(db, B, `insert into user_keys (user_id, public_key) values ($1, $2)`, [C, PUBLIC_KEY('Z')]), /row-level security|duplicate/)
  })

  it('wrapped huddle keys: each user reads only their own copy, and nobody writes them directly', async () => {
    const { db, A, B, H1 } = await world()
    await q(db, A, `select init_huddle_key($1, $2, $3, $4)`, [H1.id, WRAPPED_KEY, PUBLIC_KEY('E'), PUBLIC_KEY('A')])
    assert.equal((await q(db, A, 'select * from huddle_keys')).length, 1)
    assert.deepEqual(await q(db, B, 'select * from huddle_keys'), [])
    await assert.rejects(
      q(db, B, `insert into huddle_keys (huddle_id, user_id, wrapped_key, ephemeral_public_key, recipient_public_key)
                values ($1, $2, $3, $4, $5)`, [H1.id, B, WRAPPED_KEY, PUBLIC_KEY('E'), PUBLIC_KEY('B')]),
      RLS_DENIED,
    )
  })
})

describe('skips, reports, blocks', () => {
  it('skips: members read, nobody inserts directly', async () => {
    const { db, B, D, H1, today } = await world()
    await assert.rejects(q(db, B, `insert into skips (huddle_id, user_id, day_key) values ($1, $2, $3)`, [H1.id, B, today]), RLS_DENIED)
    await q(db, B, `select spend_skip_token($1, $2, $3)`, [H1.id, B, today])
    assert.equal((await q(db, B, 'select * from skips')).length, 1)
    assert.deepEqual(await q(db, D, 'select * from skips'), [])
  })

  it('reports: file your own, never read anyone else’s', async () => {
    const { db, A, B, depB } = await world()
    await q(db, A, `insert into reports (reporter_id, deposit_id) values ($1, $2)`, [A, depB.id])
    assert.equal((await q(db, A, 'select * from reports')).length, 1)
    assert.deepEqual(await q(db, B, 'select * from reports'), [], 'the reported author cannot see who reported them')
    await assert.rejects(q(db, B, `insert into reports (reporter_id, deposit_id) values ($1, $2)`, [A, depB.id]), RLS_DENIED)
  })

  it('blocks: fully private to the blocker', async () => {
    const { db, A, B } = await world()
    await q(db, A, `insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [A, B])
    assert.equal((await q(db, A, 'select * from blocks')).length, 1)
    assert.deepEqual(await q(db, B, 'select * from blocks'), [])
    await assert.rejects(q(db, B, `insert into blocks (blocker_id, blocked_id) values ($1, $2)`, [A, B]), /row-level security|duplicate/)
    assert.equal(await affected(db, B, 'delete from blocks'), 0)
  })
})
