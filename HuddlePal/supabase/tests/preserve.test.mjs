// remove_reported_photo(): a reported photo leaves its huddle, and what's
// needed to find and open it again is kept for NCMEC's one-year
// preservation. Operator-only: the app and the anon key can't reach it.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  freshDatabase, q, admin, serverToday, signUp, createHuddle, joinHuddle, deposit, storeObject,
  PUBLIC_KEY, randomUUID,
} from './harness.mjs'

/** Ben's photo in Ada's huddle, with a reaction, a comment, its file, and Ada's report. */
async function world() {
  const db = await freshDatabase()
  const A = await signUp(db, 'Ada')
  const B = await signUp(db, 'Ben')
  const h = await createHuddle(db, A)
  await joinHuddle(db, B, h.invite_code)
  const dep = await deposit(db, B, h.id, await serverToday(db), { caption: 'reported' })
  await storeObject(db, dep.storage_path)
  await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥')`, [dep.id, A])
  await q(db, A, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'hm')`, [dep.id, A])
  const [report] = await q(db, A,
    'insert into reports (reporter_id, deposit_id, photo_key) values ($1, $2, $3) returning id', [A, dep.id, PUBLIC_KEY('K')])
  return { db, A, h, dep, report }
}

describe('removing a reported photo', () => {
  it('takes it out of the huddle and keeps what finds and opens it', async () => {
    const { db, A, h, dep, report } = await world()
    const [{ remove_reported_photo: path }] = await admin(db, `select remove_reported_photo($1, true, 'CyberTip 123')`, [dep.id])

    assert.equal(path, dep.storage_path)
    for (const table of ['deposits where id', 'reactions where deposit_id', 'comments where deposit_id']) {
      assert.deepEqual(await admin(db, `select 1 from ${table} = $1`, [dep.id]), [], table)
    }
    assert.deepEqual(await q(db, A, 'select id from deposits'), [], 'gone for members')
    const [kept] = await admin(db, 'select * from preserved_photos')
    assert.equal(kept.deposit_id, dep.id)
    assert.equal(kept.huddle_id, h.id)
    assert.equal(kept.storage_path, dep.storage_path)
    assert.equal(kept.wrapped_photo_key, dep.wrapped_photo_key)
    assert.equal(kept.photo_key, PUBLIC_KEY('K'))
    assert.equal(kept.caption, 'reported')
    assert.deepEqual(kept.report_ids, [report.id])
    assert.equal(kept.note, 'CyberTip 123')
    const days = (kept.keep_until - kept.removed_at) / 86_400_000
    assert.ok(days >= 365 && days <= 366, `kept for a year (${days} days)`)
    assert.deepEqual(
      await admin(db, 'select deposit_id, photo_key from reports where id = $1', [report.id]),
      [{ deposit_id: null, photo_key: PUBLIC_KEY('K') }],
      'the report stays',
    )
    assert.equal((await admin(db, 'select 1 from storage.objects where name = $1', [dep.storage_path])).length, 1, 'the file stays')
  })

  it('without preserving, removes it and keeps nothing', async () => {
    const { db, dep } = await world()
    await admin(db, 'select remove_reported_photo($1, false)', [dep.id])
    assert.deepEqual(await admin(db, 'select 1 from deposits where id = $1', [dep.id]), [])
    assert.deepEqual(await admin(db, 'select 1 from preserved_photos'), [])
  })

  it('refuses a photo that does not exist and changes nothing', async () => {
    const { db } = await world()
    await assert.rejects(admin(db, 'select remove_reported_photo($1)', [randomUUID()]), /deposit_not_found/)
    assert.deepEqual(await admin(db, 'select 1 from preserved_photos'), [])
    assert.equal((await admin(db, 'select 1 from deposits')).length, 1)
  })

  it('the app and the anon key can neither call it nor read what it keeps', async () => {
    const { db, A, dep } = await world()
    await assert.rejects(q(db, A, 'select remove_reported_photo($1)', [dep.id]), /permission denied/)
    await assert.rejects(q(db, null, 'select remove_reported_photo($1)', [dep.id]), /permission denied/)
    await admin(db, 'select remove_reported_photo($1)', [dep.id])
    await assert.rejects(q(db, A, 'select * from preserved_photos'), /permission denied/)
    await assert.rejects(q(db, A, 'select * from expired_preserved_photos()'), /permission denied/)
  })

  it('lists only what is past its keep-until date', async () => {
    const { db, dep } = await world()
    await admin(db, 'select remove_reported_photo($1)', [dep.id])
    assert.deepEqual(await admin(db, 'select * from expired_preserved_photos()'), [])
    await admin(db, `update preserved_photos set keep_until = now() - interval '1 day'`)
    assert.deepEqual(await admin(db, 'select storage_path from expired_preserved_photos()'), [{ storage_path: dep.storage_path }])
  })
})
