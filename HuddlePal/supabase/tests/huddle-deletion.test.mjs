// delete_huddle(): a keeper deletes their huddle. Everyone is removed and
// everything in it goes, except a reported deposit, which is kept for the
// operator; everyone else who was in it is told. The delete-huddle edge
// function that calls it, and deletes the files, is in delete-huddle.test.mjs.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  freshDatabase, q, admin, service, serverToday, signUp, createHuddle, joinHuddle, deposit, videoDeposit,
  grantPlus, PUBLIC_KEY, randomUUID,
} from './harness.mjs'

const DENIED = /permission denied/
const remove = async (db, huddleId, uid) =>
  (await service(db, 'select delete_huddle($1, $2) as kept', [huddleId, uid]))[0].kept
const refusal = (promise) => promise.then(() => null, (e) => e.message)
const count = async (db, sql, params) => (await admin(db, `select count(*)::int n from ${sql}`, params))[0].n

/** Family (🏔): Ada keeps it, Ben and Cy are in it. Ben also keeps Other. Ben posted in Family; Ada reacted and commented. */
async function world() {
  const db = await freshDatabase()
  const A = await signUp(db, 'Ada')
  const B = await signUp(db, 'Ben')
  const C = await signUp(db, 'Cy')
  const family = await createHuddle(db, A, 'Family')
  await joinHuddle(db, B, family.invite_code)
  await joinHuddle(db, C, family.invite_code)
  const other = await createHuddle(db, B, 'Other')
  const today = await serverToday(db)
  const photo = await deposit(db, B, family.id, today, { caption: 'hi' })
  await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [photo.id, A])
  await q(db, A, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'nice')`, [photo.id, A])
  const elsewhere = await deposit(db, B, other.id, today)
  return { db, A, B, C, family, other, today, photo, elsewhere }
}

describe('deleting a huddle', () => {
  it('only its keeper can, and only through the delete-huddle function', async () => {
    const { db, A, B, family } = await world()
    const stranger = await signUp(db, 'Dee')
    assert.equal(await refusal(remove(db, family.id, B)), 'not_keeper', 'a member')
    assert.equal(await refusal(remove(db, family.id, stranger)), 'not_keeper', 'someone outside it')
    assert.equal(await refusal(remove(db, randomUUID(), A)), 'huddle_not_found')
    for (const caller of [A, null]) {
      await assert.rejects(q(db, caller, 'select delete_huddle($1, $2)', [family.id, A]), DENIED)
    }
    assert.equal(await count(db, 'huddles where id = $1', [family.id]), 1, 'still there')
  })

  it('removes everyone and everything in it, and nothing else', async () => {
    const { db, A, B, family, other, photo, elsewhere } = await world()
    assert.deepEqual(await remove(db, family.id, A), [], 'no files to keep')

    assert.equal(await count(db, 'huddles where id = $1', [family.id]), 0)
    for (const table of ['memberships', 'deposits', 'skips', 'huddle_keys', 'huddle_invite_keys']) {
      assert.equal(await count(db, `${table} where huddle_id = $1`, [family.id]), 0, table)
    }
    assert.equal(await count(db, 'reactions where deposit_id = $1', [photo.id]), 0)
    assert.equal(await count(db, 'comments where deposit_id = $1', [photo.id]), 0)
    assert.deepEqual((await q(db, B, 'select id from huddles')).map((h) => h.id), [other.id], "Ben's other huddle stays")
    assert.equal(await count(db, 'deposits where id = $1', [elsewhere.id]), 1)
    assert.deepEqual(await q(db, A, 'select id from huddles'), [])
  })

  it('frees a place among the huddles its keeper keeps', async () => {
    const { db, A, family } = await world()
    await createHuddle(db, A, 'Two')
    await createHuddle(db, A, 'Three')
    assert.equal(await refusal(createHuddle(db, A, 'Four')), 'huddle_limit_reached_free')
    await remove(db, family.id, A)
    assert.ok(await createHuddle(db, A, 'Four'))
  })

  it('keeps a reported photo or video, and its files, for the operator', async () => {
    const { db, A, B, C, family, today, photo } = await world()
    await grantPlus(db, B)
    const video = await videoDeposit(db, B, family.id, await serverToday(db, -1))
    const earlier = await deposit(db, C, family.id, today)
    const [photoReport] = await q(db, C,
      'insert into reports (reporter_id, deposit_id, photo_key) values ($1, $2, $3) returning id', [C, photo.id, PUBLIC_KEY('P')])
    await q(db, A, 'insert into reports (reporter_id, deposit_id, photo_key) values ($1, $2, $3)', [A, video.id, PUBLIC_KEY('V')])
    await q(db, A, 'insert into reports (reporter_id, deposit_id, photo_key) values ($1, $2, $3)', [A, earlier.id, PUBLIC_KEY('E')])
    await admin(db, `select remove_reported_photo($1, true, 'CyberTip 1')`, [earlier.id])

    const kept = await remove(db, family.id, A)
    assert.deepEqual(kept.sort(), [photo.storage_path, video.storage_path, video.video_path, earlier.storage_path].sort())

    const preserved = await admin(db, 'select deposit_id, photo_key, note, report_ids, media_type from preserved_photos order by removed_at, deposit_id')
    const byDeposit = Object.fromEntries(preserved.map((p) => [p.deposit_id, p]))
    assert.equal(byDeposit[photo.id].photo_key, PUBLIC_KEY('P'))
    assert.deepEqual(byDeposit[photo.id].report_ids, [photoReport.id])
    assert.equal(byDeposit[photo.id].note, 'Kept when its keeper deleted the huddle')
    assert.equal(byDeposit[video.id].media_type, 'video')
    assert.equal(byDeposit[earlier.id].note, 'CyberTip 1', 'what was already kept stays as it was')
    assert.deepEqual(
      await admin(db, 'select deposit_id, photo_key from reports where id = $1', [photoReport.id]),
      [{ deposit_id: null, photo_key: PUBLIC_KEY('P') }],
      'the report stays',
    )
  })

  it('tells everyone else who was in it, never across a block', async () => {
    const { db, A, B, C, family } = await world()
    for (const [uid, c] of [[A, 'a'], [B, 'b'], [C, 'c']]) {
      await q(db, uid, 'insert into device_tokens (user_id, token, environment) values ($1, $2, $3)', [uid, c.repeat(64), 'production'])
    }
    await q(db, C, 'insert into blocks (blocker_id, blocked_id) values ($1, $2)', [C, A])
    await admin(db, `insert into vault.secrets (name, secret) values ('push_function_url', 'https://p.supabase.co/functions/v1/send-push'), ('push_webhook_secret', 'shh')`)

    await remove(db, family.id, A)

    const [deletion] = await admin(db, 'select * from huddle_deletions')
    assert.equal(deletion.huddle_id, family.id)
    assert.equal(deletion.huddle_name, 'Family')
    assert.equal(deletion.actor_id, A)
    assert.deepEqual(deletion.member_ids.sort(), [B, C].sort())
    const queued = await admin(db, 'select body from net.http_requests')
    assert.deepEqual(queued.map((r) => r.body), [{ kind: 'huddle_deleted', id: deletion.id }])

    const targets = await service(db, 'select * from push_targets($1, $2)', ['huddle_deleted', deletion.id])
    assert.deepEqual(targets.map((t) => t.user_id), [B], 'not Ada, who did it, and not Cy, who blocked her')
    assert.equal(targets[0].huddle_name, 'Family')
    assert.equal(targets[0].huddle_emoji, '🏔')
    assert.equal(targets[0].actor_name, 'Ada')
    assert.equal(targets[0].huddle_id, family.id)
  })

  it("leaves nothing the app can read about it", async () => {
    const { db, A, B, family } = await world()
    await remove(db, family.id, A)
    for (const uid of [A, B, null]) {
      await assert.rejects(q(db, uid, 'select * from huddle_deletions'), /row-level security|permission denied/)
    }
  })
})
