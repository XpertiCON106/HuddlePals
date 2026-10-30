// Push notifications, database side: device tokens (each user manages only
// their own), who gets notified about what (push_targets), and the triggers
// that ask the send-push function to do it. The function itself is in
// send-push.test.mjs.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  freshDatabase, q, admin, affected, service, serverToday, signUp, createHuddle, joinHuddle, deposit,
} from './harness.mjs'

const RLS_DENIED = /row-level security|permission denied/
const token = (c) => c.repeat(64)
const register = (db, uid, t, environment = 'production') =>
  q(db, uid, 'insert into device_tokens (user_id, token, environment) values ($1, $2, $3) returning *', [uid, t, environment])
const targets = (db, kind, id) =>
  service(db, 'select * from push_targets($1, $2) order by token', [kind, id])
const recipients = async (db, kind, id) => (await targets(db, kind, id)).map((t) => t.user_id).sort()
/** Ages a user's registrations, past the trigger that keeps updated_at current. */
const backdate = (db, uid, interval, t = null) => db.transaction(async (tx) => {
  await tx.exec('set local session_replication_role = replica')
  await tx.query(`update device_tokens set updated_at = now() - $2::interval where user_id = $1 and ($3::text is null or token = $3)`, [uid, interval, t])
})

/**
 * Family (🏔): Ada (keeper), Ben, Cy. Dee is in another huddle with Ada.
 * Everyone has registered one device.
 */
async function world() {
  const db = await freshDatabase()
  const A = await signUp(db, 'Ada')
  const B = await signUp(db, 'Ben')
  const C = await signUp(db, 'Cy')
  const D = await signUp(db, 'Dee')
  const family = await createHuddle(db, A, 'Family')
  await joinHuddle(db, B, family.invite_code)
  await joinHuddle(db, C, family.invite_code)
  const other = await createHuddle(db, D, 'Other')
  await joinHuddle(db, A, other.invite_code)
  for (const [uid, c] of [[A, 'a'], [B, 'b'], [C, 'c'], [D, 'd']]) await register(db, uid, token(c))
  return { db, A, B, C, D, family, other, today: await serverToday(db) }
}

describe('device tokens', () => {
  it('each user registers, sees, updates and deletes only their own', async () => {
    const { db, A, B } = await world()
    assert.deepEqual((await q(db, A, 'select token from device_tokens')).map((r) => r.token), [token('a')])
    await assert.rejects(q(db, A, 'insert into device_tokens (user_id, token, environment) values ($1, $2, $3)', [B, token('f'), 'sandbox']), RLS_DENIED)
    assert.equal(await affected(db, A, `update device_tokens set environment = 'sandbox' where user_id = $1`, [B]), 0)
    assert.equal(await affected(db, A, 'delete from device_tokens where user_id = $1', [B]), 0)
    assert.equal(await affected(db, A, 'delete from device_tokens where token = $1', [token('b')]), 0, 'a known token isn’t enough')
    assert.equal((await admin(db, 'select count(*)::int n from device_tokens where user_id = $1', [B]))[0].n, 1)
    assert.equal(await affected(db, A, 'delete from device_tokens where token = $1', [token('a')]), 1)
    assert.deepEqual(await q(db, null, 'select * from device_tokens'), [])
  })

  it('refuses a malformed token or an unknown environment', async () => {
    const { db, A } = await world()
    await assert.rejects(register(db, A, 'ABCDEF'.repeat(11)), /check constraint/)
    await assert.rejects(register(db, A, 'ab'), /check constraint/)
    await assert.rejects(register(db, A, token('e'), 'staging'), /check constraint/)
  })

  it('registering again (the app’s upsert) refreshes updated_at', async () => {
    const { db, A } = await world()
    await backdate(db, A, '3 days')
    assert.equal((await admin(db, `select updated_at < now() - interval '2 days' as old from device_tokens where user_id = $1`, [A]))[0].old, true)
    await q(db, A, `insert into device_tokens (user_id, token, environment) values ($1, $2, 'sandbox')
                    on conflict (user_id, token) do update set environment = excluded.environment`, [A, token('a')])
    const [row] = await admin(db, `select environment, updated_at > now() - interval '1 minute' as fresh from device_tokens where user_id = $1`, [A])
    assert.deepEqual(row, { environment: 'sandbox', fresh: true })
  })

  it('go with the account', async () => {
    const { db, A } = await world()
    await admin(db, 'delete from auth.users where id = $1', [A])
    assert.deepEqual(await admin(db, 'select 1 from device_tokens where user_id = $1', [A]), [])
  })
})

describe('who gets notified', () => {
  it('existing device tokens receive nothing until their account confirms an eligible birthday', async () => {
    const { db, A, B, C, family, today } = await world()
    await admin(db, 'delete from profile_birthdates where user_id = $1', [A])
    const photo = await deposit(db, B, family.id, today)
    assert.deepEqual(await recipients(db, 'deposit', photo.id), [C])
    await q(db, A, "select save_birthday('1995-06-14')")
    assert.deepEqual((await recipients(db, 'deposit', photo.id)).sort(), [A, C].sort())
  })

  it('a new photo: every other member of that huddle, with what the notification says', async () => {
    const { db, A, B, C, family, today } = await world()
    const photo = await deposit(db, B, family.id, today, { caption: 'never sent' })
    const rows = await targets(db, 'deposit', photo.id)
    assert.deepEqual(rows.map((r) => r.user_id).sort(), [A, C].sort(), 'not Ben himself, not Dee from another huddle')
    assert.deepEqual(rows[0], {
      user_id: A, token: token('a'), environment: 'production',
      huddle_id: family.id, huddle_name: 'Family', huddle_emoji: '🏔', actor_name: 'Ben', detail: null,
    })
    assert.ok(!JSON.stringify(rows).includes('never sent'), 'captions never go into a notification')
  })

  it('a comment or a reaction: only the photo’s owner, and not for their own', async () => {
    const { db, A, B, C, family, today } = await world()
    const photo = await deposit(db, B, family.id, today)
    const [comment] = await q(db, C, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'private words') returning id`, [photo.id, C])
    assert.deepEqual(await recipients(db, 'comment', comment.id), [B])
    assert.ok(!JSON.stringify(await targets(db, 'comment', comment.id)).includes('private words'))

    const [reaction] = await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥') returning id`, [photo.id, A])
    const [row] = await targets(db, 'reaction', reaction.id)
    assert.deepEqual([row.user_id, row.actor_name, row.detail], [B, 'Ada', '🔥'])

    const [own] = await q(db, B, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'me') returning id`, [photo.id, B])
    assert.deepEqual(await targets(db, 'comment', own.id), [])
  })

  it('nobody, once the photo’s owner has left the huddle', async () => {
    const { db, B, C, family, today } = await world()
    const photo = await deposit(db, B, family.id, today)
    await affected(db, B, 'delete from memberships where user_id = $1 and huddle_id = $2', [B, family.id])
    const [comment] = await q(db, C, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'hi') returning id`, [photo.id, C])
    assert.deepEqual(await targets(db, 'comment', comment.id), [])
  })

  it('someone joining: the members already there', async () => {
    const { db, A, B, C, family } = await world()
    const E = await signUp(db, 'Eve')
    await joinHuddle(db, E, family.invite_code)
    const [membership] = await admin(db, 'select id from memberships where user_id = $1', [E])
    assert.deepEqual(await recipients(db, 'join', membership.id), [A, B, C].sort())
  })

  it('never across a block, whichever side blocked', async () => {
    const { db, A, B, C, family, today } = await world()
    await q(db, A, 'insert into blocks (blocker_id, blocked_id) values ($1, $2)', [A, B])
    const photo = await deposit(db, B, family.id, today)
    assert.deepEqual(await recipients(db, 'deposit', photo.id), [C], 'Ada blocked Ben')

    const photoC = await deposit(db, C, family.id, today)
    await q(db, C, 'insert into blocks (blocker_id, blocked_id) values ($1, $2)', [C, A])
    const [reaction] = await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '❤️') returning id`, [photoC.id, A])
    assert.deepEqual(await targets(db, 'reaction', reaction.id), [], 'Cy blocked Ada')
  })

  it('a device registered by two accounts notifies only the one that registered it last', async () => {
    const { db, A, B, C, family, today } = await world()
    // Cy signed out on Ben's phone without reaching the server, then Ben signed in there.
    await register(db, C, token('b'))
    await backdate(db, C, '1 day', token('b'))
    const photo = await deposit(db, A, family.id, today)
    const rows = await targets(db, 'deposit', photo.id)
    assert.deepEqual(rows.map((r) => [r.user_id, r.token]).sort(), [[B, token('b')], [C, token('c')]].sort())
  })

  it('members without a registered device are skipped; unknown events notify nobody', async () => {
    const { db, A, B, family, today } = await world()
    await affected(db, A, 'delete from device_tokens where user_id = $1', [A])
    const photo = await deposit(db, B, family.id, today)
    assert.equal((await recipients(db, 'deposit', photo.id)).includes(A), false)
    assert.deepEqual(await targets(db, 'comment', photo.id), [], 'a deposit id is no comment')
    assert.deepEqual(await targets(db, 'nonsense', photo.id), [])
  })

  it('only the service role can ask', async () => {
    const { db, A, family, today } = await world()
    const photo = await deposit(db, A, family.id, today)
    for (const caller of [null, A]) {
      await assert.rejects(q(db, caller, 'select * from push_targets($1, $2)', ['deposit', photo.id]), /permission denied/)
    }
  })
})

describe('triggers', () => {
  const URL = 'https://project.supabase.co/functions/v1/send-push'
  const configure = (db) => admin(db, `insert into vault.secrets (name, secret) values ('push_function_url', $1), ('push_webhook_secret', 'shh')`, [URL])
  const queued = (db) => admin(db, 'select url, body, headers from net.http_requests order by id')

  it('do nothing until the Vault secrets are set, and never block the insert', async () => {
    const { db, B, family, today } = await world()
    await deposit(db, B, family.id, today)
    assert.deepEqual(await queued(db), [])
  })

  it('queue one request per photo, comment, reaction and join, naming the event and the row', async () => {
    const { db, A, B, family, today } = await world()
    await configure(db)
    const photo = await deposit(db, B, family.id, today)
    const [comment] = await q(db, A, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'hi') returning id`, [photo.id, A])
    const [reaction] = await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥') returning id`, [photo.id, A])
    const E = await signUp(db, 'Eve')
    await joinHuddle(db, E, family.invite_code)
    const [membership] = await admin(db, 'select id from memberships where user_id = $1', [E])

    const requests = await queued(db)
    assert.deepEqual(requests.map((r) => r.body), [
      { kind: 'deposit', id: photo.id },
      { kind: 'comment', id: comment.id },
      { kind: 'reaction', id: reaction.id },
      { kind: 'join', id: membership.id },
    ])
    for (const r of requests) {
      assert.equal(r.url, URL)
      assert.deepEqual(r.headers, { 'Content-Type': 'application/json', 'x-push-secret': 'shh' })
    }
  })

  it('an insert that fails queues nothing', async () => {
    const { db, B, family, today } = await world()
    await configure(db)
    await deposit(db, B, family.id, today)
    await assert.rejects(deposit(db, B, family.id, today), /duplicate key/)
    assert.equal((await queued(db)).length, 1)
  })

  it('a failing request never stops the photo from being posted', async () => {
    const { db, B, family, today } = await world()
    await configure(db)
    await db.exec(`create or replace function net.http_post(url text, body jsonb default '{}'::jsonb, params jsonb default '{}'::jsonb,
                     headers jsonb default '{}'::jsonb, timeout_milliseconds integer default 5000)
                   returns bigint language plpgsql as $$ begin raise exception 'pg_net is down'; end $$`)
    const photo = await deposit(db, B, family.id, today)
    assert.equal((await admin(db, 'select count(*)::int n from deposits where id = $1', [photo.id]))[0].n, 1)
  })
})
