// The delete-huddle edge function: who may delete a huddle, and which of its
// files go. Runs the function's own TypeScript (Node strips the types)
// against fake Supabase services; the database side is in
// huddle-deletion.test.mjs.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { handleDeleteHuddle } from '../functions/delete-huddle/handler.ts'

const HUDDLE = '0f8fad5b-d9cb-469f-a165-70867728950e'
const KEEPER = '7c9e6679-7425-40de-944b-e07fc1f90ae7'

function request(body = { huddle_id: HUDDLE }, { token = 'access', method = 'POST' } = {}) {
  return new Request('https://p.supabase.co/functions/v1/delete-huddle', {
    method,
    headers: token ? { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } : {},
    body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
  })
}

/** Fake services: `files` in the huddle's folder, `kept` returned by delete_huddle. */
function fake({ user = KEEPER, refusal = null, kept = [], files = [], failRemove = false, failList = false } = {}) {
  const calls = { deleteRows: [], removed: [], logs: [] }
  const services = {
    async authenticate(token) { return token === 'access' ? user : null },
    async deleteRows(huddleId, userId) {
      calls.deleteRows.push([huddleId, userId])
      if (refusal) throw new Error(refusal)
      return kept
    },
    async listFiles(huddleId) {
      if (failList) throw new Error('storage down')
      return files.map((name) => `${huddleId}/${name}`)
    },
    async removeFiles(paths) {
      if (failRemove) throw new Error('storage down')
      calls.removed.push(...paths)
    },
    log(event, detail) { calls.logs.push(detail ? `${event} ${detail}` : event) },
  }
  return { services, calls }
}

describe('delete-huddle', () => {
  it('needs a signed-in caller, a POST and a huddle id', async () => {
    const { services, calls } = fake()
    assert.equal((await handleDeleteHuddle(request({}, { token: null }), services)).status, 401)
    assert.equal((await handleDeleteHuddle(request({}, { token: 'stolen' }), services)).status, 401)
    assert.equal((await handleDeleteHuddle(request(undefined, { method: 'GET' }), services)).status, 405)
    assert.equal((await handleDeleteHuddle(request({ huddle_id: 'family' }), services)).status, 400)
    assert.equal((await handleDeleteHuddle(request('not json'), services)).status, 400)
    assert.deepEqual(calls.deleteRows, [], 'nothing deleted')
  })

  it("deletes the huddle's rows as the caller, then every file in its folder", async () => {
    const { services, calls } = fake({ files: ['a.jpg', 'b.jpg', 'b.mp4'] })
    const response = await handleDeleteHuddle(request({ huddle_id: HUDDLE.toUpperCase() }), services)
    assert.equal(response.status, 200)
    assert.deepEqual(await response.json(), { deleted: true })
    assert.deepEqual(calls.deleteRows, [[HUDDLE, KEEPER]], 'the lowercase id the folders use')
    assert.deepEqual(calls.removed, [`${HUDDLE}/a.jpg`, `${HUDDLE}/b.jpg`, `${HUDDLE}/b.mp4`])
  })

  it("keeps a reported deposit's files", async () => {
    const { services, calls } = fake({ files: ['a.jpg', 'r.jpg', 'r.mp4'], kept: [`${HUDDLE}/r.jpg`, `${HUDDLE}/r.mp4`] })
    await handleDeleteHuddle(request(), services)
    assert.deepEqual(calls.removed, [`${HUDDLE}/a.jpg`])
  })

  it('deletes many files a hundred at a time', async () => {
    const files = Array.from({ length: 250 }, (_, i) => `${i}.jpg`)
    const { services, calls } = fake({ files })
    let batches = 0
    const remove = services.removeFiles
    services.removeFiles = async (paths) => { batches++; assert.ok(paths.length <= 100); await remove(paths) }
    await handleDeleteHuddle(request(), services)
    assert.equal(batches, 3)
    assert.equal(calls.removed.length, 250)
  })

  it("refuses anyone but the keeper, and an unknown huddle, deleting nothing", async () => {
    for (const [refusal, status] of [['not_keeper', 403], ['huddle_not_found', 404]]) {
      const { services, calls } = fake({ refusal, files: ['a.jpg'] })
      const response = await handleDeleteHuddle(request(), services)
      assert.equal(response.status, status)
      assert.deepEqual(await response.json(), { error: refusal })
      assert.deepEqual(calls.removed, [], 'no file touched')
    }
  })

  it('a database error is a 500 that shows no detail', async () => {
    const { services, calls } = fake({ refusal: 'connection reset by peer' })
    const response = await handleDeleteHuddle(request(), services)
    assert.equal(response.status, 500)
    assert.deepEqual(await response.json(), { error: 'delete_failed' })
    assert.deepEqual(calls.logs, ['delete_huddle_failed connection reset by peer'])
  })

  it('once the huddle is gone, a Storage failure is logged, not an error for the keeper', async () => {
    for (const failure of [{ failRemove: true }, { failList: true }]) {
      const { services, calls } = fake({ files: ['a.jpg'], ...failure })
      const response = await handleDeleteHuddle(request(), services)
      assert.equal(response.status, 200)
      assert.ok(calls.logs.some((l) => l.startsWith('file_cleanup_failed') || l.startsWith('file_list_failed')), calls.logs.join(' | '))
    }
  })
})
