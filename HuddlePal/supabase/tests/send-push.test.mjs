// The send-push edge function: APNs provider tokens, the exact request APNs
// gets, what each APNs answer means, and the handler's checks. Runs the
// function's own TypeScript (Node strips the types) against a fake APNs and
// fake Supabase services; who gets notified is in push.test.mjs.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  apnsConfigFromEnv, makeProviderToken, ProviderTokenCache, sendAlert,
} from '../functions/send-push/apns.ts'
import { alertFor, handleSendPush } from '../functions/send-push/handler.ts'

const SECRET = 'push-webhook-secret-for-tests'
const HUDDLE = '6f9619ff-8b86-d011-b42d-00c04fc964ff'
const EVENT = '7c9e6679-7425-40de-944b-e07fc1f90ae7'
const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'))

/** An APNs key as Apple hands it out: a PKCS#8 .p8 file. */
async function apnsConfig() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const der = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64')
  const pem = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----\n`
  return { config: { keyId: 'APNSKEY123', teamId: 'TEAM123456', privateKey: pem, bundleId: 'com.huddlepals.ios' }, publicKey: pair.publicKey }
}

const verifies = async (jwt, publicKey) => {
  const [header, claims, signature] = jwt.split('.')
  return crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' }, publicKey, Buffer.from(signature, 'base64url'), new TextEncoder().encode(`${header}.${claims}`),
  )
}

/** Stands in for api.push.apple.com / api.sandbox.push.apple.com. */
function fakeApns(answer = () => ({ status: 200 })) {
  const calls = []
  const fetch = async (url, init) => {
    const call = { url: String(url), method: init.method, headers: init.headers, body: JSON.parse(init.body) }
    calls.push(call)
    const reply = answer(call)
    if (reply instanceof Error) throw reply
    return new Response(reply.body ? JSON.stringify(reply.body) : null, { status: reply.status })
  }
  return { calls, fetch }
}

const target = (overrides = {}) => ({
  user_id: 'u1', token: 'a'.repeat(64), environment: 'production',
  huddle_id: HUDDLE, huddle_name: 'Family', huddle_emoji: '🏔', actor_name: 'Maya', detail: null,
  ...overrides,
})

describe('APNs provider token', () => {
  it('is an ES256 JWT naming the key and the team, signed with the APNs key', async () => {
    const { config, publicKey } = await apnsConfig()
    const jwt = await makeProviderToken(config, 1_800_000_000)
    const [header, claims] = jwt.split('.')
    assert.deepEqual(decode(header), { alg: 'ES256', kid: 'APNSKEY123' })
    assert.deepEqual(decode(claims), { iss: 'TEAM123456', iat: 1_800_000_000 })
    assert.ok(await verifies(jwt, publicKey))
  })

  it('accepts a .p8 pasted with escaped newlines', async () => {
    const { config, publicKey } = await apnsConfig()
    assert.ok(await verifies(await makeProviderToken({ ...config, privateKey: config.privateKey.replace(/\n/g, '\\n') }), publicKey))
  })

  it('is reused for 50 minutes, then replaced (APNs throttles frequent new tokens)', async () => {
    const { config } = await apnsConfig()
    const cache = new ProviderTokenCache(config)
    const first = await cache.get(1_800_000_000)
    assert.equal(await cache.get(1_800_000_000 + 49 * 60), first)
    const later = await cache.get(1_800_000_000 + 50 * 60)
    assert.notEqual(later, first)
    assert.equal(decode(later.split('.')[1]).iat, 1_800_000_000 + 50 * 60)
  })

  it('reads the four APNS_* secrets, and needs all of them', () => {
    const env = { APNS_KEY_ID: 'k', APNS_TEAM_ID: 't', APNS_PRIVATE_KEY: 'p', APNS_BUNDLE_ID: 'b' }
    assert.deepEqual(apnsConfigFromEnv((n) => env[n]), { keyId: 'k', teamId: 't', privateKey: 'p', bundleId: 'b' })
    for (const missing of Object.keys(env)) {
      assert.equal(apnsConfigFromEnv((n) => (n === missing ? undefined : env[n])), null, missing)
    }
  })
})

describe('sending one alert', () => {
  const alert = { title: '🏔 Family', body: 'Maya posted a photo.', huddleId: HUDDLE }

  it('posts to the right host for the token’s environment, with token auth and the app as topic', async () => {
    const { config } = await apnsConfig()
    for (const [environment, host] of [['production', 'https://api.push.apple.com'], ['sandbox', 'https://api.sandbox.push.apple.com']]) {
      const apns = fakeApns()
      const outcome = await sendAlert(apns.fetch, config, 'provider.jwt.token', 'ab'.repeat(32), environment, alert, 1_800_000_000)
      assert.deepEqual(outcome, { status: 'sent' })
      const [call] = apns.calls
      assert.equal(call.url, `${host}/3/device/${'ab'.repeat(32)}`)
      assert.equal(call.method, 'POST')
      assert.deepEqual(call.headers, {
        authorization: 'bearer provider.jwt.token',
        'apns-topic': 'com.huddlepals.ios',
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': String(1_800_000_000 + 86_400),
        'content-type': 'application/json',
      })
      assert.deepEqual(call.body, {
        aps: { alert: { title: '🏔 Family', body: 'Maya posted a photo.' }, sound: 'default', 'thread-id': HUDDLE },
        huddle_id: HUDDLE,
      })
    }
  })

  it('tells an invalid token (410, BadDeviceToken) from any other failure', async () => {
    const { config } = await apnsConfig()
    const cases = [
      [{ status: 410, body: { reason: 'Unregistered' } }, { status: 'invalid_token', reason: 'Unregistered' }],
      [{ status: 400, body: { reason: 'BadDeviceToken' } }, { status: 'invalid_token', reason: 'BadDeviceToken' }],
      [{ status: 403, body: { reason: 'InvalidProviderToken' } }, { status: 'failed', httpStatus: 403, reason: 'InvalidProviderToken' }],
      [{ status: 429, body: { reason: 'TooManyRequests' } }, { status: 'failed', httpStatus: 429, reason: 'TooManyRequests' }],
      [{ status: 500 }, { status: 'failed', httpStatus: 500, reason: '' }],
      [new TypeError('fetch failed'), { status: 'failed', httpStatus: 0, reason: 'TypeError' }],
    ]
    for (const [reply, expected] of cases) {
      const apns = fakeApns(() => reply)
      assert.deepEqual(await sendAlert(apns.fetch, config, 'jwt', 'ab'.repeat(32), 'production', alert), expected)
    }
  })
})

describe('what a notification says', () => {
  it('names the huddle and who did what; never a caption or a comment', () => {
    assert.deepEqual(alertFor('deposit', target()), { title: '🏔 Family', body: 'Maya posted a photo.', huddleId: HUDDLE })
    assert.equal(alertFor('comment', target()).body, 'Maya commented on your photo.')
    assert.equal(alertFor('reaction', target({ detail: '🔥' })).body, 'Maya reacted 🔥 to your photo.')
    assert.equal(alertFor('reaction', target()).body, 'Maya reacted to your photo.')
    assert.equal(alertFor('join', target({ actor_name: 'Sam' })).body, 'Sam joined the huddle.')
    assert.equal(alertFor('deposit', target({ actor_name: null })).body, 'Someone posted a photo.', 'an account deleted since')
  })

  it('says video for a video', () => {
    assert.equal(alertFor('deposit', target(), 'video').body, 'Maya posted a video.')
    assert.equal(alertFor('comment', target(), 'video').body, 'Maya commented on your video.')
    assert.equal(alertFor('reaction', target({ detail: '🔥' }), 'video').body, 'Maya reacted 🔥 to your video.')
    assert.equal(alertFor('reaction', target(), 'video').body, 'Maya reacted to your video.')
    assert.equal(alertFor('deposit', target(), null).body, 'Maya posted a photo.')
  })
})

describe('send-push handler', () => {
  async function setUp({ targets = [target()], apnsAnswer, withApns = true, webhookSecret = SECRET, failTargets, mediaType = 'photo' } = {}) {
    const { config } = await apnsConfig()
    const apns = fakeApns(apnsAnswer)
    const asked = []
    const askedMedia = []
    const removed = []
    const logs = []
    const services = {
      webhookSecret,
      apns: withApns ? config : null,
      providerToken: async () => 'provider.jwt.token',
      targets: async (kind, id) => {
        asked.push([kind, id])
        if (failTargets) throw failTargets
        return targets
      },
      mediaType: async (kind, id) => {
        askedMedia.push([kind, id])
        if (mediaType instanceof Error) throw mediaType
        return mediaType
      },
      removeTokens: async (tokens) => { removed.push(...tokens) },
      fetch: apns.fetch,
      log: (event, detail) => logs.push(detail ? `${event} ${detail}` : event),
    }
    return { services, apns, asked, askedMedia, removed, logs }
  }

  const request = (body = { kind: 'deposit', id: EVENT }, { secret = SECRET, method = 'POST' } = {}) =>
    new Request('https://project.functions.test/send-push', {
      method,
      headers: { ...(secret ? { 'x-push-secret': secret } : {}), 'Content-Type': 'application/json' },
      body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
    })

  it('notifies every target, one alert per device', async () => {
    const targets = [target(), target({ user_id: 'u2', token: 'b'.repeat(64), environment: 'sandbox' })]
    const { services, apns, asked } = await setUp({ targets })
    const response = await handleSendPush(request(), services)
    assert.equal(response.status, 200)
    assert.deepEqual(await response.json(), { sent: 2, failed: 0, removed: 0 })
    assert.deepEqual(asked, [['deposit', EVENT]])
    assert.deepEqual(apns.calls.map((c) => c.url), [
      `https://api.push.apple.com/3/device/${'a'.repeat(64)}`,
      `https://api.sandbox.push.apple.com/3/device/${'b'.repeat(64)}`,
    ])
    assert.ok(apns.calls.every((c) => c.body.aps.alert.body === 'Maya posted a photo.'))
  })

  it('deletes the tokens APNs reports as invalid, and keeps the rest', async () => {
    const targets = [target(), target({ token: 'b'.repeat(64) }), target({ token: 'c'.repeat(64) }), target({ user_id: 'u3', token: 'b'.repeat(64) })]
    const answers = { a: { status: 200 }, b: { status: 410, body: { reason: 'Unregistered' } }, c: { status: 400, body: { reason: 'BadDeviceToken' } } }
    const { services, removed } = await setUp({ targets, apnsAnswer: (call) => answers[call.url.at(-1)] })
    const response = await handleSendPush(request(), services)
    assert.deepEqual(await response.json(), { sent: 1, failed: 0, removed: 2 })
    assert.deepEqual(removed.sort(), ['b'.repeat(64), 'c'.repeat(64)])
  })

  it('logs other failures without the token, the secret or the provider token', async () => {
    const { services, removed, logs } = await setUp({ apnsAnswer: () => ({ status: 403, body: { reason: 'InvalidProviderToken' } }) })
    const response = await handleSendPush(request(), services)
    assert.deepEqual(await response.json(), { sent: 0, failed: 1, removed: 0 })
    assert.deepEqual(removed, [])
    assert.ok(logs.includes('push_failed deposit 403 InvalidProviderToken'))
    const logged = logs.join('\n')
    for (const secret of ['a'.repeat(64), SECRET, 'provider.jwt.token']) assert.ok(!logged.includes(secret))
  })

  it('refuses a request without the shared secret, and touches nothing', async () => {
    for (const secret of [null, 'wrong', `${SECRET}x`, SECRET.slice(0, -1)]) {
      const { services, apns, asked } = await setUp()
      assert.equal((await handleSendPush(request(undefined, { secret }), services)).status, 401, String(secret))
      assert.deepEqual(asked, [])
      assert.deepEqual(apns.calls, [])
    }
  })

  it('refuses everything while PUSH_WEBHOOK_SECRET isn’t set', async () => {
    const { services, asked, logs } = await setUp({ webhookSecret: null })
    assert.equal((await handleSendPush(request(undefined, { secret: '' }), services)).status, 500)
    assert.deepEqual(asked, [])
    assert.deepEqual(logs, ['push_refused PUSH_WEBHOOK_SECRET not set'])
  })

  it('refuses a malformed event', async () => {
    for (const body of ['not json', { kind: 'deposit' }, { kind: 'delete_everything', id: EVENT }, { kind: 'deposit', id: 'x; drop table' }]) {
      const { services, asked } = await setUp()
      assert.equal((await handleSendPush(request(body), services)).status, 400, JSON.stringify(body))
      assert.deepEqual(asked, [])
    }
  })

  it('sends nothing without the APNs secrets, and says so in the log', async () => {
    const { services, apns, logs } = await setUp({ withApns: false })
    const response = await handleSendPush(request(), services)
    assert.equal(response.status, 200)
    assert.deepEqual(apns.calls, [])
    assert.deepEqual(logs, ['push_skipped APNS_* secrets not set'])
  })

  it('a failed target lookup is a 500 with the detail kept in the log', async () => {
    const { services, apns, logs } = await setUp({ failTargets: new Error('function push_targets does not exist') })
    const response = await handleSendPush(request(), services)
    assert.equal(response.status, 500)
    assert.deepEqual(await response.json(), { error: 'targets_failed' })
    assert.deepEqual(apns.calls, [])
    assert.ok(logs.includes('push_targets_failed function push_targets does not exist'))
  })

  it('answers only POST', async () => {
    const { services, asked } = await setUp()
    assert.equal((await handleSendPush(request(undefined, { method: 'GET' }), services)).status, 405)
    assert.deepEqual(asked, [])
  })

  it('says video when the deposit is one, asking once per event', async () => {
    const targets = [target(), target({ user_id: 'u2', token: 'b'.repeat(64) })]
    const { services, apns, askedMedia } = await setUp({ targets, mediaType: 'video' })
    await handleSendPush(request({ kind: 'comment', id: EVENT }), services)
    assert.deepEqual(askedMedia, [['comment', EVENT]])
    assert.ok(apns.calls.every((c) => c.body.aps.alert.body === 'Maya commented on your video.'))
  })

  it('a failed media lookup still notifies, as a photo; a join never asks', async () => {
    const failing = await setUp({ mediaType: new Error('push_media_type does not exist') })
    assert.equal((await handleSendPush(request(), failing.services)).status, 200)
    assert.equal(failing.apns.calls[0].body.aps.alert.body, 'Maya posted a photo.')
    assert.deepEqual(failing.logs.filter((l) => l.startsWith('push_media_type_failed')), ['push_media_type_failed push_media_type does not exist'])
    const join = await setUp({ targets: [target({ actor_name: 'Sam' })] })
    await handleSendPush(request({ kind: 'join', id: EVENT }), join.services)
    assert.deepEqual(join.askedMedia, [])
    assert.equal(join.apns.calls[0].body.aps.alert.body, 'Sam joined the huddle.')
  })

  it("says who deleted a huddle, by the name it had, and asks about no photo", async () => {
    const deleted = await setUp({ targets: [target({ actor_name: 'Ada' })] })
    assert.equal((await handleSendPush(request({ kind: 'huddle_deleted', id: EVENT }), deleted.services)).status, 200)
    assert.deepEqual(deleted.askedMedia, [])
    assert.equal(deleted.apns.calls[0].body.aps.alert.title, '🏔 Family')
    assert.equal(deleted.apns.calls[0].body.aps.alert.body, 'Ada deleted the huddle.')
  })
})
