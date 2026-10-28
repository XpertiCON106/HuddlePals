// delete_huddle(): a keeper deletes their huddle. Everyone is removed and
// everything in it goes, except a reported deposit, which is kept for the
// operator; everyone else who was in it is told. The delete-huddle edge
// function that calls it, and deletes the files, is in delete-huddle.test.mjs.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  freshDatabase, q, admin, service, affected, serverToday, signUp, createHuddle, joinHuddle, deposit, videoDeposit,
  grantPlus, PUBLIC_KEY, WRAPPED_KEY, randomUUID, storeObject,
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

function deletedHuddles(value) {
  const rows = typeof value === 'string' ? JSON.parse(value) : value
  return rows.map((row) => ({
    huddle_id: row.huddle_id,
    kept_paths: [...row.kept_paths].sort(),
  })).sort((a, b) => (a.huddle_id < b.huddle_id ? -1 : a.huddle_id > b.huddle_id ? 1 : 0))
}

const deleteSole = async (db, uid) =>
  deletedHuddles((await service(db, 'select delete_sole_huddles($1) as deleted', [uid]))[0].deleted)

describe('delete_sole_huddles', () => {
  it('only the service role can call it, and it is not security definer', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    for (const caller of [A, null]) {
      await assert.rejects(q(db, caller, 'select delete_sole_huddles($1)', [A]), DENIED)
    }
    assert.deepEqual(
      await admin(db, `select prosecdef, array_to_string(proconfig, ',') as config from pg_proc where proname = 'delete_sole_huddles'`),
      [{ prosecdef: false, config: 'search_path=public' }],
    )
  })

  it('deletes a huddle whose last member is going, keeps a reported deposit, and tells nobody', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const alone = await createHuddle(db, A, 'Alone')
    await joinHuddle(db, B, alone.invite_code)
    const today = await serverToday(db)
    const photoPath = `${alone.id.toUpperCase()}/${randomUUID().toUpperCase()}.jpg`
    const [photo] = await q(db, A,
      `insert into deposits (huddle_id, author_id, storage_path, wrapped_photo_key, day_key, caption)
       values ($1, $2, $3, $4, $5, 'reported') returning *`,
      [alone.id, A, photoPath, WRAPPED_KEY, today])
    await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [photo.id, A])
    await q(db, B, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'hm')`, [photo.id, B])
    const [photoReport] = await q(db, B,
      'insert into reports (reporter_id, deposit_id, photo_key) values ($1, $2, $3) returning id',
      [B, photo.id, PUBLIC_KEY('P')])
    await affected(db, B, 'delete from memberships where user_id = $1 and huddle_id = $2', [B, alone.id])
    await grantPlus(db, A)
    const video = await videoDeposit(db, A, alone.id, await serverToday(db, -1))
    await q(db, A, 'insert into reports (reporter_id, deposit_id, photo_key) values ($1, $2, $3)', [A, video.id, PUBLIC_KEY('V')])
    const plain = await deposit(db, A, alone.id, await serverToday(db, -2))
    for (const name of [photo.storage_path, video.storage_path, video.video_path, plain.storage_path]) await storeObject(db, name)
    const bens = await createHuddle(db, B, 'Bens')
    await admin(db, `insert into vault.secrets (name, secret) values ('push_function_url', 'https://p.supabase.co/functions/v1/send-push'), ('push_webhook_secret', 'shh')`)

    const deleted = await deleteSole(db, A)

    assert.deepEqual(deleted, [{
      huddle_id: alone.id,
      kept_paths: [photo.storage_path, video.storage_path, video.video_path].sort(),
    }])
    assert.equal(photo.storage_path, photoPath, 'the uppercase path the app wrote is what gets kept')
    assert.equal(await count(db, 'huddles where id = $1', [alone.id]), 0)
    for (const table of ['memberships', 'deposits', 'huddle_keys', 'huddle_invite_keys']) {
      assert.equal(await count(db, `${table} where huddle_id = $1`, [alone.id]), 0, table)
    }
    assert.equal(await count(db, 'reactions where deposit_id = $1', [photo.id]), 0)
    assert.equal(await count(db, 'comments where deposit_id = $1', [photo.id]), 0)
    assert.equal(await count(db, 'deposits where id = $1', [plain.id]), 0, 'an unreported post goes')
    assert.equal(await count(db, 'huddles where id = $1', [bens.id]), 1, "someone else's huddle stays")
    assert.equal(await count(db, 'profiles where id = $1', [A]), 1, 'the account itself is still here')

    const preserved = await admin(db, 'select deposit_id, photo_key, note, report_ids, media_type, storage_path, video_path from preserved_photos order by media_type')
    const byDeposit = Object.fromEntries(preserved.map((p) => [p.deposit_id, p]))
    assert.equal(byDeposit[photo.id].photo_key, PUBLIC_KEY('P'))
    assert.equal(byDeposit[photo.id].note, 'Kept when its last member deleted their account')
    assert.equal(byDeposit[photo.id].storage_path, photoPath)
    assert.deepEqual(byDeposit[photo.id].report_ids, [photoReport.id])
    assert.equal(byDeposit[video.id].media_type, 'video')
    assert.equal(byDeposit[video.id].video_path, video.video_path)
    assert.deepEqual(
      await admin(db, 'select reporter_id, deposit_id, photo_key from reports where id = $1', [photoReport.id]),
      [{ reporter_id: B, deposit_id: null, photo_key: PUBLIC_KEY('P') }],
    )
    for (const name of [photo.storage_path, video.storage_path, video.video_path, plain.storage_path]) {
      assert.equal(await count(db, 'storage.objects where name = $1', [name]), 1, `${name} stays for the edge function`)
    }
    assert.deepEqual(await admin(db, 'select 1 from huddle_deletions'), [])
    assert.deepEqual(await admin(db, 'select 1 from net.http_requests'), [])
    assert.deepEqual(await deleteSole(db, A), [], 'running it again finds nothing')
  })

  it('leaves a huddle that still has someone else, and that post stays with a null author after the account goes', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const shared = await createHuddle(db, A, 'Shared')
    await joinHuddle(db, B, shared.invite_code)
    const alone = await createHuddle(db, A, 'Alone')
    const today = await serverToday(db)
    const sharedPhoto = await deposit(db, A, shared.id, today, { caption: 'us' })
    const alonePhoto = await deposit(db, A, alone.id, today)
    await q(db, B, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'hi')`, [sharedPhoto.id, B])
    await storeObject(db, sharedPhoto.storage_path)
    await storeObject(db, alonePhoto.storage_path)

    assert.deepEqual(await deleteSole(db, A), [{ huddle_id: alone.id, kept_paths: [] }])
    assert.equal(await count(db, 'huddles where id = $1', [alone.id]), 0)
    assert.equal(await count(db, 'deposits where id = $1', [alonePhoto.id]), 0)
    assert.deepEqual(
      await admin(db, 'select author_id, caption from deposits where id = $1', [sharedPhoto.id]),
      [{ author_id: A, caption: 'us' }],
    )
    assert.equal(await count(db, 'storage.objects where name = $1', [sharedPhoto.storage_path]), 1)

    await admin(db, 'delete from auth.users where id = $1', [A])

    assert.deepEqual(
      await admin(db, 'select author_id, caption from deposits where id = $1', [sharedPhoto.id]),
      [{ author_id: null, caption: 'us' }],
    )
    assert.deepEqual(
      await admin(db, 'select user_id, role from memberships where huddle_id = $1', [shared.id]),
      [{ user_id: B, role: 'keeper' }],
    )
    assert.equal((await q(db, B, 'select * from deposits')).length, 1)
    assert.equal((await q(db, B, 'select body from comments'))[0].body, 'hi')
    assert.equal(await count(db, 'huddles where id = $1', [shared.id]), 1)
    assert.equal(await count(db, 'storage.objects where name = $1', [sharedPhoto.storage_path]), 1, 'the shared photo stays')
  })

  it('deletes every huddle the user is alone in, and no other', async () => {
    const db = await freshDatabase()
    const A = await signUp(db, 'Ada')
    const B = await signUp(db, 'Ben')
    const one = await createHuddle(db, A, 'One')
    const two = await createHuddle(db, A, 'Two')
    const shared = await createHuddle(db, B, 'Shared')
    await joinHuddle(db, A, shared.invite_code)
    const deleted = await deleteSole(db, A)
    assert.deepEqual(deleted.map((row) => row.huddle_id), [one.id, two.id].sort())
    assert.equal(await count(db, 'huddles where id = $1', [shared.id]), 1)
    const roles = Object.fromEntries((await admin(db, 'select user_id, role from memberships where huddle_id = $1', [shared.id])).map((r) => [r.user_id, r.role]))
    assert.deepEqual(roles, { [B]: 'keeper', [A]: 'member' })
  })
})
