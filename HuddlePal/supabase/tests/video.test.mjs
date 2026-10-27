// Video drops: a deposit may be a clip of up to 6 seconds, posted only with
// HuddlePals+. It is two Storage objects under one photo key: the poster
// at storage_path (a JPEG, so app builds from before videos show a photo)
// and the clip at video_path, the same path ending in .mp4. Anyone in the
// huddle can watch it, and it stays once its poster's Plus ends.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  freshDatabase, q, admin, serverToday, signUp, createHuddle, joinHuddle, deposit, videoDeposit,
  grantPlus, endPlus, WRAPPED_KEY, randomUUID,
} from './harness.mjs'

const RLS_DENIED = /row-level security|permission denied/

/** A: keeper of H, with Plus. B: member of H, free. */
async function world() {
  const db = await freshDatabase()
  const A = await signUp(db, 'Ada')
  const B = await signUp(db, 'Ben')
  const H = await createHuddle(db, A, 'Family')
  await joinHuddle(db, B, H.invite_code)
  const plus = await grantPlus(db, A)
  return { db, A, B, H, plus, today: await serverToday(db) }
}

/** Inserts a deposit row as `uid` with exactly these media fields. */
const insert = (db, uid, h, day, { storagePath, videoPath = null, mediaType = 'photo', durationMs = null }) =>
  q(db, uid,
    `insert into deposits (huddle_id, author_id, storage_path, video_path, media_type, duration_ms, wrapped_photo_key, day_key)
     values ($1, $2, $3, $4, $5, $6, $7, $8) returning *`,
    [h.id, uid, storagePath, videoPath, mediaType, durationMs, WRAPPED_KEY, day])

describe('posting a video', () => {
  it('a deposit is a photo unless it says otherwise, as every app build before videos posts them', async () => {
    const { db, B, H, today } = await world()
    const dep = await deposit(db, B, H.id, today)
    assert.equal(dep.media_type, 'photo')
    assert.equal(dep.video_path, null)
    assert.equal(dep.duration_ms, null)
  })

  it('takes Plus: a free member is refused, a Plus member posts', async () => {
    const { db, A, B, H, today } = await world()
    await assert.rejects(videoDeposit(db, B, H.id, today), RLS_DENIED)
    const dep = await videoDeposit(db, A, H.id, today, { durationMs: 5800 })
    assert.equal(dep.media_type, 'video')
    assert.equal(dep.duration_ms, 5800)
  })

  it('Plus has to be on when the video is posted: lapsed is refused, a grace period is fine', async () => {
    const { db, A, B, H, plus, today } = await world()
    await endPlus(db, plus)
    await assert.rejects(videoDeposit(db, A, H.id, today), RLS_DENIED, 'lapsed between recording and posting')
    await grantPlus(db, B, { expiresIn: '-1 day', graceIn: '3 days' })
    await videoDeposit(db, B, H.id, today)
  })

  it('one deposit a day: a photo or a video, never both', async () => {
    const { db, A, H, today } = await world()
    await videoDeposit(db, A, H.id, today)
    await assert.rejects(deposit(db, A, H.id, today), /duplicate key/)
  })

  it('a video stays, for everyone in the huddle, once its poster\'s Plus ends', async () => {
    const { db, A, B, H, plus, today } = await world()
    const dep = await videoDeposit(db, A, H.id, today)
    await endPlus(db, plus)
    assert.deepEqual(await q(db, B, 'select id, media_type, video_path from deposits'), [
      { id: dep.id, media_type: 'video', video_path: dep.video_path },
    ])
  })
})

describe('the shape of a video deposit', () => {
  it('its clip is the poster\'s path ending in .mp4, and only a video has one', async () => {
    const { db, A, H, today } = await world()
    const name = `${H.id}/${randomUUID()}`
    const refused = [
      [{ storagePath: `${name}.jpg`, mediaType: 'video' }, 'a video with no clip'],
      [{ storagePath: `${name}.jpg`, videoPath: `${name}.mp4` }, 'a photo with a clip'],
      [{ storagePath: `${name}.jpg`, videoPath: `${H.id}/${randomUUID()}.mp4`, mediaType: 'video' }, 'a clip under another name'],
      [{ storagePath: `${name}.jpg`, videoPath: `${randomUUID()}/${name.split('/')[1]}.mp4`, mediaType: 'video' }, 'a clip in another folder'],
      [{ storagePath: `${name}.mp4`, videoPath: `${name}.mp4`, mediaType: 'video' }, 'a poster that is not a JPEG'],
      [{ storagePath: `${name}.jpg`, videoPath: `${name}.mp4`, mediaType: 'video', durationMs: 6200 }, 'longer than 6 seconds'],
      [{ storagePath: `${name}.jpg`, videoPath: `${name}.mp4`, mediaType: 'video', durationMs: 0 }, 'no length'],
      [{ storagePath: `${name}.jpg`, durationMs: 1000 }, 'a photo with a length'],
      [{ storagePath: `${name}.jpg`, mediaType: 'gif' }, 'not a photo or a video'],
    ]
    for (const [fields, why] of refused) {
      await assert.rejects(insert(db, A, H, today, fields), /check constraint/, why)
    }
    const [ok] = await insert(db, A, H, today, { storagePath: `${name}.jpg`, videoPath: `${name}.mp4`, mediaType: 'video', durationMs: 6000 })
    assert.equal(ok.video_path, `${name}.mp4`)
  })

  it('uppercase uuids, as the app writes them, pair up the same way', async () => {
    const { db, A, H, today } = await world()
    const name = `${H.id}/${randomUUID().toUpperCase()}`
    await insert(db, A, H, today, { storagePath: `${name}.jpg`, videoPath: `${name}.mp4`, mediaType: 'video' })
  })
})

describe('storage: video clips', () => {
  const upload = (db, uid, name) => q(db, uid, `insert into storage.objects (bucket_id, name) values ('deposits', $1)`, [name])

  it('only a member with Plus uploads a clip; anyone in the huddle uploads a JPEG', async () => {
    const { db, A, B, H } = await world()
    await assert.rejects(upload(db, B, `${H.id}/${randomUUID()}.mp4`), RLS_DENIED)
    await assert.rejects(upload(db, B, `${H.id}/${randomUUID()}.MP4`), RLS_DENIED, 'whatever the case')
    await upload(db, B, `${H.id}/${randomUUID()}.jpg`)
    await upload(db, A, `${H.id}/${randomUUID()}.mp4`)
  })

  it('Plus opens no other huddle\'s folder', async () => {
    const { db, A } = await world()
    const C = await signUp(db, 'Cy')
    const other = await createHuddle(db, C, 'Other')
    await assert.rejects(upload(db, A, `${other.id}/${randomUUID()}.mp4`), RLS_DENIED)
  })

  it('every member can download a clip, Plus or not', async () => {
    const { db, A, B, H } = await world()
    const name = `${H.id}/${randomUUID()}.mp4`
    await upload(db, A, name)
    assert.deepEqual(await q(db, B, 'select name from storage.objects where name = $1', [name]), [{ name }])
  })
})

describe('the media type in notifications', () => {
  it('push_media_type says what a deposit, a comment\'s or a reaction\'s deposit is', async () => {
    const { db, A, B, H, today } = await world()
    const video = await videoDeposit(db, A, H.id, today)
    const photo = await deposit(db, B, H.id, today)
    const [comment] = await q(db, B, `insert into comments (deposit_id, user_id, body) values ($1, $2, 'wow') returning id`, [video.id, B])
    const [reaction] = await q(db, A, `insert into reactions (deposit_id, user_id, emoji) values ($1, $2, '🔥') returning id`, [photo.id, A])
    const [membership] = await admin(db, 'select id from memberships where user_id = $1', [B])
    const kind = async (k, id) => (await admin(db, 'select push_media_type($1, $2) m', [k, id]))[0].m
    assert.equal(await kind('deposit', video.id), 'video')
    assert.equal(await kind('deposit', photo.id), 'photo')
    assert.equal(await kind('comment', comment.id), 'video')
    assert.equal(await kind('reaction', reaction.id), 'photo')
    assert.equal(await kind('join', membership.id), null)
    await assert.rejects(q(db, A, 'select push_media_type($1, $2)', ['deposit', video.id]), /permission denied/)
  })
})
